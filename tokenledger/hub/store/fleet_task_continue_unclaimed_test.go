package store

import (
	"encoding/json"
	"errors"
	"fmt"
	"reflect"
	"testing"
	"time"
)

func unclaimedContinueFixture(t *testing.T) (*Store, FleetTask, FleetOperation) {
	t.Helper()
	s := taskStore(t)
	task := acceptedTask(t, s, "unclaimed-continue", "")
	start := continueProviderOp(task, "first", "codex", nil, "")
	if _, err := s.AuthorizeTaskExecution(start, "node-a"); err != nil {
		t.Fatal(err)
	}
	stopped, _, err := s.RequestTaskStop(task.ID, task.Owner, "first-stop", "stop before claim", time.Now())
	if err != nil {
		t.Fatal(err)
	}
	return s, stopped, start
}

func unclaimedContinueOp(task FleetTask, key, agent string, requested *string) FleetOperation {
	next := task
	next.Generation++
	next.AttemptID = fmt.Sprintf("task:%s:g%d", task.Ref, next.Generation)
	intent := TaskContinuationIntent{Task: task.Ref, ExpectedStopOperationID: task.CancelRequest, ExpectedGeneration: task.Generation, RequestedAgent: requested}
	op := continueProviderOp(next, key, agent, &intent, "")
	var request map[string]any
	_ = json.Unmarshal([]byte(op.Request), &request)
	request["params"].(map[string]any)["continuation"] = map[string]any{"version": 1, "stop_operation_id": task.CancelRequest}
	b, _ := json.Marshal(request)
	op.Request = string(b)
	return op
}

func TestTaskContinueUnclaimedStoreRepeated(t *testing.T) {
	s, task, initial := unclaimedContinueFixture(t)
	original := task
	agent := "codex"
	for i := 0; i < 4; i++ {
		source, err := s.TaskContinuationSource(task.ID, task.Owner)
		if err != nil || source.ExitOperationID != "" || source.StopOperationID != task.CancelRequest || source.Endpoint != "node-a" || source.Agent != agent {
			t.Fatalf("source: %+v %v", source, err)
		}
		var requested *string
		if i == 1 {
			agent = "claude"
			requested = &agent
		}
		op := unclaimedContinueOp(task, fmt.Sprintf("retry-%d", i), agent, requested)
		next, err := s.ContinueTaskExecution(op, "node-a")
		if err != nil {
			t.Fatal(err)
		}
		view, err := s.TaskExecutionStart(task.ID, task.Owner, "node-a")
		if err != nil || view.SourceStop == nil || view.SourceStop.OperationID != task.OperationID || view.SourceStop.CancelRequest != task.CancelRequest ||
			view.SourceStop.ExecutionOwner != "" || view.SourceStart.OperationID != task.OperationID || view.WorkspaceSource != nil ||
			view.Start.Agent != agent || view.Start.Continuation.StopOperationID != task.CancelRequest {
			t.Fatalf("view: %+v %v", view, err)
		}
		if _, err := s.ContinueTaskExecution(op, "node-a"); !errors.Is(err, ErrIdemTaken) {
			t.Fatalf("duplicate: %v", err)
		}
		if _, err := s.ClaimTaskExecution(task.ID, task.Owner, initial.ID, "node-a", executionWorker, 1, original.AttemptID); !errors.Is(err, ErrTaskFence) {
			t.Fatalf("old claim: %v", err)
		}
		if next.Generation != task.Generation+1 || next.CancelRequest != "" || next.ExecutionOwner != "" || next.ExecutionEndpoint != "node-a" ||
			next.RequestPayload != original.RequestPayload || next.State != original.State || next.Outcome != "" {
			t.Fatalf("new binding changed task: %+v", next)
		}
		task, _, err = s.RequestTaskStop(task.ID, task.Owner, fmt.Sprintf("stop-%d", i), "stop retry", time.Now())
		if err != nil {
			t.Fatal(err)
		}
	}
}

