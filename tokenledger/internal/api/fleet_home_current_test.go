package api

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
)

// Back to the last home session (claude-fleet#2564, EPIC #2563 C1).

// homeInventory stores f's window list as its node's heartbeat would.
func homeInventory(t *testing.T, h *harness, fleetID string, at time.Time, workers ...map[string]any) {
	t.Helper()
	b, _ := json.Marshal(workers)
	if err := h.srv.Store.UpdateFleetWorkers(fleetID, "running", len(workers), string(b), at); err != nil {
		t.Fatal(err)
	}
}

func homeStarts(m *writeNode, wid string) {
	m.setOpGet(finished("succeeded", map[string]any{"exit": 0, "window": "@6",
		"workers": []map[string]any{{"window_id": "@6", "worker_id": wid}}}))
}

func homeAsk(extra map[string]any) map[string]any {
	p := map[string]any{"no_repo": true, "kind": "scratch", "home": true, "agent": "claude", "node": "auto", "wait": 5}
	for k, v := range extra {
		p[k] = v
	}
	return p
}

// The completion criterion: two home places in a row — the second RESUMEs
// the first, nothing sent; after its /exit (the inventory says exited) the
// third opens a new one; --new opens another beside a live one; a session the
// inventory no longer lists (read after it started) is no current.
func TestClientPlaceHomeResumesTheCurrent(t *testing.T) {
	h, _, m4, _, f4 := twoNodes(t)
	lease, key := clientLeaseFor(t, h)
	wid1 := f4.FleetID + "/scratch-1"
	homeStarts(m4, wid1)

	st, out := clientPlace(t, h, lease, key, homeAsk(map[string]any{"idempotency_key": "h-1"}))
	if st != 200 || out.State != "done" || out.WorkerID != wid1 || m4.count() != 1 {
		t.Fatalf("first = %d %+v (m4 writes %d); want one start, done", st, out, m4.count())
	}
	// Its node's next heartbeat lists it, idle.
	homeInventory(t, h, f4.FleetID, time.Now().Add(2*time.Second),
		map[string]any{"worker_id": wid1, "state": "idle"})

	st, out = clientPlace(t, h, lease, key, homeAsk(map[string]any{"idempotency_key": "h-2"}))
	if st != 200 || out.Exit != 0 || out.State != "resume" || out.WorkerID != wid1 || out.Machine != "m4" {
		t.Fatalf("second = %d %+v; want RESUME of %s on m4", st, out, wid1)
	}
	if want := "RESUME m4 " + wid1 + "\t"; !strings.HasPrefix(out.Line, want) {
		t.Fatalf("line = %q; want %q…", out.Line, want)
	}
	if m4.count() != 1 {
		t.Fatalf("a RESUME sent a start (m4 writes %d)", m4.count())
	}
	// The other agent is another current: a codex ask opens its own.
	homeStarts(m4, f4.FleetID+"/scratch-9")
	if _, out := clientPlace(t, h, lease, key, homeAsk(map[string]any{"agent": "codex", "idempotency_key": "h-c"})); out.State != "done" {
		t.Fatalf("codex = %+v; want a start of its own", out)
	}
	if m4.count() != 2 {
		t.Fatalf("m4 writes %d; want 2", m4.count())
	}

	// /exit: the wrapper's recovery page, @claude_state=exited.
	homeInventory(t, h, f4.FleetID, time.Now().Add(2*time.Second),
		map[string]any{"worker_id": wid1, "state": "exited"})
	wid2 := f4.FleetID + "/scratch-2"
	homeStarts(m4, wid2)
	st, out = clientPlace(t, h, lease, key, homeAsk(map[string]any{"idempotency_key": "h-3"}))
	if st != 200 || out.State != "done" || out.WorkerID != wid2 || m4.count() != 3 {
		t.Fatalf("after /exit = %d %+v (m4 writes %d); want a new start", st, out, m4.count())
	}

	// --new beside a live current: another start, and it is the current now.
	homeInventory(t, h, f4.FleetID, time.Now().Add(2*time.Second),
		map[string]any{"worker_id": wid2, "state": "working"})
	wid3 := f4.FleetID + "/scratch-3"
	homeStarts(m4, wid3)
	if _, out := clientPlace(t, h, lease, key, homeAsk(map[string]any{"new": true, "idempotency_key": "h-4"})); out.State != "done" || out.WorkerID != wid3 {
		t.Fatalf("--new = %+v; want a start of %s", out, wid3)
	}
	homeInventory(t, h, f4.FleetID, time.Now().Add(2*time.Second),
		map[string]any{"worker_id": wid2, "state": "working"}, map[string]any{"worker_id": wid3, "state": "idle"})
	if _, out := clientPlace(t, h, lease, key, homeAsk(map[string]any{"idempotency_key": "h-5"})); out.State != "resume" || out.WorkerID != wid3 {
		t.Fatalf("after --new = %+v; want RESUME of %s", out, wid3)
	}

	// Gone from an inventory read after it started (reaped, the window
	// closed): no current, a new start.
	homeInventory(t, h, f4.FleetID, time.Now().Add(2*time.Second),
		map[string]any{"worker_id": wid2, "state": "working"})
	homeStarts(m4, f4.FleetID+"/scratch-4")
	if _, out := clientPlace(t, h, lease, key, homeAsk(map[string]any{"idempotency_key": "h-6"})); out.State != "done" || m4.count() != 5 {
		t.Fatalf("gone = %+v (m4 writes %d); want a new start", out, m4.count())
	}
}

