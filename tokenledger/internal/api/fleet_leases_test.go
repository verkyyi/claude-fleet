package api

import (
	"bytes"
	"encoding/json"
	"net/http"
	"sync"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/fleetid"
)

// Issue leases (claude-fleet#1422, EPIC #1419 C3).

const leaseRepo = "verkyyi/claude-fleet"

// leaseNode is one machine in a lease test: its control channel, its token
// and the fleet its heartbeats register.
type leaseNode struct {
	*fakeNode
	host, machine, token string
	fleet                string
}

// newLeaseNode's label is also its hostname: show() re-derives the fleet from it.
func newLeaseNode(t *testing.T, h *harness, host, machine string) *leaseNode {
	t.Helper()
	n := connectFakeNode(t, h, host, true)
	ln := &leaseNode{fakeNode: n, host: host, machine: machine, token: h.tokens[host]}
	f := fakeFleet(t, machine, "fleet-"+host, leaseRepo, "/Users/x/"+host)
	ln.fleet = f.FleetID
	n.beat(host, "verkyyi", machine, f)
	waitFor(t, 3*time.Second, host+" fleet registered", func() bool {
		_, err := h.srv.Store.Fleet(f.FleetID)
		return err == nil
	})
	return ln
}

// show beats with the given issues live in this node's fleet.
func (n *leaseNode) show(t *testing.T, issues ...int) {
	n.beat(n.host, "verkyyi", n.machine, fakeFleet(t, n.machine, "fleet-"+n.host, leaseRepo, "/Users/x/"+n.host, issues...))
}

func (n *leaseNode) wid(issue int) string {
	return fleetid.WorkerID(n.fleet, fleetid.WorkerKey(issue, false, "", ""))
}

func leaseCall(t *testing.T, h *harness, token string, body map[string]any) (int, map[string]any) {
	t.Helper()
	b, _ := json.Marshal(body)
	req, _ := http.NewRequest(http.MethodPost, h.http.URL+"/v1/node/lease", bytes.NewReader(b))
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var out map[string]any
	_ = json.NewDecoder(resp.Body).Decode(&out)
	return resp.StatusCode, out
}

func (n *leaseNode) acquire(t *testing.T, h *harness, issue int, force bool) (int, map[string]any) {
	return leaseCall(t, h, n.token, map[string]any{"action": "acquire", "repo": leaseRepo, "issue": issue,
		"worker_id": n.wid(issue), "force": force})
}

func holderNode(out map[string]any) string {
	hv, _ := out["holder"].(map[string]any)
	s, _ := hv["node"].(string)
	return s
}

// leaseClock is the hub's lease clock in a test: real time until set, then
// frozen at whatever the test moved it to. Installed before any node
// connects, so no heartbeat goroutine ever reads the hook while it changes.
type leaseClock struct {
	mu  sync.Mutex
	at  time.Time
	set bool
}

func (c *leaseClock) now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	if !c.set {
		return time.Now()
	}
	return c.at
}

func (c *leaseClock) freeze(at time.Time) {
	c.mu.Lock()
	c.at, c.set = at, true
	c.mu.Unlock()
}

var leaseClocks sync.Map // *harness → *leaseClock

func newLeasePair(t *testing.T) (*harness, *leaseNode, *leaseNode) {
	t.Helper()
	h := newFleetHarness(t)
	c := &leaseClock{}
	h.srv.leaseNow = c.now
	leaseClocks.Store(h, c)
	m5 := newLeaseNode(t, h, "m5", machineA)
	m4 := newLeaseNode(t, h, "m4", machineB)
	return h, m5, m4
}

