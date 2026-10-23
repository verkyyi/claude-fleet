package store

import (
	"encoding/json"
	"errors"
	"reflect"
	"testing"
	"time"
)

func continueProviderOp(task FleetTask, key, agent string, intent *TaskContinuationIntent, exitID string) FleetOperation {
	op := executionOp(task, key)
	var request map[string]any
	_ = json.Unmarshal([]byte(op.Request), &request)
	p := request["params"].(map[string]any)
	p["agent"] = agent
	p["dispatch"].(map[string]any)["resolved_agent"] = agent
	if intent != nil {
		request["continuation_intent"] = intent
		p["continuation"] = TaskContinuation{Version: 1, ExitOperationID: exitID}
	}
	raw, _ := json.Marshal(request)
	op.Request = string(raw)
	return op
}

func continueStoreFixture(t *testing.T) (*Store, FleetTask, FleetOperation, TaskSessionExitReceipt) {
	t.Helper()
	s := taskStore(t)
	task := acceptedTask(t, s, "continue-store", "")
	start := continueProviderOp(task, "initial", "codex", nil, "")
	if _, e := s.AuthorizeTaskExecution(start, "node-a"); e != nil {
		t.Fatal(e)
	}
	if _, e := s.ClaimTaskExecution(task.ID, task.Owner, start.ID, "node-a", executionWorker, task.Generation, task.AttemptID); e != nil {
		t.Fatal(e)
	}
	stopped, stop, e := s.RequestTaskStop(task.ID, task.Owner, "stop", "explicit stop", time.Now())
	if e != nil {
		t.Fatal(e)
	}
	receipt := TaskSessionExitReceipt{TaskFID: task.FID, Task: task.Ref, Owner: task.Owner, ExecutionOwner: executionWorker, ExecutionEndpoint: "node-a",
		Generation: task.Generation, AttemptID: task.AttemptID, StartOperationID: start.ID, StopOperationID: stop.ID, LaunchID: "launch", Scope: "native_session", Evidence: json.RawMessage(`{"roots":[{"pid":123,"exited":true}]}`)}
	released, exit, e := s.RecordTaskSessionExit(receipt, "exit", time.Now())
	if e != nil {
		t.Fatal(e)
	}
	if released.Generation != stopped.Generation {
		t.Fatal("release changed stop generation")
	}
	return s, released, exit, receipt
}

func TestTaskContinueStoreSourceAndSameEndpoint(t *testing.T) {
	s, task, exit, receipt := continueStoreFixture(t)
	source, e := s.TaskContinuationSource(task.ID, task.Owner)
	if e != nil || source.Agent != "codex" || source.ExitOperationID != exit.ID || source.Start.ID != receipt.StartOperationID {
		t.Fatalf("source: %+v %v", source, e)
	}
	if _, e := s.TaskContinuationSource(task.ID, "bob"); !errors.Is(e, ErrTaskFence) {
		t.Fatalf("foreign source: %v", e)
	}
	next := task
	next.Generation++
	next.AttemptID = "task:" + task.Ref + ":g3"
	agent := "claude"
	intent := TaskContinuationIntent{task.Ref, receipt.StopOperationID, task.Generation, &agent}
	op := continueProviderOp(next, "continue", "claude", &intent, exit.ID)
	if _, e := s.ContinueTaskExecution(op, "node-b"); !errors.Is(e, ErrTaskFence) {
		t.Fatalf("cross-node continuation: %v", e)
	}
	got, _ := s.FleetTask(task.ID)
	if !reflect.DeepEqual(got, task) {
		t.Fatal("refusal modified task")
	}
	continued, e := s.ContinueTaskExecution(op, "node-a")
	if e != nil {
		t.Fatal(e)
	}
	if continued.RequestPayload != task.RequestPayload || continued.ResolvedAgent != task.ResolvedAgent || continued.Title != task.Title {
		t.Fatal("continuation rewrote initial task")
	}
	view, e := s.TaskExecutionStart(task.ID, task.Owner, "node-a")
	if e != nil || view.Start.Agent != "claude" || view.Start.OperationID != op.ID || view.Start.Continuation.ExitOperationID != exit.ID || view.TaskExecution.Generation != task.Generation+1 {
		t.Fatalf("current metadata: %+v %v", view, e)
	}
	if _, e := s.TaskExecutionStart(task.ID, task.Owner, "node-b"); !errors.Is(e, ErrTaskFence) {
		t.Fatalf("foreign current start: %v", e)
	}
	if _, e := s.TaskContinuationSource(task.ID, task.Owner); !errors.Is(e, ErrTaskFence) {
		t.Fatalf("active source: %v", e)
	}
}

