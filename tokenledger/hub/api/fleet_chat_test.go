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
