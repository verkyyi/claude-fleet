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

func repoChange(t *testing.T, s *Store, a RepoAuthority, action string) RepoAuthority {
	t.Helper()
	next, err := s.ChangeRepoAuthority(a.Repo, "alice", RepoAuthorityChange{Action: action, Revision: a.Revision, Key: action + time.Now().Format("150405.000000000"), LegacyTickets: "github"}, time.Now())
	if err != nil {
		t.Fatalf("%s: %v", action, err)
	}
	return next
}

func TestRepoAuthorityDryRunAndPerRepoCutover(t *testing.T) {
	s := taskStore(t)
	before, _ := s.FleetSettings()
	a, err := s.RepoAuthority("org/a")
	if err != nil || a.Mode != "legacy" {
		t.Fatal(a, err)
	}
	_, _, err = s.RepoAuthorityBlockers("org/a", true)
	if err != nil {
		t.Fatal(err)
	}
	after, _ := s.FleetSettings()
	if !reflect.DeepEqual(before, after) {
		t.Fatal("dry-run wrote settings")
	}
	b, _ := s.RepoAuthority("org/b")
	freeze := RepoAuthorityChange{Action: "freeze", Revision: 0, Key: "freeze", LegacyTickets: "github"}
	a, err = s.ChangeRepoAuthority("org/a", "alice", freeze, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	replay, err := s.ChangeRepoAuthority("org/a", "alice", freeze, time.Now())
	if err != nil || !reflect.DeepEqual(a, replay) {
		t.Fatal("freeze replay", replay, err)
	}
	if _, err = s.CreateFleetTask(FleetTask{Repo: "org/a", Owner: "alice", Title: "frozen", AuthorityVersion: 1, RequestedAgent: "codex", ResolvedAgent: "codex"}, "frozen", time.Now()); !errors.Is(err, ErrRepoAuthority) {
		t.Fatal("accepted while frozen", err)
	}
	if _, _, _, err = s.AcquireLease(LeaseClaim{Repo: "org/a", Issue: 7, WorkerID: "old", FleetID: "f"}, time.Minute, time.Now()); !errors.Is(err, ErrRepoAuthority) {
		t.Fatal("legacy starts during freeze", err)
	}
	if err = s.InsertFleetOperation(FleetOperation{ID: "legacy", Actor: "alice", Idem: "legacy", Action: "worker_start", Request: `{"params":{"repo":"org/a","kind":"scratch"}}`, Created: time.Now(), Updated: time.Now()}); !errors.Is(err, ErrRepoAuthority) {
		t.Fatal("scratch bypass", err)
	}
	a = repoChange(t, s, a, "apply")
	apply := RepoAuthorityChange{Action: "apply", Revision: a.Revision, Key: "apply-again"}
	a, err = s.ChangeRepoAuthority("org/a", "alice", apply, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	replay, err = s.ChangeRepoAuthority("org/a", "alice", apply, time.Now())
	if err != nil || !reflect.DeepEqual(a, replay) {
		t.Fatal("apply replay", err)
	}
	if _, _, _, err = s.AcquireLease(LeaseClaim{Repo: "org/a", Issue: 7, WorkerID: "old", FleetID: "f", Force: true}, time.Minute, time.Now()); !errors.Is(err, ErrRepoAuthority) {
		t.Fatal("forced legacy bypass", err)
	}
	if ok, _, _, err := s.AcquireLease(LeaseClaim{Repo: "org/b", Issue: 7, WorkerID: "other", FleetID: "g"}, time.Minute, time.Now()); err != nil || !ok {
		t.Fatal("repo B changed", err)
	}
	b2, _ := s.RepoAuthority("org/b")
	if !reflect.DeepEqual(b, b2) {
		t.Fatal("repo B authority changed")
	}
	a = repoChange(t, s, a, "freeze")
	a = repoChange(t, s, a, "rollback")
	if a.Mode != "legacy" || a.LegacyTickets != "github" {
		t.Fatal(a)
	}
	t.Log("fixture dry-run=0 writes; explicit freeze/apply/replay/rollback; repo B unchanged")
}

func TestRepoAuthorityExpiredOwnerAndNativeStop(t *testing.T) {
	s := taskStore(t)
	now := time.Now()
	_, _, _, err := s.AcquireLease(LeaseClaim{Repo: "org/a", Issue: 7, WorkerID: "f/old", FleetID: "f", EndpointID: "node-a"}, time.Minute, now.Add(-time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	a, _ := s.RepoAuthority("org/a")
	a = repoChange(t, s, a, "freeze")
	if len(a.Owners) != 1 {
		t.Fatal("expired owner forgotten", a)
	}
	_, err = s.ChangeRepoAuthority(a.Repo, "alice", RepoAuthorityChange{Action: "apply", Revision: a.Revision, Key: "unsafe"}, now)
	if !errors.Is(err, ErrRepoAuthority) {
		t.Fatal("expired lease treated as stopped", err)
	}
	// Even release/disappearance is insufficient after the owner is captured.
	_, _ = s.ReleaseLease("org/a", 7, "f/old")
	_, err = s.ChangeRepoAuthority(a.Repo, "alice", RepoAuthorityChange{Action: "apply", Revision: a.Revision, Key: "absent"}, now)
	if !errors.Is(err, ErrRepoAuthority) {
		t.Fatal("absence treated as stopped", err)
	}
	ack := RepoAuthorityChange{Action: "stop_ack", Revision: a.Revision, Key: "stop", WorkerID: "f/old", EndpointID: "node-b", Evidence: "fixture native stop"}
	if _, err = s.ChangeRepoAuthority(a.Repo, "alice", ack, now); !errors.Is(err, ErrTaskFence) {
		t.Fatal("foreign node stopped owner", err)
	}
	ack.EndpointID = "node-a"
	if _, err = s.ChangeRepoAuthority(a.Repo, "alice", ack, now); !errors.Is(err, ErrTaskFence) {
		t.Fatal("unbound legacy receipt accepted", err)
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
	a, _ := s.RepoAuthority("org/a")
	a = repoChange(t, s, a, "freeze")
	if len(a.Owners) != 0 {
		t.Fatal("fixture must have no observed window", a)
	}
	if _, err := s.ChangeRepoAuthority("org/a", "alice", RepoAuthorityChange{Action: "apply", Revision: a.Revision, Key: "empty-inventory"}, time.Now().Add(24*time.Hour)); !errors.Is(err, ErrRepoAuthority) {
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
			a, _ := s.RepoAuthority("org/a")
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
			ack := RepoAuthorityChange{Action: "stop_ack", Revision: a.Revision, Key: "ack", EndpointID: "node-a", WorkerID: "f/w", Evidence: proof(&wrong)}
			if _, err := s.ChangeRepoAuthority("org/a", "alice", ack, time.Now()); !errors.Is(err, ErrTaskFence) {
				t.Fatal("wrong dead process released owner", err)
			}
			ack.Evidence = proof(old)
			if replacement {
				if _, err := s.ChangeRepoAuthority("org/a", "alice", ack, time.Now()); !errors.Is(err, ErrTaskFence) {
					t.Fatal("pre-transfer native receipt released live replacement", err)
				}
				return
			}
			run("old", "stopped", current)
			var err error
			a, err = s.ChangeRepoAuthority("org/a", "alice", ack, time.Now())
			if err != nil {
				t.Fatal(err)
			}
			ack.EndpointID = "node-b"
			if _, err := s.ChangeRepoAuthority("org/a", "alice", ack, time.Now()); err == nil {
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
	a, _ := s.RepoAuthority("org/a")
	a = repoChange(t, s, a, "freeze")
	a = repoChange(t, s, a, "apply")
	m, err := s.AdoptRepoTicket("org/a", "alice", "gh:org/a#7", "selected GH seven", "selected body", a.Revision, now)
	if err != nil || m.From != "gh:org/a#7" || m.To != "hub:org/a#8" || m.SourceURL != "https://github.com/org/a/issues/7" {
		t.Fatal(m, err)
	}
	again, err := s.AdoptRepoTicket("org/a", "alice", "gh:org/a#7", "selected GH seven", "selected body", a.Revision, now)
	if err != nil || again != m {
		t.Fatal("mapping not idempotent", again, err)
	}
	if _, err = s.AdoptRepoTicket("org/a", "alice", "gh:org/a#7", "changed input", "selected body", a.Revision, now); !errors.Is(err, ErrTaskConflict) {
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
	a, _ := s.RepoAuthority("org/a")
	a = repoChange(t, s, a, "freeze")
	a = repoChange(t, s, a, "apply")
	rec := startTask(t, s, acceptedTask(t, s, "retained", "gh:org/a#9"))
	rec = mutateTask(t, s, rec, TaskMutation{Key: "complete", Kind: "transition", State: TaskSucceeded, Evidence: `{"work_result":"succeeded","pr":"org/a#10","pr_state":"waiting"}`})
	a = repoChange(t, s, a, "freeze")
	if _, err := s.ChangeRepoAuthority(a.Repo, "alice", RepoAuthorityChange{Action: "rollback", Revision: a.Revision, Key: "unsafe"}, time.Now()); !errors.Is(err, ErrRepoAuthority) {
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
		granted, _, _, claimErr = s.AcquireLease(LeaseClaim{Repo: "org/race", Issue: 1, WorkerID: "f/w", EndpointID: "node", FleetID: "f"}, time.Minute, time.Now())
	}()
	go func() {
		defer wg.Done()
		_, freezeErr = s.ChangeRepoAuthority("org/race", "alice", RepoAuthorityChange{Action: "freeze", Key: "freeze", LegacyTickets: "github"}, time.Now())
	}()
	wg.Wait()
	if freezeErr != nil || (claimErr != nil && !errors.Is(claimErr, ErrRepoAuthority)) {
		t.Fatal(freezeErr, claimErr)
	}
	a, _ := s.RepoAuthority("org/race")
	if granted && len(a.Owners) != 1 {
		t.Fatal("racing owner escaped freeze", a)
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
