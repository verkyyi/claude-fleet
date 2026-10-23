package store

import (
	"encoding/json"
	"errors"
	"fmt"
	"sync"
	"testing"
	"time"
)

const executionFleet = "11111111-1111-4111-8111-111111111111"
const executionWorker = executionFleet + "/22222222-2222-4222-8222-222222222222"

func executionOp(t FleetTask, key string) FleetOperation {
	o := taskStartOperation(t, key)
	o.FleetID = executionFleet
	var request map[string]any
	_ = json.Unmarshal([]byte(o.Request), &request)
	request["control_version"] = 1
	b, _ := json.Marshal(request)
	o.Request = string(b)
	return o
}

// taskStore runs the same transactions on SQLite and the CI Postgres leg.
func TestTaskExecutionConcurrentAuthorization(t *testing.T) {
	for _, sameKey := range []bool{false, true} {
		t.Run(fmt.Sprint(sameKey), func(t *testing.T) {
			s := taskStore(t)
			task := acceptedTask(t, s, "one-binding", "")
			gate := make(chan struct{})
			results := make(chan error, 12)
			var wg sync.WaitGroup
			for i := 0; i < cap(results); i++ {
				wg.Add(1)
				go func(i int) {
					defer wg.Done()
					key := fmt.Sprintf("start-%d", i)
					if sameKey {
						key = "same-start"
					}
					o := executionOp(task, key)
					o.ID = fmt.Sprintf("op-%d", i)
					<-gate
					_, err := s.AuthorizeTaskExecution(o, fmt.Sprintf("node-%d", i))
					results <- err
				}(i)
			}
			close(gate)
			wg.Wait()
			close(results)
			winners := 0
			for err := range results {
				if err == nil {
					winners++
					continue
				}
				want := ErrTaskConflict
				if sameKey {
					want = ErrIdemTaken
				}
				if !errors.Is(err, want) {
					t.Fatal(err)
				}
			}
			var count int
			if err := s.read.QueryRow(`SELECT COUNT(*) FROM fleet_operations WHERE action = 'worker_start'`).Scan(&count); err != nil || count != 1 || winners != 1 {
				t.Fatalf("winners=%d rows=%d err=%v", winners, count, err)
			}
			got, _ := s.FleetTask(task.ID)
			if got.ExecutionEndpoint == "" || got.OperationID == "" || got.ExecutionOwner != "" || got.State != task.State || got.Generation != task.Generation {
				t.Fatalf("binding %+v", got)
			}
		})
	}
}