func TestTaskContinueUnclaimedNativeWorkspaceAcrossProviders(t *testing.T) {
	s, task, exit, receipt := continueStoreFixture(t)
	claude := "claude"
	next := task
	next.Generation++
	next.AttemptID = fmt.Sprintf("task:%s:g%d", task.Ref, next.Generation)
	intent := TaskContinuationIntent{task.Ref, task.CancelRequest, task.Generation, &claude}
	op := continueProviderOp(next, "native-to-claude", "claude", &intent, exit.ID)
	if _, err := s.ContinueTaskExecution(op, "node-a"); err != nil {
		t.Fatal(err)
	}
	var err error
	task, _, err = s.RequestTaskStop(task.ID, task.Owner, "claude-never-started", "stop", time.Now())
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 3; i++ {
		op = unclaimedContinueOp(task, fmt.Sprintf("workspace-retry-%d", i), "claude", nil)
		next, err = s.ContinueTaskExecution(op, "node-a")
		if err != nil {
			t.Fatal(err)
		}
		view, err := s.TaskExecutionStart(task.ID, task.Owner, "node-a")
		if err != nil || view.SourceStart == nil || view.SourceStart.Agent != "claude" || view.SourceStart.OperationID != task.OperationID ||
			view.WorkspaceSource == nil || view.WorkspaceSource.ExitOperationID != exit.ID || view.WorkspaceSource.Start.Agent != "codex" ||
			view.WorkspaceSource.Start.OperationID != receipt.StartOperationID || view.WorkspaceSource.Start.Continuation != nil || view.SourceStart.Continuation != nil {
			t.Fatalf("workspace provenance: %+v %v", view, err)
		}
		task, _, err = s.RequestTaskStop(task.ID, task.Owner, fmt.Sprintf("workspace-stop-%d", i), "stop", time.Now())
		if err != nil {
			t.Fatal(err)
		}
	}
	// This retry really runs, so its exit becomes the nearest workspace source.
	op = unclaimedContinueOp(task, "finally-runs", "claude", nil)
	next, err = s.ContinueTaskExecution(op, "node-a")
	if err != nil {
		t.Fatal(err)
	}
	worker := executionFleet + "/33333333-3333-4333-8333-333333333333"
	if _, err = s.ClaimTaskExecution(task.ID, task.Owner, op.ID, "node-a", worker, next.Generation, next.AttemptID); err != nil {
		t.Fatal(err)
	}
	task, stop, err := s.RequestTaskStop(task.ID, task.Owner, "real-second-stop", "stop", time.Now())
	if err != nil {
		t.Fatal(err)
	}
	r := receipt
	r.StartOperationID = op.ID
	r.StopOperationID = stop.ID
	r.Generation = next.Generation
	r.AttemptID = next.AttemptID
	r.ExecutionOwner = worker
	r.LaunchID = "second-native"
	task, newExit, err := s.RecordTaskSessionExit(r, "second-native-exit", time.Now())
	if err != nil {
		t.Fatal(err)
	}
	next = task
	next.Generation++
	next.AttemptID = fmt.Sprintf("task:%s:g%d", task.Ref, next.Generation)
	intent = TaskContinuationIntent{Task: task.Ref, ExpectedStopOperationID: task.CancelRequest, ExpectedGeneration: task.Generation}
	op = continueProviderOp(next, "native-after-unclaimed-history", "claude", &intent, newExit.ID)
	if _, err = s.ContinueTaskExecution(op, "node-a"); err != nil {
		t.Fatalf("mixed history rejected: %v", err)
	}
	task, _, err = s.RequestTaskStop(task.ID, task.Owner, "newest-unclaimed", "stop", time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if _, err = s.ContinueTaskExecution(unclaimedContinueOp(task, "newest-workspace", "claude", nil), "node-a"); err != nil {
		t.Fatal(err)
	}
	view, err := s.TaskExecutionStart(task.ID, task.Owner, "node-a")
	if err != nil || view.WorkspaceSource == nil || view.WorkspaceSource.ExitOperationID != newExit.ID || view.WorkspaceSource.Start.OperationID != r.StartOperationID {
		t.Fatalf("nearest native: %+v %v", view, err)
	}
}

func TestTaskContinueUnclaimedStrictUnion(t *testing.T) {
	for _, raw := range []string{
		`null`, `{}`, `{"version":1}`, `{"version":1,"exit_operation_id":""}`, `{"version":1,"stop_operation_id":null}`,
		`{"version":1,"exit_operation_id":"exit","stop_operation_id":"stop"}`,
		`{"version":1,"exit_operation_id":"exit","stop_operation_id":""}`,
		`{"version":1,"stop_operation_id":"stop","workspace":"/tmp"}`,
		`{"version":1,"version":1,"stop_operation_id":"stop"}`,
		`{"version":1,"stop_operation_id":"stop","stop_operation_id":"other"}`,
		`{"version":2,"stop_operation_id":"stop"}`, `{"version":1.0,"stop_operation_id":"stop"}`,
	} {
		t.Run(raw, func(t *testing.T) {
			var c TaskContinuation
			if json.Unmarshal([]byte(raw), &c) == nil {
				t.Fatalf("invalid union accepted: %s", raw)
			}
			s, task, _ := unclaimedContinueFixture(t)
			op := unclaimedContinueOp(task, "invalid-union", "codex", nil)
			var request map[string]any
			_ = json.Unmarshal([]byte(op.Request), &request)
			request["params"].(map[string]any)["continuation"] = json.RawMessage(raw)
			b, _ := json.Marshal(request)
			op.Request = string(b)
			if _, err := s.ContinueTaskExecution(op, "node-a"); err == nil {
				t.Fatal("invalid union authorized")
			}
			got, _ := s.FleetTask(task.ID)
			if !reflect.DeepEqual(got, task) {
				t.Fatal("rejection changed binding")
			}
		})
	}
}

func TestTaskContinueUnclaimedStoreRefusals(t *testing.T) {
	for _, which := range []string{"other-node", "other-fleet", "wrong-stop", "wrong-generation", "wrong-owner", "claimed", "unindexed", "alias", "duplicate-stop", "unknown-start", "omitted-provider-change", "environment-change"} {
		t.Run(which, func(t *testing.T) {
			s, task, start := unclaimedContinueFixture(t)
			op := unclaimedContinueOp(task, "refused", "codex", nil)
			endpoint := "node-a"
			switch which {
			case "other-node":
				endpoint = "node-b"
			case "other-fleet":
				op.FleetID = "other-fleet"
			case "wrong-owner":
				op.Actor = "bob"
			case "claimed":
				_, _ = s.write.Exec(`UPDATE fleet_tasks SET execution_owner=? WHERE id=?`, executionWorker, task.ID)
			case "unindexed":
				_, _ = s.write.Exec(`UPDATE fleet_operations SET task_ref='' WHERE id=?`, task.CancelRequest)
			case "duplicate-stop":
				stop, _ := s.FleetOperation(task.CancelRequest)
				stop.ID = "duplicate"
				stop.Idem = "duplicate"
				if err := s.InsertFleetOperation(stop); err != nil {
					t.Fatal(err)
				}
				_, _ = s.write.Exec(`UPDATE fleet_operations SET task_ref=?,task_generation=? WHERE id=?`, task.Ref, task.Generation-1, stop.ID)
			case "unknown-start":
				extra := start
				extra.ID = "unknown-start"
				extra.Idem = "unknown-start"
				// Inject a real journal row as historical damage; generic start insertion
				// normally refuses this because admission is already controlled.
				_, err := s.write.Exec(`INSERT INTO fleet_operations (id,fleet_id,action,request,actor,idem,status,created,updated,worker_id,task_owner,task_ref,task_generation) SELECT ?,fleet_id,action,request,actor,?,status,created,updated,worker_id,task_owner,'',0 FROM fleet_operations WHERE id=?`, extra.ID, extra.Idem, start.ID)
				if err != nil {
					t.Fatal(err)
				}
			case "alias":
				if _, _, err := s.RequestTaskStop(task.ID, task.Owner, "alias", "repeat", time.Now()); err != nil {
					t.Fatal(err)
				}
				alias, _ := s.FleetOperationByIdem(task.Owner, "alias")
				var request map[string]any
				_ = json.Unmarshal([]byte(op.Request), &request)
				request["params"].(map[string]any)["continuation"].(map[string]any)["stop_operation_id"] = alias.ID
				b, _ := json.Marshal(request)
				op.Request = string(b)
			default:
				var request map[string]any
				_ = json.Unmarshal([]byte(op.Request), &request)
				p := request["params"].(map[string]any)
				intent := request["continuation_intent"].(map[string]any)
				switch which {
				case "wrong-stop":
					intent["expected_stop_operation_id"] = "other"
				case "wrong-generation":
					intent["expected_generation"] = 99
				case "omitted-provider-change":
					p["agent"] = "claude"
					p["dispatch"].(map[string]any)["resolved_agent"] = "claude"
				case "environment-change":
					p["no_repo"] = true
				}
				b, _ := json.Marshal(request)
				op.Request = string(b)
			}
			before, _ := s.FleetTask(task.ID)
			if _, err := s.ContinueTaskExecution(op, endpoint); err == nil {
				t.Fatal("invalid continuation accepted")
			}
			after, _ := s.FleetTask(task.ID)
			if !reflect.DeepEqual(before, after) {
				t.Fatal("refusal changed task")
			}
		})
	}
}

func TestTaskContinueUnclaimedSourceAssociationDamage(t *testing.T) {
	for _, which := range []string{"missing-stop", "old-attempt", "worker-claim", "missing-worker", "different-endpoint", "source-fleet", "missing-first", "cycle", "missing-link", "missing-head-link", "missing-head-intent", "generation-gap", "workspace-exit", "workspace-provider", "workspace-repo"} {
		t.Run(which, func(t *testing.T) {
			s, task, exit, _ := continueStoreFixture(t)
			next := task
			next.Generation++
			next.AttemptID = fmt.Sprintf("task:%s:g%d", task.Ref, next.Generation)
			claude := "claude"
			intent := TaskContinuationIntent{task.Ref, task.CancelRequest, task.Generation, &claude}
			first := continueProviderOp(next, "never-native", "claude", &intent, exit.ID)
			if _, err := s.ContinueTaskExecution(first, "node-a"); err != nil {
				t.Fatal(err)
			}
			task, stop, err := s.RequestTaskStop(task.ID, task.Owner, "intermediate-stop", "stop", time.Now())
			if err != nil {
				t.Fatal(err)
			}
			head := unclaimedContinueOp(task, "current", "claude", nil)
			if _, err = s.ContinueTaskExecution(head, "node-a"); err != nil {
				t.Fatal(err)
			}
			mutate := func(id string, fn func(map[string]any)) {
				op, err := s.FleetOperation(id)
				if err != nil {
					t.Fatal(err)
				}
				var r map[string]any
				if json.Unmarshal([]byte(op.Request), &r) != nil {
					t.Fatal("decode")
				}
				fn(r)
				b, _ := json.Marshal(r)
				if _, err = s.write.Exec(`UPDATE fleet_operations SET request=? WHERE id=?`, string(b), id); err != nil {
					t.Fatal(err)
				}
			}
			switch which {
			case "missing-stop":
				_, err = s.write.Exec(`DELETE FROM fleet_operations WHERE id=?`, stop.ID)
			case "old-attempt", "worker-claim", "missing-worker", "different-endpoint":
				mutate(stop.ID, func(r map[string]any) {
					p := r["params"].(map[string]any)
					switch which {
					case "old-attempt":
						p["attempt_id"] = "other"
					case "worker-claim":
						p["worker_id"] = executionWorker
					case "missing-worker":
						delete(p, "worker_id")
					case "different-endpoint":
						p["execution_endpoint"] = "node-b"
					}
				})
			case "source-fleet":
				_, err = s.write.Exec(`UPDATE fleet_operations SET fleet_id='other' WHERE id=?`, first.ID)
			case "missing-first":
				_, err = s.write.Exec(`DELETE FROM fleet_operations WHERE id=?`, first.ID)
			case "cycle":
				mutate(stop.ID, func(r map[string]any) { r["params"].(map[string]any)["start_operation_id"] = head.ID })
			case "missing-link":
				mutate(first.ID, func(r map[string]any) {
					delete(r["params"].(map[string]any), "continuation")
					delete(r, "continuation_intent")
				})
			case "missing-head-link":
				mutate(head.ID, func(r map[string]any) {
					delete(r["params"].(map[string]any), "continuation")
					delete(r, "continuation_intent")
				})
			case "missing-head-intent":
				mutate(head.ID, func(r map[string]any) { delete(r, "continuation_intent") })
			case "generation-gap":
				mutate(first.ID, func(r map[string]any) { r["continuation_intent"].(map[string]any)["expected_generation"] = 99 })
			case "workspace-exit":
				_, err = s.write.Exec(`DELETE FROM fleet_operations WHERE id=?`, exit.ID)
			case "workspace-provider":
				mutate(first.ID, func(r map[string]any) { r["params"].(map[string]any)["agent"] = "codex" })
			case "workspace-repo":
				mutate(first.ID, func(r map[string]any) { r["params"].(map[string]any)["repo"] = "other/repo" })
			}
			if err != nil {
				t.Fatal(err)
			}
			view, err := s.TaskExecutionStart(task.ID, task.Owner, "node-a")
			if err == nil || view.SourceStart != nil || view.SourceStop != nil || view.WorkspaceSource != nil {
				t.Fatalf("damaged source exported: %+v %v", view, err)
			}
		})
	}
}

func TestTaskContinueUnclaimedStopClaimRaces(t *testing.T) {
	for i := 0; i < 20; i++ {
		s, task, original := unclaimedContinueFixture(t)
		op := unclaimedContinueOp(task, "race-continue", "codex", nil)
		gate := make(chan struct{})
		continued := make(chan error, 1)
		claimed := make(chan error, 1)
		stopped := make(chan error, 1)
		go func() { <-gate; _, err := s.ContinueTaskExecution(op, "node-a"); continued <- err }()
		go func() {
			<-gate
			_, err := s.ClaimTaskExecution(task.ID, task.Owner, original.ID, "node-a", executionWorker, 1, task.AttemptID)
			claimed <- err
		}()
		go func() {
			<-gate
			_, _, err := s.RequestTaskStop(task.ID, task.Owner, "first-stop", "old stop redelivery", time.Now())
			stopped <- err
		}()
		close(gate)
		if err := <-continued; err != nil {
			t.Fatal(err)
		}
		if err := <-claimed; !errors.Is(err, ErrTaskFence) {
			t.Fatalf("old claim revived: %v", err)
		}
		if err := <-stopped; err != nil && !errors.Is(err, ErrTaskConflict) {
			t.Fatalf("old stop: %v", err)
		}
		current, err := s.FleetTask(task.ID)
		if err != nil || current.OperationID != op.ID || current.CancelRequest != "" || current.Generation != task.Generation+1 {
			t.Fatalf("race current: %+v %v", current, err)
		}
	}
}

func TestTaskContinueUnclaimedCommitFailurePreservesSource(t *testing.T) {
	s, task, original := unclaimedContinueFixture(t)
	op := unclaimedContinueOp(task, "failed-transaction", "codex", nil)
	op.ID = original.ID // a primary-key collision after all proof checks
	if _, err := s.ContinueTaskExecution(op, "node-a"); err == nil {
		t.Fatal("duplicate operation ID accepted")
	}
	current, err := s.FleetTask(task.ID)
	if err != nil || !reflect.DeepEqual(current, task) {
		t.Fatalf("failed commit changed source: %+v %v", current, err)
	}
	op.ID = "after-failed-transaction"
	if _, err := s.ContinueTaskExecution(op, "node-a"); err != nil {
		t.Fatalf("rollback consumed idempotency key: %v", err)
	}
}
