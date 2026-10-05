package api

import (
	"bytes"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/fleetid"
)

// A node's own placement (claude-fleet#1425, EPIC #1419 C6).

// The handler waits on a REMOTE start's outcome (claude-fleet#1586); under
// test that wait is short, so a node that never finishes costs 300ms.
func init() { placeWait, placePoll = 300*time.Millisecond, 10*time.Millisecond }

// finished is the node's record of an operation that reached a final state.
func finished(status string, result map[string]any) func(map[string]any) (any, *control.Error) {
	return func(env map[string]any) (any, *control.Error) {
		return map[string]any{"operation_id": env["operation_id"], "fleet_id": env["fleet_id"],
			"action": env["action"], "status": status, "result": result}, nil
	}
}

// placeOutcomeOf is the answer's outcome object, failing the test without one.
func placeOutcomeOf(t *testing.T, out map[string]any) map[string]any {
	t.Helper()
	oc, ok := out["outcome"].(map[string]any)
	if !ok {
		t.Fatalf("no outcome in %v", out)
	}
	return oc
}

func placeCall(t *testing.T, h *harness, token string, body map[string]any) (int, map[string]any) {
	t.Helper()
	b, _ := json.Marshal(body)
	req, _ := http.NewRequest(http.MethodPost, h.http.URL+"/v1/node/place", bytes.NewReader(b))
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

func issueWID(fleet string, issue int) string {
	return fleetid.WorkerID(fleet, fleetid.WorkerKey(issue, false, "", ""))
}

// The issue's acceptance check: m5 above 0.8 load per core takes the lease,
// asks where to open #7, and the session goes to m4 — with the parent's
// worker_id, the placement on the journal, and the lease now m4's.
func TestNodePlaceBusyNodeHandsStartToIdleOne(t *testing.T) {
	h, m5, m4, f5, f4 := twoNodes(t)
	tok5, tok4 := h.tokens["m5"], h.tokens["m4"]
	wid5, parent := issueWID(f5.FleetID, 7), issueWID(f5.FleetID, 1)
	if st, out := leaseCall(t, h, tok5, map[string]any{"action": "acquire", "repo": writeRepo, "issue": 7, "worker_id": wid5}); st != 200 {
		t.Fatalf("m5's lease: %d %v", st, out)
	}

	st, out := placeCall(t, h, tok5, map[string]any{"repo": writeRepo, "issue": 7, "worker_id": wid5,
		"origin_wid": parent, "idempotency_key": "place-7"})
	if st != 200 || out["local"] != false {
		t.Fatalf("place = %d %v; want a remote placement", st, out)
	}
	pl := out["placement"].(map[string]any)
	if pl["machine"] != "m4" || !strings.Contains(pl["reason"].(string), "m5 excluded: load 1.00/core > 0.8") {
		t.Fatalf("placement = %v; want m4, with m5's load as the reason", pl)
	}
	op := out["operation"].(map[string]any)
	if op["status"] != "accepted" || op["fleet_id"] != f4.FleetID {
		t.Fatalf("operation = %v; want accepted on m4's fleet", op)
	}
	if m5.count() != 0 || m4.count() != 1 {
		t.Fatalf("writes: m5=%d m4=%d; want 0 and 1", m5.count(), m4.count())
	}
	params := m4.writes[0]["params"].(map[string]any)
	if params["issue"].(float64) != 7 || params["origin_wid"] != parent || params["repo"] != writeRepo {
		t.Fatalf("m4 was sent %v; want issue 7 with the parent's worker_id", params)
	}
	if m4.writes[0]["actor"] != "node:verk@m5" {
		t.Fatalf("actor = %v; want the asking node", m4.writes[0]["actor"])
	}
	// The journal keeps the choice: the metric reads worker_start placements.
	got := getFleet(t, h, "/v1/fleet/operation_get?operation_id="+op["operation_id"].(string), 200)
	if got["placement"].(map[string]any)["machine"] != "m4" {
		t.Fatalf("operation_get lost the placement: %v", got)
	}

	// The lease went with the start: m4's spawn takes it up, m5 no longer can.
	if st, out := leaseCall(t, h, tok4, map[string]any{"action": "acquire", "repo": writeRepo, "issue": 7,
		"worker_id": issueWID(f4.FleetID, 7)}); st != 200 {
		t.Fatalf("m4's spawn could not take the handed-over lease: %d %v", st, out)
	}
	if st, out := leaseCall(t, h, tok5, map[string]any{"action": "acquire", "repo": writeRepo, "issue": 7,
		"worker_id": wid5}); st != 409 || holderNode(out) != "m4" {
		t.Fatalf("m5 re-acquire = %d %v; want HELD by m4", st, out)
	}

	// The same key again: the same operation, no second start.
	if st, again := placeCall(t, h, tok5, map[string]any{"repo": writeRepo, "issue": 7, "worker_id": wid5,
		"origin_wid": parent, "idempotency_key": "place-7"}); st != 200 && st != 409 || m4.count() != 1 {
		t.Fatalf("repeat = %d %v (m4 writes %d); want no second start", st, again, m4.count())
	}
}

// An idle asker keeps its own session: LOCAL, nothing sent, the lease stays.
func TestNodePlaceIdleNodeStaysLocal(t *testing.T) {
	h, m5, m4, f5, f4 := twoNodes(t)
	m5.beatLoad("m5", "verk", machineA, 0.5, 3, f5) // 0.05/core
	m4.beatLoad("m4", "verk", machineB, 6, 1, f4)   // 0.60/core
	waitFor(t, 3*time.Second, "m5 cooled down", func() bool {
		hb, _, _ := h.srv.nodeStatusOf("ep_m5", time.Now())
		return hb.Load1 == 0.5
	})
	wid5 := issueWID(f5.FleetID, 9)
	st, out := placeCall(t, h, h.tokens["m5"], map[string]any{"repo": writeRepo, "issue": 9, "worker_id": wid5})
	if st != 200 || out["local"] != true || out["placement"].(map[string]any)["machine"] != "m5" {
		t.Fatalf("place = %d %v; want LOCAL m5", st, out)
	}
	if m5.count()+m4.count() != 0 {
		t.Fatal("a local placement sent a write")
	}
}

// A machine named explicitly is honoured or refused, never swapped.
func TestNodePlaceNamedNode(t *testing.T) {
	h, _, m4, f5, _ := twoNodes(t)
	wid5 := issueWID(f5.FleetID, 11)
	st, out := placeCall(t, h, h.tokens["m5"], map[string]any{"repo": writeRepo, "issue": 11, "worker_id": wid5, "node": "m5"})
	if e, _ := out["error"].(map[string]any); st != 503 || e["code"] != "NO_ELIGIBLE_NODE" || m4.count() != 0 {
		t.Fatalf("node=m5 while m5 is busy = %d %v; want NO_ELIGIBLE_NODE and nothing sent", st, out)
	}
	if st, out := placeCall(t, h, h.tokens["m5"], map[string]any{"repo": writeRepo, "issue": 11, "worker_id": wid5, "node": "m4"}); st != 200 || out["local"] != false {
		t.Fatalf("node=m4 = %d %v; want the start sent to m4", st, out)
	}
}

// The chosen machine refuses: the lease comes back to the asker, so its
// fallback can open the issue itself.
func TestNodePlaceRefusalGivesLeaseBack(t *testing.T) {
	h, _, m4, f5, _ := twoNodes(t)
	tok5 := h.tokens["m5"]
	wid5 := issueWID(f5.FleetID, 13)
	if st, _ := leaseCall(t, h, tok5, map[string]any{"action": "acquire", "repo": writeRepo, "issue": 13, "worker_id": wid5}); st != 200 {
		t.Fatal("m5's lease")
	}
	m4.setAnswer(func(map[string]any) (any, *control.Error) {
		return nil, &control.Error{Code: "NOT_FOUND", Message: "Fleet is not configured"}
	})
	st, out := placeCall(t, h, tok5, map[string]any{"repo": writeRepo, "issue": 13, "worker_id": wid5})
	if st != 200 || out["operation"].(map[string]any)["status"] != "failed" {
		t.Fatalf("place = %d %v; want a failed remote start", st, out)
	}
	ls, err := h.srv.Store.Leases(time.Now())
	if err != nil || len(ls) != 1 || ls[0].WorkerID != wid5 {
		t.Fatalf("leases after the refusal = %+v %v; want #13 back with %s", ls, err, wid5)
	}
}

// Only a fleet this endpoint registered may ask.
func TestNodePlaceRefusesAnotherNodesFleet(t *testing.T) {
	h, _, m4, _, f4 := twoNodes(t)
	st, _ := placeCall(t, h, h.tokens["m5"], map[string]any{"repo": writeRepo, "issue": 3, "worker_id": issueWID(f4.FleetID, 3)})
	if st != 403 || m4.count() != 0 {
		t.Fatalf("m5 placing as m4's fleet = %d; want 403", st)
	}
	if st, _ := placeCall(t, h, "nope", map[string]any{"repo": writeRepo, "issue": 3, "worker_id": issueWID(f4.FleetID, 3)}); st != 401 {
		t.Fatalf("bad token = %d; want 401", st)
	}
}

// A node that says it is not ready (claude-fleet#1475: no gh login, no
// credential, a checkout missing) is never auto's pick, with the reason on the
// refusal; a start that names it still goes there.
func TestNodePlaceSkipsNotReadyNodeOnAuto(t *testing.T) {
	h, _, m4, f5, f4 := twoNodes(t)
	no := false
	beat(t, m4.conn, control.Proto, control.Heartbeat{Hostname: "m4", OSUser: "verk", MachineID: machineB,
		Load1: 1, NCPU: 10, MemFreeBytes: 8 << 30, MemTotalBytes: 16 << 30, Sessions: 1,
		Fleets: []control.Fleet{f4}, Ready: &no, NotReady: "gh, checkout:fleet-m4", ObservedAt: time.Now()})
	waitFor(t, 3*time.Second, "m4 reported not ready", func() bool {
		hb, _, _ := h.srv.nodeStatusOf("ep_m4", time.Now())
		return hb.Ready != nil && !*hb.Ready
	})
	wid5 := issueWID(f5.FleetID, 15)
	st, out := placeCall(t, h, h.tokens["m5"], map[string]any{"repo": writeRepo, "issue": 15, "worker_id": wid5})
	e, _ := out["error"].(map[string]any)
	msg, _ := e["message"].(string)
	if st != 503 || e["code"] != "NO_ELIGIBLE_NODE" || !strings.Contains(msg, "m4: not ready: gh, checkout:fleet-m4") || m4.count() != 0 {
		t.Fatalf("auto with m4 not ready = %d %v; want NO_ELIGIBLE_NODE naming m4's reason, nothing sent", st, out)
	}
	if st, out := placeCall(t, h, h.tokens["m5"], map[string]any{"repo": writeRepo, "issue": 15, "worker_id": wid5, "node": "m4"}); st != 200 || out["local"] != false {
		t.Fatalf("node=m4 while not ready = %d %v; want the start sent there anyway", st, out)
	}
}

// claude-fleet#1586: the asker hears what became of a REMOTE start, not just
// that it was accepted. A window opened there: done, exit 0, its window id.
func TestNodePlaceWaitsForTheWindow(t *testing.T) {
	h, _, m4, f5, _ := twoNodes(t)
	tok5 := h.tokens["m5"]
	wid5 := issueWID(f5.FleetID, 21)
	if st, _ := leaseCall(t, h, tok5, map[string]any{"action": "acquire", "repo": writeRepo, "issue": 21, "worker_id": wid5}); st != 200 {
		t.Fatal("m5's lease")
	}
	m4.setOpGet(finished("succeeded", map[string]any{"exit": 0, "window": "@42",
		"workers": []any{map[string]any{"window_id": "@42", "issue": 21}}}))
	st, out := placeCall(t, h, tok5, map[string]any{"repo": writeRepo, "issue": 21, "worker_id": wid5})
	oc := placeOutcomeOf(t, out)
	if st != 200 || oc["state"] != "done" || oc["exit"] != 0.0 || oc["window"] != "@42" || oc["node"] != "m4" {
		t.Fatalf("place = %d %v; want done on m4 with window @42", st, out)
	}
	if out["operation"].(map[string]any)["status"] != "succeeded" {
		t.Fatalf("operation = %v; want the reconciled succeeded", out["operation"])
	}
	ls, _ := h.srv.Store.Leases(time.Now())
	if len(ls) != 1 || ls[0].FleetID == f5.FleetID {
		t.Fatalf("leases = %+v; want #21 m4's", ls)
	}
}

// The target was full: refused with the spawn's own exit code and line, and
// the lease is the asker's again — its exit releases it, no --force next time.
func TestNodePlaceRemoteRefusalComesBack(t *testing.T) {
	h, _, m4, f5, _ := twoNodes(t)
	tok5 := h.tokens["m5"]
	wid5 := issueWID(f5.FleetID, 22)
	if st, _ := leaseCall(t, h, tok5, map[string]any{"action": "acquire", "repo": writeRepo, "issue": 22, "worker_id": wid5}); st != 200 {
		t.Fatal("m5's lease")
	}
	why := "dash-issue-session: at capacity: 6/6 sessions on m4"
	m4.setOpGet(finished("failed", map[string]any{"error": map[string]any{"code": "AT_CAPACITY",
		"message": "Fleet refused to start the worker: " + why, "exit": 2, "stderr1": why}}))
	st, out := placeCall(t, h, tok5, map[string]any{"repo": writeRepo, "issue": 22, "worker_id": wid5})
	oc := placeOutcomeOf(t, out)
	if st != 200 || oc["state"] != "refused" || oc["exit"] != 2.0 || oc["stderr1"] != why {
		t.Fatalf("place = %d %v; want refused, exit 2, the spawn's line", st, out)
	}
	ls, _ := h.srv.Store.Leases(time.Now())
	if len(ls) != 1 || ls[0].WorkerID != wid5 {
		t.Fatalf("leases = %+v; want #22 back with %s", ls, wid5)
	}
	if st, _ := leaseCall(t, h, tok5, map[string]any{"action": "release", "repo": writeRepo, "issue": 22, "worker_id": wid5}); st != 200 {
		t.Fatalf("the asker could not release the lease it got back: %d", st)
	}
	if st, out := leaseCall(t, h, tok5, map[string]any{"action": "acquire", "repo": writeRepo, "issue": 22, "worker_id": wid5}); st != 200 {
		t.Fatalf("re-dispatch without --force = %d %v; want granted", st, out)
	}
}

// A node that never reports a final state (an agent predating #1586, or a
// spawn still running): unknown after the wait — never done — and the lease
// stays with the target, which may yet open it.
func TestNodePlaceNoFinalStateIsUnknown(t *testing.T) {
	h, _, _, f5, f4 := twoNodes(t)
	wid5 := issueWID(f5.FleetID, 23)
	start := time.Now()
	st, out := placeCall(t, h, h.tokens["m5"], map[string]any{"repo": writeRepo, "issue": 23, "worker_id": wid5})
	oc := placeOutcomeOf(t, out)
	if st != 200 || oc["state"] != "unknown" || oc["exit"] != nil || !strings.Contains(oc["stderr1"].(string), "no final state") {
		t.Fatalf("place = %d %v; want unknown with a reason and no exit", st, out)
	}
	if time.Since(start) < placeWait {
		t.Fatalf("answered in %v; want it to wait %v first", time.Since(start), placeWait)
	}
	ls, _ := h.srv.Store.Leases(time.Now())
	if len(ls) != 1 || ls[0].FleetID != f4.FleetID {
		t.Fatalf("leases = %+v; want #23 still m4's", ls)
	}
}

// wait 0 is the asynchronous ask: the answer on acceptance, as before.
func TestNodePlaceWaitZeroAnswersOnAcceptance(t *testing.T) {
	h, _, m4, f5, _ := twoNodes(t)
	m4.setOpGet(finished("succeeded", map[string]any{"window": "@1"}))
	st, out := placeCall(t, h, h.tokens["m5"], map[string]any{"repo": writeRepo, "issue": 24,
		"worker_id": issueWID(f5.FleetID, 24), "wait": 0})
	if _, has := out["outcome"]; st != 200 || has || out["operation"].(map[string]any)["status"] != "accepted" {
		t.Fatalf("place wait=0 = %d %v; want accepted and no outcome", st, out)
	}
}
