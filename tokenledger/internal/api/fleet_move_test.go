package api

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
)

// Moving a session between machines through the hub (claude-fleet#1426,
// EPIC #1419 C7).

// twoMoveNodes is twoNodes with each agent able to take a moved session
// (CapMove), unless the label is in old.
func twoMoveNodes(t *testing.T, old ...string) (*harness, *writeNode, *writeNode, control.Fleet, control.Fleet) {
	t.Helper()
	h := newFleetHarness(t)
	caps := func(label string) []string {
		for _, o := range old {
			if o == label {
				return []string{control.CapRead, control.CapWrite}
			}
		}
		return []string{control.CapRead, control.CapWrite, control.CapMove}
	}
	m5 := connectWriteNodeCaps(t, h, h.enroll(t, "m5"), caps("m5")...)
	m4 := connectWriteNodeCaps(t, h, h.enroll(t, "m4"), caps("m4")...)
	f5 := fakeFleet(t, machineA, "fleet-m5", writeRepo, "/u/verk/claude-fleet", 1)
	f4 := fakeFleet(t, machineB, "fleet-m4", writeRepo, "/u/verk/claude-fleet", 2)
	m5.beatLoad("m5", "verk", machineA, 10, 3, f5)
	m4.beatLoad("m4", "verk", machineB, 1, 1, f4)
	waitFor(t, 3*time.Second, "both fleets registered", func() bool {
		return len(getFleet(t, h, "/v1/fleet/fleet_list", 200)["fleets"].([]any)) == 2
	})
	return h, m5, m4, f5, f4
}

func moveCall(t *testing.T, h *harness, token string, body map[string]any) (int, map[string]any) {
	t.Helper()
	b, _ := json.Marshal(body)
	req, _ := http.NewRequest(http.MethodPost, h.http.URL+"/v1/node/move", bytes.NewReader(b))
	req.Header.Set("Authorization", "Bearer "+token)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var out map[string]any
	_ = json.NewDecoder(resp.Body).Decode(&out)
	return resp.StatusCode, out
}

func uploadBundle(t *testing.T, h *harness, token string, data []byte) string {
	t.Helper()
	req, _ := http.NewRequest(http.MethodPost, h.http.URL+"/v1/node/move/bundle", bytes.NewReader(data))
	req.Header.Set("Authorization", "Bearer "+token)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var out map[string]any
	_ = json.NewDecoder(resp.Body).Decode(&out)
	id, _ := out["bundle_id"].(string)
	if resp.StatusCode != 200 || id == "" {
		t.Fatalf("upload = %d %v", resp.StatusCode, out)
	}
	return id
}

func downloadBundle(t *testing.T, h *harness, token, id string) (int, []byte) {
	t.Helper()
	req, _ := http.NewRequest(http.MethodGet, h.http.URL+"/v1/node/move/bundle/"+id, nil)
	req.Header.Set("Authorization", "Bearer "+token)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, b
}

func moveBody(wid, bundle, state string) map[string]any {
	return map[string]any{"action": "move", "repo": writeRepo, "worker_id": wid, "node": "m4",
		"branch": "issue-7", "pushed": true, "sid": "11111111-1111-4111-8111-111111111111",
		"name": "issue-7", "state": state, "origin": "issue-1", "bundle_id": bundle}
}

