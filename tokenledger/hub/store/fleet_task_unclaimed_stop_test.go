package store

import (
	"encoding/json"
	"errors"
	"fmt"
	"testing"
	"time"
)

func unclaimedStopFixture(t *testing.T, s *Store, key string) (FleetTask, FleetOperation, FleetOperation) {
	t.Helper()
	task := acceptedTask(t, s, key, "")
	start := executionOp(task, key+"-start")
	if _, err := s.AuthorizeTaskExecution(start, "node-a"); err != nil {
		t.Fatal(err)
	}
	stopped, stop, err := s.RequestTaskStop(task.ID, task.Owner, key+"-stop", "explicit stop", time.Now())
	if err != nil {
		t.Fatal(err)
	}
	return stopped, start, stop
}

func TestTaskUnclaimedStopProofRetainsBinding(t *testing.T) {
	s := taskStore(t)
	task, start, stop := unclaimedStopFixture(t, s, "unclaimed")
	before, err := s.TaskExecutionSnapshot(task.ID, task.Owner)
	if err != nil {
		t.Fatal(err)
	}
	for _, status := range []string{"pending", "accepted", "failed", "unknown", "succeeded"} {
		if err := s.UpdateFleetOperation(stop.ID, status, `{"not_an_exit":true}`, time.Now()); err != nil {
			t.Fatal(err)
		}
		proof, err := s.TaskUnclaimedStop(task.ID, task.Owner, stop.ID)
		if err != nil || proof != before {
			t.Fatalf("status %s affected immutable proof: %+v %v", status, proof, err)
		}
	}
	if _, err := s.ClaimTaskExecution(task.ID, task.Owner, start.ID, "node-a", executionWorker, before.BindingGeneration, task.AttemptID); !errors.Is(err, ErrTaskFence) {
		t.Fatalf("stop-first allowed old claim: %v", err)
	}
	if _, err := s.AuthorizeTaskExecution(executionResumeOp(task, "ordinary-retry"), "node-a"); !errors.Is(err, ErrTaskFence) {
		t.Fatalf("proof allowed ordinary reauthorization: %v", err)
	}
	if _, err := s.ResumeTaskExecution(executionResumeOp(task, "fake-exit"), "node-a", stop.ID); !errors.Is(err, ErrTaskFence) {
		t.Fatalf("stop masqueraded as native exit: %v", err)
	}
	after, err := s.FleetTask(task.ID)
	if err != nil || after.ExecutionEndpoint != task.ExecutionEndpoint || after.ExecutionOwner != "" || after.CancelRequest != stop.ID ||
		after.OperationID != start.ID || after.Generation != task.Generation || after.AttemptID != task.AttemptID ||
		after.State != task.State || after.Outcome != task.Outcome || !after.UpdatedAt.Equal(task.UpdatedAt) {
		t.Fatalf("proof mutated task: %+v %v", after, err)
	}
	var receipts int
	if err := s.read.QueryRow(`SELECT COUNT(*) FROM fleet_operations WHERE action = ?`, taskSessionExitAction).Scan(&receipts); err != nil || receipts != 0 {
		t.Fatalf("proof invented native receipt: %d %v", receipts, err)
	}
}

