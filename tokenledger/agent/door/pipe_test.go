package door

import (
	"context"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/coder/websocket"

	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

type pipeRig struct {
	p     *Pipes
	srv   *httptest.Server
	key   string
	mu    sync.Mutex
	lines []PipeLine
}

func newPipeRig(t *testing.T, cfg PipeConfig) *pipeRig {
	t.Helper()
	r := &pipeRig{key: control.ChatTokenHash("the-door-token")}
	if cfg.ID == "" {
		cfg.ID = "us"
	}
	cfg.Key = r.key
	p, err := NewPipes(cfg, func(v any) {
		r.mu.Lock()
		defer r.mu.Unlock()
		r.lines = append(r.lines, v.(PipeLine))
	})
	if err != nil {
		t.Fatal(err)
	}
	r.p = p
	r.srv = httptest.NewServer(p.Handler())
	t.Cleanup(r.srv.Close)
	return r
}

func (r *pipeRig) ticket(door, pipe, role, key string) string {
	now := time.Now()
	return control.SignDoorPipe(control.DoorPipeTicket{V: 1, Door: door, Pipe: pipe, Role: role,
		Iat: now.Unix(), Exp: now.Add(control.DoorPipeTicketTTL).Unix()}, key)
}

func (r *pipeRig) dial(t *testing.T, ticket, origin string) (*websocket.Conn, int) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	h := http.Header{}
	if origin != "" {
		h.Set("Origin", origin)
	}
	c, resp, err := websocket.Dial(ctx, "ws"+strings.TrimPrefix(r.srv.URL, "http")+control.DoorPipePath+"?t="+url.QueryEscape(ticket),
		&websocket.DialOptions{HTTPHeader: h})
	if err != nil {
		if resp != nil {
			return nil, resp.StatusCode
		}
		t.Fatal(err)
	}
	return c, 101
}

func (r *pipeRig) results() []string {
	r.mu.Lock()
	defer r.mu.Unlock()
	var out []string
	for _, l := range r.lines {
		out = append(out, l.Result+":"+l.Why)
	}
	return out
}

const pipeID = "pipe0123456789abcdefgh"

