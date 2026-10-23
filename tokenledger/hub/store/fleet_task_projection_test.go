package store

import (
	"database/sql"
	"fmt"
	"reflect"
	"testing"
	"time"
)

// Historical ID events and sweep observations are not execution authority.
func TestTaskProjectionControlledGeneration(t *testing.T) {
	for _, kind := range []string{"result", "close", "reconcile-never-started"} {
		t.Run(kind, func(t *testing.T) {
			s := taskStore(t)
			_, receipt := executionExit(t, s, "audit-"+kind)
			released, exit, err := s.RecordTaskSessionExit(receipt, "audit-exit", time.Now())
			if err != nil {
				t.Fatal(err)
			}
			current, err := s.ResumeTaskExecution(executionResumeOp(released, "audit-next"), "node-b", exit.ID)
			if err != nil {
				t.Fatal(err)
			}
			if kind == "reconcile-never-started" {
				_, err = s.write.Exec(`UPDATE fleet_tasks SET created_at = ? WHERE id = ?`, time.Now().Add(-48*time.Hour).UTC().Format(rfc), current.ID)
				if err != nil {
					t.Fatal(err)
				}
				_, err = s.ReconcileClosedTasks(current.Owner, true, time.Now())
			} else {
				tx, e := s.write.Begin()
				if e != nil {
					t.Fatal(e)
				}
				if kind == "result" {
					_, err = writeTaskResult(tx, current.Owner, "22222222-2222-4222-8222-222222222222", current.FID, []int64{current.ID}, "succeeded", "", 99, time.Now())
				} else {
					_, err = endTasksOnIDClose(tx, current.Owner, "22222222-2222-4222-8222-222222222222", current.FID, []int64{current.ID}, "old wrapper closed", time.Now())
				}
				if err != nil {
					tx.Rollback()
					t.Fatal(err)
				}
				err = tx.Commit()
			}
			if err != nil {
				t.Fatal(err)
			}
			got, err := s.FleetTask(current.ID)
			if err != nil {
				t.Fatal(err)
			}
			if got.Outcome != current.Outcome || got.State != current.State || got.Generation != current.Generation || got.OperationID != current.OperationID {
				t.Fatalf("historical projection rewrote current execution: %+v", got)
			}

		})
	}
}

func TestTaskProjectionKeepsControlledIDHistory(t *testing.T) {
	for _, phase := range []string{"released", "unclaimed", "same-worker-old-generation"} {
		t.Run(phase, func(t *testing.T) {
			s := taskStore(t)
			_, receipt := executionExit(t, s, "projection-history")
			task, exit, err := s.RecordTaskSessionExit(receipt, "projection-exit", time.Now())
			if err != nil {
				t.Fatal(err)
			}
			if phase != "released" {
				task, err = s.ResumeTaskExecution(executionResumeOp(task, "projection-next"), "node-b", exit.ID)
				if err != nil {
					t.Fatal(err)
				}
			}
			if phase == "same-worker-old-generation" {
				// FID alone is not sufficient proof: emulate a retained current worker
				// with an earlier event generation. Old ledger events have no trusted fence.
				_, err = s.write.Exec(`UPDATE fleet_tasks SET execution_owner = ? WHERE id = ?`, executionWorker, task.ID)
				if err != nil {
					t.Fatal(err)
				}
				task, _ = s.FleetTask(task.ID)
			}
			id := "22222222-2222-4222-8222-222222222222"
			for i, ev := range []map[string]any{
				{"ev": "opened", "task": task.Ref, "task_id": task.FID, "agent": "claude"},
				{"ev": "result", "state": "succeeded", "summary": "old work result", "pr": "o/r#17"},
				{"ev": "closed", "reason": "old wrapper closed"},
				{"ev": "reopened", "window": "@9"},
			} {
				ev["seq"], ev["ts"], ev["generation"] = float64(i+1), float64(1000+i), float64(receipt.Generation)
				_, err = s.ApplyFleetIDEvents(FleetIDPush{Owner: task.Owner, EndpointID: "node-a", ID: id, Events: []map[string]any{ev}})
				if err != nil {
					t.Fatal(err)
				}
				got, e := s.FleetTask(task.ID)
				if e != nil || !reflect.DeepEqual(got, task) {
					t.Fatalf("%s mutated controlled Task: %+v, err=%v", ev["ev"], got, e)
				}
			}
			var n int
			if err = s.read.QueryRow(`SELECT COUNT(*) FROM fleet_id_results WHERE id = ? AND state = 'succeeded' AND summary = 'old work result' AND pr = 'o/r#17'`, id).Scan(&n); err != nil || n != 1 {
				t.Fatalf("result history lost: %d %v", n, err)
			}
			rec, err := s.FleetIDOf(task.Owner, id)
			if err != nil || rec.Seq != 4 || rec.ClosedAt != 0 {
				t.Fatalf("ID close/reopen history lost: %+v %v", rec, err)
			}
		})
	}
}

