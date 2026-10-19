package api

import (
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

func launchReceiptFixture(env map[string]any) map[string]any {
	c := env["params"].(map[string]any)["launch"].(map[string]any)
	r := map[string]any{}
	for k, v := range c {
		r[k] = v
	}
	r["actual_provider"] = c["provider"]
	r["native_session"] = "44444444-4444-4444-8444-444444444444"
	r["pid"] = 42
	r["birth"] = "fixture process birth"
	r["executable"] = "/fixture/codex"
	r["observed_at"] = 1
	r["phase"] = "delivered"
	return r
}
func verifiedLaunchFixture(env map[string]any) (any, *control.Error) {
	return finished("succeeded", map[string]any{"window": "@7", "window_id": "@7", "launch_receipt": launchReceiptFixture(env)})(env)
}
func TestAcceptedLaunchRequiresCapability(t *testing.T) {
	h, first, second, _, _ := twoNodes(t)
	postFleet(t, h, "worker_start", map[string]any{"issue": 7, "repo": writeRepo, "coding_agent": "codex", "idempotency_key": "launch-cap"}, 503)
	if first.count()+second.count() != 0 {
		t.Fatal("downlevel node received accepted work")
	}
}
func TestLaunchReceiptRejectsMissingMismatchAndOldGeneration(t *testing.T) {
	h, _, node, _, target := twoNodesCaps(t, control.CapLaunch)
	args := map[string]any{"kind": "scratch", "repo": writeRepo, "coding_agent": "codex", "idempotency_key": "native-proof"}
	op := postFleet(t, h, "worker_start", args, 200)
	id := op["operation_id"].(string)
	task := node.writes[0]["params"].(map[string]any)["task"].(string)
	node.setOpGet(finished("succeeded", map[string]any{"window": "@7", "exit": 0}))
	if got := getFleet(t, h, "/v1/fleet/operation_get?operation_id="+id, 200); got["status"] != "unknown" {
		t.Fatalf("label/exit accepted: %v", got)
	}
	node.setOpGet(func(env map[string]any) (any, *control.Error) {
		r := launchReceiptFixture(env)
		r["actual_provider"] = "claude"
		return finished("succeeded", map[string]any{"launch_receipt": r})(env)
	})
	if got := getFleet(t, h, "/v1/fleet/operation_get?operation_id="+id, 200); got["status"] != "unknown" {
		t.Fatalf("mismatch accepted: %v", got)
	}
	rec, _ := h.srv.Store.FleetTask(store.ParseTaskRef(task))
	if rec.ActualAgent != "" || rec.State != "starting" {
		t.Fatalf("unverified task changed: %+v", rec)
	}
	node.setOpGet(verifiedLaunchFixture)
	for i := 0; i < 2; i++ {
		if got := getFleet(t, h, "/v1/fleet/operation_get?operation_id="+id, 200); got["status"] != "succeeded" {
			t.Fatalf("verified/reconnected: %v", got)
		}
	}
	rec, _ = h.srv.Store.FleetTask(store.ParseTaskRef(task))
	if rec.ActualAgent != "codex" || rec.State != "running" || rec.Generation != 1 {
		t.Fatalf("native receipt lost: %+v", rec)
	}
	again := postFleet(t, h, "worker_start", args, 200)
	if again["operation_id"] != id || node.count() != 1 {
		t.Fatal("lost ack replay opened twice")
	}
	row, _ := h.srv.Store.Fleet(target.FleetID)
	newer, err := h.srv.Store.MutateFleetTask(rec.ID, rec.Owner, store.TaskMutation{Kind: "transfer", Key: "explicit-transfer", Generation: 1, ExpectedWorker: rec.ExecutionOwner, EndpointID: row.EndpointID, FleetID: row.FleetID, ExecutionStopped: true, RequestedAgent: "claude", ResolvedAgent: "claude", Evidence: "fixture source process confirmed stopped"}, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if got := getFleet(t, h, "/v1/fleet/operation_get?operation_id="+id, 200); got["status"] != "unknown" {
		t.Fatalf("old receipt accepted: %v", got)
	}
	after, _ := h.srv.Store.FleetTask(rec.ID)
	if after.Generation != newer.Generation || after.ExecutionOwner != "" || after.ActualAgent != "" {
		t.Fatalf("old receipt acquired new work: %+v", after)
	}
	if node.count() != 1 {
		t.Fatal("reconciliation launched again")
	}
	t.Log("fixture: capability, missing/mismatched native proof, one launch, unchanged reconnect, old-generation rejection")
}
