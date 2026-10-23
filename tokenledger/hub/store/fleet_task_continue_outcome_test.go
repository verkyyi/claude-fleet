package store

import (
	"errors"
	"fmt"
	"reflect"
	"testing"
)

// Old result projections may already be on disk when controlled execution takes
// over. Keep them byte-for-byte; only a fully proved explicit continue may pass.
func outcomeContinueFixture(t *testing.T, kind, outcome string) (*Store, FleetTask, FleetOperation) {
	t.Helper()
	var s *Store
	var task FleetTask
	var op FleetOperation
	if kind == "native" {
		var exit FleetOperation
		s, task, exit, _ = continueStoreFixture(t)
		next := task
		next.Generation++
		next.AttemptID = fmt.Sprintf("task:%s:g%d", task.Ref, next.Generation)
		intent := TaskContinuationIntent{Task: task.Ref, ExpectedStopOperationID: task.CancelRequest, ExpectedGeneration: task.Generation}
		op = continueProviderOp(next, "continue-history", "codex", &intent, exit.ID)
	} else {
		s, task, _ = unclaimedContinueFixture(t)
		op = unclaimedContinueOp(task, "continue-history", "codex", nil)
	}
	state := TaskClosed
	if outcome == "cancelled" || outcome == "" {
		state = TaskCancelled
	}
	if _, err := s.write.Exec(`UPDATE fleet_tasks SET state=?, outcome=? WHERE id=?`, state, outcome, task.ID); err != nil {
		t.Fatal(err)
	}
	task, err := s.FleetTask(task.ID)
	if err != nil {
		t.Fatal(err)
	}
	return s, task, op
}

func TestTaskContinueHistoricalOutcome(t *testing.T) {
	for _, kind := range []string{"native", "unclaimed"} {
		for _, outcome := range []string{"succeeded", "failed", "cancelled", "refused", ""} {
			for _, entry := range []string{"source", "commit"} {
				t.Run(kind+"/"+outcome+"/"+entry, func(t *testing.T) {
					s, task, op := outcomeContinueFixture(t, kind, outcome)
					if entry == "source" {
						source, err := s.TaskContinuationSource(task.ID, task.Owner)
						if err != nil || !reflect.DeepEqual(source.Task, task) {
							t.Fatalf("historical result blocked proved source: %+v %v", source, err)
						}
					}
					next, err := s.ContinueTaskExecution(op, "node-a")
					if err != nil {
						t.Fatalf("historical result blocked explicit continue: %v", err)
					}
					expected := task
					expected.Generation, expected.AttemptID, expected.CancelRequest = next.Generation, next.AttemptID, ""
					expected.ExecutionEndpoint, expected.OperationID, expected.UpdatedAt = "node-a", op.ID, next.UpdatedAt
					if next.Generation != task.Generation+1 || !reflect.DeepEqual(next, expected) {
						t.Fatalf("continuation changed history or binding incorrectly: %+v", next)
					}
					if _, err := s.ContinueTaskExecution(op, "node-a"); !errors.Is(err, ErrIdemTaken) {
						t.Fatalf("replay: %v", err)
					}
					if _, err := s.ClaimTaskExecution(task.ID, task.Owner, task.OperationID, "node-a", executionWorker, task.Generation-1, task.AttemptID); !errors.Is(err, ErrTaskFence) {
						t.Fatalf("old claim: %v", err)
					}
					view, err := s.TaskExecutionStart(task.ID, task.Owner, "node-a")
					if err != nil || view.SourceStart == nil || view.TaskExecution.Generation != next.Generation {
						t.Fatalf("new start proof: %+v %v", view, err)
					}
					if _, err := s.ClaimTaskExecution(task.ID, task.Owner, op.ID, "node-a", executionFleet+"/44444444-4444-4444-8444-444444444444", next.Generation, next.AttemptID); err != nil {
						t.Fatalf("new claim: %v", err)
					}
					got, err := s.FleetTask(task.ID)
					if err != nil || got.State != task.State || got.Outcome != task.Outcome {
						t.Fatalf("claim changed history: %+v %v", got, err)
					}
				})
			}
		}
	}
}

