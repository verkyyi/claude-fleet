package e2e

import (
	"sync"

	. "github.com/verkyyi/claude-fleet/tokenledger/hub/api"
	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"

	"bufio"
	"context"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func serveFakeChat(t *testing.T, conf string) *fakeChatService {
	t.Helper()
	if err := os.MkdirAll(filepath.Join(conf, "webchat"), 0o700); err != nil {
		t.Fatal(err)
	}
	ln, err := net.Listen("unix", filepath.Join(conf, "webchat", "chat.sock"))
	if err != nil {
		t.Fatal(err)
	}
	f := &fakeChatService{release: make(chan struct{})}
	srv := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		f.mu.Lock()
		f.hits = append(f.hits, r.Method+" "+r.URL.Path+" person="+r.Header.Get("X-Fleet-Person")+" cookie="+r.Header.Get("Cookie"))
		f.clients = append(f.clients, r.Header.Get("X-Fleet-Client"))
		f.queries = append(f.queries, r.URL.RawQuery)
		f.mu.Unlock()
		switch r.URL.Path {
		case "/api/conversation":
			f.mu.Lock()
			conversation := f.conversation
			f.mu.Unlock()
			if conversation != nil {
				conversation(w)
				return
			}
			w.Header().Set("Content-Type", "application/json")
			io.WriteString(w, `{"session":"s1","items":[]}`)
		case "/api/turn":
			f.mu.Lock()
			turn := f.turn
			f.mu.Unlock()
			if turn != nil {
				io.ReadAll(r.Body)
				turn(w)
				return
			}
			body, _ := io.ReadAll(r.Body)
			w.Header().Set("Content-Type", "application/x-ndjson")
			io.WriteString(w, `{"t":"start","echo":`+strconvQuote(string(body))+"}\n")
			w.(http.Flusher).Flush()
			select {
			case <-f.release:
			case <-time.After(10 * time.Second):
			}
			io.WriteString(w, `{"t":"done"}`+"\n")
		case "/api/file":
			w.Header().Set("Content-Type", "image/png")
			w.Header().Set("Cache-Control", "private, max-age=604800, immutable")
			io.WriteString(w, fakePNG)
		case "/api/view":
			// 只读 (task F481): one state, one batch of items, as the service streams them
			w.Header().Set("Content-Type", "text/event-stream")
			io.WriteString(w, `data: {"t":"state","agent":"claude","busy":true}`+"\n\n")
			io.WriteString(w, "id: 1\ndata: "+`{"t":"items","replace":true,"session":"s1","from":0,"items":[{"t":"text","d":"hi"},{"t":"tool_result","id":"x","text":"SECRET-OUTPUT"}],"q":`+strconvQuote(r.URL.RawQuery)+"}\n\n")
			w.(http.Flusher).Flush()
		case "/api/takeover", "/api/giveback":
			// 接管 / 交回 (task VV8F): the body the hub wrote, echoed
			body, _ := io.ReadAll(r.Body)
			w.Header().Set("Content-Type", "application/json")
			io.WriteString(w, `{"ok":true,"agent":"claude","got":`+strconvQuote(string(body))+`}`)
		case "/api/say":
			// 会话合一 (task PQ41): the body the hub wrote, echoed; "refuse" is refused
			body, _ := io.ReadAll(r.Body)
			w.Header().Set("Content-Type", "application/json")
			state := "sent"
			if strings.Contains(string(body), `"text":"refuse"`) {
				state = "refused"
			}
			io.WriteString(w, `{"delivery":"d1","state":"`+state+`","got":`+strconvQuote(string(body))+`}`)
		case "/api/stop", "/api/answer", "/api/ack":
			body, _ := io.ReadAll(r.Body)
			w.Header().Set("Content-Type", "application/json")
			io.WriteString(w, `{"ok":true,"got":`+strconvQuote(string(body))+`}`)
		case "/api/open":
			io.ReadAll(r.Body)
			w.Header().Set("Content-Type", "application/json")
			io.WriteString(w, `{"fid":"f-new","agent":"claude","state":"sent"}`)
		case "/api/new":
			w.Header().Set("Content-Type", "application/json")
			io.WriteString(w, `{"ok":true}`)
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	})}
	go srv.Serve(ln)
	t.Cleanup(func() { srv.Close() })
	return f
}

// fakePNG is what the fake service answers /api/file with.
const fakePNG = "\x89PNG\r\n\x1a\nfake-image-bytes"

func strconvQuote(s string) string { b, _ := json.Marshal(s); return string(b) }

