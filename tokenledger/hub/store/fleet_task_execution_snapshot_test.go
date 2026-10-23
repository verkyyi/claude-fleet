package store

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"reflect"
	"testing"
	"time"
)

// This fixture is also consumed by the node fence selftest. In particular the
// stable Task FID is NOT the session component of execution_owner.
func TestTaskExecutionSnapshotContract(t *testing.T) {
	s := taskStore(t)
	task := acceptedTask(t, s, "snapshot", "")
	if _, err := s.TaskExecutionSnapshot(task.ID, task.Owner); !errors.Is(err, ErrTaskFence) {
		t.Fatalf("uncontrolled task exported: %v", err)
	}
	o := executionOp(task, "snapshot-start")
	o.ID = "start-fixture"
	if _, err := s.AuthorizeTaskExecution(o, "node-a"); err != nil {
		t.Fatal(err)
	}
	reserved, err := s.TaskExecutionSnapshot(task.ID, task.Owner)
	if err != nil || reserved.ExecutionOwner != "" || reserved.OperationID != o.ID {
		t.Fatalf("reservation: %+v %v", reserved, err)
	}
	if _, err := s.TaskExecutionSnapshot(task.ID, "bob"); !errors.Is(err, ErrTaskFence) {
		t.Fatalf("foreign snapshot: %v", err)
	}
	if _, err := s.ClaimTaskExecution(task.ID, task.Owner, o.ID, "node-a", executionWorker, task.Generation, task.AttemptID); err != nil {
		t.Fatal(err)
	}
	snapshot, err := s.TaskExecutionSnapshot(task.ID, task.Owner)
	if err != nil {
		t.Fatal(err)
	}
	fixture, err := os.ReadFile("testdata/task_execution.json")
	if err != nil {
		t.Fatal(err)
	}
	var want, got map[string]any
	if err := json.Unmarshal(fixture, &want); err != nil {
		t.Fatal(err)
	}
	want["task_ref"], want["task_fid"], want["attempt_id"] = task.Ref, task.FID, task.AttemptID
	encoded, err := json.Marshal(snapshot)
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(encoded, &got); err != nil || !reflect.DeepEqual(got, want) {
		t.Fatalf("snapshot contract: got %s want %v err %v", encoded, want, err)
	}
	stopped, stop, err := s.RequestTaskStop(task.ID, task.Owner, "snapshot-stop", "explicit stop", time.Now())
	if err != nil {
		t.Fatal(err)
	}
	snapshot, err = s.TaskExecutionSnapshot(task.ID, task.Owner)
	if err != nil || snapshot.Generation != stopped.Generation || snapshot.BindingGeneration != task.Generation ||
		snapshot.AttemptID != task.AttemptID || snapshot.OperationID != o.ID || snapshot.CancelRequest != stop.ID || snapshot.ExecutionOwner != executionWorker {
		t.Fatalf("stopped snapshot: %+v %v", snapshot, err)
	}
}

func TestTaskExecutionSnapshotsReconnectScope(t *testing.T) {
	s := taskStore(t)
	for i := 0; i < 103; i++ {
		task := acceptedTask(t, s, fmt.Sprintf("sync-%d", i), "")
		endpoint := "node-a"
		if i == 102 {
			endpoint = "node-b"
		}
		if _, err := s.AuthorizeTaskExecution(executionOp(task, fmt.Sprintf("start-sync-%d", i)), endpoint); err != nil {
			t.Fatal(err)
		}
		if i == 101 {
			if _, _, err := s.RequestTaskStop(task.ID, task.Owner, "stop-last", "offline stop", time.Now()); err != nil {
				t.Fatal(err)
			}
		}
	}
	legacy := acceptedTask(t, s, "legacy-sync", "")
	if _, err := s.write.Exec(`UPDATE fleet_tasks SET execution_endpoint = ? WHERE id = ?`, "node-a", legacy.ID); err != nil {
		t.Fatal(err)
	}
	snapshots, err := s.TaskExecutionSnapshots("alice", "node-a")
	if err != nil || len(snapshots) != 102 {
		t.Fatalf("complete sync: %d %v", len(snapshots), err)
	}
	if snapshots[101].CancelRequest == "" || snapshots[101].ExecutionOwner != "" {
		t.Fatalf("lost unclaimed stop beyond first 100: %+v", snapshots[101])
	}
	other, err := s.TaskExecutionSnapshots("alice", "node-b")
	if err != nil || len(other) != 1 {
		t.Fatalf("endpoint isolation: %+v %v", other, err)
	}
	foreign, err := s.TaskExecutionSnapshots("bob", "node-a")
	if err != nil || len(foreign) != 0 {
		t.Fatalf("owner isolation: %+v %v", foreign, err)
	}
	if _, err := s.write.Exec(`UPDATE fleet_tasks SET attempt_id = 'broken' WHERE operation_id = ?`, snapshots[101].OperationID); err != nil {
		t.Fatal(err)
	}
	if partial, err := s.TaskExecutionSnapshots("alice", "node-a"); !errors.Is(err, ErrTaskFence) || partial != nil {
		t.Fatalf("corruption returned a partial sync: %d %v", len(partial), err)
	}
}