func TestTaskUnclaimedStopClaimACKLost(t *testing.T) {
	s := taskStore(t)
	task := acceptedTask(t, s, "lost-claim-ack", "")
	start := executionOp(task, "lost-claim-start")
	if _, err := s.AuthorizeTaskExecution(start, "node-a"); err != nil {
		t.Fatal(err)
	}
	// Commit the claim but discard its reply. No inventory or native registration
	// arrives: absence of either must never replace the committed Hub identity.
	if _, err := s.ClaimTaskExecution(task.ID, task.Owner, start.ID, "node-a", executionWorker, task.Generation, task.AttemptID); err != nil {
		t.Fatal(err)
	}
	stopped, stop, err := s.RequestTaskStop(task.ID, task.Owner, "lost-claim-stop", "stop", time.Now())
	if err != nil || stopped.ExecutionOwner != executionWorker {
		t.Fatalf("lost claim: %+v %v", stopped, err)
	}
	if _, err := s.TaskUnclaimedStop(task.ID, task.Owner, stop.ID); !errors.Is(err, ErrTaskFence) {
		t.Fatalf("lost ACK became unclaimed proof: %v", err)
	}
	// Even a current owner accidentally cleared independently cannot change the
	// canonical stop's immutable nonempty worker identity into an unclaimed one.
	if _, err := s.write.Exec(`UPDATE fleet_tasks SET execution_owner = '' WHERE id = ?`, task.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := s.TaskUnclaimedStop(task.ID, task.Owner, stop.ID); !errors.Is(err, ErrTaskFence) {
		t.Fatalf("empty current owner erased immutable claim evidence: %v", err)
	}
}

func TestTaskUnclaimedStopClaimRace(t *testing.T) {
	s := taskStore(t)
	for i := 0; i < 32; i++ {
		task := acceptedTask(t, s, fmt.Sprintf("unclaimed-race-%d", i), "")
		start := executionOp(task, fmt.Sprintf("race-start-%d", i))
		worker := fmt.Sprintf("%s/22222222-2222-4222-8222-%012x", executionFleet, i+1000)
		if _, err := s.AuthorizeTaskExecution(start, "node-a"); err != nil {
			t.Fatal(err)
		}
		gate := make(chan struct{})
		claimDone := make(chan error, 1)
		type stopResult struct {
			op  FleetOperation
			err error
		}
		stopDone := make(chan stopResult, 1)
		go func() {
			<-gate
			_, err := s.ClaimTaskExecution(task.ID, task.Owner, start.ID, "node-a", worker, task.Generation, task.AttemptID)
			claimDone <- err
		}()
		go func() {
			<-gate
			_, stop, err := s.RequestTaskStop(task.ID, task.Owner, fmt.Sprintf("race-stop-%d", i), "stop", time.Now())
			stopDone <- stopResult{stop, err}
		}()
		close(gate)
		claimed, stopped := <-claimDone, <-stopDone
		if stopped.err != nil || claimed != nil && !errors.Is(claimed, ErrTaskFence) {
			t.Fatalf("race claim=%v stop=%v", claimed, stopped.err)
		}
		proof, err := s.TaskUnclaimedStop(task.ID, task.Owner, stopped.op.ID)
		if claimed == nil {
			if !errors.Is(err, ErrTaskFence) {
				t.Fatalf("committed claim classified unclaimed: %+v %v", proof, err)
			}
		} else if err != nil || proof.ExecutionOwner != "" || proof.Generation != task.Generation+1 || proof.CancelRequest != stopped.op.ID {
			t.Fatalf("stop won but proof failed: %+v %v", proof, err)
		}
		if _, err := s.ClaimTaskExecution(task.ID, task.Owner, start.ID, "node-a", worker, task.Generation, task.AttemptID); !errors.Is(err, ErrTaskFence) {
			t.Fatalf("old claim revived: %v", err)
		}
	}
}

func TestTaskUnclaimedStopRejectsUnindexedAndNoncanonical(t *testing.T) {
	s := taskStore(t)
	task, _, stop := unclaimedStopFixture(t, s, "canonical")
	_, same, err := s.RequestTaskStop(task.ID, task.Owner, "alias", "again", time.Now())
	if err != nil || same.ID != stop.ID {
		t.Fatal(err)
	}
	alias, err := s.FleetOperationByIdem(task.Owner, "alias")
	if err != nil {
		t.Fatal(err)
	}
	forged := stop
	forged.ID, forged.Idem, forged.Status = "generic-stop", "generic-stop", "succeeded"
	if err := s.InsertFleetOperation(forged); err != nil {
		t.Fatal(err)
	}
	for _, id := range []string{alias.ID, forged.ID, "missing", ""} {
		if _, err := s.TaskUnclaimedStop(task.ID, task.Owner, id); !errors.Is(err, ErrTaskFence) {
			t.Fatalf("noncanonical %q proved unclaimed: %v", id, err)
		}
	}
	// A corrupted current pointer is not enough to upgrade a generic journal
	// entry whose request JSON is byte-for-byte the canonical stop's request.
	if _, err := s.write.Exec(`UPDATE fleet_tasks SET cancel_request = ? WHERE id = ?`, forged.ID, task.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := s.TaskUnclaimedStop(task.ID, task.Owner, forged.ID); !errors.Is(err, ErrTaskFence) {
		t.Fatalf("unindexed identical request became proof: %v", err)
	}
}

func TestTaskUnclaimedStopRejectsAssociationDamage(t *testing.T) {
	type damage struct {
		name, query string
		args        func(FleetTask, FleetOperation, FleetOperation) []any
	}
	cases := []damage{
		{"released-endpoint", `UPDATE fleet_tasks SET execution_endpoint = '' WHERE id = ?`, nil},
		{"different-endpoint", `UPDATE fleet_tasks SET execution_endpoint = 'node-b' WHERE id = ?`, nil},
		{"claimed-owner", `UPDATE fleet_tasks SET execution_owner = 'a-worker' WHERE id = ?`, nil},
		{"later-generation", `UPDATE fleet_tasks SET generation = generation + 1 WHERE id = ?`, nil},
		{"earlier-generation", `UPDATE fleet_tasks SET generation = generation - 1 WHERE id = ?`, nil},
		{"different-attempt", `UPDATE fleet_tasks SET attempt_id = 'other-attempt' WHERE id = ?`, nil},
		{"legacy-task", `UPDATE fleet_tasks SET authority_version = 0 WHERE id = ?`, nil},
		{"stop-owner", `UPDATE fleet_operations SET task_owner = 'other-person' WHERE id = ?`, func(_ FleetTask, _, stop FleetOperation) []any { return []any{stop.ID} }},
		{"stop-ref", `UPDATE fleet_operations SET task_ref = 'T99999' WHERE id = ?`, func(_ FleetTask, _, stop FleetOperation) []any { return []any{stop.ID} }},
		{"stop-generation", `UPDATE fleet_operations SET task_generation = task_generation + 1 WHERE id = ?`, func(_ FleetTask, _, stop FleetOperation) []any { return []any{stop.ID} }},
		{"stop-fleet", `UPDATE fleet_operations SET fleet_id = 'other-fleet' WHERE id = ?`, func(_ FleetTask, _, stop FleetOperation) []any { return []any{stop.ID} }},
		{"start-owner", `UPDATE fleet_operations SET task_owner = 'other-person' WHERE id = ?`, func(_ FleetTask, start, _ FleetOperation) []any { return []any{start.ID} }},
		{"start-ref", `UPDATE fleet_operations SET task_ref = '' WHERE id = ?`, func(_ FleetTask, start, _ FleetOperation) []any { return []any{start.ID} }},
		{"start-generation", `UPDATE fleet_operations SET task_generation = task_generation + 1 WHERE id = ?`, func(_ FleetTask, start, _ FleetOperation) []any { return []any{start.ID} }},
		{"missing-start", `DELETE FROM fleet_operations WHERE id = ?`, func(_ FleetTask, start, _ FleetOperation) []any { return []any{start.ID} }},
		{"missing-stop", `DELETE FROM fleet_operations WHERE id = ?`, func(_ FleetTask, _, stop FleetOperation) []any { return []any{stop.ID} }},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			s := taskStore(t)
			task, start, stop := unclaimedStopFixture(t, s, "damaged")
			args := []any{task.ID}
			if tc.args != nil {
				args = tc.args(task, start, stop)
			}
			if _, err := s.write.Exec(tc.query, args...); err != nil {
				t.Fatal(err)
			}
			if _, err := s.TaskUnclaimedStop(task.ID, task.Owner, stop.ID); !errors.Is(err, ErrTaskFence) {
				t.Fatalf("damaged association accepted: %v", err)
			}
		})
	}
}

