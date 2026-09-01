package agent

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/verkyyi/ccquota/internal/model"
)

// fakeHome builds a Claude Code home containing n billable turns.
func fakeHome(t *testing.T, n int) string {
	t.Helper()
	home := t.TempDir()

	cfg := `{"machineID":"m1","lastReleaseNotesSeen":"2.1.252",
	  "oauthAccount":{"accountUuid":"acct-test","emailAddress":"t@example.com",
	                  "organizationUuid":"org","organizationName":"Org","displayName":"T"}}`
	if err := os.WriteFile(filepath.Join(home, ".claude.json"), []byte(cfg), 0o600); err != nil {
		t.Fatal(err)
	}

	dir := filepath.Join(home, ".claude", "projects", "proj")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	var buf []byte
	for i := 0; i < n; i++ {
		// Padding makes each turn big enough that a small spool cap is reached
		// within a realistic number of events.
		line := fmt.Sprintf(
			`{"type":"assistant","uuid":"u-%d","sessionId":"s1","timestamp":"2026-08-31T12:00:00Z",`+
				`"cwd":"/w/%s","message":{"role":"assistant","model":"claude-sonnet-5",`+
				`"usage":{"output_tokens":%d,"input_tokens":10}}}`,
			i, padding, i+1)
		buf = append(buf, line...)
		buf = append(buf, '\n')
	}
	if err := os.WriteFile(filepath.Join(dir, "sess.jsonl"), buf, 0o644); err != nil {
		t.Fatal(err)
	}
	return home
}

// padding inflates each transcript line so a modest event count exceeds a
// modest spool cap.
var padding = func() string {
	b := make([]byte, 400)
	for i := range b {
		b[i] = 'x'
	}
	return string(b)
}()

// collector is a stand-in hub that records every message uuid it is told about.
type collector struct {
	mu      sync.Mutex
	seen    map[string]bool
	down    bool
	srv     *httptest.Server
	batches int
}

func newCollector(t *testing.T) *collector {
	t.Helper()
	c := &collector{seen: map[string]bool{}}
	c.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		c.mu.Lock()
		defer c.mu.Unlock()
		if c.down {
			http.Error(w, "hub is down", http.StatusServiceUnavailable)
			return
		}
		var b model.Batch
		if err := json.NewDecoder(r.Body).Decode(&b); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		c.batches++
		n := 0
		for _, e := range b.Events {
			if !c.seen[e.MessageUUID] {
				c.seen[e.MessageUUID] = true
				n++
			}
		}
		json.NewEncoder(w).Encode(model.IngestResponse{Accepted: n, EndpointID: "ep"})
	}))
	t.Cleanup(c.srv.Close)
	return c
}

func (c *collector) setDown(down bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.down = down
}

func (c *collector) count() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return len(c.seen)
}

func newAgent(t *testing.T, home, hub string, spoolBytes int64) *Agent {
	t.Helper()
	a, err := New(Config{
		HubURL: hub, Token: "tok", Home: home,
		StateDir:      filepath.Join(t.TempDir(), "state"),
		SpoolMaxBytes: spoolBytes, Version: "test", Once: true,
	})
	if err != nil {
		t.Fatal(err)
	}
	// Never touch the network for limits in tests.
	a.lastLimitsPoll = alwaysRecent()
	return a
}

func TestAgent_DeliversEverythingWhenTheHubIsUp(t *testing.T) {
	const n = 500
	c := newCollector(t)
	a := newAgent(t, fakeHome(t, n), c.srv.URL, DefaultSpoolBytesForTest)

	if err := a.cycle(context.Background()); err != nil {
		t.Fatalf("cycle: %v", err)
	}
	if got := c.count(); got != n {
		t.Fatalf("hub received %d of %d turns", got, n)
	}
}