// chatHarness: a fleet hub with sign-in, alice and bob on the list (bob an
// admin by the deploy), and a real agent serving the fake conversation service.
func chatHarness(t *testing.T) (h *harness, svc *fakeChatService, host, login string) {
	t.Helper()
	h = newFleetHarness(t)
	enablePeople(t, h, pAlice, pBob)
	h.Srv.Admins = []string{pBob}
	conf := shortTemp(t)
	svc = serveFakeChat(t, conf)
	_, host, login = runChatAgentIn(t, h, "chat-entry", true, conf)
	return h, svc, host, login
}

func chatAudits(t *testing.T, h *harness, action string) int {
	t.Helper()
	var n int
	if err := h.Srv.Store.DB().QueryRow(`SELECT COUNT(*) FROM fleet_audit WHERE action = ?`, action).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n
}

func TestChatRefusals(t *testing.T) {
	h, svc, host, login := chatHarness(t)
	alice := personCookie(pAlice, "alice")
	cases := []struct {
		name   string
		method string
		path   string
		cookie *http.Cookie
		hdr    map[string]string
		status int
		code   string
	}{
		{"signed out", "GET", "/v1/chat/conversation", nil, nil, http.StatusUnauthorized, ""},
		{"not on the list", "GET", "/v1/chat/conversation", personCookie(pGhost, "ghost"), nil, http.StatusForbidden, ""},
		{"the operator's door", "GET", "/v1/chat/conversation", nil, map[string]string{"Authorization": "Bearer " + viewerToken}, http.StatusForbidden, "operator"},
		{"no home", "GET", "/v1/chat/conversation", alice, nil, http.StatusConflict, "no_home"},
		{"unknown route", "GET", "/v1/chat/sessions", alice, nil, http.StatusNotFound, ""},
		{"wrong method", "GET", "/v1/chat/turn", alice, nil, http.StatusMethodNotAllowed, ""},
	}
	for _, c := range cases {
		resp := chatDo(t, h, c.method, c.path, c.cookie, c.hdr, "")
		if resp.StatusCode != c.status {
			t.Errorf("%s: %d; want %d", c.name, resp.StatusCode, c.status)
		}
		if c.code != "" {
			if got := chatCode(t, resp); got != c.code {
				t.Errorf("%s: code %q; want %q", c.name, got, c.code)
			}
		}
	}

	// A POST the page did not make (no X-Fleet-Webchat) never reaches the service.
	setChatHome(t, h, pAlice, host, login)
	if resp := chatDo(t, h, "POST", "/v1/chat/turn", alice, nil, `{"text":"hi"}`); resp.StatusCode != http.StatusForbidden {
		t.Errorf("POST without X-Fleet-Webchat: %d; want 403", resp.StatusCode)
	}

	// A home that is not connected: 503, never another machine (D2).
	setChatHome(t, h, pAlice, "elsewhere", login)
	resp := chatDo(t, h, "GET", "/v1/chat/conversation", alice, nil, "")
	if resp.StatusCode != http.StatusServiceUnavailable || chatCode(t, resp) != "home_down" {
		t.Errorf("home offline: %d; want 503 home_down", resp.StatusCode)
	}
	// A home in maintenance: the same, and no relay is opened.
	setChatHome(t, h, pAlice, host, login)
	if err := h.Srv.Store.SetFleetSetting(MaintenanceKeyForTest(host), "drill", time.Now()); err != nil {
		t.Fatal(err)
	}
	resp = chatDo(t, h, "GET", "/v1/chat/conversation", alice, nil, "")
	if resp.StatusCode != http.StatusServiceUnavailable || chatCode(t, resp) != "home_down" {
		t.Errorf("home in maintenance: %d; want 503 home_down", resp.StatusCode)
	}
	if hits := svc.seen(); len(hits) != 0 {
		t.Errorf("the service was reached by a refused request: %v", hits)
	}
	if n := chatAudits(t, h, "chat_refused"); n < 5 {
		t.Errorf("%d refusals audited; want every one (≥ 5)", n)
	}
	if n := chatAudits(t, h, "chat_relay"); n != 0 {
		t.Errorf("%d relays audited; want none", n)
	}
}