func TestTaskExecutionClaimAndPersistentStop(t *testing.T) {
	s := taskStore(t)
	task := acceptedTask(t, s, "stop", "")
	o := executionOp(task, "start")
	if _, err := s.AuthorizeTaskExecution(o, "node-a"); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 2; i++ {
		got, err := s.ClaimTaskExecution(task.ID, task.Owner, o.ID, "node-a", executionWorker, task.Generation, task.AttemptID)
		if err != nil || got.ExecutionOwner != executionWorker {
			t.Fatalf("claim %+v %v", got, err)
		}
	}
	if _, err := s.ClaimTaskExecution(task.ID, task.Owner, o.ID, "node-b", executionWorker, task.Generation, task.AttemptID); !errors.Is(err, ErrTaskFence) {
		t.Fatalf("foreign endpoint %v", err)
	}
	otherWorker := executionFleet + "/33333333-3333-4333-8333-333333333333"
	if _, err := s.ClaimTaskExecution(task.ID, task.Owner, o.ID, "node-a", otherWorker, task.Generation, task.AttemptID); !errors.Is(err, ErrTaskConflict) {
		t.Fatalf("second worker %v", err)
	}
	stopped, stop, err := s.RequestTaskStop(task.ID, task.Owner, "stop-key", "person stopped", time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if stopped.Generation != task.Generation+1 || stopped.CancelRequest != stop.ID || stopped.AttemptID != task.AttemptID || stopped.OperationID != o.ID || stopped.ExecutionOwner != executionWorker || stopped.State != task.State || stopped.Outcome != task.Outcome || stop.Action != "worker_stop" || stop.Status != "pending" {
		t.Fatalf("stop %+v %+v", stopped, stop)
	}
	for _, key := range []string{"stop-key", "another-stop-key"} {
		again, same, err := s.RequestTaskStop(task.ID, task.Owner, key, "person stopped", time.Now())
		if err != nil || again.Generation != stopped.Generation || same.ID != stop.ID {
			t.Fatalf("repeat %+v %+v %v", again, same, err)
		}
	}
	for _, state := range []string{"accepted", "running", "succeeded", "failed"} {
		if err := s.UpdateFleetOperation(o.ID, state, `{"late":true}`, time.Now()); err != nil {
			t.Fatal(err)
		}
	}
	got, _ := s.FleetTask(task.ID)
	old, _ := s.FleetOperation(o.ID)
	if got.CancelRequest != stop.ID || got.ExecutionOwner != executionWorker || old.Result != taskStartCancelledResult {
		t.Fatalf("late receipt changed stop %+v %+v", got, old)
	}
	if _, err := s.ClaimTaskExecution(task.ID, task.Owner, o.ID, "node-a", executionWorker, task.Generation, task.AttemptID); !errors.Is(err, ErrTaskFence) {
		t.Fatalf("claim after stop %v", err)
	}
	if _, err := s.AuthorizeTaskExecution(o, "node-a"); !errors.Is(err, ErrIdemTaken) {
		t.Fatalf("start replay after stop %v", err)
	}
	for _, id := range []string{o.ID, stop.ID} {
		var generation int64
		if err := s.read.QueryRow(`SELECT task_generation FROM fleet_operations WHERE id = ?`, id).Scan(&generation); err != nil || generation != task.Generation {
			t.Fatalf("original generation %d %v", generation, err)
		}
	}
}

func TestTaskExecutionStopClaimRace(t *testing.T) {
	s := taskStore(t)
	for i := 0; i < 16; i++ {
		task := acceptedTask(t, s, fmt.Sprintf("race-%d", i), "")
		worker := fmt.Sprintf("%s/22222222-2222-4222-8222-%012x", executionFleet, i+100)
		o := executionOp(task, fmt.Sprintf("start-%d", i))
		if _, err := s.AuthorizeTaskExecution(o, "node-a"); err != nil {
			t.Fatal(err)
		}
		gate := make(chan struct{})
		results := make(chan error, 2)
		go func() {
			<-gate
			_, err := s.ClaimTaskExecution(task.ID, task.Owner, o.ID, "node-a", worker, task.Generation, task.AttemptID)
			results <- err
		}()
		go func() {
			<-gate
			_, _, err := s.RequestTaskStop(task.ID, task.Owner, fmt.Sprintf("stop-%d", i), "stop", time.Now())
			results <- err
		}()
		close(gate)
		for j := 0; j < 2; j++ {
			if err := <-results; err != nil && !errors.Is(err, ErrTaskFence) && !errors.Is(err, ErrTaskConflict) {
				t.Fatal(err)
			}
		}
		got, _ := s.FleetTask(task.ID)
		if got.CancelRequest == "" || got.Generation != task.Generation+1 {
			t.Fatalf("missing stop %+v", got)
		}
		if _, err := s.AuthorizeTaskExecution(executionOp(got, fmt.Sprintf("late-%d", i)), "node-b"); err == nil {
			t.Fatal("late start authorized")
		}
	}
}

func TestTaskExecutionOneWorkerCannotClaimTwoTasks(t *testing.T) {
	s := taskStore(t)
	a, b := acceptedTask(t, s, "worker-a", ""), acceptedTask(t, s, "worker-b", "")
	for _, task := range []FleetTask{a, b} {
		if _, err := s.AuthorizeTaskExecution(executionOp(task, "start-"+task.Ref), "node-a"); err != nil {
			t.Fatal(err)
		}
	}
	gate := make(chan struct{})
	results := make(chan error, 2)
	for _, task := range []FleetTask{a, b} {
		go func(task FleetTask) {
			<-gate
			_, err := s.ClaimTaskExecution(task.ID, task.Owner, "op-start-"+task.Ref, "node-a", executionWorker, task.Generation, task.AttemptID)
			results <- err
		}(task)
	}
	close(gate)
	winners := 0
	for i := 0; i < 2; i++ {
		if err := <-results; err == nil {
			winners++
		} else if !errors.Is(err, ErrTaskConflict) {
			t.Fatal(err)
		}
	}
	if winners != 1 {
		t.Fatalf("one worker claimed %d tasks", winners)
	}
	for _, task := range []FleetTask{a, b} {
		got, _ := s.FleetTask(task.ID)
		if got.ExecutionOwner == executionWorker {
			if _, _, err := s.RequestTaskStop(task.ID, task.Owner, "stop-bound", "stop", time.Now()); err != nil {
				t.Fatal(err)
			}
		}
	}
	for _, task := range []FleetTask{a, b} {
		got, _ := s.FleetTask(task.ID)
		if got.ExecutionOwner == "" {
			if _, err := s.ClaimTaskExecution(task.ID, task.Owner, "op-start-"+task.Ref, "node-a", executionWorker, task.Generation, task.AttemptID); !errors.Is(err, ErrTaskConflict) {
				t.Fatalf("stop released worker identity: %v", err)
			}
		}
	}
}

func TestTaskExecutionClaimRejectsHistoricalIdentity(t *testing.T) {
	for _, association := range []string{"worker", "task-fid", "ledger-task", "ledger-alias", "ledger-task-id", "foreign-owner", "ledger-unassigned"} {
		t.Run(association, func(t *testing.T) {
			s := taskStore(t)
			a, b := acceptedTask(t, s, "new", ""), acceptedTask(t, s, "old", "")
			fid := "22222222-2222-4222-8222-222222222222"
			switch association {
			case "worker":
				_, err := s.write.Exec(`UPDATE fleet_tasks SET worker_id = ? WHERE id = ?`, executionWorker, b.ID)
				if err != nil {
					t.Fatal(err)
				}
			case "task-fid":
				fid = b.FID
			default:
				owner, task, taskID, aliases := a.Owner, "", "", "[]"
				switch association {
				case "ledger-task":
					task = b.Ref
				case "ledger-alias":
					aliases = fmt.Sprintf(`["%s"]`, b.Ref)
				case "ledger-task-id":
					taskID = b.FID
				case "foreign-owner":
					owner = "bob"
				}
				_, err := s.write.Exec(`INSERT INTO fleet_ids (id, owner, code, short, endpoint_id, task, task_id, aliases, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`, fid, owner, FleetIDCode(fid), "TEST", "node-a", task, taskID, aliases, time.Now().UTC().Format(rfc))
				if err != nil {
					t.Fatal(err)
				}
			}
			o := executionOp(a, "claim-old")
			if _, err := s.AuthorizeTaskExecution(o, "node-a"); err != nil {
				t.Fatal(err)
			}
			_, err := s.ClaimTaskExecution(a.ID, a.Owner, o.ID, "node-a", executionFleet+"/"+fid, a.Generation, a.AttemptID)
			if !errors.Is(err, ErrTaskConflict) {
				t.Fatalf("claimed historical %s identity: %v", association, err)
			}
			got, err := s.FleetTask(a.ID)
			if err != nil || got.ExecutionOwner != "" {
				t.Fatalf("refused claim mutated binding: %+v %v", got, err)
			}
		})
	}
}

func TestTaskExecutionSessionIdentitySurvivesFleetMove(t *testing.T) {
	s := taskStore(t)
	tasks := []FleetTask{acceptedTask(t, s, "move-a", ""), acceptedTask(t, s, "move-b", "")}
	fleets := []string{executionFleet, "55555555-5555-4555-8555-555555555555"}
	for i, task := range tasks {
		o := executionOp(task, "move-start-"+task.Ref)
		o.FleetID = fleets[i]
		if _, err := s.AuthorizeTaskExecution(o, fmt.Sprintf("node-%d", i)); err != nil {
			t.Fatal(err)
		}
	}
	gate := make(chan struct{})
	results := make(chan error, 2)
	for i, task := range tasks {
		go func(i int, task FleetTask) {
			<-gate
			_, err := s.ClaimTaskExecution(task.ID, task.Owner, "op-move-start-"+task.Ref, fmt.Sprintf("node-%d", i),
				fleets[i]+"/22222222-2222-4222-8222-222222222222", task.Generation, task.AttemptID)
			results <- err
		}(i, task)
	}
	close(gate)
	winners := 0
	for range tasks {
		if err := <-results; err == nil {
			winners++
		} else if !errors.Is(err, ErrTaskConflict) {
			t.Fatal(err)
		}
	}
	if winners != 1 {
		t.Fatalf("same Session FID acquired %d tasks through different fleets", winners)
	}
}

func TestTaskExecutionRejectsLegacyAndForeign(t *testing.T) {
	s := taskStore(t)
	task := acceptedTask(t, s, "legacy", "")
	if _, _, err := s.RequestTaskStop(task.ID, task.Owner, "stop", "stop", time.Now()); !errors.Is(err, ErrTaskFence) {
		t.Fatalf("uncontrolled stop %v", err)
	}
	for _, column := range []string{"execution_owner", "execution_endpoint", "operation_id"} {
		if _, err := s.write.Exec(`UPDATE fleet_tasks SET `+column+` = ? WHERE id = ?`, "historical", task.ID); err != nil {
			t.Fatal(err)
		}
		if _, err := s.AuthorizeTaskExecution(executionOp(task, "start"), "node-a"); !errors.Is(err, ErrTaskFence) {
			t.Fatalf("adopted %s: %v", column, err)
		}
		if _, err := s.write.Exec(`UPDATE fleet_tasks SET `+column+` = '' WHERE id = ?`, task.ID); err != nil {
			t.Fatal(err)
		}
	}
	o := executionOp(task, "start")
	o.TaskOwner = "bob"
	if _, err := s.AuthorizeTaskExecution(o, "node-a"); !errors.Is(err, ErrTaskFence) {
		t.Fatalf("foreign owner %v", err)
	}
	o = taskStartOperation(task, "old-protocol")
	o.FleetID = executionFleet
	if _, err := s.AuthorizeTaskExecution(o, "node-a"); !errors.Is(err, ErrTaskInvalid) {
		t.Fatalf("legacy protocol %v", err)
	}
	if _, err := s.AuthorizeTaskExecution(executionOp(task, "start"), "node-a"); err != nil {
		t.Fatal(err)
	}
	if _, _, err := s.RequestTaskStop(task.ID, "bob", "stop", "stop", time.Now()); !errors.Is(err, ErrTaskFence) {
		t.Fatalf("foreign stop %v", err)
	}
}

func TestTaskExecutionCancelAuthorizationRace(t *testing.T) {
	s := taskStore(t)
	for i := 0; i < 16; i++ {
		task := acceptedTask(t, s, fmt.Sprintf("cancel-race-%d", i), "")
		o := executionOp(task, fmt.Sprintf("cancel-start-%d", i))
		gate := make(chan struct{})
		results := make(chan error, 2)
		go func() { <-gate; _, err := s.AuthorizeTaskExecution(o, "node-a"); results <- err }()
		go func() {
			<-gate
			_, err := s.CancelUnopenedTask(task.ID, task.Owner, "cancel before claim", time.Now())
			results <- err
		}()
		close(gate)
		for j := 0; j < 2; j++ {
			if err := <-results; err != nil && !errors.Is(err, ErrTaskFence) && !errors.Is(err, ErrTaskConflict) {
				t.Fatal(err)
			}
		}
		got, _ := s.FleetTask(task.ID)
		if got.CancelRequest != "" {
			if got.Generation != task.Generation+1 || got.OperationID != "" {
				t.Fatalf("cancelled task got binding %+v", got)
			}
		} else if got.OperationID != o.ID || got.ExecutionEndpoint != "node-a" {
			t.Fatalf("neither cancellation nor binding: %+v", got)
		}
	}
}

func TestTaskExecutionOldCancelCannotReplaceStop(t *testing.T) {
	s := taskStore(t)
	task := acceptedTask(t, s, "old-cancel", "")
	o := executionOp(task, "start")
	if _, err := s.AuthorizeTaskExecution(o, "node-a"); err != nil {
		t.Fatal(err)
	}
	if _, err := s.CancelUnopenedTask(task.ID, task.Owner, "old cancel", time.Now()); !errors.Is(err, ErrTaskConflict) {
		t.Fatalf("old cancel admitted controlled task: %v", err)
	}
	stopped, stop, err := s.RequestTaskStop(task.ID, task.Owner, "stop", "stop", time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.CancelUnopenedTask(task.ID, task.Owner, "old cancel after stop", time.Now()); !errors.Is(err, ErrTaskConflict) {
		t.Fatalf("old cancel overwrote stop: %v", err)
	}
	got, _ := s.FleetTask(task.ID)
	if got.CancelRequest != stop.ID || got.Generation != stopped.Generation || got.State != task.State || got.Outcome != task.Outcome {
		t.Fatalf("old cancel altered stop %+v", got)
	}
}

func TestTaskExecutionOldAndNewAdmissionRace(t *testing.T) {
	s := taskStore(t)
	for i := 0; i < 24; i++ {
		task := acceptedTask(t, s, fmt.Sprintf("mixed-%d", i), "")
		old := taskStartOperation(task, fmt.Sprintf("old-%d", i))
		old.FleetID = executionFleet
		if i%2 == 0 {
			old.Request = fmt.Sprintf(`{"params":{"task":%q}}`, task.Ref)
		}
		controlled := executionOp(task, fmt.Sprintf("controlled-%d", i))
		gate := make(chan struct{})
		results := make(chan error, 2)
		go func() { <-gate; results <- s.InsertFleetOperation(old) }()
		go func() { <-gate; _, err := s.AuthorizeTaskExecution(controlled, "node-a"); results <- err }()
		close(gate)
		winners := 0
		for j := 0; j < 2; j++ {
			err := <-results
			if err == nil {
				winners++
			} else if !errors.Is(err, ErrTaskConflict) {
				t.Fatal(err)
			}
		}
		if winners != 1 {
			t.Fatalf("old and new both admitted: %d", winners)
		}
	}
}

func TestTaskExecutionNeverAdoptsLegacyJournal(t *testing.T) {
	s := taskStore(t)
	for _, status := range []string{"pending", "accepted", "unknown", "failed", "succeeded"} {
		task := acceptedTask(t, s, "legacy-"+status, "")
		old := taskStartOperation(task, "old-"+status)
		old.FleetID = executionFleet
		if err := s.InsertFleetOperation(old); err != nil {
			t.Fatal(err)
		}
		if err := s.UpdateFleetOperation(old.ID, status, `{}`, time.Now()); err != nil {
			t.Fatal(err)
		}
		// Old journals may predate the task_ref association or dispatch envelope.
		if _, err := s.write.Exec(`UPDATE fleet_operations SET task_ref='', request=? WHERE id=?`, fmt.Sprintf(`{"params":{"task":%q}}`, task.Ref), old.ID); err != nil {
			t.Fatal(err)
		}
		if _, err := s.AuthorizeTaskExecution(executionOp(task, "new-"+status), "node-a"); !errors.Is(err, ErrTaskConflict) {
			t.Fatalf("adopted %s legacy start: %v", status, err)
		}
	}
}

func TestTaskExecutionResultsNeverReleaseBinding(t *testing.T) {
	s := taskStore(t)
	for _, result := range []string{"failed", "unknown", "succeeded"} {
		task := acceptedTask(t, s, result, "")
		o := executionOp(task, "start-"+result)
		if _, err := s.AuthorizeTaskExecution(o, "node-a"); err != nil {
			t.Fatal(err)
		}
		if err := s.UpdateFleetOperation(o.ID, result, `{"receipt":true}`, time.Now()); err != nil {
			t.Fatal(err)
		}
		if _, err := s.AuthorizeTaskExecution(executionOp(task, "new-"+result), "node-b"); !errors.Is(err, ErrTaskConflict) {
			t.Fatalf("%s released binding: %v", result, err)
		}
		stopped, stop, err := s.RequestTaskStop(task.ID, task.Owner, "stop-"+result, "stop", time.Now())
		if err != nil {
			t.Fatal(err)
		}
		if err := s.UpdateFleetOperation(stop.ID, "succeeded", `{"transport_only":true}`, time.Now()); err != nil {
			t.Fatal(err)
		}
		got, _ := s.FleetTask(task.ID)
		if got.ExecutionEndpoint != "node-a" || got.OperationID != o.ID || got.CancelRequest != stop.ID || got.Generation != stopped.Generation {
			t.Fatalf("ordinary stop success released binding: %+v", got)
		}
		if result == "succeeded" {
			prior, _ := s.FleetOperation(o.ID)
			if prior.Status != "succeeded" || prior.Result != `{"receipt":true}` {
				t.Fatal("stop erased historical successful start")
			}
		}
	}
}

func TestTaskExecutionStopIdempotencyScope(t *testing.T) {
	s := taskStore(t)
	a, b := acceptedTask(t, s, "a", ""), acceptedTask(t, s, "b", "")
	for _, task := range []FleetTask{a, b} {
		if _, err := s.AuthorizeTaskExecution(executionOp(task, "start-"+task.Ref), "node-a"); err != nil {
			t.Fatal(err)
		}
	}
	gate := make(chan struct{})
	results := make(chan error, 12)
	for i := 0; i < 12; i++ {
		go func(i int) {
			<-gate
			_, _, err := s.RequestTaskStop(a.ID, a.Owner, fmt.Sprintf("stop-%d", i), "stop", time.Now())
			results <- err
		}(i)
	}
	close(gate)
	for i := 0; i < 12; i++ {
		if err := <-results; err != nil {
			t.Fatal(err)
		}
	}
	got, _ := s.FleetTask(a.ID)
	stop, _ := s.FleetOperation(got.CancelRequest)
	if got.Generation != a.Generation+1 {
		t.Fatalf("concurrent stops advanced more than once: %+v", got)
	}
	var n int
	if err := s.read.QueryRow(`SELECT COUNT(*) FROM fleet_operations WHERE action='worker_stop'`).Scan(&n); err != nil || n != 1 {
		t.Fatalf("stop operations %d %v", n, err)
	}
	if _, _, err := s.RequestTaskStop(b.ID, b.Owner, stop.Idem, "stop other task", time.Now()); !errors.Is(err, ErrTaskConflict) {
		t.Fatalf("same key changed task: %v", err)
	}
	other, _ := s.FleetTask(b.ID)
	if other.Generation != b.Generation || other.CancelRequest != "" {
		t.Fatal("conflicting stop changed other task")
	}
}

func TestTaskExecutionStopAliasCannotChangeTask(t *testing.T) {
	s := taskStore(t)
	a, b := acceptedTask(t, s, "alias-a", ""), acceptedTask(t, s, "alias-b", "")
	for _, task := range []FleetTask{a, b} {
		if _, err := s.AuthorizeTaskExecution(executionOp(task, "start-"+task.Ref), "node-a"); err != nil {
			t.Fatal(err)
		}
	}
	first, stop, err := s.RequestTaskStop(a.ID, a.Owner, "stop-A", "stop", time.Now())
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 2; i++ {
		again, same, err := s.RequestTaskStop(a.ID, a.Owner, "stop-B", "stop", time.Now())
		if err != nil || again.Generation != first.Generation || same.ID != stop.ID {
			t.Fatalf("alias replay: %+v %+v %v", again, same, err)
		}
	}
	alias, err := s.FleetOperationByIdem(a.Owner, "stop-B")
	if err != nil || alias.ID == stop.ID || alias.Action != "task_stop_alias" || alias.Status != "succeeded" {
		t.Fatalf("no durable non-deliverable alias: %+v %v", alias, err)
	}
	for _, state := range []string{"running", "failed", "unknown", "succeeded"} {
		if err := s.UpdateFleetOperation(alias.ID, state, `{"remote_exit":true}`, time.Now()); err != nil {
			t.Fatal(err)
		}
	}
	unchanged, _ := s.FleetOperation(alias.ID)
	if unchanged.Status != alias.Status || unchanged.Result != alias.Result || unchanged.Request != alias.Request || !unchanged.Updated.Equal(alias.Updated) {
		t.Fatalf("ordinary receipt changed alias: %+v", unchanged)
	}
	if _, _, err := s.RequestTaskStop(a.ID, a.Owner, "start-"+b.Ref, "conflicting start key", time.Now()); !errors.Is(err, ErrTaskConflict) {
		t.Fatalf("stop accepted existing start key: %v", err)
	}
	if _, err := s.AuthorizeTaskExecution(executionOp(b, "stop-B"), "node-b"); !errors.Is(err, ErrIdemTaken) {
		t.Fatalf("start reused stop alias: %v", err)
	}
	if _, _, err := s.RequestTaskStop(b.ID, b.Owner, "stop-B", "different task", time.Now()); !errors.Is(err, ErrTaskConflict) {
		t.Fatalf("accepted stop alias changed task: %v", err)
	}
	other, _ := s.FleetTask(b.ID)
	if other.CancelRequest != "" || other.Generation != b.Generation {
		t.Fatal("conflicting alias changed second task")
	}
	var stops int
	if err := s.read.QueryRow(`SELECT COUNT(*) FROM fleet_operations WHERE action = 'worker_stop'`).Scan(&stops); err != nil || stops != 1 {
		t.Fatalf("alias created deliverable stop: %d %v", stops, err)
	}
	canonical, _ := s.FleetOperation(stop.ID)
	if canonical.Status != "pending" {
		t.Fatalf("alias registration claimed remote exit: %+v", canonical)
	}
	var aliases int
	if err := s.read.QueryRow(`SELECT COUNT(*) FROM fleet_operations WHERE action = 'task_stop_alias'`).Scan(&aliases); err != nil || aliases != 1 {
		t.Fatalf("alias replay created %d aliases: %v", aliases, err)
	}
}

func TestTaskExecutionStopAliasRace(t *testing.T) {
	s := taskStore(t)
	for i := 0; i < 12; i++ {
		a, b := acceptedTask(t, s, fmt.Sprintf("alias-race-a%d", i), ""), acceptedTask(t, s, fmt.Sprintf("alias-race-b%d", i), "")
		for _, task := range []FleetTask{a, b} {
			if _, err := s.AuthorizeTaskExecution(executionOp(task, "start-"+task.Ref), "node-a"); err != nil {
				t.Fatal(err)
			}
		}
		if _, _, err := s.RequestTaskStop(a.ID, a.Owner, "first-"+a.Ref, "stop", time.Now()); err != nil {
			t.Fatal(err)
		}
		key := fmt.Sprintf("shared-alias-%d", i)
		gate := make(chan struct{})
		results := make(chan error, 2)
		for _, task := range []FleetTask{a, b} {
			go func(task FleetTask) {
				<-gate
				_, _, err := s.RequestTaskStop(task.ID, task.Owner, key, "stop", time.Now())
				results <- err
			}(task)
		}
		close(gate)
		winners := 0
		for j := 0; j < 2; j++ {
			if err := <-results; err == nil {
				winners++
			} else if !errors.Is(err, ErrTaskConflict) {
				t.Fatal(err)
			}
		}
		if winners != 1 {
			t.Fatalf("one alias key stopped %d tasks", winners)
		}
	}
}
