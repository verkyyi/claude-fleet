package api

import (
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// A machine that declines an auto send is not the end of it
// (claude-fleet#1610): the next candidate gets the start, the asker last.

// threeNodes is twoNodes plus m3: m4 (0.1/core) is placement's first pick,
// m3 (0.6/core) its second, m5 (1.0/core) is out unless re-beaten.
func threeNodes(t *testing.T) (*harness, *writeNode, *writeNode, *writeNode, control.Fleet, control.Fleet, control.Fleet) {
	t.Helper()
	h, m5, m4, f5, f4 := twoNodes(t)
	m3 := connectWriteNode(t, h, "m3")
	f3 := fakeFleet(t, machineC, "fleet-m3", writeRepo, "/u/verk/claude-fleet", 3)
	m3.beatLoad("m3", "verk", machineC, 6, 1, f3)
	waitFor(t, 3*time.Second, "three fleets registered", func() bool {
		return len(getFleet(t, h, "/v1/fleet/fleet_list", 200)["fleets"].([]any)) == 3
	})
	waitLoad(t, h, "m3", 6)
	return h, m5, m4, m3, f5, f4, f3
}

// declines is a node's record of a start its spawn refused with exit code
// and line — the shape of today's mini2: `fleet discover: fork/exec …`.
func declines(exit int, line string) func(map[string]any) (any, *control.Error) {
	return finished("failed", map[string]any{"error": map[string]any{"code": "FAILED",
		"message": "Fleet refused to start the worker: " + line, "exit": exit, "stderr1": line}})
}

const discoverFail = "fleet discover: fork/exec fleet-control.py: invalid argument"

func attemptsOf(t *testing.T, out map[string]any) []map[string]any {
	t.Helper()
	raw, _ := out["attempts"].([]any)
	as := []map[string]any{}
	for _, a := range raw {
		as = append(as, a.(map[string]any))
	}
	return as
}

// The completion criterion's first: m4 declines → m3 opens it; the answer
// says m4 went first, the lease is m3's, and m3 got a start of its own.
func TestNodePlaceDeclinedTriesNextMachine(t *testing.T) {
	h, m5, m4, m3, f5, _, f3 := threeNodes(t)
	tok5 := h.tokens["m5"]
	wid5 := issueWID(f5.FleetID, 41)
	if st, _ := leaseCall(t, h, tok5, map[string]any{"action": "acquire", "repo": writeRepo, "issue": 41, "worker_id": wid5}); st != 200 {
		t.Fatal("m5's lease")
	}
	m4.setOpGet(declines(1, discoverFail))
	m3.setOpGet(finished("succeeded", map[string]any{"exit": 0, "window": "@41"}))

	st, out := placeCall(t, h, tok5, map[string]any{"repo": writeRepo, "issue": 41, "worker_id": wid5,
		"idempotency_key": "place-41", "tries": 3})
	oc := placeOutcomeOf(t, out)
	if st != 200 || oc["state"] != "done" || out["placement"].(map[string]any)["machine"] != "m3" {
		t.Fatalf("place = %d %v; want done on m3", st, out)
	}
	as := attemptsOf(t, out)
	if len(as) != 1 || as[0]["machine"] != "m4" || as[0]["exit"] != 1.0 || as[0]["why"] != discoverFail ||
		as[0]["operation_id"] == "" {
		t.Fatalf("attempts = %v; want m4's decline with its line", as)
	}
	if m4.count() != 1 || m3.count() != 1 || m5.count() != 0 {
		t.Fatalf("writes m4=%d m3=%d m5=%d; want one start each on m4 and m3", m4.count(), m3.count(), m5.count())
	}
	if a, b := m4.writes[0]["operation_id"], m3.writes[0]["operation_id"]; a == b || b == nil {
		t.Fatalf("m3's start is operation %v, m4's %v; want a new start, not m4's again", b, a)
	}
	ls, _ := h.srv.Store.Leases(time.Now())
	if len(ls) != 1 || ls[0].FleetID != f3.FleetID {
		t.Fatalf("leases = %+v; want #41 m3's", ls)
	}
}

// Every machine declines: ALL_DECLINED with each reason, and the lease is the
// asker's again — so its exit gives it back and the next send needs no --force.
func TestNodePlaceAllDeclinedRefuses(t *testing.T) {
	h, _, m4, m3, f5, _, _ := threeNodes(t)
	tok5 := h.tokens["m5"]
	wid5 := issueWID(f5.FleetID, 42)
	if st, _ := leaseCall(t, h, tok5, map[string]any{"action": "acquire", "repo": writeRepo, "issue": 42, "worker_id": wid5}); st != 200 {
		t.Fatal("m5's lease")
	}
	m4.setOpGet(declines(1, discoverFail))
	m3.setOpGet(declines(2, "fleet-m3 is full: 8/8"))
	st, out := placeCall(t, h, tok5, map[string]any{"repo": writeRepo, "issue": 42, "worker_id": wid5, "tries": 3})
	e, _ := out["error"].(map[string]any)
	if st != 409 || e["code"] != "ALL_DECLINED" || !strings.Contains(e["message"].(string), "m4: declined: "+discoverFail) ||
		!strings.Contains(e["message"].(string), "m3: declined: fleet-m3 is full: 8/8") {
		t.Fatalf("place = %d %v; want ALL_DECLINED naming both machines' reasons", st, out)
	}
	if as := attemptsOf(t, out); len(as) != 2 || as[0]["machine"] != "m4" || as[1]["machine"] != "m3" {
		t.Fatalf("attempts = %v; want m4 then m3", as)
	}
	ls, _ := h.srv.Store.Leases(time.Now())
	if len(ls) != 1 || ls[0].WorkerID != wid5 {
		t.Fatalf("leases = %+v; want #42 back with the asker", ls)
	}
	if st, _ := leaseCall(t, h, tok5, map[string]any{"action": "release", "repo": writeRepo, "issue": 42, "worker_id": wid5}); st != 200 {
		t.Fatal("release")
	}
	if st, out := leaseCall(t, h, tok5, map[string]any{"action": "acquire", "repo": writeRepo, "issue": 42, "worker_id": wid5}); st != 200 {
		t.Fatalf("re-send without --force = %d %v; want granted", st, out)
	}
}

// The asking machine comes last, whatever its score: m4 declines, m3 (worse
// than m5) is tried before it, m3 declines, and the answer is LOCAL m5.
func TestNodePlaceAskerIsTriedLast(t *testing.T) {
	h, m5, m4, m3, f5, f4, _ := threeNodes(t)
	m5.beatLoad("m5", "verk", machineA, 2, 1, f5) // 0.2/core: better than m3
	waitLoad(t, h, "m5", 2)
	m4.beatLoad("m4", "verk", machineB, 0.5, 1, f4)
	tok5 := h.tokens["m5"]
	wid5 := issueWID(f5.FleetID, 43)
	m4.setOpGet(declines(1, discoverFail))
	m3.setOpGet(declines(1, "no checkout"))
	// m4 must be first: wait for its cooler beat.
	waitLoad(t, h, "m4", 0.5)
	st, out := placeCall(t, h, tok5, map[string]any{"repo": writeRepo, "issue": 43, "worker_id": wid5, "tries": 3})
	if st != 200 || out["local"] != true || out["placement"].(map[string]any)["machine"] != "m5" {
		t.Fatalf("place = %d %v; want LOCAL m5 after the others", st, out)
	}
	if as := attemptsOf(t, out); len(as) != 2 || as[0]["machine"] != "m4" || as[1]["machine"] != "m3" {
		t.Fatalf("attempts = %v; want m4 then m3 before the asker", as)
	}
	if m5.count() != 0 {
		t.Fatal("LOCAL sent the asker a write")
	}
}

// A machine named is honoured or refused, never swapped; a "claimed" no is
// the issue's, not the machine's — neither tries another machine.
func TestNodePlaceNamedOrClaimedIsTriedOnce(t *testing.T) {
	h, _, m4, m3, f5, _, _ := threeNodes(t)
	tok5 := h.tokens["m5"]
	m4.setOpGet(declines(1, discoverFail))
	st, out := placeCall(t, h, tok5, map[string]any{"repo": writeRepo, "issue": 44, "worker_id": issueWID(f5.FleetID, 44),
		"node": "m4", "tries": 3})
	if oc := placeOutcomeOf(t, out); st != 200 || oc["state"] != "refused" || m3.count() != 0 || out["attempts"] != nil {
		t.Fatalf("named m4 = %d %v (m3 writes %d); want m4's decline alone", st, out, m3.count())
	}
	m4.setOpGet(declines(3, "#45 already claimed (assigned)"))
	st, out = placeCall(t, h, tok5, map[string]any{"repo": writeRepo, "issue": 45, "worker_id": issueWID(f5.FleetID, 45), "tries": 3})
	if oc := placeOutcomeOf(t, out); st != 200 || oc["exit"] != 3.0 || m3.count() != 0 {
		t.Fatalf("claimed = %d %v (m3 writes %d); want exit 3 and no second machine", st, out, m3.count())
	}
}

// The client's place (claude-fleet#1777) tries the next machine the same way;
// its line names the machine that declined first, and every machine declining
// is REFUSED ALL_DECLINED with no lease left behind.
func TestClientPlaceDeclinedTriesNextMachine(t *testing.T) {
	h, _, m4, m3, _, _, f3 := threeNodes(t)
	lease, key := clientLeaseFor(t, h)
	m4.setOpGet(declines(1, discoverFail))
	m3.setOpGet(finished("succeeded", map[string]any{"exit": 0, "window": "@51",
		"workers": []map[string]any{{"window_id": "@51", "worker_id": f3.FleetID + "/issue-51"}}}))
	st, out := clientPlace(t, h, lease, key, map[string]any{"repo": writeRepo, "kind": "issue", "issue": 51, "wait": 5})
	if st != 200 || out.Exit != 0 || out.Machine != "m3" || len(out.Attempts) != 1 ||
		!strings.HasPrefix(out.Line, "REMOTE m3 "+out.OperationID+" done ") ||
		!strings.HasSuffix(out.Line, "\tafter m4:"+out.Attempts[0].OperationID+":1") {
		t.Fatalf("place = %d %+v; want done on m3 after m4", st, out)
	}
	if ls, _ := h.srv.Store.Leases(time.Now()); len(ls) != 1 || ls[0].FleetID != f3.FleetID {
		t.Fatalf("leases = %+v; want #51 m3's", ls)
	}

	m3.setOpGet(declines(2, "fleet-m3 is full: 8/8"))
	st, out = clientPlace(t, h, lease, key, map[string]any{"repo": writeRepo, "kind": "issue", "issue": 52, "wait": 5})
	if st != 200 || out.Exit != 4 || !strings.HasPrefix(out.Line, "REFUSED ALL_DECLINED\t") ||
		!strings.Contains(out.Line, "m4: declined: "+discoverFail) || !strings.Contains(out.Line, "m3: declined: fleet-m3 is full") ||
		!strings.Contains(out.Line, "\tafter m4:") || len(out.Attempts) != 2 {
		t.Fatalf("all declined = %d %+v; want REFUSED ALL_DECLINED with both", st, out)
	}
	for _, l := range mustLeases(t, h) {
		if l.Issue == 52 {
			t.Fatalf("a send every machine declined kept a lease: %+v", l)
		}
	}
}

func mustLeases(t *testing.T, h *harness) []store.Lease {
	t.Helper()
	ls, err := h.srv.Store.Leases(time.Now())
	if err != nil {
		t.Fatal(err)
	}
	return ls
}