func TestTaskContinueStoreIntentAndProvider(t *testing.T) {
	for _, test := range []string{"omitted-change", "wrong-stop", "wrong-generation", "wrong-task", "wrong-exit", "different-fleet", "mismatched-agent", "no-intent", "different-repo", "different-no-repo", "wrong-actor"} {
		t.Run(test, func(t *testing.T) {
			s, task, exit, receipt := continueStoreFixture(t)
			next := task
			next.Generation++
			next.AttemptID = "task:" + task.Ref + ":g3"
			agent := "claude"
			intent := TaskContinuationIntent{task.Ref, receipt.StopOperationID, task.Generation, &agent}
			exitID := exit.ID
			switch test {
			case "omitted-change":
				intent.RequestedAgent = nil
			case "wrong-stop":
				intent.ExpectedStopOperationID = "other"
			case "wrong-generation":
				intent.ExpectedGeneration++
			case "wrong-task":
				intent.Task = "T999"
			case "wrong-exit":
				exitID = "other"
			case "mismatched-agent":
				agent = "codex"
			}
			op := continueProviderOp(next, "continue", "claude", &intent, exitID)
			if test == "different-fleet" {
				op.FleetID = "33333333-3333-4333-8333-333333333333"
			}
			if test == "no-intent" {
				op = continueProviderOp(next, "continue", "claude", nil, exitID)
			}
			if test == "wrong-actor" {
				op.Actor = "bob"
			}
			if test == "different-repo" || test == "different-no-repo" {
				var request map[string]any
				_ = json.Unmarshal([]byte(op.Request), &request)
				params := request["params"].(map[string]any)
				if test == "different-repo" {
					params["repo"] = "other/repo"
				} else {
					params["no_repo"] = true
				}
				raw, _ := json.Marshal(request)
				op.Request = string(raw)
			}
			if _, e := s.ContinueTaskExecution(op, "node-a"); e == nil {
				t.Fatal("invalid continuation accepted")
			}
			got, _ := s.FleetTask(task.ID)
			if !reflect.DeepEqual(got, task) {
				t.Fatal("rejected intent changed task")
			}
		})
	}
}

func TestTaskContinueCurrentStartRequiresExactReceiptSource(t *testing.T) {
	for _, which := range []string{"endpoint", "missing-receipt", "receipt-start", "receipt-endpoint", "source-provider"} {
		t.Run(which, func(t *testing.T) {
			s, task, exit, receipt := continueStoreFixture(t)
			next := task
			next.Generation++
			next.AttemptID = "task:" + task.Ref + ":g3"
			agent := "claude"
			intent := TaskContinuationIntent{task.Ref, receipt.StopOperationID, task.Generation, &agent}
			op := continueProviderOp(next, "continue", "claude", &intent, exit.ID)
			if _, e := s.ContinueTaskExecution(op, "node-a"); e != nil {
				t.Fatal(e)
			}
			valid, e := s.TaskExecutionStart(task.ID, task.Owner, "node-a")
			if e != nil || valid.SourceStart == nil || valid.SourceStart.OperationID != receipt.StartOperationID || valid.SourceStart.Agent != "codex" {
				t.Fatalf("source: %+v %v", valid, e)
			}
			endpoint := "node-a"
			switch which {
			case "endpoint":
				endpoint = "node-b"
			case "missing-receipt":
				var r map[string]any
				_ = json.Unmarshal([]byte(op.Request), &r)
				r["params"].(map[string]any)["continuation"].(map[string]any)["exit_operation_id"] = "missing-exit"
				raw, _ := json.Marshal(r)
				if _, e := s.write.Exec("UPDATE fleet_operations SET request=? WHERE id=?", string(raw), op.ID); e != nil {
					t.Fatal(e)
				}
			case "receipt-start", "receipt-endpoint":
				var r taskSessionExitRequest
				_ = json.Unmarshal([]byte(exit.Request), &r)
				if which == "receipt-start" {
					r.Receipt.StartOperationID = op.ID
				} else {
					r.Receipt.ExecutionEndpoint = "node-b"
				}
				raw, _ := json.Marshal(r)
				if _, e := s.write.Exec("UPDATE fleet_operations SET request=? WHERE id=?", string(raw), exit.ID); e != nil {
					t.Fatal(e)
				}
			case "source-provider":
				source, e := s.FleetOperation(receipt.StartOperationID)
				if e != nil {
					t.Fatal(e)
				}
				var r map[string]any
				_ = json.Unmarshal([]byte(source.Request), &r)
				r["params"].(map[string]any)["agent"] = "claude"
				raw, _ := json.Marshal(r)
				if _, e := s.write.Exec("UPDATE fleet_operations SET request=? WHERE id=?", string(raw), source.ID); e != nil {
					t.Fatal(e)
				}
			}
			rejected, e := s.TaskExecutionStart(task.ID, task.Owner, endpoint)
			if e == nil || rejected.SourceStart != nil {
				t.Fatalf("bad source returned: %+v %v", rejected, e)
			}
		})
	}
}