// THE regression test.
//
// Measured on a real machine: a first scan against a down hub overflowed the
// spool, the spool evicted its oldest batches, and the agent committed its scan
// position anyway — so 46% of the events were gone for good with only a log
// line to show for it. The cursor must not advance past anything the spool
// refused.
func TestAgent_HubDownThenUp_LosesNothing(t *testing.T) {
	const n = 900
	// A cap far too small to hold the whole scan, so batches WILL be refused.
	const tinySpool = 64 << 10

	c := newCollector(t)
	c.setDown(true)

	home := fakeHome(t, n)
	state := filepath.Join(t.TempDir(), "state")
	mk := func() *Agent {
		a, err := New(Config{HubURL: c.srv.URL, Token: "tok", Home: home,
			StateDir: state, SpoolMaxBytes: tinySpool, Version: "test", Once: true})
		if err != nil {
			t.Fatal(err)
		}
		a.lastLimitsPoll = alwaysRecent()
		return a
	}

	// While the hub is down, cycles fail. That is expected and fine.
	for i := 0; i < 3; i++ {
		_ = mk().cycle(context.Background())
	}
	if c.count() != 0 {
		t.Fatalf("hub recorded %d turns while it was down", c.count())
	}

	// Hub comes back. Keep cycling until it stops making progress.
	c.setDown(false)
	prev := -1
	for i := 0; i < 60 && c.count() != prev; i++ {
		prev = c.count()
		if err := mk().cycle(context.Background()); err != nil {
			t.Logf("cycle %d: %v", i, err)
		}
	}

	if got := c.count(); got != n {
		t.Fatalf("hub ended up with %d of %d turns — %d were lost when the spool overflowed",
			got, n, n-got)
	}
}

// The cursor is the only thing protecting unqueued events, so a cycle that
// could not queue everything must leave it alone.
func TestAgent_PartialEnqueueDoesNotAdvanceTheCursor(t *testing.T) {
	const n = 900
	c := newCollector(t)
	c.setDown(true)

	home := fakeHome(t, n)
	state := filepath.Join(t.TempDir(), "state")

	a, err := New(Config{HubURL: c.srv.URL, Token: "tok", Home: home,
		StateDir: state, SpoolMaxBytes: 64 << 10, Version: "test", Once: true})
	if err != nil {
		t.Fatal(err)
	}
	a.lastLimitsPoll = alwaysRecent()
	_ = a.cycle(context.Background())

	// A cursor file that exists and records progress would mean those events
	// can never be re-read.
	b, err := os.ReadFile(filepath.Join(state, "cursor.json"))
	if err != nil {
		return // no cursor written at all: also correct
	}
	var doc struct {
		Files map[string]struct {
			Offset int64 `json:"offset"`
		} `json:"files"`
	}
	if err := json.Unmarshal(b, &doc); err != nil {
		t.Fatal(err)
	}
	for path, st := range doc.Files {
		if st.Offset > 0 {
			t.Fatalf("cursor advanced to offset %d in %s despite a refused batch; "+
				"those events are now unreachable", st.Offset, path)
		}
	}
}

// Control for the test above: when everything fits, the cursor MUST advance —
// otherwise the assertion is vacuous and would pass on a broken agent that
// never commits at all.
func TestAgent_FullEnqueueDoesAdvanceTheCursor(t *testing.T) {
	c := newCollector(t)
	home := fakeHome(t, 50)
	state := filepath.Join(t.TempDir(), "state")

	a, err := New(Config{HubURL: c.srv.URL, Token: "tok", Home: home,
		StateDir: state, SpoolMaxBytes: DefaultSpoolBytesForTest, Version: "test", Once: true})
	if err != nil {
		t.Fatal(err)
	}
	a.lastLimitsPoll = alwaysRecent()
	if err := a.cycle(context.Background()); err != nil {
		t.Fatal(err)
	}

	b, err := os.ReadFile(filepath.Join(state, "cursor.json"))
	if err != nil {
		t.Fatalf("no cursor written after a fully successful cycle: %v", err)
	}
	var doc struct {
		Files map[string]struct {
			Offset int64 `json:"offset"`
		} `json:"files"`
	}
	if err := json.Unmarshal(b, &doc); err != nil {
		t.Fatal(err)
	}
	advanced := false
	for _, st := range doc.Files {
		if st.Offset > 0 {
			advanced = true
		}
	}
	if !advanced {
		t.Fatal("cursor did not advance after a fully successful cycle")
	}
}

func TestBackoffInterval_GrowsThenCaps(t *testing.T) {
	a := &Agent{cfg: Config{ScanInterval: minute}}
	if got := a.backoffInterval(); got != minute {
		t.Errorf("healthy interval = %v, want %v", got, minute)
	}
	a.consecutiveFailures = 3
	if got := a.backoffInterval(); got != 8*minute {
		t.Errorf("after 3 failures = %v, want %v", got, 8*minute)
	}
	a.consecutiveFailures = 25
	if got := a.backoffInterval(); got != maxBackoffFactor*minute {
		t.Errorf("backoff is uncapped: %v", got)
	}
}

// Test helpers.
const (
	minute                   = time.Minute
	DefaultSpoolBytesForTest = int64(64 << 20)
)

// alwaysRecent parks the limits poll in the near past so tests never reach out
// to Anthropic.
func alwaysRecent() time.Time { return time.Now() }
