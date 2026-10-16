package store

import (
	"encoding/json"
	"errors"
	"fmt"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

// Decode the wire contract so this is a behavioral red before its implementation.
func TestTaskBlockerContract(t *testing.T) {
	s := taskStore(t)
	work := startTask(t, s, acceptedTask(t, s, "blocked", ""))
	dep := startTask(t, s, acceptedTask(t, s, "dependency", ""))
	wire := map[string]any{
		"kind": "blocker", "idempotency_key": "create", "generation": work.Generation, "expected_worker": work.ExecutionOwner,
		"blocker": map[string]any{"version": 1, "action": "create", "blocker_id": "dependency-one", "repo": work.Repo, "ticket_ref": work.TicketRef,
			"reason": "waiting for prerequisite", "evidence": "fixture explicit dependency",
			"dependency": map[string]any{"task": dep.Ref, "owner": dep.Owner, "repo": dep.Repo, "ticket_ref": dep.TicketRef, "generation": dep.Generation, "worker_id": dep.ExecutionOwner}},
	}
	raw, _ := json.Marshal(wire)
	var command TaskMutation
	if err := json.Unmarshal(raw, &command); err != nil {
		t.Fatal(err)
	}
	command.EndpointID = "node-a"
	got, err := s.MutateFleetTask(work.ID, work.Owner, command, time.Now())
	if err != nil {
		t.Fatalf("create explicit blocker: %v", err)
	}
	b, _ := json.Marshal(got)
	var result map[string]any
	_ = json.Unmarshal(b, &result)
	if result["task_blockers"] == nil {
		t.Fatal("task read omitted blocker projection")
	}
}

func blockerCommand(work, dep FleetTask, id string) TaskMutation {
	return TaskMutation{Kind: "blocker", Key: "create-" + id, Generation: work.Generation, ExpectedWorker: work.ExecutionOwner, EndpointID: work.ExecutionEndpoint,
		Blocker: &TaskBlockerCommand{Version: 1, Action: "create", BlockerID: id, Repo: work.Repo, TicketRef: work.TicketRef, Dependency: blockerScope(dep), Evidence: "fixture dependency grant", Reason: "wait for dependency"}}
}

func assertBlocker(t *testing.T, s *Store, work FleetTask, id, state string) TaskBlocker {
	t.Helper()
	got, err := s.FleetTask(work.ID)
	if err != nil {
		t.Fatal(err)
	}
	if got.State != work.State || got.Outcome != work.Outcome || got.CancelRequest != work.CancelRequest || got.Asked != work.Asked {
		t.Fatalf("blocker changed task/attention: %+v", got)
	}
	if got.Blockers != nil {
		for _, b := range got.Blockers.Items {
			if b.BlockerID == id {
				if b.State != state {
					t.Fatalf("blocker %s=%s want %s", id, b.State, state)
				}
				return b
			}
		}
	}
	t.Fatalf("blocker %s missing: %+v", id, got.Blockers)
	return TaskBlocker{}
}

func TestTaskBlockerDependencyEvents(t *testing.T) {
	s := taskStore(t)
	work := startTask(t, s, acceptedTask(t, s, "work", "gh:work/repo#7"))
	a := startTask(t, s, acceptedTask(t, s, "a", "gh:one/repo#7"))
	b := startTask(t, s, acceptedTask(t, s, "b", "gh:two/repo#7"))
	// Attention is not a blocker writer, and blocker writes must not clear it.
	if _, err := s.write.Exec(`UPDATE fleet_tasks SET asked = 'native approval pending' WHERE id = ?`, work.ID); err != nil {
		t.Fatal(err)
	}
	work.Asked = "native approval pending"
	create := blockerCommand(work, a, "one")
	first := mutateTask(t, s, work, create)
	again := mutateTask(t, s, work, create)
	if !first.Blockers.Items[0].CreatedAt.Equal(again.Blockers.Items[0].CreatedAt) {
		t.Fatal("duplicate create changed time")
	}
	changed := create
	copyCommand := *create.Blocker
	changed.Blocker = &copyCommand
	changed.Blocker.Reason = "changed"
	if _, err := s.MutateFleetTask(work.ID, work.Owner, changed, time.Now()); !errors.Is(err, ErrTaskConflict) {
		t.Fatalf("changed replay: %v", err)
	}
	mutateTask(t, s, work, blockerCommand(work, b, "two"))
	for i, observation := range []string{"unknown", "stale"} {
		work = mutateTask(t, s, work, TaskMutation{Kind: "transition", Key: fmt.Sprint("observation", i), Observation: observation})
		assertBlocker(t, s, work, "one", "active")
	}
	r := TaskReport{EventID: "done", Task: a.Ref, Owner: a.Owner, TicketRef: a.TicketRef, Generation: a.Generation, WorkerID: a.ExecutionOwner, Outcome: TaskSucceeded, Evidence: "fixture verified work result"}
	firstReport, err := s.RecordFleetTaskReport(a.Owner, a.ExecutionEndpoint, r, time.Now())
	if err != nil || firstReport.Disposition != "committed" {
		t.Fatalf("report: %+v %v", firstReport, err)
	}
	closed := assertBlocker(t, s, work, "one", "resolved")
	assertBlocker(t, s, work, "two", "active")
	if closed.ResolvedAt == nil || closed.RevokedAt != nil || closed.Reason != "dependency:succeeded" {
		t.Fatalf("resolution audit: %+v", closed)
	}
	if _, err = s.RecordFleetTaskReport(a.Owner, a.ExecutionEndpoint, r, time.Now()); err != nil {
		t.Fatal(err)
	}
	var count int
	if err = s.read.QueryRow(`SELECT COUNT(*) FROM fleet_operations WHERE action = 'task_blocker_event' AND task_ref = ?`, work.Ref).Scan(&count); err != nil || count != 1 {
		t.Fatalf("lost ack emitted %d events: %v", count, err)
	}
	audit, err := s.FleetOperation(closed.EventID)
	if err != nil {
		t.Fatal(err)
	}
	if err = s.UpdateFleetOperation(audit.ID, "failed", "{}", time.Now()); err != nil {
		t.Fatal(err)
	}
	still, _ := s.FleetOperation(audit.ID)
	if still.Result != audit.Result {
		t.Fatal("generic writer changed audit")
	}
	// Cancellation intent is not a dependency result. Only its confirmed ack revokes.
	b = mutateTask(t, s, b, TaskMutation{Kind: "cancel_request", Key: "cancel", Evidence: "explicit request"})
	assertBlocker(t, s, work, "two", "active")
	mutateTask(t, s, b, TaskMutation{Kind: "cancel_ack", Key: "ack", CancelRequest: "cancel", ExecutionStopped: true, Evidence: "confirmed stopped"})
	revoked := assertBlocker(t, s, work, "two", "revoked")
	if revoked.RevokedAt == nil || revoked.ResolvedAt != nil {
		t.Fatal("missing revocation audit")
	}
	// Completion before registration uses the committed attempt, not a missed event timer.
	mutateTask(t, s, work, blockerCommand(work, firstReport.Task, "already-complete"))
	assertBlocker(t, s, work, "already-complete", "resolved")
	t.Log("fixture: duplicate create/report once; two blockers close independently; unknown/stale/attention preserved; completed/cancelled dependencies audited")
}

func TestTaskBlockerOwnerAndGenerationFence(t *testing.T) {
	s := taskStore(t)
	work := startTask(t, s, acceptedTask(t, s, "work", "gh:one/repo#7"))
	dep := startTask(t, s, acceptedTask(t, s, "dep", "gh:two/repo#7"))
	create := blockerCommand(work, dep, "one")
	mutateTask(t, s, work, create)
	for _, which := range []string{"owner", "endpoint", "generation", "worker", "repo", "ticket", "dependency"} {
		bad := create
		c := *create.Blocker
		bad.Blocker = &c
		bad.Key = which
		bad.Blocker.Action = "resolve"
		owner := work.Owner
		switch which {
		case "owner":
			owner = "bob"
		case "endpoint":
			bad.EndpointID = "foreign"
		case "generation":
			bad.Generation++
		case "worker":
			bad.ExpectedWorker = "foreign/session"
		case "repo":
			bad.Blocker.Repo = "foreign/repo"
		case "ticket":
			bad.Blocker.TicketRef = dep.TicketRef
		case "dependency":
			bad.Blocker.Dependency.TicketRef = work.TicketRef
		}
		if _, err := s.MutateFleetTask(work.ID, owner, bad, time.Now()); !errors.Is(err, ErrTaskFence) {
			t.Fatalf("%s: %v", which, err)
		}
		assertBlocker(t, s, work, "one", "active")
	}
	// Old dependency report is historical and never closes its pinned blocker.
	nextDep := mutateTask(t, s, dep, TaskMutation{Kind: "transfer", Key: "transfer", RequestedAgent: "codex", ResolvedAgent: "codex", ExecutionStopped: true, Evidence: "explicit transfer"})
	oldReport := TaskReport{EventID: "late", Task: dep.Ref, Owner: dep.Owner, TicketRef: dep.TicketRef, Generation: dep.Generation, WorkerID: dep.ExecutionOwner, Outcome: TaskSucceeded, Evidence: "late result"}
	receipt, err := s.RecordFleetTaskReport(dep.Owner, dep.ExecutionEndpoint, oldReport, time.Now())
	if err != nil || receipt.Disposition != "historical" {
		t.Fatalf("late report: %+v %v", receipt, err)
	}
	assertBlocker(t, s, work, "one", "active")
	nextDep = startBlockerGeneration(t, s, nextDep)
	mutateTask(t, s, nextDep, TaskMutation{Kind: "transition", Key: "done-new", State: TaskSucceeded, Evidence: "new generation result"})
	assertBlocker(t, s, work, "one", "active")
	// Owner can explicitly revoke a dead dependency; same event is idempotent.
	close := create
	c := *create.Blocker
	close.Blocker = &c
	close.Key = "revoke"
	close.Blocker.Action = "revoke"
	mutateTask(t, s, work, close)
	mutateTask(t, s, work, close)
	assertBlocker(t, s, work, "one", "revoked")
	close.Key = "second-revoke"
	if _, err = s.MutateFleetTask(work.ID, work.Owner, close, time.Now()); !errors.Is(err, ErrTaskConflict) {
		t.Fatalf("new event changed closed blocker: %v", err)
	}
	newWork := mutateTask(t, s, work, TaskMutation{Kind: "transfer", Key: "transfer", RequestedAgent: "codex", ResolvedAgent: "codex", ExecutionStopped: true, Evidence: "explicit transfer"})
	newWork = startBlockerGeneration(t, s, newWork)
	freshDep := startTask(t, s, acceptedTask(t, s, "fresh-dependency", ""))
	newCreate := blockerCommand(newWork, freshDep, "one")
	mutateTask(t, s, newWork, newCreate)
	close.Key = "late-owner"
	if _, err = s.MutateFleetTask(work.ID, work.Owner, close, time.Now()); !errors.Is(err, ErrTaskFence) {
		t.Fatalf("old owner generation: %v", err)
	}
	assertBlocker(t, s, newWork, "one", "active")
}

func TestTaskBlockerReportAndTerminalFence(t *testing.T) {
	s := taskStore(t)
	work := startTask(t, s, acceptedTask(t, s, "work", ""))
	dep := startTask(t, s, acceptedTask(t, s, "dep", ""))
	c := blockerCommand(work, dep, "one")
	r := TaskReport{EventID: "create", Task: work.Ref, Owner: work.Owner, Generation: work.Generation, WorkerID: work.ExecutionOwner, Status: "blocked", Evidence: "explicit blocker", Blocker: c.Blocker}
	if got, err := s.RecordFleetTaskReport(work.Owner, work.ExecutionEndpoint, r, time.Now()); err != nil || got.Disposition != "progress" {
		t.Fatalf("blocker report: %+v %v", got, err)
	}
	assertBlocker(t, s, work, "one", "active")
	r.EventID = "resolve"
	r.Blocker.Action = "resolve"
	for i := 0; i < 2; i++ {
		if _, err := s.RecordFleetTaskReport(work.Owner, work.ExecutionEndpoint, r, time.Now()); err != nil {
			t.Fatal(err)
		}
	}
	assertBlocker(t, s, work, "one", "resolved")
	mutateTask(t, s, work, blockerCommand(work, dep, "two"))
	work = mutateTask(t, s, work, TaskMutation{Kind: "transition", Key: "done", State: TaskSucceeded, Evidence: "explicit task result"})
	mutateTask(t, s, dep, TaskMutation{Kind: "transition", Key: "done", State: TaskSucceeded, Evidence: "dependency done"})
	assertBlocker(t, s, work, "two", "active")
	r.EventID = "after-terminal"
	r.Blocker.BlockerID = "two"
	if got, err := s.RecordFleetTaskReport(work.Owner, work.ExecutionEndpoint, r, time.Now()); err != nil || got.Disposition != "historical" {
		t.Fatalf("terminal report: %+v %v", got, err)
	}
	assertBlocker(t, s, work, "two", "active")
}

func TestTaskBlockerConcurrentEvents(t *testing.T) {
	path := filepath.Join(t.TempDir(), "blockers.db")
	var hubs [2]*Store
	for i := range hubs {
		s, err := Open(path)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { s.Close() })
		if err = s.EnsureNodes(); err != nil {
			t.Fatal(err)
		}
		hubs[i] = s
	}
	race := func(f func(int) error) {
		var wg sync.WaitGroup
		var errs [2]error
		start := make(chan struct{})
		for i := 0; i < 2; i++ {
			wg.Add(1)
			go func(i int) { defer wg.Done(); <-start; errs[i] = f(i) }(i)
		}
		close(start)
		wg.Wait()
		for _, err := range errs {
			if err != nil {
				t.Fatal(err)
			}
		}
	}
	for round := 0; round < 4; round++ {
		s := hubs[0]
		work := startTask(t, s, acceptedTask(t, s, fmt.Sprint("work", round), ""))
		dep := startTask(t, s, acceptedTask(t, s, fmt.Sprint("dep", round), ""))
		cmd := blockerCommand(work, dep, "one")
		race(func(i int) error { _, err := hubs[i].MutateFleetTask(work.ID, work.Owner, cmd, time.Now()); return err })
		// Register/complete, cancel/complete and terminal/complete all serialize.
		race(func(i int) error {
			if i == 0 {
				_, err := hubs[i].MutateFleetTask(dep.ID, dep.Owner, TaskMutation{Kind: "transition", Key: "done", Generation: dep.Generation, ExpectedWorker: dep.ExecutionOwner, EndpointID: dep.ExecutionEndpoint, State: TaskSucceeded, Evidence: "dependency done"}, time.Now())
				return err
			}
			kind, state := "cancel_request", ""
			if round%2 == 1 {
				kind, state = "transition", TaskSucceeded
			}
			_, err := hubs[i].MutateFleetTask(work.ID, work.Owner, TaskMutation{Kind: kind, State: state, Key: "finish", Generation: work.Generation, ExpectedWorker: work.ExecutionOwner, EndpointID: work.ExecutionEndpoint, Evidence: "explicit intent/result"}, time.Now())
			return err
		})
		got, err := s.FleetTask(work.ID)
		if err != nil {
			t.Fatal(err)
		}
		b := got.Blockers.Items[0]
		if b.State != "active" && b.State != "resolved" {
			t.Fatal(b.State)
		}
		if round%2 == 0 && (got.Outcome != "" || got.CancelRequest != "finish") {
			t.Fatal("inferred cancellation")
		}
		if round%2 == 1 && got.Outcome != TaskSucceeded {
			t.Fatal("changed terminal result")
		}
		var n int
		if err = s.read.QueryRow(`SELECT COUNT(*) FROM fleet_operations WHERE action = 'task_blocker_event' AND task_ref = ?`, work.Ref).Scan(&n); err != nil || n > 1 {
			t.Fatalf("duplicate event: %d %v", n, err)
		}
	}
	t.Log("fixture: independent writer connections; duplicate registration and terminal/cancel/dependency races fenced")
}

func startBlockerGeneration(t *testing.T, s *Store, rec FleetTask) FleetTask {
	rec = mutateTask(t, s, rec, TaskMutation{Kind: "claim", Key: fmt.Sprintf("claim-g%d", rec.Generation), WorkerID: "fleet-a/session-a", FleetID: "fleet-a"})
	return mutateTask(t, s, rec, TaskMutation{Kind: "transition", Key: fmt.Sprintf("start-g%d", rec.Generation), State: TaskRunning, ActualAgent: "codex", Evidence: "fixture native receipt"})
}