func TestTaskProjectionControlledSweepsAndUndo(t *testing.T) {
	for _, kind := range []string{"result", "closed", "legacy-cutoff", "undo", "reopen"} {
		t.Run(kind, func(t *testing.T) {
			s := taskStore(t)
			task := acceptedTask(t, s, "projection-sweep", "")
			op := executionOp(task, "projection-start")
			var err error
			task, err = s.AuthorizeTaskExecution(op, "node-a")
			if err != nil {
				t.Fatal(err)
			}
			id := "33333333-3333-4333-8333-333333333333"
			if kind == "result" || kind == "closed" {
				events := []map[string]any{{"ev": "opened", "task": task.Ref, "task_id": task.FID, "seq": float64(1), "ts": float64(1000)}}
				ev := map[string]any{"ev": "closed", "reason": "old close", "seq": float64(2), "ts": float64(1001)}
				if kind == "result" {
					ev["ev"], ev["state"] = "result", "failed"
				}
				events = append(events, ev)
				if _, err = s.ApplyFleetIDEvents(FleetIDPush{Owner: task.Owner, EndpointID: "node-a", ID: id, Events: events}); err != nil {
					t.Fatal(err)
				}
			}
			if kind == "undo" || kind == "reopen" {
				observation := ObsReconcileCancel + TaskAccepted
				if kind == "reopen" {
					observation = ObsIDClosed + id + ":" + TaskAccepted
				}
				_, err = s.write.Exec(`UPDATE fleet_tasks SET state = ?, outcome = ?, observation = ? WHERE id = ?`, TaskCancelled, TaskCancelled, observation, task.ID)
				if err != nil {
					t.Fatal(err)
				}
				task, _ = s.FleetTask(task.ID)
			}
			if kind == "undo" {
				n, e := s.UndoReconcileCancel(task.Owner, time.Now())
				if e != nil || n != 0 {
					t.Fatalf("undo: %d %v", n, e)
				}
			} else if kind == "reopen" {
				tx, e := s.write.Begin()
				if e != nil {
					t.Fatal(e)
				}
				if err = reopenTasksOnID(tx, task.Owner, id, time.Now()); err != nil {
					tx.Rollback()
					t.Fatal(err)
				}
				if err = tx.Commit(); err != nil {
					t.Fatal(err)
				}
			} else {
				for _, apply := range []bool{false, true} {
					r, e := s.ReconcileTaskStates(task.Owner, task.ID+1, apply, time.Now())
					if e != nil || len(r.Items) != 0 {
						t.Fatalf("state sweep: %+v %v", r, e)
					}
					c, e := s.ReconcileClosedTasks(task.Owner, apply, time.Now())
					if e != nil || len(c.Items) != 0 {
						t.Fatalf("close sweep: %+v %v", c, e)
					}
				}
			}
			got, e := s.FleetTask(task.ID)
			if e != nil || !reflect.DeepEqual(task, got) {
				t.Fatalf("projection changed controlled history: %+v %v", got, e)
			}
		})
	}
}