// The issue's acceptance check, the hub's half: m5 moves its idle #7 to m4 —
// m4 is sent the move with the session's branch and id, the lease is m4's
// from that moment, only m4 can fetch the transcript and gets it byte for
// byte, and once the move succeeds the bundle is gone.
func TestNodeMoveHandsSessionAndLeaseToTarget(t *testing.T) {
	h, m5, m4, f5, f4 := twoMoveNodes(t)
	tok5, tok4 := h.tokens["m5"], h.tokens["m4"]
	wid5, wid4 := issueWID(f5.FleetID, 7), issueWID(f4.FleetID, 7)
	if st, out := leaseCall(t, h, tok5, map[string]any{"action": "acquire", "repo": writeRepo, "issue": 7, "worker_id": wid5}); st != 200 {
		t.Fatalf("m5's lease: %d %v", st, out)
	}

	if st, out := moveCall(t, h, tok5, map[string]any{"action": "plan", "repo": writeRepo, "worker_id": wid5, "node": "m4"}); st != 200 ||
		out["local"] != false || out["movable"] != true {
		t.Fatalf("plan = %d %v; want m4, movable", st, out)
	}

	transcript := []byte("tar bytes of <sid>.jsonl and its sidecar")
	bundle := uploadBundle(t, h, tok5, transcript)
	st, out := moveCall(t, h, tok5, moveBody(wid5, bundle, "done"))
	if st != 200 || out["to_wid"] != wid4 {
		t.Fatalf("move = %d %v; want it sent to m4 as %s", st, out, wid4)
	}
	op := out["operation"].(map[string]any)
	if op["status"] != "accepted" || op["fleet_id"] != f4.FleetID || m5.count() != 0 || m4.count() != 1 {
		t.Fatalf("operation = %v (writes m5=%d m4=%d); want one accepted write on m4", op, m5.count(), m4.count())
	}
	env := m4.writes[0]
	p := env["params"].(map[string]any)
	if env["action"] != "worker_move_in" || p["move_id"] != bundle || p["worker_key"] != "issue-7" ||
		p["branch"] != "issue-7" || p["sid"] != "11111111-1111-4111-8111-111111111111" || p["issue"].(float64) != 7 ||
		p["pushed"] != true || p["from_node"] != "m5" {
		t.Fatalf("m4 was sent %v", env)
	}

	ls, err := h.srv.Store.Leases(time.Now())
	if err != nil || len(ls) != 1 || ls[0].WorkerID != wid4 {
		t.Fatalf("leases = %+v %v; want #7 held by m4's %s", ls, err, wid4)
	}
	if st, out := leaseCall(t, h, tok5, map[string]any{"action": "acquire", "repo": writeRepo, "issue": 7,
		"worker_id": wid5}); st != 409 || holderNode(out) != "m4" {
		t.Fatalf("m5 re-acquire = %d %v; want HELD by m4", st, out)
	}

	if st, _ := downloadBundle(t, h, tok5, bundle); st != 404 {
		t.Fatalf("the source fetched the bundle: %d; only the target may", st)
	}
	if st, got := downloadBundle(t, h, tok4, bundle); st != 200 || !bytes.Equal(got, transcript) {
		t.Fatalf("m4's download = %d %q; want the transcript byte for byte", st, got)
	}

	// m4 reports it done; the source's status read settles the move.
	opID := op["operation_id"].(string)
	res, _ := json.Marshal(map[string]any{"window": "@3", "pid": "4242"})
	if err := h.srv.Store.UpdateFleetOperation(opID, "succeeded", string(res), time.Now()); err != nil {
		t.Fatal(err)
	}
	st, out = moveCall(t, h, tok5, map[string]any{"action": "status", "worker_id": wid5, "operation_id": opID})
	if got := out["operation"].(map[string]any); st != 200 || got["status"] != "succeeded" {
		t.Fatalf("status = %d %v; want succeeded", st, out)
	}
	if st, _ := downloadBundle(t, h, tok4, bundle); st != 404 {
		t.Fatalf("bundle still served after the move settled: %d", st)
	}
	if ls, _ := h.srv.Store.Leases(time.Now()); len(ls) != 1 || ls[0].WorkerID != wid4 {
		t.Fatalf("a successful move kept the lease with %+v; want m4", ls)
	}
	// Another node cannot read this move's outcome.
	if st, _ := moveCall(t, h, tok4, map[string]any{"action": "status", "worker_id": wid4, "operation_id": opID}); st != 404 {
		t.Fatalf("m4 read m5's move: %d", st)
	}
}

