package agent

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// claude-fleet#1721: CCQUOTA_FLEET_PERSONAL=1 is read live, and only while
// compute is on; no line (every node before #1721) is not personal.
func TestPersonalNow(t *testing.T) {
	envf := filepath.Join(t.TempDir(), "node.env")
	a := &Agent{cfg: Config{FleetNodeEnvPath: envf}}
	write := func(s string) {
		if err := os.WriteFile(envf, []byte(s), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	if a.personalNow() {
		t.Fatal("no node.env: want not personal")
	}
	write("CCQUOTA_TOKEN=x\nCCQUOTA_FLEET_COMPUTE=1\n")
	if a.personalNow() {
		t.Fatal("no personal line: want not personal")
	}
	write("CCQUOTA_TOKEN=x\nCCQUOTA_FLEET_COMPUTE=1\nCCQUOTA_FLEET_PERSONAL=1\n")
	if !a.personalNow() {
		t.Fatal("personal line not read")
	}
	write("CCQUOTA_TOKEN=x\nCCQUOTA_FLEET_COMPUTE=0\nCCQUOTA_FLEET_PERSONAL=1\n")
	if a.personalNow() {
		t.Fatal("a login that only coordinates is never personal")
	}
}

// The monotonic clock moves with the wall clock while the machine is awake.
func TestSleptAwake(t *testing.T) {
	now := time.Now()
	if slept(now, now.Add(time.Hour)) {
		t.Fatal("an hour awake read as a sleep")
	}
}

type hubCall struct {
	path string
	body map[string]any
}

// fakeHub records every POST; fail makes maintenance answer 503.
type fakeHub struct {
	mu    sync.Mutex
	calls []hubCall
	fail  bool
	srv   *httptest.Server
}

func newFakeHub(t *testing.T) *fakeHub {
	h := &fakeHub{}
	h.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var b map[string]any
		_ = json.NewDecoder(r.Body).Decode(&b)
		h.mu.Lock()
		h.calls = append(h.calls, hubCall{r.URL.Path, b})
		fail := h.fail
		h.mu.Unlock()
		if r.Header.Get("Authorization") != "Bearer tok" {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		if fail {
			w.WriteHeader(http.StatusServiceUnavailable)
			return
		}
		_, _ = w.Write([]byte(`{}`))
	}))
	t.Cleanup(h.srv.Close)
	return h
}

func (h *fakeHub) snapshot() []hubCall {
	h.mu.Lock()
	defer h.mu.Unlock()
	return append([]hubCall(nil), h.calls...)
}

func waitCalls(t *testing.T, h *fakeHub, n int) []hubCall {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if c := h.snapshot(); len(c) >= n {
			return c
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("hub saw %v; want %d calls", h.snapshot(), n)
	return nil
}

// A personal machine: start clears a leftover sleep flag; sleep flags it and
// tells the person how many sessions run; wake clears it — only the sleep one.
func TestSleepLoopPersonal(t *testing.T) {
	hub := newFakeHub(t)
	envf := filepath.Join(t.TempDir(), "node.env")
	if err := os.WriteFile(envf, []byte("CCQUOTA_FLEET_COMPUTE=1\nCCQUOTA_FLEET_PERSONAL=1\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	a := &Agent{cfg: Config{HubURL: hub.srv.URL, Token: "tok", FleetNodeEnvPath: envf, SleepRetry: 10 * time.Millisecond}}
	a.lastSessions.Store(3)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	ev := make(chan string)
	go a.sleepLoop(ctx, ev)

	c := waitCalls(t, hub, 1)
	if c[0].path != "/v1/node/maintenance" || c[0].body["action"] != "leave" || c[0].body["if_reason"] != "sleep" {
		t.Fatalf("start: %+v; want a leave if_reason=sleep", c[0])
	}
	ev <- "sleep"
	c = waitCalls(t, hub, 3)
	if c[1].path != "/v1/node/maintenance" || c[1].body["action"] != "enter" || c[1].body["reason"] != "sleep" {
		t.Fatalf("sleep: %+v; want enter reason=sleep", c[1])
	}
	if c[2].path != "/v1/node/client/actions" || c[2].body["kind"] != "notify" {
		t.Fatalf("sleep: %+v; want a notify", c[2])
	}
	if b, _ := c[2].body["body"].(string); !containsAll(b, "还有 3 个会话在跑", "维护中") {
		t.Fatalf("notify body %q", b)
	}

	// The hub is out right after waking: the leave is retried until it answers.
	hub.mu.Lock()
	hub.fail = true
	hub.mu.Unlock()
	ev <- "wake"
	waitCalls(t, hub, 5)
	hub.mu.Lock()
	hub.fail = false
	hub.mu.Unlock()
	time.Sleep(50 * time.Millisecond)
	c = hub.snapshot()
	last := c[len(c)-1]
	if last.body["action"] != "leave" || last.body["if_reason"] != "sleep" {
		t.Fatalf("wake: last %+v; want leave if_reason=sleep", last)
	}
	n := len(c)
	time.Sleep(50 * time.Millisecond)
	if len(hub.snapshot()) != n {
		t.Fatalf("leave kept retrying after the hub answered: %v", hub.snapshot()[n:])
	}
}

// No sessions: the flag, no notify. Not personal: nothing at all.
func TestSleepLoopQuiet(t *testing.T) {
	hub := newFakeHub(t)
	envf := filepath.Join(t.TempDir(), "node.env")
	if err := os.WriteFile(envf, []byte("CCQUOTA_FLEET_COMPUTE=1\nCCQUOTA_FLEET_PERSONAL=1\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	a := &Agent{cfg: Config{HubURL: hub.srv.URL, Token: "tok", FleetNodeEnvPath: envf}}
	ctx, cancel := context.WithCancel(context.Background())
	ev := make(chan string)
	go a.sleepLoop(ctx, ev)
	waitCalls(t, hub, 1)
	ev <- "sleep"
	ev <- "wake" // handled after the sleep's posts
	c := waitCalls(t, hub, 3)
	for _, x := range c {
		if x.path != "/v1/node/maintenance" {
			t.Fatalf("no sessions running must send no notify: %+v", c)
		}
	}
	cancel()

	shared := newFakeHub(t)
	if err := os.WriteFile(envf, []byte("CCQUOTA_FLEET_COMPUTE=1\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	b := &Agent{cfg: Config{HubURL: shared.srv.URL, Token: "tok", FleetNodeEnvPath: envf}}
	b.lastSessions.Store(2)
	ctx2, cancel2 := context.WithCancel(context.Background())
	defer cancel2()
	ev2 := make(chan string)
	go b.sleepLoop(ctx2, ev2)
	ev2 <- "sleep"
	ev2 <- "wake"
	time.Sleep(50 * time.Millisecond)
	if c := shared.snapshot(); len(c) != 0 {
		t.Fatalf("a shared machine's sleep sent %+v; want nothing", c)
	}
}

func containsAll(s string, subs ...string) bool {
	for _, x := range subs {
		if !strings.Contains(s, x) {
			return false
		}
	}
	return true
}