func TestDoorPipeJoinsTheTwoHalves(t *testing.T) {
	r := newPipeRig(t, PipeConfig{Origins: []string{"https://console.example.com"}})
	home, st := r.dial(t, r.ticket("us", pipeID, control.DoorPipeHome, r.key), "")
	if home == nil {
		t.Fatalf("home half: %d", st)
	}
	browser, st := r.dial(t, r.ticket("us", pipeID, control.DoorPipeBrowser, r.key), "https://console.example.com")
	if browser == nil {
		t.Fatalf("browser half: %d", st)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	// every message arrives as it was sent: type and bytes (a split UTF-8 scalar too)
	cn := []byte("中")
	for _, m := range []struct {
		from, to *websocket.Conn
		typ      websocket.MessageType
		b        []byte
	}{
		{home, browser, websocket.MessageText, []byte(`{"t":"ready"}`)},
		{browser, home, websocket.MessageBinary, cn[:1]},
		{browser, home, websocket.MessageBinary, cn[1:]},
		{home, browser, websocket.MessageBinary, []byte("got:中\r\n")},
		{browser, home, websocket.MessageText, []byte(`{"t":"resize","cols":80,"rows":24}`)},
	} {
		if err := m.from.Write(ctx, m.typ, m.b); err != nil {
			t.Fatal(err)
		}
		typ, b, err := m.to.Read(ctx)
		if err != nil || typ != m.typ || string(b) != string(m.b) {
			t.Fatalf("carried %v %q %v, want %v %q", typ, b, err, m.typ, m.b)
		}
	}
	// one side going takes the other with it, and the pipe is recorded
	home.Close(websocket.StatusNormalClosure, "")
	if _, _, err := browser.Read(ctx); err == nil {
		t.Fatal("the browser half outlived the home half")
	}
	waitPipe(t, func() bool { return len(r.results()) == 1 })
	r.mu.Lock()
	l := r.lines[0]
	r.mu.Unlock()
	if l.Result != "joined" || l.Pipe != pipeID || l.Door != "us" || l.Up != 3 || l.Down != int64(len("got:中\r\n")) {
		t.Fatalf("the pipe's record: %+v", l)
	}
}

// door-term-ticket-replay: a ticket opens its half of its pipe once — a second
// use, a ticket another door's key signed, one for another door, and no ticket
// all join nothing.
func TestDoorPipeTicketReplay(t *testing.T) {
	r := newPipeRig(t, PipeConfig{Wait: 300 * time.Millisecond})
	tk := r.ticket("us", pipeID, control.DoorPipeBrowser, r.key)
	first, _ := r.dial(t, tk, "")
	if first == nil {
		t.Fatal("the first use was refused")
	}
	defer first.CloseNow()
	if c, st := r.dial(t, tk, ""); c != nil || st != http.StatusForbidden {
		t.Fatalf("a replayed ticket: %v %d", c, st)
	}
	for name, bad := range map[string]string{
		"another door's key": r.ticket("us", "pipeZZZZZZZZZZZZZZZZZ", control.DoorPipeHome, control.ChatTokenHash("x")),
		"another door":       r.ticket("sz", "pipeZZZZZZZZZZZZZZZZZ", control.DoorPipeHome, r.key),
		"none":               "",
	} {
		if c, st := r.dial(t, bad, ""); c != nil || st != http.StatusForbidden {
			t.Errorf("%s: %v %d", name, c, st)
		}
	}
	// the half that waited alone goes, said so
	waitPipe(t, func() bool {
		for _, l := range r.results() {
			if strings.HasPrefix(l, "unpaired:") {
				return true
			}
		}
		return false
	})
}

// door-term-wrong-person: nothing but its own pipe's other half joins a half —
// a browser ticket for another pipe pairs with nobody's terminal, a second
// browser of the same pipe is turned away, and a page of another origin is too.
func TestDoorPipeOnlyItsOwnOtherHalf(t *testing.T) {
	r := newPipeRig(t, PipeConfig{Wait: 2 * time.Second, Origins: []string{"https://console.example.com"}})
	home, _ := r.dial(t, r.ticket("us", pipeID, control.DoorPipeHome, r.key), "")
	if home == nil {
		t.Fatal("home half refused")
	}
	defer home.CloseNow()
	mallory, _ := r.dial(t, r.ticket("us", "pipeMALLORYxxxxxxxxxxx", control.DoorPipeBrowser, r.key), "https://console.example.com")
	if mallory == nil {
		t.Fatal("a valid ticket for another pipe was refused at the door")
	}
	defer mallory.CloseNow()
	ctx, cancel := context.WithTimeout(context.Background(), 4*time.Second)
	defer cancel()
	if err := home.Write(ctx, websocket.MessageBinary, []byte("secret")); err != nil {
		t.Fatal(err)
	}
	rctx, rcancel := context.WithTimeout(ctx, 500*time.Millisecond)
	if _, b, err := mallory.Read(rctx); err == nil {
		t.Fatalf("another pipe's browser read %q", b)
	}
	rcancel()
	if c, st := r.dial(t, r.ticket("us", pipeID, control.DoorPipeBrowser, r.key), "https://evil.example.com"); c != nil || st != http.StatusForbidden {
		t.Fatalf("another origin: %v %d", c, st)
	}
	if c, _ := r.dial(t, r.ticket("us", pipeID, control.DoorPipeHome, r.key), ""); c != nil {
		// a second home ticket (minted separately) for the same pipe: turned away
		if _, _, err := c.Read(ctx); err == nil {
			t.Fatal("a second home half was joined")
		}
	}
}

func TestDoorPipeHealthz(t *testing.T) {
	r := newPipeRig(t, PipeConfig{})
	resp, err := http.Get(r.srv.URL + "/healthz")
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != 200 || resp.Header.Get("Access-Control-Allow-Origin") != "*" {
		t.Fatalf("probe: %d %q", resp.StatusCode, resp.Header.Get("Access-Control-Allow-Origin"))
	}
	if resp, _ := http.Get(r.srv.URL + "/relay"); resp == nil || resp.StatusCode != 404 {
		t.Fatal("the browser listener answers what is not its own")
	}
}

func waitPipe(t *testing.T, ok func() bool) {
	t.Helper()
	for end := time.Now().Add(5 * time.Second); time.Now().Before(end); time.Sleep(20 * time.Millisecond) {
		if ok() {
			return
		}
	}
	t.Fatal("timed out")
}
