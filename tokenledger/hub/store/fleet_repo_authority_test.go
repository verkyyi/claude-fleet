package store

import (
	"encoding/json"
	"errors"
	"fmt"
	"reflect"
	"sync"
	"testing"
	"time"
)

func repoChange(t *testing.T, s *Store, a OwnerAuthority, action string) OwnerAuthority {
	t.Helper()
	next, err := s.ChangeOwnerAuthority(a.Owner, OwnerAuthorityChange{Action: action, Revision: a.Revision, Key: action + time.Now().Format("150405.000000000")}, time.Now())
	if err != nil {
		t.Fatalf("%s: %v", action, err)
	}
	return next
}

func TestRepoAuthorityExpiredOwnerAndNativeStop(t *testing.T) {
	s := taskStore(t)
	now := time.Now()
	_, _, _, err := s.AcquireLease(LeaseClaim{Repo: "org/a", Issue: 7, WorkerID: "f/old", FleetID: "f", EndpointID: "node-a", Owner: "alice"}, time.Minute, now.Add(-time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	before, _ := s.FleetSettings()
	a, _ := s.OwnerAuthority("alice")
	_, err = s.ChangeOwnerAuthority("alice", OwnerAuthorityChange{Action: "freeze", Revision: 0, Key: "old-unbound"}, now)
	if !errors.Is(err, ErrRepoAuthority) {
		t.Fatal("unbound expired owner froze alice", err)
	}
	unchanged, _ := s.OwnerAuthority("alice")
	after, _ := s.FleetSettings()
	if !reflect.DeepEqual(a, unchanged) || !reflect.DeepEqual(before, after) {
		t.Fatal("refused preflight mutated authority", unchanged)
	}
	ack := OwnerAuthorityChange{Action: "stop_ack", Revision: 0, Key: "unbound-stop", WorkerID: "f/old", EndpointID: "node-a", Evidence: "unbound native stop"}
	if _, err = s.ChangeOwnerAuthority("alice", ack, now); err == nil {
		t.Fatal("unbound proof accepted")
	}
	// Existing legacy stop/release remains available because freeze did not
	// commit. Once the legacy owner is explicitly drained, staging can retry.
	if _, err = s.ReleaseLease("org/a", 7, "f/old"); err != nil {
		t.Fatal(err)
	}
	a = repoChange(t, s, a, "freeze")
	a = repoChange(t, s, a, "apply")
	if a.Mode != "hub" {
		t.Fatal(a)
	}
}

func TestRepoAuthorityPausedAfterFinalGate(t *testing.T) {
	s := taskStore(t)
	// This is the last admission, not the early read. No window/native process
	// exists yet. The launcher is paused until freeze + empty inventory + apply.
	paused, resume, done := make(chan struct{}), make(chan struct{}), make(chan error, 1)
	go func() {
		_, err := s.RepoLocalStart("org/a", "alice", "node-a", "paused", "reserve", "", nil, time.Now())
		if err != nil {
			done <- err
			close(paused)
			return
		}
		close(paused)
		<-resume
		_, err = s.RepoLocalStart("org/a", "alice", "node-a", "paused", "begin", "f/w", nil, time.Now())
		done <- err
	}()
	<-paused
	a, _ := s.OwnerAuthority("alice")
	a = repoChange(t, s, a, "freeze")
	if len(a.Owners) != 0 {
		t.Fatal("fixture must have no observed window", a)
	}
	if _, err := s.ChangeOwnerAuthority("alice", OwnerAuthorityChange{Action: "apply", Revision: a.Revision, Key: "empty-inventory"}, time.Now().Add(24*time.Hour)); !errors.Is(err, ErrRepoAuthority) {
		t.Fatal("paused start lost to empty inventory/expiry", err)
	}
	close(resume)
	if err := <-done; !errors.Is(err, ErrRepoAuthority) {
		t.Fatal("resumed start created native after freeze", err)
	}
	if _, err := s.RepoLocalStart("org/a", "alice", "node-b", "paused", "cancel", "", nil, time.Now()); err == nil {
		t.Fatal("foreign node cancelled reservation")
	}
	if _, err := s.RepoLocalStart("org/a", "alice", "node-a", "paused", "cancel", "", nil, time.Now()); err != nil {
		t.Fatal(err)
	}
	a = repoChange(t, s, a, "apply")
	if a.Mode != "hub" {
		t.Fatal(a)
	}
}

func TestRepoAuthorityLegacyTaskWithoutLeaseOrSnapshot(t *testing.T) {
	s := taskStore(t)
	_, err := s.CreateFleetTask(FleetTask{Owner: "alice", Repo: "org/a", Title: "old task", WorkerID: "f/old", State: TaskOpen}, "legacy-owner", time.Now())
	if err != nil {
		t.Fatal(err)
	}
	a, _ := s.OwnerAuthority("alice")
	if _, err := s.ChangeOwnerAuthority("alice", OwnerAuthorityChange{Action: "freeze", Revision: a.Revision, Key: "missing-owner"}, time.Now()); !errors.Is(err, ErrRepoAuthority) {
		t.Fatal("unbound legacy T froze", err)
	}
	after, _ := s.OwnerAuthority("alice")
	if !reflect.DeepEqual(a, after) {
		t.Fatal("legacy T refusal changed authority", after)
	}
}

func TestRepoAuthorityStopBoundToCurrentNative(t *testing.T) {
	for _, replacement := range []bool{false, true} {
		t.Run(fmt.Sprint(replacement), func(t *testing.T) {
			s := taskStore(t)
			old := &RepoNativeIdentity{WorkerID: "f/w", NativeSession: "old", PID: 123, Birth: "old-birth", Executable: "/bin/codex"}
			run := func(key, action string, native *RepoNativeIdentity) {
				t.Helper()
				if _, err := s.RepoLocalStart("org/a", "alice", "node-a", key, action, "f/w", native, time.Now()); err != nil {
					t.Fatal(action, err)
				}
			}
			for _, action := range []string{"reserve", "begin", "observe"} {
				run("old", action, old)
			}
			current := old
			if replacement {
				run("old", "stopped", old)
				current = &RepoNativeIdentity{WorkerID: "f/w", NativeSession: "new", PID: 456, Birth: "new-birth", Executable: "/bin/codex"}
				for _, action := range []string{"reserve", "begin", "observe"} {
					run("replacement", action, current)
				}
			}
			a, _ := s.OwnerAuthority("alice")
			a = repoChange(t, s, a, "freeze")
			proof := func(n *RepoNativeIdentity) string {
				b, _ := json.Marshal(struct {
					*RepoNativeIdentity
					Stopped bool `json:"execution_stopped"`
				}{n, true})
				return string(b)
			}
			wrong := *old
			wrong.PID = 999
			ack := OwnerAuthorityChange{Action: "stop_ack", Revision: a.Revision, Key: "ack", EndpointID: "node-a", WorkerID: "f/w", Evidence: proof(&wrong)}
			if _, err := s.ChangeOwnerAuthority("alice", ack, time.Now()); !errors.Is(err, ErrTaskFence) {
				t.Fatal("wrong dead process released owner", err)
			}
			ack.Evidence = proof(old)
			if replacement {
				if _, err := s.ChangeOwnerAuthority("alice", ack, time.Now()); !errors.Is(err, ErrTaskFence) {
					t.Fatal("pre-transfer native receipt released live replacement", err)
				}
				return
			}
			run("old", "stopped", current)
			var err error
			a, err = s.ChangeOwnerAuthority("alice", ack, time.Now())
			if err != nil {
				t.Fatal(err)
			}
			ack.EndpointID = "node-b"
			if _, err := s.ChangeOwnerAuthority("alice", ack, time.Now()); err == nil {
				t.Fatal("foreign replay accepted")
			}
			a = repoChange(t, s, a, "apply")
		})
	}
}

func TestRepoAuthorityCollisionAndSelectiveMapping(t *testing.T) {
	s := taskStore(t)
	now := time.Now()
	legacy, err := s.CreateFleetTicket(FleetTicket{Repo: "org/a", Owner: "alice", Title: "unrelated hub seven"}, 7, now)
	if err != nil {
		t.Fatal(err)
	}
	a, _ := s.OwnerAuthority("alice")
	a = repoChange(t, s, a, "freeze")
	a = repoChange(t, s, a, "apply")
	m, err := s.AdoptRepoTicket("org/a", "alice", nil, "gh:org/a#7", "selected GH seven", "selected body", a.Revision, now)
	if err != nil || m.From != "gh:org/a#7" || m.To != "hub:org/a#8" || m.SourceURL != "https://github.com/org/a/issues/7" {
		t.Fatal(m, err)
	}
	again, err := s.AdoptRepoTicket("org/a", "alice", nil, "gh:org/a#7", "selected GH seven", "selected body", a.Revision, now)
	if err != nil || again != m {
		t.Fatal("mapping not idempotent", again, err)
	}
	if _, err = s.AdoptRepoTicket("org/a", "alice", nil, "gh:org/a#7", "changed input", "selected body", a.Revision, now); !errors.Is(err, ErrTaskConflict) {
		t.Fatal("changed adoption replay", err)
	}
	unchanged, err := s.FleetTicketAt("org/a", 7)
	if err != nil || !reflect.DeepEqual(legacy, unchanged) {
		t.Fatal("collision changed existing hub seven", unchanged, err)
	}
	gh := acceptedTask(t, s, "gh-seven", "gh:org/a#7")
	hub := acceptedTask(t, s, "hub-eight", m.To)
	if _, err = s.CreateFleetTask(FleetTask{Owner: "bob", Title: "foreign", AuthorityVersion: 1, RequestedAgent: "codex", ResolvedAgent: "codex", TicketRef: "gh:org/a#7"}, "foreign-seven", now); !errors.Is(err, ErrTaskFence) {
		t.Fatal("colliding hub row hid the original GH owner", err)
	}
	if gh.TicketRef != "gh:org/a#7" || hub.TicketRef != m.To {
		t.Fatal("refs reinterpreted", gh, hub)
	}
	t.Logf("fixture mapping: %s -> %s; hub:org/a#7 unchanged; original URL %s", m.From, m.To, m.SourceURL)
}

func TestRepoAuthorityRollbackRetainsCompletedExecution(t *testing.T) {
	s := taskStore(t)
	a, _ := s.OwnerAuthority("alice")
	a = repoChange(t, s, a, "freeze")
	a = repoChange(t, s, a, "apply")
	rec := startTask(t, s, acceptedTask(t, s, "retained", "gh:org/a#9"))
	rec = mutateTask(t, s, rec, TaskMutation{Key: "complete", Kind: "transition", State: TaskSucceeded, Evidence: `{"work_result":"succeeded","pr":"org/a#10","pr_state":"waiting"}`})
	a = repoChange(t, s, a, "freeze")
	if _, err := s.ChangeOwnerAuthority("alice", OwnerAuthorityChange{Action: "rollback", Revision: a.Revision, Key: "unsafe"}, time.Now()); !errors.Is(err, ErrRepoAuthority) {
		t.Fatal("terminal outcome released authority", err)
	}
	rec = mutateTask(t, s, rec, TaskMutation{Key: "native-stop", Kind: "stop_ack", ExecutionStopped: true, Evidence: "fixture native exit"})
	a = repoChange(t, s, a, "rollback")
	if rec.Outcome != TaskSucceeded || a.Mode != "legacy" {
		t.Fatal(rec, a)
	}
	var proof map[string]string
	_ = json.Unmarshal([]byte(rec.Evidence), &proof)
	if proof["pr_state"] != "waiting" {
		t.Fatal("PR marked merged", proof)
	}
	t.Log("fixture work succeeded; GitHub PR waiting; native stop independently required for rollback")
}

func TestRepoAuthorityFreezeSerializesClaim(t *testing.T) {
	s := taskStore(t)
	var wg sync.WaitGroup
	wg.Add(2)
	var granted bool
	var claimErr, freezeErr error
	go func() {
		defer wg.Done()
		granted, _, _, claimErr = s.AcquireLease(LeaseClaim{Repo: "org/race", Issue: 1, WorkerID: "f/w", EndpointID: "node", FleetID: "f", Owner: "alice"}, time.Minute, time.Now())
	}()
	go func() {
		defer wg.Done()
		_, freezeErr = s.ChangeOwnerAuthority("alice", OwnerAuthorityChange{Action: "freeze", Key: "freeze"}, time.Now())
	}()
	wg.Wait()
	a, _ := s.OwnerAuthority("alice")
	if granted {
		if !errors.Is(freezeErr, ErrRepoAuthority) || a.Mode != "legacy" || a.Revision != 0 {
			t.Fatal("racing unbound owner was frozen", a, freezeErr)
		}
	} else if freezeErr != nil || !errors.Is(claimErr, ErrRepoAuthority) || a.Mode != "frozen" {
		t.Fatal(a, freezeErr, claimErr)
	}
}

func TestRepoAuthorityLandingAfterWorkCompleted(t *testing.T) {
	s := taskStore(t)
	rec := startTask(t, s, acceptedTask(t, s, "landing", "gh:org/a#7"))
	r := TaskReport{EventID: "work", Task: rec.Ref, Owner: rec.Owner, TicketRef: rec.TicketRef, Generation: rec.Generation, WorkerID: rec.ExecutionOwner, Outcome: TaskSucceeded, Status: "waiting", Evidence: `{"pr":"10","pr_state":"waiting"}`}
	work, err := s.RecordFleetTaskReport(rec.Owner, rec.ExecutionEndpoint, r, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	before, err := s.RepoTaskInventory("org/a", rec.Owner)
	if err != nil || len(before) != 1 || before[0]["pr_state"] != "waiting" {
		t.Fatal(before, err)
	}
	r.EventID, r.Status, r.Evidence = "merge", "merged", `{"pr":"10","pr_state":"merged"}`
	merge, err := s.RecordFleetTaskReport(rec.Owner, rec.ExecutionEndpoint, r, time.Now())
	if err != nil || merge.Disposition != "historical" {
		t.Fatal(merge, err)
	}
	current, _ := s.FleetTask(rec.ID)
	if current.Evidence != work.Task.Evidence || current.Outcome != work.Task.Outcome {
		t.Fatal("landing rewrote work outcome", current)
	}
	after, err := s.RepoTaskInventory("org/a", rec.Owner)
	if err != nil || after[0]["pr_state"] != "merged" || after[0]["work_outcome"] != TaskSucceeded {
		t.Fatal(after, err)
	}
}

// Task authority is a person's (claude-fleet#4896): alice and bob share org/a,
// each cuts over alone, and neither's mode, starts or leftovers touch the other.
func TestOwnerAuthorityDryRunAndPerOwnerCutover(t *testing.T) {
	s := taskStore(t)
	now := time.Now()
	before, _ := s.FleetSettings()
	a, err := s.OwnerAuthority("alice")
	if err != nil || a.Mode != "legacy" || a.Owner != "alice" {
		t.Fatal(a, err)
	}
	if _, _, err = s.OwnerAuthorityBlockers("alice", nil, true); err != nil {
		t.Fatal(err)
	}
	if after, _ := s.FleetSettings(); !reflect.DeepEqual(before, after) {
		t.Fatal("dry-run wrote settings")
	}
	// bob runs legacy work in the same repo: a live lease, a local start, a
	// v0 T, an unsettled worker_start. None of it is alice's to drain.
	if ok, _, _, err := s.AcquireLease(LeaseClaim{Repo: "org/a", Issue: 1, WorkerID: "fb/w", FleetID: "fb", EndpointID: "node-b", Owner: "bob"}, time.Hour, now); err != nil || !ok {
		t.Fatal("bob's lease", err)
	}
	if _, err = s.RepoLocalStart("org/a", "bob", "node-b", "bob-start", "reserve", "", nil, now); err != nil {
		t.Fatal(err)
	}
	if _, err = s.CreateFleetTask(FleetTask{Owner: "bob", Repo: "org/a", Title: "bob legacy", WorkerID: "fb/old", State: TaskOpen}, "bob-v0", now); err != nil {
		t.Fatal(err)
	}
	if err = s.InsertFleetOperation(FleetOperation{ID: "bob-op", Actor: "node:bob@mac-b", TaskOwner: "bob", Idem: "bob-op", Action: "worker_start", Status: "running", Request: `{"params":{"repo":"org/a","kind":"scratch"}}`, Created: now, Updated: now}); err != nil {
		t.Fatal(err)
	}
	mine, _, _ := s.OwnerAuthorityBlockers("alice", []string{"node-a"}, false)
	if len(mine) != 0 {
		t.Fatal("another person's work blocks alice", mine)
	}
	theirs, _, _ := s.OwnerAuthorityBlockers("bob", []string{"node-b"}, false)
	if len(theirs) != 4 {
		t.Fatal("bob's own blockers", theirs)
	}
	bob, _ := s.OwnerAuthority("bob")

	freeze := OwnerAuthorityChange{Action: "freeze", Revision: 0, Key: "freeze"}
	a, err = s.ChangeOwnerAuthority("alice", freeze, now)
	if err != nil || a.Mode != "frozen" || a.Revision != 1 {
		t.Fatal(a, err)
	}
	replay, err := s.ChangeOwnerAuthority("alice", freeze, now)
	if err != nil || !reflect.DeepEqual(a, replay) {
		t.Fatal("freeze replay", replay, err)
	}
	if _, err = s.ChangeOwnerAuthority("alice", OwnerAuthorityChange{Action: "apply", Revision: 0, Key: "freeze"}, now); !errors.Is(err, ErrTaskConflict) {
		t.Fatal("changed replay accepted", err)
	}
	// alice frozen: every start of hers waits, in any repo or none.
	if _, err = s.CreateFleetTask(FleetTask{Repo: "org/a", Owner: "alice", Title: "frozen", AuthorityVersion: 1, RequestedAgent: "codex", ResolvedAgent: "codex"}, "frozen", now); !errors.Is(err, ErrRepoAuthority) {
		t.Fatal("accepted while frozen", err)
	}
	if _, _, _, err = s.AcquireLease(LeaseClaim{Repo: "org/a", Issue: 7, WorkerID: "fa/w", FleetID: "fa", Owner: "alice"}, time.Minute, now); !errors.Is(err, ErrRepoAuthority) {
		t.Fatal("legacy lease during freeze", err)
	}
	if err = s.InsertFleetOperation(FleetOperation{ID: "alice-scratch", Actor: "alice", Idem: "alice-scratch", Action: "worker_start", Request: `{"params":{"kind":"scratch"}}`, Created: now, Updated: now}); !errors.Is(err, ErrRepoAuthority) {
		t.Fatal("no-repo scratch bypass", err)
	}
	if _, err = s.RepoLocalStart("org/b", "alice", "node-a", "a-start", "reserve", "", nil, now); !errors.Is(err, ErrRepoAuthority) {
		t.Fatal("local start during freeze", err)
	}
	// bob in the same repo goes on as before.
	if ok, _, _, err := s.AcquireLease(LeaseClaim{Repo: "org/a", Issue: 2, WorkerID: "fb/w2", FleetID: "fb", Owner: "bob"}, time.Minute, now); err != nil || !ok {
		t.Fatal("alice's freeze held bob", err)
	}
	a = repoChange(t, s, a, "apply")
	if a.Mode != "hub" {
		t.Fatal(a)
	}
	if _, _, _, err = s.AcquireLease(LeaseClaim{Repo: "org/a", Issue: 7, WorkerID: "fa/w", FleetID: "fa", Force: true, Owner: "alice"}, time.Minute, now); !errors.Is(err, ErrRepoAuthority) {
		t.Fatal("forced legacy bypass", err)
	}
	if _, err = s.CreateFleetTask(FleetTask{Repo: "org/a", Owner: "alice", Title: "hub", AuthorityVersion: 1, RequestedAgent: "codex", ResolvedAgent: "codex"}, "hub-accept", now); err != nil {
		t.Fatal("accepted work on the hub", err)
	}
	if err = s.InsertFleetOperation(FleetOperation{ID: "bob-op2", Actor: "bob", Idem: "bob-op2", Action: "worker_start", Request: `{"params":{"repo":"org/a","kind":"scratch"}}`, Created: now, Updated: now}); err != nil {
		t.Fatal("alice on the hub refused bob's legacy start", err)
	}
	if _, err = s.RepoLocalStart("org/a", "bob", "node-b", "bob-start-2", "reserve", "", nil, now); err != nil {
		t.Fatal("alice on the hub refused bob's local start", err)
	}
	if b2, _ := s.OwnerAuthority("bob"); !reflect.DeepEqual(bob, b2) {
		t.Fatal("bob's authority changed", b2)
	}
	a = repoChange(t, s, a, "freeze")
	if _, err = s.ChangeOwnerAuthority("alice", OwnerAuthorityChange{Action: "rollback", Revision: a.Revision, Key: "early"}, now); !errors.Is(err, ErrRepoAuthority) {
		t.Fatal("rollback with accepted work open", err)
	}
	t.Log("alice: dry-run 0 writes, freeze/replay/apply; bob's legacy in the same repo neither blocks nor is blocked")
}

// The per-repo rows of before (claude-fleet#4885's hub default included) are
// read as absent: they admit and refuse nothing.
func TestOwnerAuthorityIgnoresOldRepoRow(t *testing.T) {
	s := taskStore(t)
	now := time.Now()
	if _, err := s.write.Exec(`INSERT INTO fleet_settings (key, value, updated) VALUES ('task-authority:org/new', '{"repo":"org/new","owner":"alice","mode":"hub","revision":1,"legacy_tickets":"hub"}', ?)`, now.UTC().Format(rfc)); err != nil {
		t.Fatal(err)
	}
	if a, err := s.OwnerAuthority("alice"); err != nil || a.Mode != "legacy" || a.Revision != 0 {
		t.Fatal(a, err)
	}
	if ok, _, _, err := s.AcquireLease(LeaseClaim{Repo: "org/new", Issue: 1, WorkerID: "f/w", FleetID: "f", Owner: "alice"}, time.Minute, now); err != nil || !ok {
		t.Fatal("old repo row refused a legacy lease", err)
	}
}
