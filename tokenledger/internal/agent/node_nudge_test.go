package agent

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
)

// The state nudge (claude-fleet#1481): a touch of the fleet's nudge file is
// one extra heartbeat, soon; a burst is still one; a flood is at most two a
// second. The 5 s ticker is kept out of the way by a long LiveInterval.

// keepHub is a control hub that stays connected and stamps when each
// heartbeat arrives.
type keepHub struct {
	srv     *httptest.Server
	mu      sync.Mutex
	beatsAt []time.Time
}

func newKeepHub(t *testing.T) *keepHub {
	t.Helper()
	k := &keepHub{}
	k.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != control.Path {
			w.WriteHeader(http.StatusOK)
			w.Write([]byte(`{}`))
			return
		}
		c, err := websocket.Accept(w, r, nil)
		if err != nil {
			return
		}
		defer c.CloseNow()
		ctx := r.Context()
		var h control.Message
		if wsjson.Read(ctx, c, &h) != nil {
			return
		}
		reply, _ := control.New(control.TypeWelcome, control.Welcome{Accepted: true, HubProto: control.Proto, MinProto: control.MinProto})
		reply.OpID = h.OpID
		if wsjson.Write(ctx, c, reply) != nil {
			return
		}
		for {
			var m control.Message
			if wsjson.Read(ctx, c, &m) != nil {
				return
			}
			if m.Type == control.TypeHeartbeat {
				k.mu.Lock()
				k.beatsAt = append(k.beatsAt, time.Now())
				k.mu.Unlock()
			}
		}
	}))
	t.Cleanup(k.srv.Close)
	return k
}

func (k *keepHub) beats() int {
	k.mu.Lock()
	defer k.mu.Unlock()
	return len(k.beatsAt)
}

// nudgeAgent runs an agent whose only reason to beat again is a nudge, and
// returns the nudge file it watches plus a stop.
func nudgeAgent(t *testing.T, hub string) (nudge string, stop func()) {
	t.Helper()
	home := t.TempDir()
	nudge = filepath.Join(home, "conf", "global", "hub-nudge")
	a, err := New(Config{
		HubURL: hub, Token: "tok", Home: home, Sources: "claude",
		StateDir: filepath.Join(home, "state"), SessionsDir: filepath.Join(home, "sessions"),
		LiveInterval: time.Hour, ScanInterval: time.Hour, LimitsInterval: time.Hour,
		Version: "test", Fleet: true, FleetNudgePath: nudge,
	})
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { a.Run(ctx); close(done) }()
	return nudge, func() { cancel(); <-done }
}

func touch(t *testing.T, path string) {
	t.Helper()
	os.MkdirAll(filepath.Dir(path), 0o755)
	if err := os.WriteFile(path, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
}

func waitBeats(t *testing.T, k *keepHub, n int, within time.Duration) bool {
	t.Helper()
	deadline := time.Now().Add(within)
	for time.Now().Before(deadline) {
		if k.beats() >= n {
			return true
		}
		time.Sleep(10 * time.Millisecond)
	}
	return k.beats() >= n
}

// With Fleet on and no nudge path given, the agent watches the default
// conf dir under its home.
func TestNudgePathDefaultsUnderHome(t *testing.T) {
	a := nodeTestAgent(t, "http://unused", true)
	want := filepath.Join(a.cfg.Home, ".config", "claude-fleet", "global", "hub-nudge")
	if a.cfg.FleetNudgePath != want {
		t.Fatalf("FleetNudgePath = %q, want %q", a.cfg.FleetNudgePath, want)
	}
	off := nodeTestAgent(t, "http://unused", false)
	if off.cfg.FleetNudgePath != "" {
		t.Fatalf("Fleet off: FleetNudgePath = %q, want none", off.cfg.FleetNudgePath)
	}
}

// One touch → one extra heartbeat, within the poll + debounce budget.
func TestNudgeBeatsAtOnce(t *testing.T) {
	k := newKeepHub(t)
	nudge, stop := nudgeAgent(t, k.srv.URL)
	defer stop()
	if !waitBeats(t, k, 1, 5*time.Second) {
		t.Fatal("no first heartbeat")
	}
	time.Sleep(2 * nodeNudgePoll) // let the watcher take its baseline
	t0 := time.Now()
	touch(t, nudge)
	// Budget: one poll (250 ms) + the debounce (300 ms), with slack for a
	// loaded CI box — far under the 5 s the ticker alone would take.
	if !waitBeats(t, k, 2, 2*time.Second) {
		t.Fatalf("no heartbeat within 2 s of a nudge (beats=%d)", k.beats())
	}
	k.mu.Lock()
	at := k.beatsAt[1]
	k.mu.Unlock()
	if d := at.Sub(t0); d < nodeNudgeDebounce {
		t.Fatalf("nudge beat after %v, before the %v debounce had passed", d, nodeNudgeDebounce)
	}
	// And a quiet file asks for nothing more.
	time.Sleep(time.Second)
	if n := k.beats(); n != 2 {
		t.Fatalf("beats = %d after one nudge, want 2 (first + nudged)", n)
	}
}

// A burst of touches inside the debounce window is one beat; a flood is at
// most two beats a second — and never zero.
func TestNudgeDebouncesAndRateLimits(t *testing.T) {
	k := newKeepHub(t)
	nudge, stop := nudgeAgent(t, k.srv.URL)
	defer stop()
	if !waitBeats(t, k, 1, 5*time.Second) {
		t.Fatal("no first heartbeat")
	}
	time.Sleep(2 * nodeNudgePoll)

	// Burst: five touches 20 ms apart (each a distinct mtime on any
	// filesystem with ms resolution) all land inside one debounce window.
	for i := 0; i < 5; i++ {
		touch(t, nudge)
		time.Sleep(20 * time.Millisecond)
	}
	if !waitBeats(t, k, 2, 2*time.Second) {
		t.Fatalf("burst: no beat (beats=%d)", k.beats())
	}
	time.Sleep(nodeNudgeMinGap + nodeNudgeDebounce + 2*nodeNudgePoll)
	if n := k.beats(); n != 2 {
		t.Fatalf("burst of 5 touches → %d beats, want exactly 1 extra (2 total)", n-1)
	}

	// Flood: a touch every 50 ms for 2 s. The cap is two nudge beats a
	// second; the floor is that the changes keep going out at all.
	before := k.beats()
	start := time.Now()
	for time.Since(start) < 2*time.Second {
		touch(t, nudge)
		time.Sleep(50 * time.Millisecond)
	}
	time.Sleep(nodeNudgeMinGap + nodeNudgeDebounce + 2*nodeNudgePoll) // drain the last held beat
	got := k.beats() - before
	if got < 2 || got > 5 {
		t.Fatalf("2 s flood → %d nudge beats, want 2..5 (≤ 2/s, never silent)", got)
	}
	k.mu.Lock()
	ats := append([]time.Time(nil), k.beatsAt[before:]...)
	k.mu.Unlock()
	for i := 1; i < len(ats); i++ {
		if gap := ats[i].Sub(ats[i-1]); gap < nodeNudgeMinGap-20*time.Millisecond {
			t.Fatalf("nudge beats %v apart, under the %v minimum gap", gap, nodeNudgeMinGap)
		}
	}
}

// No nudge path: nothing is watched and nothing can panic.
func TestNudgeOffWatchesNothing(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	ch := watchNudge(ctx, "")
	select {
	case <-ch:
		t.Fatal("an empty path signalled")
	case <-time.After(3 * nodeNudgePoll):
	}
}
