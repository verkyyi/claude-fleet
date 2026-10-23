package store

import (
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"sync"
	"testing"
	"time"
)

func taskStartOperation(t FleetTask, key string) FleetOperation {
	b, _ := json.Marshal(map[string]any{"params": map[string]any{"task": t.Ref,
		"dispatch": taskStartEnvelope{t.Ref, t.Generation, t.AttemptID}}})
	return FleetOperation{ID: "op-" + key, Actor: t.Owner, TaskOwner: t.Owner, Idem: key,
		Action: "worker_start", Request: string(b), Status: "pending", Created: time.Now(), Updated: time.Now()}
}

func TestTaskCancelFencesQueuedAndLateStarts(t *testing.T) {
	s := taskStore(t)
	task := acceptedTask(t, s, "cancel-start", "")
	op := taskStartOperation(task, "before")
	if err := s.InsertFleetOperation(op); err != nil {
		t.Fatal(err)
	}
	var ref string
	var generation int64
	if err := s.read.QueryRow(`SELECT task_ref, task_generation FROM fleet_operations WHERE id = ?`, op.ID).Scan(&ref, &generation); err != nil || ref != task.Ref || generation != task.Generation {
		t.Fatalf("journal binding: %q %d %v", ref, generation, err)
	}
	cancelled, err := s.CancelUnopenedTask(task.ID, task.Owner, "operator cancelled pending start", time.Now())
	if err != nil || cancelled.Generation != task.Generation+1 || cancelled.CancelRequest == "" || cancelled.AttemptID != task.AttemptID {
		t.Fatalf("cancel fence: %+v %v", cancelled, err)
	}
	again, err := s.CancelUnopenedTask(task.ID, task.Owner, "repeat", time.Now())
	if err != nil || again.Generation != cancelled.Generation || again.CancelRequest != cancelled.CancelRequest {
		t.Fatalf("repeat cancellation changed generation: %+v %v", again, err)
	}
	for _, late := range []string{"accepted", "running", "succeeded", "failed", "unknown"} {
		if err := s.UpdateFleetOperation(op.ID, late, `{"late":true}`, time.Now()); err != nil {
			t.Fatal(err)
		}
		got, err := s.FleetOperation(op.ID)
		if err != nil || got.Status != "failed" || got.Result != taskStartCancelledResult || got.Result == `{"late":true}` {
			t.Fatalf("late %s overwrote cancellation: %+v %v", late, got, err)
		}
	}
	if err := s.InsertFleetOperation(op); !errors.Is(err, ErrIdemTaken) {
		t.Fatalf("replay must return existing operation: %v", err)
	}
	late := taskStartOperation(task, "after")
	if err := s.InsertFleetOperation(late); !errors.Is(err, ErrTaskFence) {
		t.Fatalf("late old generation accepted: %v", err)
	}
	// Copying the newer generation does not clear the persistent cancellation.
	if err := s.InsertFleetOperation(taskStartOperation(cancelled, "forged-new-generation")); !errors.Is(err, ErrTaskFence) {
		t.Fatalf("cancel marker bypassed: %v", err)
	}
	if _, err := s.FleetOperation(late.ID); !errors.Is(err, sql.ErrNoRows) {
		t.Fatalf("refused start journalled: %v", err)
	}
}

func TestTaskCancelStartTransactionRace(t *testing.T) {
	s := taskStore(t)
	// Real competing DB transactions, shared barrier; either ordering is
	// valid, but no pending operation may survive a committed cancellation.
	for i := 0; i < 24; i++ {
		task := acceptedTask(t, s, fmt.Sprintf("race-%d", i), "")
		op := taskStartOperation(task, fmt.Sprintf("race-%d", i))
		gate := make(chan struct{})
		results := make(chan error, 2)
		go func() { <-gate; results <- s.InsertFleetOperation(op) }()
		go func() {
			<-gate
			_, err := s.CancelUnopenedTask(task.ID, task.Owner, "cancel racing enqueue", time.Now())
			results <- err
		}()
		close(gate)
		for j := 0; j < 2; j++ {
			if err := <-results; err != nil && !errors.Is(err, ErrTaskFence) {
				t.Fatal(err)
			}
		}
		got, err := s.FleetOperation(op.ID)
		if err == nil && (got.Status != "failed" || got.Result != taskStartCancelledResult) || err != nil && !errors.Is(err, sql.ErrNoRows) {
			t.Fatalf("cancel/insert left live permission: %+v %v", got, err)
		}
		if err := s.InsertFleetOperation(taskStartOperation(task, fmt.Sprintf("late-%d", i))); !errors.Is(err, ErrTaskFence) {
			t.Fatalf("old request after both commits: %v", err)
		}
	}
}

func TestTaskStartConcurrentIdempotency(t *testing.T) {
	s := taskStore(t)
	task := acceptedTask(t, s, "idem-race", "")
	gate := make(chan struct{})
	results := make(chan error, 12)
	var wg sync.WaitGroup
	for i := 0; i < cap(results); i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			op := taskStartOperation(task, "same-key")
			op.ID = fmt.Sprintf("competing-%d", i)
			<-gate
			results <- s.InsertFleetOperation(op)
		}(i)
	}
	close(gate)
	wg.Wait()
	close(results)
	winners := 0
	for err := range results {
		if err == nil {
			winners++
		} else if !errors.Is(err, ErrIdemTaken) {
			t.Fatal(err)
		}
	}
	if winners != 1 {
		t.Fatalf("idempotency winners=%d", winners)
	}
}