// The acceptance test: m5 and m4 open the same issue at the same moment —
// exactly one wins, and the other is told who holds it.
func TestLeaseConcurrentAcquireOneWinner(t *testing.T) {
	h, m5, m4 := newLeasePair(t)
	const rounds = 8
	type res struct {
		node   string
		status int
		out    map[string]any
	}
	results := make(chan res, 2*rounds)
	var wg sync.WaitGroup
	start := make(chan struct{})
	for i := 0; i < rounds; i++ {
		for _, n := range []*leaseNode{m5, m4} {
			wg.Add(1)
			go func(n *leaseNode) {
				defer wg.Done()
				<-start
				st, out := n.acquire(t, h, 77, false)
				results <- res{n.host, st, out}
			}(n)
		}
	}
	close(start)
	wg.Wait()
	close(results)
	winners := map[string]bool{}
	var losers []res
	for r := range results {
		switch r.status {
		case http.StatusOK:
			winners[r.node] = true
		case http.StatusConflict:
			losers = append(losers, r)
		default:
			t.Fatalf("%s: HTTP %d %v", r.node, r.status, r.out)
		}
	}
	if len(winners) != 1 {
		t.Fatalf("winners = %v, want exactly one node", winners)
	}
	var winner string
	for w := range winners {
		winner = w
	}
	if len(losers) != rounds {
		t.Fatalf("%d refusals, want %d (every call from the losing node)", len(losers), rounds)
	}
	for _, l := range losers {
		if l.node == winner || holderNode(l.out) != winner {
			t.Fatalf("refusal %+v: want the other node told %q holds it", l, winner)
		}
	}
	ls, _ := h.srv.Store.Leases(time.Now())
	if len(ls) != 1 || ls[0].Issue != 77 {
		t.Fatalf("leases = %+v", ls)
	}
}

// A session that ended (its window gone from the holder's heartbeat) frees
// the issue for anyone.
func TestLeaseReleasedWhenSessionEnds(t *testing.T) {
	h, m5, m4 := newLeasePair(t)
	if st, out := m5.acquire(t, h, 12, false); st != http.StatusOK {
		t.Fatalf("m5 acquire: %d %v", st, out)
	}
	// Before the window exists the beat does not show it: the lease holds.
	m5.show(t)
	time.Sleep(100 * time.Millisecond)
	if st, out := m4.acquire(t, h, 12, false); st != http.StatusConflict || holderNode(out) != "m5" {
		t.Fatalf("m4 acquire while m5 starts: %d %v", st, out)
	}
	m5.show(t, 12)
	waitFor(t, 3*time.Second, "lease seen", func() bool {
		ls, _ := h.srv.Store.Leases(time.Now())
		return len(ls) == 1 && ls[0].Seen
	})
	m5.show(t)
	waitFor(t, 3*time.Second, "lease released", func() bool {
		ls, _ := h.srv.Store.Leases(time.Now())
		return len(ls) == 0
	})
	if st, out := m4.acquire(t, h, 12, false); st != http.StatusOK {
		t.Fatalf("m4 acquire after the session ended: %d %v", st, out)
	}
}

// A node that goes silent keeps its leases for 30 minutes after the last beat
// that saw them, then they are released — nothing is re-dispatched.
func TestLeaseReleasedThirtyMinutesAfterNodeLost(t *testing.T) {
	h, m5, m4 := newLeasePair(t)
	base := time.Now()
	c, _ := leaseClocks.Load(h)
	set := func(d time.Duration) { c.(*leaseClock).freeze(base.Add(d)) }

	if st, _ := m5.acquire(t, h, 5, false); st != http.StatusOK {
		t.Fatal("m5 acquire")
	}
	m5.show(t, 5)
	waitFor(t, 3*time.Second, "lease seen", func() bool {
		ls, _ := h.srv.Store.Leases(base)
		return len(ls) == 1 && ls[0].Seen
	})
	// m5 goes silent now.
	set(29 * time.Minute)
	if st, out := m4.acquire(t, h, 5, false); st != http.StatusConflict || holderNode(out) != "m5" {
		t.Fatalf("29 min after m5's last beat: %d %v", st, out)
	}
	set(31 * time.Minute)
	if st, out := m4.acquire(t, h, 5, false); st != http.StatusOK {
		t.Fatalf("31 min after m5's last beat: %d %v", st, out)
	}
}

// A spawn that dies before its window exists frees the issue after the start
// grace, without any heartbeat ever showing it.
func TestLeaseStartGraceExpires(t *testing.T) {
	h, m5, m4 := newLeasePair(t)
	base := time.Now()
	c, _ := leaseClocks.Load(h)
	clk := c.(*leaseClock)
	clk.freeze(base)
	if st, _ := m5.acquire(t, h, 9, false); st != http.StatusOK {
		t.Fatal("m5 acquire")
	}
	clk.freeze(base.Add(leaseStartGrace - time.Minute))
	if st, _ := m4.acquire(t, h, 9, false); st != http.StatusConflict {
		t.Fatal("inside the start grace the lease must hold")
	}
	clk.freeze(base.Add(leaseStartGrace + time.Minute))
	if st, out := m4.acquire(t, h, 9, false); st != http.StatusOK {
		t.Fatalf("after the start grace: %d %v", st, out)
	}
}

