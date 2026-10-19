package api

import (
	"fmt"
	"math"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

// A burst of starts is spread (claude-fleet#2077, EPIC #2074 C6): a new
// session takes 10–30 s to show in a node's heartbeat, and in that window
// every pick of a burst chose the same machine. The hub now counts what it
// just sent where (Candidate.Recent) and scores as if those sessions were
// already there.

// burstStart sends one auto-placed worker_start and returns its placement.
func burstStart(t *testing.T, h *harness, i int) map[string]any {
	t.Helper()
	op := postFleet(t, h, "worker_start", map[string]any{"issue": 40 + i, "repo": writeRepo,
		"idempotency_key": fmt.Sprintf("burst-%d", i)}, 200)
	if op["status"] != "accepted" {
		t.Fatalf("start %d = %v; want accepted", i, op)
	}
	pl, _ := op["placement"].(map[string]any)
	return pl
}

// recentOf reads each candidate's `recent` off a journalled placement
// (absent = 0).
func recentOf(pl map[string]any) map[string]float64 {
	out := map[string]float64{}
	for _, c := range pl["candidates"].([]any) {
		cm := c.(map[string]any)
		r, _ := cm["recent"].(float64)
		out[cm["machine"].(string)] = r
	}
	return out
}

// The issue's acceptance check: two machines reading the same, four starts in
// a row with no heartbeat in between → two each; the journal says how many
// were just placed on each, and a first pick with nothing in flight carries no
// `recent` at all (the degenerate case, byte for byte).
func TestPlacementBurstSpreads(t *testing.T) {
	h, macD, macC, f5, f4 := twoNodes(t)
	beatMem(t, h, macD, "mac-d", machineA, 2, 32<<30, 64<<30, 1, 3, f5)
	beatMem(t, h, macC, "mac-c", machineB, 2, 32<<30, 64<<30, 1, 3, f4)
	got := map[string]int{}
	var first, last map[string]any
	for i := 0; i < 4; i++ {
		pl := burstStart(t, h, i)
		got[pl["machine"].(string)]++
		if i == 0 {
			first = pl
		}
		last = pl
	}
	if got["mac-d"] != 2 || got["mac-c"] != 2 {
		t.Fatalf("4 starts landed mac-d=%d mac-c=%d; want 2 and 2 (last placement: %v)", got["mac-d"], got["mac-c"], last["reason"])
	}
	for m, r := range recentOf(first) {
		if r != 0 {
			t.Fatalf("the first pick's %s carries recent=%v; want none", m, r)
		}
	}
	if b, _ := first["candidates"].([]any); strings.Contains(fmt.Sprint(b), "recent") {
		t.Fatalf("the first pick's candidates spell recent: %v", b)
	}
	// At the 4th pick one machine had two in flight, the other one; the
	// pick went to the one with one.
	chosen := last["machine"].(string)
	rec := recentOf(last)
	if rec[chosen] != 1 || rec["mac-d"]+rec["mac-c"] != 3 {
		t.Fatalf("4th placement recent = %v (chose %s); want 1 on the chosen, 2 on the other", rec, chosen)
	}
	if r := last["reason"].(string); !strings.Contains(r, "1 just placed") {
		t.Fatalf("reason %q does not say how many were just placed", r)
	}
	if macD.count()+macC.count() != 4 {
		t.Fatalf("writes sent: mac-d=%d mac-c=%d; want 4 in all", macD.count(), macC.count())
	}
}

// A start ages out of the table after recentWindow (90 s); until then it
// counts, whatever the heartbeat says, when the count is unknown.
func TestPlacementRecentExpires(t *testing.T) {
	var r recentTable
	t0 := time.Now()
	r.note("ep", intp(3), t0)
	r.note("ep", nil, t0.Add(time.Second))
	if n := r.count("ep", intp(3), t0.Add(89*time.Second)); n != 2 {
		t.Fatalf("at 89 s: %d in flight; want 2", n)
	}
	if n := r.count("ep", intp(3), t0.Add(90*time.Second)); n != 1 {
		t.Fatalf("at 90 s: %d in flight; want 1 (the first aged out)", n)
	}
	if n := r.count("ep", intp(3), t0.Add(92*time.Second)); n != 0 {
		t.Fatalf("at 92 s: %d in flight; want 0", n)
	}
	if n := r.count("other", nil, t0); n != 0 {
		t.Fatalf("an endpoint never sent to: %d; want 0", n)
	}
}

// Once the node's beat shows the sessions, they are no longer in flight — and
// one beat is credited once: four sent at count 3, a beat saying 5 clears two,
// the next two are measured against 5, a beat saying 7 clears the rest; a
// count that fell credits nothing.
func TestPlacementRecentReflectedByBeat(t *testing.T) {
	var r recentTable
	t0 := time.Now()
	for i := 0; i < 2; i++ {
		r.note("ep", intp(3), t0)
	}
	if n := r.count("ep", intp(5), t0.Add(time.Second)); n != 0 {
		t.Fatalf("beat 5 after two sent at 3: %d in flight; want 0", n)
	}
	for i := 0; i < 4; i++ {
		r.note("ep", intp(3), t0)
	}
	if n := r.count("ep", intp(5), t0.Add(time.Second)); n != 2 {
		t.Fatalf("beat 5 after four sent at 3: %d in flight; want 2", n)
	}
	if n := r.count("ep", intp(5), t0.Add(2*time.Second)); n != 2 {
		t.Fatalf("the same beat read again: %d in flight; want still 2 (never credited twice)", n)
	}
	if n := r.count("ep", intp(4), t0.Add(3*time.Second)); n != 2 {
		t.Fatalf("a count that fell to 4: %d in flight; want still 2", n)
	}
	if n := r.count("ep", intp(7), t0.Add(4*time.Second)); n != 0 {
		t.Fatalf("beat 7: %d in flight; want 0", n)
	}
	r.forget("ep", r.note("ep", intp(7), t0))
	if n := r.count("ep", intp(7), t0.Add(5*time.Second)); n != 0 {
		t.Fatalf("a forgotten start still counts: %d", n)
	}
}

// beatSessions is beatMem at load 2, 32 of 64 GiB, with the given session
// count — and waits for that count to land, which is all that changes.
func beatSessions(t *testing.T, h *harness, n *writeNode, host, machine string, sessions int, f control.Fleet) {
	t.Helper()
	beat(t, n.conn, control.Proto, control.Heartbeat{Hostname: host, OSUser: "frank", MachineID: machine,
		Load1: 2, NCPU: 10, MemFreeBytes: 32 << 30, MemTotalBytes: 64 << 30, MemPressure: 1,
		Sessions: sessions, Fleets: []control.Fleet{f}, ObservedAt: time.Now()})
	waitFor(t, 3*time.Second, host+"'s session count landed", func() bool {
		got, _, _ := h.srv.nodeStatusOf("ep_"+host, time.Now())
		return got.Sessions == sessions
	})
}

// Through judge: two starts sent to mac-c lower its score as two more sessions
// would (one core and 1.5 GiB each); mac-c's beat reporting them restores the
// plain load score, which with nothing in flight is loadScore to the byte.
func TestPlacementRecentScoredUntilTheBeatShowsIt(t *testing.T) {
	h, macD, macC, f5, f4 := twoNodes(t)
	beatMem(t, h, macD, "mac-d", machineA, 2, 32<<30, 64<<30, 1, 3, f5)
	beatMem(t, h, macC, "mac-c", machineB, 2, 32<<30, 64<<30, 1, 3, f4)
	plain := judgeAll(t, h, nil)
	if plain["mac-c"].Score != plain["mac-d"].Score || plain["mac-c"].Recent != 0 || plain["mac-c"].Score != 0.5 {
		t.Fatalf("plain: mac-c %+v mac-d %+v; want both 0.5 with nothing in flight", plain["mac-c"], plain["mac-d"])
	}
	now := time.Now()
	h.srv.recent.note("ep_mac-c", intp(3), now)
	h.srv.recent.note("ep_mac-c", intp(3), now)
	c := judgeAll(t, h, nil)
	// load 0.2/core + 2/10 cores = 0.4/core → cpu idle 0.5; 32 − 3 GiB of 64 → 0.453
	if c["mac-c"].Recent != 2 || c["mac-c"].Score != 0.453 || c["mac-d"].Score != 0.5 || c["mac-d"].Recent != 0 {
		t.Fatalf("two in flight on mac-c: mac-c %+v mac-d %+v; want mac-c recent 2 scored 0.453, mac-d untouched", c["mac-c"], c["mac-d"])
	}
	if !better(c["mac-d"], c["mac-c"]) {
		t.Fatal("mac-d should now win over mac-c")
	}
	beatSessions(t, h, macC, "mac-c", machineB, 4, f4) // one of them is in the count
	c = judgeAll(t, h, nil)
	if c["mac-c"].Recent != 1 || c["mac-c"].Score != 0.477 {
		t.Fatalf("beat says 4: mac-c %+v; want recent 1 scored 0.477", c["mac-c"])
	}
	beatSessions(t, h, macC, "mac-c", machineB, 5, f4) // both are
	c = judgeAll(t, h, nil)
	if c["mac-c"].Recent != 0 || c["mac-c"].Score != 0.5 {
		t.Fatalf("beat says 5: mac-c %+v; want nothing in flight, score 0.5 again", c["mac-c"])
	}
}

// Readings the beat did not give still move with what is in flight — so a
// burst at two bare machines is spread too — and with nothing in flight every
// shape is loadScore exactly.
func TestRecentScore(t *testing.T) {
	f := func(x float64) *float64 { return &x }
	for _, tc := range []struct {
		name        string
		load        *float64
		ncpu        int
		free, total uint64
		recent      int
		want        float64
	}{
		{"nothing in flight is loadScore", f(0.4), 10, 48 << 30, 64 << 30, 0, 0.5},
		{"one start: a core more", f(0.4), 10, 48 << 30, 64 << 30, 1, 0.375},
		{"memory tighter: 1.5 GiB each", f(0), 10, 4 << 30, 16 << 30, 1, 0.15625},
		{"clamps at zero", f(0.7), 10, 48 << 30, 64 << 30, 4, 0},
		{"no readings at all: a share each", nil, 0, 0, 0, 2, 0.375},
		{"no readings, nothing in flight", nil, 0, 0, 0, 0, 0.5},
	} {
		if got := recentScore(tc.load, tc.ncpu, tc.free, tc.total, tc.recent); math.Abs(got-tc.want) > 1e-9 {
			t.Errorf("%s: recentScore = %v; want %v", tc.name, got, tc.want)
		}
	}
}

// The room a node reported is spoken for by what was just sent there: room 1
// with one in flight is held as paused (the C5 verdict, with the count), and
// with nothing in flight it is a candidate as before.
func TestPlacementRecentTakesTheRoom(t *testing.T) {
	h, macD, macC, f5, f4 := twoNodes(t)
	beatAdmit(t, h, macD, "mac-d", machineA, 2, boolp(true), "", 5, f5)
	beatAdmit(t, h, macC, "mac-c", machineB, 2, boolp(true), "", 1, f4)
	c := judgeAll(t, h, nil)
	if !c["mac-c"].Eligible || !c["mac-d"].Eligible {
		t.Fatalf("nothing in flight: mac-c %+v mac-d %+v; want both eligible", c["mac-c"], c["mac-d"])
	}
	h.srv.recent.note("ep_mac-c", intp(2), time.Now())
	h.srv.recent.note("ep_mac-d", intp(2), time.Now())
	c = judgeAll(t, h, nil)
	if c["mac-c"].Eligible || !strings.HasPrefix(c["mac-c"].Excluded, excludedPaused) || !strings.Contains(c["mac-c"].Excluded, "room 1") || !strings.Contains(c["mac-c"].Excluded, "刚派出 1 个") {
		t.Fatalf("room 1 with one in flight: %+v; want 机器暂停接新 naming the room and the one in flight", c["mac-c"])
	}
	if !c["mac-d"].Eligible || c["mac-d"].Recent != 1 {
		t.Fatalf("room 5 with one in flight: %+v; want still a candidate", c["mac-d"])
	}
	if !excludedForFullness(c["mac-c"].Excluded) {
		t.Fatal("the held room should count as full for the all-full verdict")
	}
}

// A start the node refused outright never opened: it leaves the table at once,
// so the next pick is not steered away from a machine that took nothing.
func TestPlacementRecentForgottenOnRefusal(t *testing.T) {
	h, macD, macC, f5, f4 := twoNodes(t)
	beatMem(t, h, macD, "mac-d", machineA, 2, 32<<30, 64<<30, 1, 3, f5)
	beatMem(t, h, macC, "mac-c", machineB, 2, 32<<30, 64<<30, 1, 3, f4)
	macC.setAnswer(func(map[string]any) (any, *control.Error) {
		return nil, &control.Error{Code: "AT_CAPACITY", Message: "the gate held it"}
	})
	op := postFleet(t, h, "worker_start", map[string]any{"issue": 51, "fleet_id": f4.FleetID, "idempotency_key": "named-51"}, 200)
	if op["status"] != "failed" {
		t.Fatalf("a refused named start = %v; want failed", op)
	}
	c := judgeAll(t, h, nil)
	if c["mac-c"].Recent != 0 || c["mac-c"].Score != 0.5 {
		t.Fatalf("after a refusal mac-c %+v; want nothing in flight", c["mac-c"])
	}
	macC.setAnswer(accepted)
	op = postFleet(t, h, "worker_start", map[string]any{"issue": 52, "fleet_id": f4.FleetID, "idempotency_key": "named-52"}, 200)
	if op["status"] != "accepted" {
		t.Fatalf("a named start = %v; want accepted", op)
	}
	if c = judgeAll(t, h, nil); c["mac-c"].Recent != 1 {
		t.Fatalf("a named start counts too: mac-c %+v; want recent 1", c["mac-c"])
	}
}