func TestTaskContinueHistoricalOutcomeProofStillRequired(t *testing.T) {
	for _, kind := range []string{"native", "unclaimed"} {
		for _, change := range []string{"owner", "authority", "generation", "attempt", "start", "stop", "claim", "endpoint", "missing-proof", "unindexed-start"} {
			t.Run(kind+"/"+change, func(t *testing.T) {
				s, task, op := outcomeContinueFixture(t, kind, "cancelled")
				// Prove the read succeeded before a concurrent binding/history change.
				if _, err := s.TaskContinuationSource(task.ID, task.Owner); err != nil {
					t.Fatalf("source: %v", err)
				}
				query := map[string]string{
					"owner":      `UPDATE fleet_tasks SET owner='bob' WHERE id=?`,
					"authority":  `UPDATE fleet_tasks SET authority_version=0 WHERE id=?`,
					"generation": `UPDATE fleet_tasks SET generation=generation+1 WHERE id=?`,
					"attempt":    `UPDATE fleet_tasks SET attempt_id='other' WHERE id=?`,
					"start":      `UPDATE fleet_tasks SET operation_id='other' WHERE id=?`,
					"stop":       `UPDATE fleet_tasks SET cancel_request='other' WHERE id=?`,
					"claim":      `UPDATE fleet_tasks SET execution_owner='other' WHERE id=?`,
					"endpoint":   `UPDATE fleet_tasks SET execution_endpoint='node-b' WHERE id=?`,
				}[change]
				if query != "" {
					if _, err := s.write.Exec(query, task.ID); err != nil {
						t.Fatal(err)
					}
				} else if change == "missing-proof" {
					if _, err := s.write.Exec(`DELETE FROM fleet_operations WHERE id=?`, task.CancelRequest); err != nil {
						t.Fatal(err)
					}
				} else {
					// Simulate an old unindexed start; current generic admission refuses it.
					_, err := s.write.Exec(`INSERT INTO fleet_operations (id,fleet_id,action,request,actor,idem,status,created,updated,worker_id,task_owner,task_ref,task_generation) SELECT 'unindexed',fleet_id,action,request,actor,'unindexed',status,created,updated,worker_id,task_owner,'',0 FROM fleet_operations WHERE id=?`, task.OperationID)
					if err != nil {
						t.Fatal(err)
					}
				}
				before, _ := s.FleetTask(task.ID)
				if _, err := s.TaskContinuationSource(task.ID, task.Owner); err == nil {
					t.Fatal("invalid source accepted")
				}
				if _, err := s.ContinueTaskExecution(op, "node-a"); err == nil {
					t.Fatal("invalid commit accepted")
				}
				after, _ := s.FleetTask(task.ID)
				if !reflect.DeepEqual(before, after) {
					t.Fatal("rejected continue changed task")
				}
				if _, err := s.FleetOperation(op.ID); err == nil {
					t.Fatal("rejected continue wrote operation")
				}
			})
		}
	}
}

func TestTaskContinueHistoricalOutcomeDoesNotRelaxOtherStarts(t *testing.T) {
	for _, outcome := range []string{"succeeded", "failed", "cancelled", "refused", ""} {
		t.Run(outcome, func(t *testing.T) {
			s := taskStore(t)
			task := acceptedTask(t, s, "legacy-history", "")
			// Accepted + Outcome isolates the result guard from the legacy state guard.
			state := TaskAccepted
			if outcome == "" {
				state = TaskCancelled
			}
			if _, err := s.write.Exec(`UPDATE fleet_tasks SET state=?, outcome=? WHERE id=?`, state, outcome, task.ID); err != nil {
				t.Fatal(err)
			}
			op := continueProviderOp(task, "ordinary-start", "codex", nil, "")
			if _, err := s.AuthorizeTaskExecution(op, "node-a"); !errors.Is(err, ErrTaskFence) {
				t.Fatalf("ordinary start relaxed: %v", err)
			}
			if _, err := s.TaskContinuationSource(task.ID, task.Owner); !errors.Is(err, ErrTaskFence) {
				t.Fatalf("legacy task invented proof: %v", err)
			}
			s, task, explicit := outcomeContinueFixture(t, "native", outcome)
			m, _, err := taskStartMetadata(explicit)
			if err != nil {
				t.Fatal(err)
			}
			if _, err := s.ResumeTaskExecution(explicit, "node-a", m.Continuation.ExitOperationID); !errors.Is(err, ErrTaskFence) {
				t.Fatalf("non-explicit resume relaxed: %v", err)
			}
		})
	}
}