// The same worker asking again keeps its lease; release gives it back; a
// forced take is granted and recorded with whom it displaced.
func TestLeaseRepeatReleaseAndForce(t *testing.T) {
	h, m5, m4 := newLeasePair(t)
	if st, _ := m5.acquire(t, h, 3, false); st != http.StatusOK {
		t.Fatal("first acquire")
	}
	if st, out := m5.acquire(t, h, 3, false); st != http.StatusOK {
		t.Fatalf("same worker again: %d %v", st, out)
	}
	st, out := m4.acquire(t, h, 3, true)
	if st != http.StatusOK {
		t.Fatalf("forced: %d %v", st, out)
	}
	if d, _ := out["displaced"].(map[string]any); d["node"] != "m5" {
		t.Fatalf("forced grant should name the displaced holder: %v", out)
	}
	var n int
	if err := h.srv.Store.DB().QueryRow(`SELECT COUNT(*) FROM fleet_audit WHERE action = 'lease_force'
		AND outcome LIKE 'FORCED from %m5'`).Scan(&n); err != nil || n != 1 {
		t.Fatalf("lease_force audit rows = %d (%v), want 1", n, err)
	}
	// m5 no longer holds it, so its release is a no-op; m4's is real.
	if st, out := leaseCall(t, h, m5.token, map[string]any{"action": "release", "repo": leaseRepo, "issue": 3,
		"worker_id": m5.wid(3)}); st != http.StatusOK || out["released"] != false {
		t.Fatalf("stale release: %d %v", st, out)
	}
	if st, out := leaseCall(t, h, m4.token, map[string]any{"action": "release", "repo": leaseRepo, "issue": 3,
		"worker_id": m4.wid(3)}); st != http.StatusOK || out["released"] != true {
		t.Fatalf("release: %d %v", st, out)
	}
	if st, _ := m5.acquire(t, h, 3, false); st != http.StatusOK {
		t.Fatal("acquire after release")
	}
}

// A node cannot take a lease in another node's name, and a malformed request
// or a stranger's token is refused.
func TestLeaseRefusals(t *testing.T) {
	h, m5, m4 := newLeasePair(t)
	if st, _ := leaseCall(t, h, m4.token, map[string]any{"action": "acquire", "repo": leaseRepo, "issue": 4,
		"worker_id": m5.wid(4)}); st != http.StatusForbidden {
		t.Fatalf("m4 acquiring for m5's fleet: HTTP %d, want 403", st)
	}
	if st, _ := leaseCall(t, h, m5.token, map[string]any{"action": "acquire", "repo": leaseRepo, "issue": 4,
		"worker_id": m5.wid(5)}); st != http.StatusBadRequest {
		t.Fatalf("worker_id for another issue: HTTP %d, want 400", st)
	}
	if st, _ := leaseCall(t, h, "nope", map[string]any{"action": "acquire", "repo": leaseRepo, "issue": 4,
		"worker_id": m5.wid(4)}); st != http.StatusUnauthorized {
		t.Fatalf("unknown token: HTTP %d, want 401", st)
	}
	if st, _ := leaseCall(t, h, viewerToken, map[string]any{"action": "acquire", "repo": leaseRepo, "issue": 4,
		"worker_id": m5.wid(4)}); st != http.StatusUnauthorized {
		t.Fatalf("viewer token is not a node: HTTP %d, want 401", st)
	}
}

// Off is today's hub: no lease route.
func TestLeaseRouteAbsentWhenModuleOff(t *testing.T) {
	h := newHarness(t)
	req, _ := http.NewRequest(http.MethodPost, h.http.URL+"/v1/node/lease", bytes.NewReader([]byte(`{}`)))
	req.Header.Set("Authorization", "Bearer "+h.enroll(t, "m5"))
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode == http.StatusOK || resp.StatusCode == http.StatusConflict {
		t.Fatalf("module off: /v1/node/lease answered %d", resp.StatusCode)
	}
}
