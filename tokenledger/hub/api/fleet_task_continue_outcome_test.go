package api

import (
	"net/http"
	"testing"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

func TestTaskContinueHistoricalOutcomeAPI(t *testing.T) {
	for _, kind := range []string{"native", "unclaimed"} {
		for _, outcome := range []string{"succeeded", "failed", "cancelled", "refused", ""} {
			t.Run(kind+"/"+outcome, func(t *testing.T) {
				var h *harness
				var node *writeNode
				var task store.FleetTask
				var snapshot store.TaskExecutionSnapshot
				if kind == "native" {
					h, node, task, snapshot, _ = continueFixture(t)
				} else {
					h, node, task, snapshot = continueUnclaimedFixture(t)
				}
				if _, err := h.srv.Store.DB().Exec(`UPDATE fleet_tasks SET state='cancelled', outcome=? WHERE id=?`, outcome, task.ID); err != nil {
					t.Fatal(err)
				}
				before := node.count()
				body := continueBody(snapshot, "history-continue")
				out := postFleet(t, h, "tasks/"+task.Ref+"/continue", body, 202)
				replay := postFleet(t, h, "tasks/"+task.Ref+"/continue", body, 202)
				if out["operation"].(map[string]any)["operation_id"] != replay["operation"].(map[string]any)["operation_id"] || node.count() != before+1 {
					t.Fatal("replay redispatched")
				}
				body["idempotency_key"] = "stale-history-continue"
				postFleet(t, h, "tasks/"+task.Ref+"/continue", body, 409)
				status, view := nodeTaskCall(t, h, h.tokens["mac-c"], http.MethodGet, NodeTasksPath+"/"+task.Ref+"/execution/start", nil)
				if status != 200 || view["source_start"] == nil {
					t.Fatalf("current source lost: %d %v", status, view)
				}
				got, err := h.srv.Store.FleetTask(task.ID)
				if err != nil || got.State != store.TaskCancelled || got.Outcome != outcome || got.Generation != snapshot.Generation+1 || got.CancelRequest != "" || got.RequestPayload != task.RequestPayload {
					t.Fatalf("history changed: %+v %v", got, err)
				}
				if node.count() != before+1 {
					t.Fatal("stale request dispatched")
				}
			})
		}
	}
}