func TestTaskCancelPreIndexJournal(t *testing.T) {
	s := taskStore(t)
	task := acceptedTask(t, s, "old-journal", "")
	op := taskStartOperation(task, "old")
	if err := s.InsertFleetOperation(op); err != nil {
		t.Fatal(err)
	}
	if _, err := s.write.Exec(`UPDATE fleet_operations SET task_ref = '', task_generation = 0 WHERE id = ?`, op.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := s.CancelUnopenedTask(task.ID, task.Owner, "cancel old queued request", time.Now()); err != nil {
		t.Fatal(err)
	}
	got, err := s.FleetOperation(op.ID)
	if err != nil || got.Status != "failed" || got.Result != taskStartCancelledResult {
		t.Fatalf("old journal bypassed fence: %+v %v", got, err)
	}
}

func TestTaskCancelLegacyReplayAndObservation(t *testing.T) {
	s := taskStore(t)
	task := acceptedTask(t, s, "legacy-cancel", "")
	op := taskStartOperation(task, "old-pending")
	if err := s.InsertFleetOperation(op); err != nil {
		t.Fatal(err)
	}
	// A cancellation persisted by the previous release has no generation
	// fence. Repeating it repairs that omission and its old pending journal.
	if _, err := s.write.Exec(`UPDATE fleet_tasks SET state = 'cancelled', outcome = 'cancelled' WHERE id = ?`, task.ID); err != nil {
		t.Fatal(err)
	}
	repaired, err := s.CancelUnopenedTask(task.ID, task.Owner, "repeat old cancellation", time.Now())
	if err != nil || repaired.Generation != task.Generation+1 || repaired.CancelRequest == "" {
		t.Fatalf("legacy cancellation not fenced: %+v %v", repaired, err)
	}
	got, err := s.FleetOperation(op.ID)
	if err != nil || got.Status != "failed" || got.Result != taskStartCancelledResult {
		t.Fatalf("legacy cancellation left pending operation: %+v %v", got, err)
	}
	// Observers that update lifecycle words do not erase the explicit stop.
	if _, err := s.write.Exec(`UPDATE fleet_tasks SET state = 'accepted', outcome = '' WHERE id = ?`, task.ID); err != nil {
		t.Fatal(err)
	}
	if err := s.InsertFleetOperation(taskStartOperation(repaired, "after-observation")); !errors.Is(err, ErrTaskFence) {
		t.Fatalf("observation revived a cancelled start: %v", err)
	}
	// Existing reconciliation semantics for ordinary failures are unchanged.
	other := acceptedTask(t, s, "ordinary-failure", "")
	ordinary := taskStartOperation(other, "ordinary-failure")
	if err := s.InsertFleetOperation(ordinary); err != nil {
		t.Fatal(err)
	}
	for _, state := range []string{"failed", "unknown", "succeeded"} {
		if err := s.UpdateFleetOperation(ordinary.ID, state, `{"ordinary":true}`, time.Now()); err != nil {
			t.Fatal(err)
		}
	}
	if got, err := s.FleetOperation(ordinary.ID); err != nil || got.Status != "succeeded" {
		t.Fatalf("ordinary observation was frozen: %+v %v", got, err)
	}
}

func TestTaskStartDraftHasNoAcceptedIdentity(t *testing.T) {
	s := taskStore(t)
	op := FleetOperation{ID: "draft", Actor: "alice", TaskOwner: "alice", Idem: "draft", Action: "worker_start",
		Request: `{"params":{"draft":"unsent words","dispatch":{"version":1,"request_id":"draft","requested_agent":"default","resolved_agent":"codex","agent_source":"fleet"}}}`,
		Status:  "pending", Created: time.Now(), Updated: time.Now()}
	if err := s.InsertFleetOperation(op); err != nil {
		t.Fatalf("an unsent draft's provider choice is not task authority: %v", err)
	}
}

func TestTaskCancelProtectsPreviouslyFailedStart(t *testing.T) {
	s := taskStore(t)
	task := acceptedTask(t, s, "failed-before-cancel", "")
	op := taskStartOperation(task, "failed-before-cancel")
	if err := s.InsertFleetOperation(op); err != nil {
		t.Fatal(err)
	}
	if err := s.UpdateFleetOperation(op.ID, "failed", `{"error":{"code":"REMOTE_ERROR"}}`, time.Now()); err != nil {
		t.Fatal(err)
	}
	if _, err := s.CancelUnopenedTask(task.ID, task.Owner, "cancel after transport failure", time.Now()); err != nil {
		t.Fatal(err)
	}
	for _, late := range []string{"accepted", "running", "succeeded"} {
		if err := s.UpdateFleetOperation(op.ID, late, `{"late":true}`, time.Now()); err != nil {
			t.Fatal(err)
		}
		if got, err := s.FleetOperation(op.ID); err != nil || got.Status != "failed" || got.Result != taskStartCancelledResult {
			t.Fatalf("late observation revived pre-cancel failure: %+v %v", got, err)
		}
	}
}