// A second device of the same person resumes the first's session and is told
// the first one has it open; a test identity never sees the person's current.
func TestClientPlaceHomeAnotherDevice(t *testing.T) {
	h, _, m4, _, f4 := twoNodes(t)
	lease, key := clientLeaseFor(t, h)
	wid := f4.FleetID + "/scratch-1"
	homeStarts(m4, wid)
	if _, out := clientPlace(t, h, lease, key, homeAsk(map[string]any{"idempotency_key": "d-1"})); out.State != "done" {
		t.Fatalf("first = %+v", out)
	}
	homeInventory(t, h, f4.FleetID, time.Now().Add(2*time.Second), map[string]any{"worker_id": wid, "state": "idle"})

	var acq ClientLeaseResponse
	if st := clientPost(t, h, control.ClientPath, ClientLeaseRequest{Action: "acquire", Device: "iPad"}, &acq); st != 200 || acq.State != "active" {
		t.Fatalf("acquire iPad = %d %+v", st, acq)
	}
	st, out := clientPlace(t, h, acq.Lease.ID, acq.ActionKey, homeAsk(map[string]any{"idempotency_key": "d-2"}))
	if st != 200 || out.State != "resume" || out.WorkerID != wid {
		t.Fatalf("iPad = %d %+v; want RESUME of %s", st, out, wid)
	}
	if len(out.AlsoOpen) != 1 || out.AlsoOpen[0] != "MacBook" {
		t.Fatalf("also_open = %v; want [MacBook]", out.AlsoOpen)
	}
	if m4.count() != 1 {
		t.Fatalf("m4 writes %d; want 1", m4.count())
	}
}

// home is a no-repo scratch only; new goes with home.
func TestClientPlaceHomeShape(t *testing.T) {
	h, _, m4, _, _ := twoNodes(t)
	lease, key := clientLeaseFor(t, h)
	for _, bad := range []map[string]any{
		{"repo": writeRepo, "kind": "scratch", "home": true},
		{"no_repo": true, "kind": "new", "title": "x", "home": true},
		{"no_repo": true, "kind": "scratch", "new": true},
	} {
		if st, _ := clientPlace(t, h, lease, key, bad); st != 400 {
			t.Fatalf("%v = %d; want 400", bad, st)
		}
	}
	if m4.count() != 0 {
		t.Fatalf("a refused call sent a write (m4 writes %d)", m4.count())
	}
}