func TestTaskProjectionSnapshotRejectsAdmissionAndGenerationChange(t *testing.T) {
	for _, change := range []string{"generation", "operation", "attempt", "owner", "endpoint", "stop", "state", "outcome", "observation"} {
		t.Run(change, func(t *testing.T) {
			s := taskStore(t)
			task := acceptedTask(t, s, "projection-cas", "")
			tx, err := s.write.Begin()
			if err != nil {
				t.Fatal(err)
			}
			defer tx.Rollback()
			where, args, err := legacyTaskProjection(tx, task.Owner, "id = ?", []any{task.ID})
			if err != nil {
				t.Fatal(err)
			}
			updates := map[string]string{"generation": "generation = generation + 1", "operation": "operation_id = 'new-start'", "attempt": "attempt_id = 'new-attempt'", "owner": "execution_owner = 'new-worker'", "endpoint": "execution_endpoint = 'new-node'", "stop": "cancel_request = 'stop'", "state": "state = 'running'", "outcome": "outcome = 'failed'", "observation": "observation = 'new-result'"}
			if _, err = tx.Exec(`UPDATE fleet_tasks SET `+updates[change]+` WHERE id = ?`, task.ID); err != nil {
				t.Fatal(err)
			}
			res, err := tx.Exec(`UPDATE fleet_tasks SET state = 'cancelled' WHERE `+where, args...)
			if err != nil {
				t.Fatal(err)
			}
			n, err := res.RowsAffected()
			if err != nil || n != 0 {
				t.Fatalf("stale projection applied: %d %v", n, err)
			}
		})
	}
	for _, controlled := range []bool{false, true} {
		t.Run(fmt.Sprintf("sweep-rechecks-controlled-%v", controlled), func(t *testing.T) {
			s := taskStore(t)
			snapshot := acceptedTask(t, s, "projection-recheck", "")
			if controlled {
				if _, err := s.AuthorizeTaskExecution(executionOp(snapshot, "new-start"), "node-a"); err != nil {
					t.Fatal(err)
				}
			} else if _, err := s.write.Exec(`UPDATE fleet_tasks SET generation = generation + 1 WHERE id = ?`, snapshot.ID); err != nil {
				t.Fatal(err)
			}
			called := false
			err := s.reconcileWrite(snapshot, func(tx *sql.Tx) (int64, error) { called = true; return 1, nil })
			if err != nil || called {
				t.Fatalf("stale sweep callback ran: %v %v", called, err)
			}
		})
	}
}

func TestTaskProjectionMixedLegacyAliases(t *testing.T) {
	s := taskStore(t)
	legacy := acceptedTask(t, s, "legacy-projection", "")
	controlled := acceptedTask(t, s, "controlled-projection", "")
	var err error
	controlled, err = s.AuthorizeTaskExecution(executionOp(controlled, "controlled-start"), "node-a")
	if err != nil {
		t.Fatal(err)
	}
	tx, err := s.write.Begin()
	if err != nil {
		t.Fatal(err)
	}
	n, err := writeTaskResult(tx, legacy.Owner, "44444444-4444-4444-8444-444444444444", "", []int64{legacy.ID, controlled.ID}, "succeeded", "o/r#2", 1, time.Now())
	if err != nil {
		tx.Rollback()
		t.Fatal(err)
	}
	if err = tx.Commit(); err != nil {
		t.Fatal(err)
	}
	if n != 1 {
		t.Fatalf("projected %d tasks; want only legacy", n)
	}
	got, err := s.FleetTask(controlled.ID)
	if err != nil || !reflect.DeepEqual(got, controlled) {
		t.Fatalf("controlled alias changed: %+v %v", got, err)
	}
	old, err := s.FleetTask(legacy.ID)
	if err != nil || old.Outcome != TaskSucceeded || old.PR != "o/r#2" {
		t.Fatalf("legacy projection lost: %+v %v", old, err)
	}
}