func TestChatReachesOwnHomeAsThemselves(t *testing.T) {
	h, svc, host, login := chatHarness(t)
	setChatHome(t, h, pAlice, host, login)
	alice := personCookie(pAlice, "alice")
	// The browser names someone else: the service still hears alice, and no
	// cookie of hers goes on.
	resp := chatDo(t, h, "GET", "/v1/chat/conversation", alice, map[string]string{"X-Fleet-Person": pBob}, "")
	b, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusOK || !strings.Contains(string(b), `"session":"s1"`) {
		t.Fatalf("conversation: %d %s", resp.StatusCode, b)
	}
	hits := svc.seen()
	if len(hits) != 1 || hits[0] != "GET /api/conversation person="+pAlice+" cookie=" {
		t.Fatalf("the service saw %q; want one GET as %s with no cookie", hits, pAlice)
	}
	if n := chatAudits(t, h, "chat_relay"); n != 1 {
		t.Errorf("%d relays audited; want 1", n)
	}
	waitFor(t, 5*time.Second, "relay released", func() bool { return h.Srv.ChatRelaysOpenForTest() == 0 })
}

func TestChatTurnStreamsLineByLine(t *testing.T) {
	h, svc, host, login := chatHarness(t)
	setChatHome(t, h, pAlice, host, login)
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	req, _ := http.NewRequestWithContext(ctx, "POST", h.HTTP.URL+"/v1/chat/turn", strings.NewReader(`{"text":"hi"}`))
	req.AddCookie(personCookie(pAlice, "alice"))
	req.Header.Set("X-Fleet-Webchat", "1")
	req.Header.Set("Content-Type", "application/json")
	resp, err := h.HTTP.Client().Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("turn: %d", resp.StatusCode)
	}
	rd := bufio.NewReader(resp.Body)
	// The first line arrives while the service is still holding the second.
	got := make(chan string, 1)
	go func() { l, _ := rd.ReadString('\n'); got <- l }()
	select {
	case l := <-got:
		if !strings.Contains(l, `"t":"start"`) || !strings.Contains(l, `\"text\":\"hi\"`) {
			t.Fatalf("first line %q", l)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("the first NDJSON line was held back (buffered)")
	}
	close(svc.release)
	if l, _ := rd.ReadString('\n'); !strings.Contains(l, `"t":"done"`) {
		t.Fatalf("second line %q", l)
	}
	if hits := svc.seen(); len(hits) != 1 || !strings.HasPrefix(hits[0], "POST /api/turn person="+pAlice) {
		t.Fatalf("the service saw %q", hits)
	}
}

func TestChatAdminOnlyTheirOwn(t *testing.T) {
	h, svc, host, login := chatHarness(t)
	setChatHome(t, h, pAlice, host, login)
	bob := personCookie(pBob, "bob")
	// Naming alice is refused outright, even for an admin (D5).
	resp := chatDo(t, h, "GET", "/v1/chat/conversation?principal="+pAlice, bob, nil, "")
	if resp.StatusCode != http.StatusForbidden || chatCode(t, resp) != "not_yours" {
		t.Errorf("admin naming alice: %d; want 403 not_yours", resp.StatusCode)
	}
	// Without a home of his own he has no conversation — alice's is not his.
	resp = chatDo(t, h, "GET", "/v1/chat/conversation", bob, nil, "")
	if resp.StatusCode != http.StatusConflict || chatCode(t, resp) != "no_home" {
		t.Errorf("admin with no home: %d; want 409 no_home", resp.StatusCode)
	}
	if hits := svc.seen(); len(hits) != 0 {
		t.Fatalf("the service was reached: %v", hits)
	}
	// His own home: reached as himself.
	setChatHome(t, h, pBob, host, login)
	resp = chatDo(t, h, "GET", "/v1/chat/conversation", bob, nil, "")
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("admin's own: %d", resp.StatusCode)
	}
	if hits := svc.seen(); len(hits) != 1 || !strings.Contains(hits[0], "person="+pBob+" ") {
		t.Fatalf("the service saw %q; want bob", hits)
	}
}

// fakeChatService serves /api/* on <conf>/webchat/chat.sock and records what it
// saw. /api/turn writes one NDJSON line, waits for release, writes the second.
type fakeChatService struct {
	mu           sync.Mutex
	hits         []string // "<method> <path> person=<X-Fleet-Person> cookie=<Cookie>"
	clients      []string // each request's X-Fleet-Client (claude-fleet#4034)
	queries      []string // each request's raw query (task T773: a file's ref)
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
	if _, err := h.Srv.Store.SetEntryHome(store.EntryHome{Person: person, Machine: machine, Login: login, SetBy: "t", SetAt: time.Now()}); err != nil {
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
	req, _ := http.NewRequest(method, h.HTTP.URL+path, rd)
	req.Header.Set("Accept", "application/json")
	if cookie != nil {
		req.AddCookie(cookie)
	}
	for k, v := range hdr {
		req.Header.Set(k, v)
	}
	c := *h.HTTP.Client()
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
