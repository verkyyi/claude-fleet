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

func taskStore(t *testing.T) *Store {
	t.Helper()
	// the template already has the fleet registry (newStoreFrom)
	return newStoreFrom(t, "fleet", func(s *Store) error { return s.EnsureNodes() })
}
func acceptedTask(t *testing.T, s *Store, token, ticket string) FleetTask {
	t.Helper()
	rec, err := s.CreateFleetTask(FleetTask{Owner: "alice", Title: "Review work", AuthorityVersion: 1,
		RequestedAgent: "codex", ResolvedAgent: "codex", TicketRef: ticket, RequestPayload: `{"body":"original"}`}, token, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	return rec
}
func mutateTask(t *testing.T, s *Store, rec FleetTask, m TaskMutation) FleetTask {
	t.Helper()
	m.Generation, m.ExpectedWorker = rec.Generation, rec.ExecutionOwner
	if m.EndpointID == "" {
		m.EndpointID = "node-a"
	}
	got, err := s.MutateFleetTask(rec.ID, rec.Owner, m, time.Now())
	if err != nil {
		t.Fatalf("%s: %v", m.Kind, err)
	}
	return got
}
func claimTask(t *testing.T, s *Store, rec FleetTask) FleetTask {
	return mutateTask(t, s, rec, TaskMutation{Key: "claim", Kind: "claim", WorkerID: "fleet-a/session-a", FleetID: "fleet-a"})
}
func startTask(t *testing.T, s *Store, rec FleetTask) FleetTask {
	return mutateTask(t, s, claimTask(t, s, rec), TaskMutation{Key: "running", Kind: "transition", State: TaskRunning, ActualAgent: "codex", Evidence: "fixture native session receipt"})
}

// Both CI dialect legs exercise the same assertions, including two independent
// writer connections. Test output is fixture evidence, never live acceptance.
func TestTaskAuthorityLifecycle(t *testing.T) {
	s := taskStore(t)
	rec := acceptedTask(t, s, "one", "")
	if rec.Ref != "T1" || rec.Generation != 1 || rec.State != TaskAccepted || rec.TicketRef != "" {
		t.Fatalf("accepted: %+v", rec)
	}
	original := rec
	rec = startTask(t, s, rec)
	rec = mutateTask(t, s, rec, TaskMutation{Key: "wait", Kind: "transition", State: TaskWaiting})
	rec = mutateTask(t, s, rec, TaskMutation{Key: "resume", Kind: "transition", State: TaskRunning})
	rec = mutateTask(t, s, rec, TaskMutation{Key: "stale", Kind: "transition", Observation: "stale"})
	if rec.State != TaskRunning || rec.Outcome != "" {
		t.Fatalf("staleness became an outcome: %+v", rec)
	}
	if _, err := s.UpdateFleetTask(rec.ID, FleetTaskUpdate{State: "done"}, time.Now()); !errors.Is(err, ErrTaskFence) {
		t.Fatalf("legacy writer: %v", err)
	}
	if _, err := s.MutateFleetTask(rec.ID, "bob", TaskMutation{Key: "foreign", Kind: "transition", Generation: 1, EndpointID: "node-a", ExpectedWorker: rec.ExecutionOwner}, time.Now()); !errors.Is(err, ErrTaskFence) {
		t.Fatalf("foreign owner: %v", err)
	}
	if _, err := s.MutateFleetTask(rec.ID, rec.Owner, TaskMutation{Key: "foreign-node", Kind: "transition", Generation: 1, EndpointID: "node-b", ExpectedWorker: rec.ExecutionOwner}, time.Now()); !errors.Is(err, ErrTaskFence) {
		t.Fatalf("foreign executor: %v", err)
	}
	end := TaskMutation{Key: "complete", Kind: "transition", Generation: 1, EndpointID: "node-a", ExpectedWorker: rec.ExecutionOwner, State: TaskSucceeded, Evidence: "fixture completion and stopped receipt", ExecutionStopped: true}
	rec, err := s.MutateFleetTask(rec.ID, rec.Owner, end, time.Now())
	if err != nil || rec.Outcome != TaskSucceeded {
		t.Fatalf("complete: %+v %v", rec, err)
	}
	dup, err := s.MutateFleetTask(rec.ID, rec.Owner, end, time.Now())
	if err != nil || dup.Outcome != rec.Outcome || !dup.UpdatedAt.Equal(rec.UpdatedAt) {
		t.Fatalf("lost ack: %+v %v", dup, err)
	}
	changed := end
	changed.State = TaskFailed
	if _, err = s.MutateFleetTask(rec.ID, rec.Owner, changed, time.Now()); !errors.Is(err, ErrTaskConflict) {
		t.Fatalf("changed event: %v", err)
	}
	changed.Key = "late-result"
	if _, err = s.MutateFleetTask(rec.ID, rec.Owner, changed, time.Now()); !errors.Is(err, ErrTaskConflict) {
		t.Fatalf("terminal changed: %v", err)
	}
	event, err := s.FleetOperationByIdem(rec.Owner, "task-event:"+rec.Ref+":complete")
	if err != nil || event.WorkerID != rec.ExecutionOwner {
		t.Fatalf("terminal event lost worker attribution: %+v %v", event, err)
	}
	b, _ := json.Marshal(rec)
	t.Logf("fixture after: %s", b)
	rec = mutateTask(t, s, rec, TaskMutation{Key: "retry", Kind: "retry", RequestedAgent: "claude", ResolvedAgent: "claude", Evidence: "explicit retry"})
	if rec.Generation != 2 || rec.State != TaskAccepted || rec.ActualAgent != "" || rec.Outcome != "" {
		t.Fatalf("retry: %+v", rec)
	}
	if _, err = s.MutateFleetTask(rec.ID, rec.Owner, changed, time.Now()); !errors.Is(err, ErrTaskFence) {
		t.Fatalf("old generation: %v", err)
	}
	op, err := s.FleetOperation(taskAttemptID(rec.ID, 1))
	if err != nil {
		t.Fatal(err)
	}
	var history FleetTask
	if err = json.Unmarshal([]byte(op.Result), &history); err != nil || history.Outcome != TaskSucceeded || history.ActualAgent != "codex" {
		t.Fatalf("history: %s %v", op.Result, err)
	}
	if err = s.UpdateFleetOperation(op.ID, "failed", `{}`, time.Now()); err != nil {
		t.Fatal(err)
	}
	unchanged, _ := s.FleetOperation(op.ID)
	if unchanged.Result != op.Result {
		t.Fatal("generic operation writer changed task history")
	}
	again := acceptedTask(t, s, "one", "")
	if again.State != original.State || again.Generation != 1 || again.AttemptID != original.AttemptID {
		t.Fatalf("accepted replay lost original result: %+v", again)
	}
	input := FleetTask{Owner: "alice", Title: "changed", AuthorityVersion: 1, RequestedAgent: "codex", ResolvedAgent: "codex"}
	if _, err = s.CreateFleetTask(input, "one", time.Now()); !errors.Is(err, ErrTaskConflict) {
		t.Fatalf("changed request: %v", err)
	}
	input.Owner = "bob"
	if _, err = s.CreateFleetTask(input, "one", time.Now()); !errors.Is(err, ErrTaskFence) {
		t.Fatalf("foreign request: %v", err)
	}
}

func TestTaskAuthorityTransferAndPinnedLease(t *testing.T) {
	s := taskStore(t)
	rec := startTask(t, s, acceptedTask(t, s, "one", "gh:org/repo#7"))
	now := time.Now().Add(24 * time.Hour)
	c := LeaseClaim{Repo: "org/repo", Issue: 7, WorkerID: "fleet-a/other", FleetID: "fleet-a", EndpointID: "node-a", Force: true}
	if granted, _, _, err := s.AcquireLease(c, time.Minute, now); err != nil || granted {
		t.Fatalf("expired/forced/same-fleet takeover: %v %v", granted, err)
	}
	if released, err := s.ReleaseLease(c.Repo, c.Issue, rec.ExecutionOwner); err != nil || released {
		t.Fatalf("legacy release: %v %v", released, err)
	}
	if moved, err := s.HandOverLease(c.Repo, c.Issue, rec.ExecutionOwner, c, time.Minute, time.Now()); err != nil || moved {
		t.Fatalf("legacy handover: %v %v", moved, err)
	}
	if _, _, err := s.RenewLeases("node-a", map[string]bool{"fleet-a": true}, []LeaseSession{{WorkerID: rec.ExecutionOwner}}, time.Minute, time.Now()); err != nil {
		t.Fatal(err)
	}
	if _, released, err := s.RenewLeases("node-a", map[string]bool{"fleet-a": true}, nil, time.Minute, now); err != nil || released != 0 {
		t.Fatalf("inventory released: %d %v", released, err)
	}
	if released, err := s.ReleaseLeasesOfEndpoint("node-a"); err != nil || len(released) != 0 {
		t.Fatalf("endpoint cleanup released: %v %v", released, err)
	}
	ls, err := s.Leases(now)
	if err != nil || len(ls) != 1 || ls[0].TaskID != rec.ID {
		t.Fatalf("pinned lease: %+v %v", ls, err)
	}
	competing := acceptedTask(t, s, "two", "gh:org/repo#7")
	if _, err = s.MutateFleetTask(competing.ID, competing.Owner, TaskMutation{Key: "compete", Kind: "claim", Generation: 1, EndpointID: "node-b", FleetID: "fleet-b", WorkerID: "fleet-b/w"}, now); !errors.Is(err, ErrTaskConflict) {
		t.Fatalf("competing task: %v", err)
	}
	transfer := TaskMutation{Key: "transfer", Kind: "transfer", Generation: 1, ExpectedWorker: rec.ExecutionOwner, EndpointID: "node-a", RequestedAgent: "claude", ResolvedAgent: "claude", Evidence: "explicit native transfer"}
	if _, err = s.MutateFleetTask(rec.ID, rec.Owner, transfer, now); !errors.Is(err, ErrTaskConflict) {
		t.Fatalf("unfenced transfer: %v", err)
	}
	transfer.ExecutionStopped = true
	rec, err = s.MutateFleetTask(rec.ID, rec.Owner, transfer, now)
	if err != nil || rec.Generation != 2 || rec.State != TaskAccepted {
		t.Fatalf("transfer: %+v %v", rec, err)
	}
	rec = mutateTask(t, s, rec, TaskMutation{Key: "claim-2", Kind: "claim", WorkerID: "fleet-b/session-b", FleetID: "fleet-b", EndpointID: "node-b"})
	if rec.ExecutionOwner != "fleet-b/session-b" {
		t.Fatalf("new owner: %+v", rec)
	}
	op, _ := s.FleetOperation(taskAttemptID(rec.ID, 1))
	var old FleetTask
	_ = json.Unmarshal([]byte(op.Result), &old)
	if old.ActualAgent != "codex" || old.ExecutionOwner != "fleet-a/session-a" {
		t.Fatalf("old attempt lost: %s", op.Result)
	}
}

func TestTaskAuthorityRaces(t *testing.T) {
	path := filepath.Join(t.TempDir(), "race.db")
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
	race := func(f func(int) error) [2]error {
		var errs [2]error
		var wg sync.WaitGroup
		start := make(chan struct{})
		for i := 0; i < 2; i++ {
			wg.Add(1)
			go func(i int) { defer wg.Done(); <-start; errs[i] = f(i) }(i)
		}
		close(start)
		wg.Wait()
		return errs
	}
	winner := func(errs [2]error) int {
		t.Helper()
		win := -1
		for i, e := range errs {
			if e == nil {
				if win != -1 {
					t.Fatalf("two winners: %v", errs)
				}
				win = i
			} else if !errors.Is(e, ErrTaskConflict) && !errors.Is(e, ErrTaskFence) {
				t.Fatalf("race error: %v", e)
			}
		}
		if win < 0 {
			t.Fatalf("no winner: %v", errs)
		}
		return win
	}
	for round := 0; round < 8; round++ {
		token := fmt.Sprintf("race-%d", round)
		var accepted [2]FleetTask
		errs := race(func(i int) error {
			var err error
			accepted[i], err = hubs[i].CreateFleetTask(FleetTask{Owner: "alice", Title: token, AuthorityVersion: 1, RequestedAgent: "codex", ResolvedAgent: "codex"}, token, time.Now())
			return err
		})
		if errs[0] != nil || errs[1] != nil || accepted[0].ID != accepted[1].ID {
			t.Fatalf("repeated accept: %+v %v", accepted, errs)
		}
		rec := accepted[0]
		errs = race(func(i int) error {
			_, err := hubs[i].MutateFleetTask(rec.ID, "alice", TaskMutation{Key: fmt.Sprintf("claim-%d", i), Kind: "claim", Generation: 1, EndpointID: fmt.Sprintf("node-%d", i), FleetID: fmt.Sprintf("fleet-%d", i), WorkerID: fmt.Sprintf("fleet-%d/session", i)}, time.Now())
			return err
		})
		win := winner(errs)
		rec, _ = hubs[0].FleetTask(rec.ID)
		ep := fmt.Sprintf("node-%d", win)
		rec = mutateTask(t, hubs[win], rec, TaskMutation{Key: "start", Kind: "transition", State: TaskRunning, ActualAgent: "codex", Evidence: "fixture receipt", EndpointID: ep})
		rec = mutateTask(t, hubs[win], rec, TaskMutation{Key: "cancel", Kind: "cancel_request", EndpointID: ep, Evidence: "cancel requested"})
		var disposition string
		errs = race(func(i int) error {
			if i == 0 {
				receipt, err := hubs[i].RecordFleetTaskReport(rec.Owner, ep, TaskReport{EventID: "complete", Task: rec.Ref, Owner: rec.Owner, Generation: 1, WorkerID: rec.ExecutionOwner, Outcome: TaskSucceeded, Evidence: "explicit result with native retained"}, time.Now())
				disposition = receipt.Disposition
				return err
			}
			_, err := hubs[i].MutateFleetTask(rec.ID, rec.Owner, TaskMutation{Key: "ack", Kind: "cancel_ack", Generation: 1, ExpectedWorker: rec.ExecutionOwner, EndpointID: ep, CancelRequest: "cancel", ExecutionStopped: true, Evidence: "confirmed stop"}, time.Now())
			return err
		})
		if errs[0] != nil || (disposition == "committed" && !errors.Is(errs[1], ErrTaskConflict)) || (disposition == "historical" && errs[1] != nil) {
			t.Fatalf("cancel/report race: %s %v", disposition, errs)
		}

		final, _ := hubs[0].FleetTask(rec.ID)
		if !taskTerminal(final.State) || final.Outcome != final.State {
			t.Fatalf("no terminal outcome: %+v", final)
		}
	}
}

func TestTaskAuthorityTicketScopeAndMigration(t *testing.T) {
	s := taskStore(t)
	now := time.Now()
	// Ensure additive migration is idempotent and preserves old readers/writers.
	legacy, err := s.CreateFleetTask(FleetTask{Owner: "alice", Title: "legacy"}, "legacy", now)
	if err != nil {
		t.Fatal(err)
	}
	if err = s.EnsureNodes(); err != nil {
		t.Fatal(err)
	}
	if _, err = s.UpdateFleetTask(legacy.ID, FleetTaskUpdate{State: TaskOpen}, now); err != nil {
		t.Fatal(err)
	}
	if _, err = s.CreateFleetTicket(FleetTicket{Owner: "alice", Repo: "hub/repo", Title: "hub item"}, 7, now); err != nil {
		t.Fatal(err)
	}
	for i, ticket := range []string{"gh:org/a#7", "gh:org/b#7", "hub:hub/repo#7"} {
		rec := claimTask(t, s, acceptedTask(t, s, fmt.Sprintf("ticket-%d", i), ticket))
		if rec.LeaseRef != ticket {
			t.Fatalf("lost backend/repo: %+v", rec)
		}
	}
	// A legacy claimant uses the same pair for hub tickets too. A separate
	// hub lease namespace would allow a second execution through that road.
	if ok, _, _, err := s.AcquireLease(LeaseClaim{Repo: "hub/repo", Issue: 7, WorkerID: "legacy/worker", Force: true}, time.Minute, now.Add(time.Hour)); err != nil || ok {
		t.Fatalf("legacy bypassed hub task lease: %v %v", ok, err)
	}
	// A legacy held item must drain explicitly, even after TTL.
	c := LeaseClaim{Repo: "org/held", Issue: 7, WorkerID: "legacy/worker", FleetID: "legacy"}
	if ok, _, _, err := s.AcquireLease(c, time.Nanosecond, now.Add(-time.Hour)); err != nil || !ok {
		t.Fatalf("legacy lease: %v", err)
	}
	rec := acceptedTask(t, s, "held", "gh:org/held#7")
	if _, err = s.MutateFleetTask(rec.ID, "alice", TaskMutation{Key: "claim", Kind: "claim", Generation: 1, EndpointID: "node-a", FleetID: "fleet-a", WorkerID: "fleet-a/session"}, now); !errors.Is(err, ErrTaskConflict) {
		t.Fatalf("adopted legacy owner: %v", err)
	}
	// A linked ticket or parent belonging to another account is not adoptable.
	if _, err = s.CreateFleetTicket(FleetTicket{Owner: "bob", Repo: "foreign/repo", Title: "private"}, 7, now); err != nil {
		t.Fatal(err)
	}
	input := FleetTask{Owner: "alice", Title: "foreign", AuthorityVersion: 1, RequestedAgent: "codex", ResolvedAgent: "codex", TicketRef: "hub:foreign/repo#7"}
	if _, err = s.CreateFleetTask(input, "foreign-ticket", now); !errors.Is(err, ErrTaskFence) {
		t.Fatalf("foreign ticket: %v", err)
	}
	input.TicketRef = ""
	input.Owner = "bob"
	input.ParentTask = legacy.Ref
	if _, err = s.CreateFleetTask(input, "foreign-parent", now); !errors.Is(err, ErrTaskFence) {
		t.Fatalf("foreign parent: %v", err)
	}
}

func TestTaskAuthoritySharedTicketRace(t *testing.T) {
	path := filepath.Join(t.TempDir(), "shared-ticket.db")
	var hubs [2]*Store
	var records [2]FleetTask
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
		records[i] = acceptedTask(t, s, fmt.Sprintf("task-%d", i), "gh:org/repo#7")
	}
	var errs [2]error
	var wg sync.WaitGroup
	start := make(chan struct{})
	for i := range hubs {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			<-start
			_, errs[i] = hubs[i].MutateFleetTask(records[i].ID, "alice", TaskMutation{Key: "claim", Kind: "claim", Generation: 1, EndpointID: fmt.Sprintf("node-%d", i), FleetID: fmt.Sprintf("fleet-%d", i), WorkerID: fmt.Sprintf("fleet-%d/worker", i)}, time.Now())
		}(i)
	}
	close(start)
	wg.Wait()
	wins := 0
	for _, err := range errs {
		if err == nil {
			wins++
		} else if !errors.Is(err, ErrTaskConflict) {
			t.Fatal(err)
		}
	}
	if wins != 1 {
		t.Fatalf("shared work item: %v", errs)
	}
	var count int
	if err := hubs[0].read.QueryRow(`SELECT COUNT(*) FROM fleet_leases WHERE repo = 'org/repo' AND issue = 7 AND task_id <> 0`).Scan(&count); err != nil || count != 1 {
		t.Fatalf("owners: %d %v", count, err)
	}
}