func TestTaskUnclaimedStopRejectsRequestDamage(t *testing.T) {
	for _, tc := range []struct {
		field string
		value any
	}{
		{"worker_id", "claimed-worker"}, {"worker_id", nil}, {"worker_id", json.RawMessage(`null`)}, {"worker_id", false},
		{"task", "T99999"}, {"start_operation_id", "older-start"}, {"generation", 99},
		{"attempt_id", "older-attempt"}, {"execution_endpoint", "node-b"},
		{"control_version", 0}, {"action", "worker_start"}, {"fleet_id", "other-fleet"},
	} {
		t.Run(fmt.Sprintf("%s-%v", tc.field, tc.value), func(t *testing.T) {
			s := taskStore(t)
			task, _, stop := unclaimedStopFixture(t, s, "request")
			var request map[string]any
			if err := json.Unmarshal([]byte(stop.Request), &request); err != nil {
				t.Fatal(err)
			}
			dst := request["params"].(map[string]any)
			if tc.field == "control_version" || tc.field == "action" || tc.field == "fleet_id" {
				dst = request
			}
			dst[tc.field] = tc.value
			if tc.value == nil {
				delete(dst, tc.field) // missing worker_id must not decode as empty
			}
			b, err := json.Marshal(request)
			if err != nil {
				t.Fatal(err)
			}
			if _, err := s.write.Exec(`UPDATE fleet_operations SET request = ? WHERE id = ?`, string(b), stop.ID); err != nil {
				t.Fatal(err)
			}
			if _, err := s.TaskUnclaimedStop(task.ID, task.Owner, stop.ID); !errors.Is(err, ErrTaskFence) {
				t.Fatalf("damaged request accepted: %v", err)
			}
		})
	}
}

