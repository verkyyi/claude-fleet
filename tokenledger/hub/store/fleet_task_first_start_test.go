package store

import (
	"encoding/json"
	"testing"
)

// The node may use the original ACK's binding generation 1 as evidence of
// initial execution only because authenticated continuation metadata walks
// every indexed start to a generation 1 root without continuation or intent.
func TestTaskContinueFirstStartGenerationBoundary(t *testing.T) {
	for _, mutation := range []string{"none", "continuation", "intent", "both", "root-generation"} {
		t.Run(mutation, func(t *testing.T) {
			s, task, exit, receipt := continueStoreFixture(t)
			if receipt.Generation != 1 || task.Generation != 2 {
				t.Fatalf("initial generation: receipt=%d stopped=%d", receipt.Generation, task.Generation)
			}
			next := task
			next.Generation++
			next.AttemptID = "task:" + task.Ref + ":g3"
			intent := TaskContinuationIntent{Task: task.Ref, ExpectedStopOperationID: receipt.StopOperationID, ExpectedGeneration: task.Generation}
			op := continueProviderOp(next, "continue", "codex", &intent, exit.ID)
			if _, err := s.ContinueTaskExecution(op, "node-a"); err != nil {
				t.Fatal(err)
			}
			view, err := s.TaskExecutionStart(task.ID, task.Owner, "node-a")
			if err != nil || view.TaskExecution.BindingGeneration != 3 || view.SourceStart == nil ||
				view.SourceStart.OperationID != receipt.StartOperationID || view.SourceStart.Continuation != nil {
				t.Fatalf("verified generation 3 source: %+v %v", view, err)
			}
			if mutation == "none" {
				return
			}
			root, err := s.FleetOperation(receipt.StartOperationID)
			if err != nil {
				t.Fatal(err)
			}
			var request map[string]any
			if err := json.Unmarshal([]byte(root.Request), &request); err != nil {
				t.Fatal(err)
			}
			params := request["params"].(map[string]any)
			if mutation == "continuation" || mutation == "both" {
				params["continuation"] = TaskContinuation{Version: 1, ExitOperationID: exit.ID}
			}
			if mutation == "intent" || mutation == "both" {
				request["continuation_intent"] = TaskContinuationIntent{Task: task.Ref, ExpectedStopOperationID: receipt.StopOperationID, ExpectedGeneration: 0}
			}
			if mutation == "root-generation" {
				params["dispatch"].(map[string]any)["generation"] = 3
			}
			raw, err := json.Marshal(request)
			if err != nil {
				t.Fatal(err)
			}
			if _, err := s.write.Exec("UPDATE fleet_operations SET request=? WHERE id=?", string(raw), root.ID); err != nil {
				t.Fatal(err)
			}
			rejected, err := s.TaskExecutionStart(task.ID, task.Owner, "node-a")
			if err == nil || rejected.SourceStart != nil || rejected.WorkspaceSource != nil {
				t.Fatalf("forged initial start supplied source: %+v %v", rejected, err)
			}
		})
	}
}