// A session mid-turn is never moved: refused before anything changes hands.
func TestNodeMoveRefusesWorkingSession(t *testing.T) {
	h, _, m4, f5, _ := twoMoveNodes(t)
	tok5 := h.tokens["m5"]
	wid5 := issueWID(f5.FleetID, 7)
	if st, _ := leaseCall(t, h, tok5, map[string]any{"action": "acquire", "repo": writeRepo, "issue": 7, "worker_id": wid5}); st != 200 {
		t.Fatal("m5's lease")
	}
	bundle := uploadBundle(t, h, tok5, []byte("x"))
	st, out := moveCall(t, h, tok5, moveBody(wid5, bundle, "working"))
	if e, _ := out["error"].(map[string]any); st == 200 || e["code"] != "INVALID_STATE" || m4.count() != 0 {
		t.Fatalf("move of a working session = %d %v (m4 writes %d); want INVALID_STATE and nothing sent", st, out, m4.count())
	}
	if ls, _ := h.srv.Store.Leases(time.Now()); len(ls) != 1 || ls[0].WorkerID != wid5 {
		t.Fatalf("a refused move moved the lease: %+v", ls)
	}
}

// The target tries and fails: the lease comes back to the source's worker,
// so the session can be resumed where it was.
func TestNodeMoveFailureGivesLeaseBack(t *testing.T) {
	h, _, m4, f5, _ := twoMoveNodes(t)
	tok5 := h.tokens["m5"]
	wid5 := issueWID(f5.FleetID, 7)
	if st, _ := leaseCall(t, h, tok5, map[string]any{"action": "acquire", "repo": writeRepo, "issue": 7, "worker_id": wid5}); st != 200 {
		t.Fatal("m5's lease")
	}
	m4.setAnswer(func(env map[string]any) (any, *control.Error) {
		return map[string]any{"operation_id": env["operation_id"], "fleet_id": env["fleet_id"], "action": env["action"],
			"status": "failed", "result": map[string]any{"error": map[string]string{"code": "EXECUTION_FAILED", "message": "stale branch"}}}, nil
	})
	bundle := uploadBundle(t, h, tok5, []byte("x"))
	st, out := moveCall(t, h, tok5, moveBody(wid5, bundle, "done"))
	if st != 200 || out["operation"].(map[string]any)["status"] != "failed" {
		t.Fatalf("move = %d %v; want a failed operation", st, out)
	}
	if ls, _ := h.srv.Store.Leases(time.Now()); len(ls) != 1 || ls[0].WorkerID != wid5 {
		t.Fatalf("leases after a failed move = %+v; want #7 back with %s", ls, wid5)
	}
}

// An agent that predates moves is never sent one, and plan says so.
func TestNodeMoveNeedsTargetCapability(t *testing.T) {
	h, _, m4, f5, _ := twoMoveNodes(t, "m4")
	tok5 := h.tokens["m5"]
	wid5 := issueWID(f5.FleetID, 7)
	if st, out := moveCall(t, h, tok5, map[string]any{"action": "plan", "repo": writeRepo, "worker_id": wid5, "node": "m4"}); st != 200 ||
		out["movable"] != false {
		t.Fatalf("plan = %d %v; want movable false", st, out)
	}
	bundle := uploadBundle(t, h, tok5, []byte("x"))
	st, out := moveCall(t, h, tok5, moveBody(wid5, bundle, "done"))
	if e, _ := out["error"].(map[string]any); st != 503 || e["code"] != "UNAVAILABLE" || m4.count() != 0 {
		t.Fatalf("move to an old agent = %d %v; want UNAVAILABLE, nothing sent", st, out)
	}
}

// Only a fleet this endpoint registered may move a worker.
func TestNodeMoveRefusesAnotherNodesWorker(t *testing.T) {
	h, _, _, _, f4 := twoMoveNodes(t)
	if st, _ := moveCall(t, h, h.tokens["m5"], map[string]any{"action": "plan", "repo": writeRepo,
		"worker_id": issueWID(f4.FleetID, 7), "node": "m4"}); st != 403 {
		t.Fatalf("m5 planning m4's worker = %d; want 403", st)
	}
}
