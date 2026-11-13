package api

import (
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

// The entry's web chat routes (claude-fleet#3645, EPIC #3642 C3): a hub, a REAL
// agent on the control channel (C2's relay), and a small HTTP server on the
// login's $FLEET_CONF_DIR/webchat/chat.sock standing in for
// extras/web-chat/server.mjs. Only a signed-in person reaches it, only their own
// conversation, only at their home; every refusal says which.

// fakeChatService serves /api/* on <conf>/webchat/chat.sock and records what it
// saw. /api/turn writes one NDJSON line, waits for release, writes the second.
type fakeChatService struct {
	mu           sync.Mutex
	hits         []string // "<method> <path> person=<X-Fleet-Person> cookie=<Cookie>"
	clients      []string // each request's X-Fleet-Client (claude-fleet#4034)
	release      chan struct{}
	conversation func(w http.ResponseWriter)
	turn         func(w http.ResponseWriter) // set: /api/turn answers this way instead
}

func (f *fakeChatService) seen() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string(nil), f.hits...)
}

func setChatHome(t *testing.T, h *harness, person, machine, login string) {
	t.Helper()
	if _, err := h.srv.Store.SetEntryHome(store.EntryHome{Person: person, Machine: machine, Login: login, SetBy: "t", SetAt: time.Now()}); err != nil {
		t.Fatal(err)
	}
}

// chatDo sends one request to the entry; cookie nil = no credential.
func chatDo(t *testing.T, h *harness, method, path string, cookie *http.Cookie, hdr map[string]string, body string) *http.Response {
	t.Helper()
	var rd io.Reader
	if body != "" {
		rd = strings.NewReader(body)
	}
	req, _ := http.NewRequest(method, h.http.URL+path, rd)
	req.Header.Set("Accept", "application/json")
	if cookie != nil {
		req.AddCookie(cookie)
	}
	for k, v := range hdr {
		req.Header.Set(k, v)
	}
	c := *h.http.Client()
	c.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	resp, err := c.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { resp.Body.Close() })
	return resp
}

func chatCode(t *testing.T, resp *http.Response) string {
	t.Helper()
	var v struct {
		Code string `json:"code"`
	}
	b, _ := io.ReadAll(resp.Body)
	_ = json.Unmarshal(b, &v)
	return v.Code
}

func TestChatGateBounds(t *testing.T) {
	var g chatGate
	now := time.Now()
	for i := 0; i < 2; i++ {
		if why := g.admit("a", 2, 100, now); why != "" {
			t.Fatalf("admit %d: %s", i, why)
		}
	}
	if why := g.admit("a", 2, 100, now); why != "too_many" {
		t.Fatalf("third in flight: %q; want too_many", why)
	}
	if why := g.admit("b", 2, 100, now); why != "" {
		t.Fatalf("another person is not held by a's bound: %q", why)
	}
	g.release("a")
	g.release("a")
	var r chatGate
	for i := 0; i < 3; i++ {
		if why := r.admit("a", -1, 3, now); why != "" {
			t.Fatalf("token %d: %s", i, why)
		}
	}
	if why := r.admit("a", -1, 3, now); why != "rate" {
		t.Fatalf("fourth in the minute: %q; want rate", why)
	}
	if why := r.admit("a", -1, 3, now.Add(30*time.Second)); why != "" {
		t.Fatalf("half a minute later: %q; want admitted", why)
	}
}

// A relayed answer on the hub's origin: the service's cookies dropped, never
// sniffed, a file or a session view sandboxed whatever the service sent.
func TestChatRelayHeaders(t *testing.T) {
	for _, route := range []string{"conversation", "file", chatViewRoute} {
		sandbox := route != "conversation"
		resp := &http.Response{Header: http.Header{}, StatusCode: http.StatusOK, ContentLength: -1}
		resp.Header.Add("Set-Cookie", "a=1; Path=/")
		resp.Header.Add("Set-Cookie", "b=2; Path=/")
		resp.Header.Set("X-Content-Type-Options", "")
		resp.Header.Set("Content-Security-Policy", "default-src *")
		resp.Header.Set("Content-Type", "application/json; charset=utf-8")
		if err := chatRelayHeaders(resp, route); err != nil {
			t.Errorf("%s: %v", route, err)
		}
		if v := resp.Header.Values("Set-Cookie"); len(v) != 0 {
			t.Errorf("%s: Set-Cookie kept %q", route, v)
		}
		if resp.Header.Get("X-Content-Type-Options") != "nosniff" {
			t.Errorf("%s: headers %v", route, resp.Header)
		}
		want := "default-src *"
		if sandbox {
			want = chatRelaySandbox
		}
		if got := resp.Header.Get("Content-Security-Policy"); got != want {
			t.Errorf("%s: CSP %q; want %q", route, got, want)
		}
	}
}

// Only the types a route returns cross onto the hub's origin: JSON, NDJSON
// and event streams everywhere, any type for a (sandboxed) file; anything
// else — a page, a script, an unnamed body — is refused.
func TestChatRelayTypes(t *testing.T) {
	for _, c := range []struct {
		route, ct string
		status    int
		length    int64
		ok        bool
	}{
		{"conversation", "application/json; charset=utf-8", 200, -1, true},
		{"turn", "application/x-ndjson; charset=utf-8", 200, -1, true},
		{"warm", "text/event-stream", 200, -1, true},
		{chatViewRoute, "text/event-stream; charset=utf-8", 200, -1, true},
		{"studio/open", "text/html; charset=utf-8", 200, -1, false},
		{"migration", "text/html", 200, -1, false},
		{"warm", "application/javascript", 200, -1, false},
		{"conversation", "image/svg+xml", 200, -1, false},
		{chatViewRoute, "text/html", 200, -1, false},
		{"conversation", "", 200, -1, false},
		{"conversation", "", 200, 0, true},
		{"stop", "", http.StatusNoContent, -1, true},
		{"conversation", "not a type;;", 200, -1, false},
		{"file", "image/png", 200, -1, true},
		{"file", "text/html", 200, -1, true}, // under chatRelaySandbox
	} {
		resp := &http.Response{Header: http.Header{}, StatusCode: c.status, ContentLength: c.length}
		if c.ct != "" {
			resp.Header.Set("Content-Type", c.ct)
		}
		err := chatRelayHeaders(resp, c.route)
		if (err == nil) != c.ok {
			t.Errorf("%s %q (%d): err %v; want ok=%v", c.route, c.ct, c.status, err, c.ok)
		}
		if resp.Header.Get("X-Content-Type-Options") != "nosniff" {
			t.Errorf("%s %q: no nosniff", c.route, c.ct)
		}
		if c.route == "file" && resp.Header.Get("Content-Security-Policy") != chatRelaySandbox {
			t.Errorf("file %q: CSP %q", c.ct, resp.Header.Get("Content-Security-Policy"))
		}
	}
}