func TestTaskUnclaimedStopRejectsHistoricalAndForeign(t *testing.T) {
	s := taskStore(t)
	task, _, stop := unclaimedStopFixture(t, s, "old")
	other, _, newer := unclaimedStopFixture(t, s, "new")
	for _, tc := range []struct {
		id          int64
		owner, stop string
	}{
		{task.ID, "bob", stop.ID}, {task.ID, "", stop.ID}, {other.ID, task.Owner, stop.ID},
		{task.ID, task.Owner, newer.ID}, {999999, task.Owner, stop.ID},
	} {
		if _, err := s.TaskUnclaimedStop(tc.id, tc.owner, tc.stop); !errors.Is(err, ErrTaskFence) {
			t.Fatalf("foreign proof: %+v %v", tc, err)
		}
	}
	claimed, receipt := executionExit(t, s, "real-native")
	if _, _, err := s.RecordTaskSessionExit(receipt, "real-native-exit", time.Now()); err != nil {
		t.Fatal(err)
	}
	if _, err := s.TaskUnclaimedStop(claimed.ID, claimed.Owner, receipt.StopOperationID); !errors.Is(err, ErrTaskFence) {
		t.Fatalf("released native session mistaken for unclaimed: %v", err)
	}
}

func TestTaskUnclaimedStopAfterNativeHistory(t *testing.T) {
	s := taskStore(t)
	task, receipt := executionExit(t, s, "native-before-unclaimed")
	// The Task has genuinely run before. Retained historical display fields and
	// that prior native exit are not this new execution's ownership or exit proof.
	if _, err := s.write.Exec(`UPDATE fleet_tasks SET worker_id = ?, session_key = 'scratch-old', state = ? WHERE id = ?`, executionWorker, TaskRunning, task.ID); err != nil {
		t.Fatal(err)
	}
	released, exit, err := s.RecordTaskSessionExit(receipt, "history-exit", time.Now())
	if err != nil {
		t.Fatal(err)
	}
	start := executionResumeOp(released, "history-resume")
	resumed, err := s.ResumeTaskExecution(start, "node-a", exit.ID)
	if err != nil {
		t.Fatal(err)
	}
	stopped, stop, err := s.RequestTaskStop(task.ID, task.Owner, "history-new-stop", "stop before new claim", time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.TaskUnclaimedStop(task.ID, task.Owner, receipt.StopOperationID); !errors.Is(err, ErrTaskFence) {
		t.Fatalf("historical stop covered newer execution: %v", err)
	}
	proof, err := s.TaskUnclaimedStop(task.ID, task.Owner, stop.ID)
	if err != nil || proof.OperationID != start.ID || proof.BindingGeneration != resumed.Generation ||
		proof.Generation != stopped.Generation || proof.ExecutionOwner != "" {
		t.Fatalf("new unclaimed execution confused with old native session: %+v %v", proof, err)
	}
	current, err := s.FleetTask(task.ID)
	if err != nil || current.WorkerID != executionWorker || current.SessionKey != "scratch-old" || current.State != TaskRunning || current.Outcome != "" {
		t.Fatalf("proof erased native history or changed outcome: %+v %v", current, err)
	}
}