func TestTaskAuthorityAdditiveColumns(t *testing.T) {
	s := newStore(t)
	for _, schema := range []string{fleetTasksSchema, fleetLeasesSchema} {
		if _, err := s.write.Exec(s.d.ddl(schema)); err != nil {
			t.Fatal(err)
		}
	}
	ts := time.Now().UTC().Format(rfc)
	if _, err := s.write.Exec(`INSERT INTO fleet_tasks (token,owner,title,created_at,updated_at) VALUES ('old','alice','legacy',?,?)`, ts, ts); err != nil {
		t.Fatal(err)
	}
	if _, err := s.write.Exec(`INSERT INTO fleet_leases (`+leaseCols+`) VALUES ('org/repo',7,'old/worker','old','node','','',?,?,?,0,0)`, ts, ts, ts); err != nil {
		t.Fatal(err)
	}
	if err := s.EnsureNodes(); err != nil {
		t.Fatal(err)
	}
	rec, err := s.FleetTask(1)
	if err != nil || rec.Title != "legacy" || rec.AuthorityVersion != 0 || rec.Generation != 0 {
		t.Fatalf("migration: %+v %v", rec, err)
	}
	if _, err = s.UpdateFleetTask(1, FleetTaskUpdate{State: TaskOpen}, time.Now()); err != nil {
		t.Fatal(err)
	}
	if ok, err := s.ReleaseLease("org/repo", 7, "old/worker"); err != nil || !ok {
		t.Fatalf("legacy lease changed: %v %v", ok, err)
	}
}
