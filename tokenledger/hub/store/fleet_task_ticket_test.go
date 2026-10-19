package store

import (
	"encoding/json"
	"errors"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

func ticketMutation(kind, key, ref string) TaskMutation {
	var m TaskMutation
	_ = json.Unmarshal([]byte(`{"kind":"`+kind+`","idempotency_key":"`+key+`","generation":1,"ticket_ref":"`+ref+`"}`), &m)
	m.EndpointID = "node-a"
	m.FilingID = "11111111-1111-4111-8111-111111111111"
	return m
}

func TestTaskTicketScopeAndConcurrentWriters(t *testing.T) {
	path := filepath.Join(t.TempDir(), "tickets.db")
	s, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	if err = s.EnsureNodes(); err != nil {
		t.Fatal(err)
	}
	other, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer other.Close()
	makeTask := func(key string) FleetTask {
		t.Helper()
		rec, err := s.CreateFleetTask(FleetTask{Owner: "alice", Repo: "org/repo", Title: key, AuthorityVersion: 1, RequestedAgent: "codex", ResolvedAgent: "codex"}, key, time.Now())
		if err != nil {
			t.Fatal(err)
		}
		return rec
	}
	rec := makeTask("scope")
	prepare := ticketMutation("ticket_prepare", "ticket-file:g1", "")
	link := ticketMutation("ticket_link", "ticket-link:g1", "gh:org/repo#71")
	if _, err = s.MutateFleetTask(rec.ID, rec.Owner, link, time.Now()); !errors.Is(err, ErrTaskFence) {
		t.Fatalf("link without prepare: %v", err)
	}
	if _, err = s.MutateFleetTask(rec.ID, rec.Owner, prepare, time.Now()); err != nil {
		t.Fatal(err)
	}
	foreignPrepare := prepare
	foreignPrepare.EndpointID = "node-b"
	if _, err = other.MutateFleetTask(rec.ID, rec.Owner, foreignPrepare, time.Now()); !errors.Is(err, ErrTaskConflict) {
		t.Fatalf("second node could prepare a duplicate create: %v", err)
	}
	wrongRepo := link
	wrongRepo.TicketRef = "gh:other/repo#71"
	if _, err = s.MutateFleetTask(rec.ID, rec.Owner, wrongRepo, time.Now()); !errors.Is(err, ErrTaskFence) {
		t.Fatalf("cross repo: %v", err)
	}
	wrongNode := link
	wrongNode.EndpointID = "node-b"
	if _, err = s.MutateFleetTask(rec.ID, rec.Owner, wrongNode, time.Now()); !errors.Is(err, ErrTaskFence) {
		t.Fatalf("foreign filing endpoint: %v", err)
	}
	newJournal := prepare
	newJournal.FilingID = "22222222-2222-4222-8222-222222222222"
	if _, err = s.MutateFleetTask(rec.ID, rec.Owner, newJournal, time.Now()); !errors.Is(err, ErrTaskConflict) {
		t.Fatalf("lost local journal reopened filing: %v", err)
	}
	if _, err = s.RegisterTicket("gh:org/repo#71", FleetTicket{Owner: "bob", Title: "foreign", State: "open"}, time.Now()); err != nil {
		t.Fatal(err)
	}
	if _, err = s.MutateFleetTask(rec.ID, rec.Owner, link, time.Now()); !errors.Is(err, ErrTaskFence) {
		t.Fatalf("foreign ticket owner: %v", err)
	}
	link.TicketRef = "hub:org/repo#71"
	if _, err = s.MutateFleetTask(rec.ID, rec.Owner, link, time.Now()); err == nil {
		t.Fatal("backend collision")
	}
	link.TicketRef = "gh:org/repo#72"
	// Independent connections race two different ticket results under the ONE
	// generation key. Both dialect jobs run this through the standard dbURL rig.
	var wg sync.WaitGroup
	results := make(chan error, 2)
	for i, db := range []*Store{s, other} {
		wg.Add(1)
		go func(i int, db *Store) {
			defer wg.Done()
			m := link
			if i == 1 {
				m.TicketRef = "gh:org/repo#73"
			}
			_, e := db.MutateFleetTask(rec.ID, rec.Owner, m, time.Now())
			results <- e
		}(i, db)
	}
	wg.Wait()
	close(results)
	success := 0
	for e := range results {
		if e == nil {
			success++
		} else if !errors.Is(e, ErrTaskConflict) {
			t.Fatal(e)
		}
	}
	if success != 1 {
		t.Fatalf("association winners=%d", success)
	}
	hubTicket, err := s.CreateFleetTicket(FleetTicket{Repo: "org/repo", Owner: "alice", Title: "hub-only"}, 80, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	hubTask := makeTask("hub-ticket")
	if _, err = s.MutateFleetTask(hubTask.ID, hubTask.Owner, prepare, time.Now()); err != nil {
		t.Fatal(err)
	}
	hubLink := ticketMutation("ticket_link", "ticket-link:g1", hubTicket.ID)
	hubTask, err = s.MutateFleetTask(hubTask.ID, hubTask.Owner, hubLink, time.Now())
	if err != nil || hubTask.TicketRef != hubTicket.ID {
		t.Fatalf("hub association requires no GitHub: %+v %v", hubTask, err)
	}
	noTicket := makeTask("no-ticket-start")
	noTicket = startTask(t, s, noTicket) // GitHub is not required for task control.
	late := link
	if _, err = s.MutateFleetTask(noTicket.ID, noTicket.Owner, late, time.Now()); !errors.Is(err, ErrTaskFence) {
		t.Fatalf("late association moved lease: %v", err)
	}
	t.Log("SQLite/PostgreSQL fixture: independent writers, one link; repo/account/endpoint/incarnation/backend/owner scope; no-GitHub control retained")
}

func TestTaskTicketLinkContract(t *testing.T) {
	s := taskStore(t)
	parent := startTask(t, s, acceptedTask(t, s, "parent", ""))
	input := FleetTask{Owner: "alice", Repo: "org/repo", Title: "original", AuthorityVersion: 1,
		RequestedAgent: "codex", ResolvedAgent: "codex", ParentTask: parent.Ref, ParentSession: parent.ExecutionOwner, RequestPayload: `{"rule":"n=1 v=abcd","body":"original"}`}
	rec, err := s.CreateFleetTask(input, "ticket-followup", time.Now())
	if err != nil {
		t.Fatal(err)
	}
	prepare := ticketMutation("ticket_prepare", "ticket-file:g1", "")
	if _, err = s.MutateFleetTask(rec.ID, rec.Owner, prepare, time.Now()); err != nil {
		t.Fatalf("prepare: %v", err)
	}
	link := ticketMutation("ticket_link", "ticket-link:g1", "gh:org/repo#71")
	before := rec
	rec, err = s.MutateFleetTask(rec.ID, rec.Owner, link, time.Now())
	if err != nil {
		t.Fatalf("link: %v", err)
	}
	if rec.TicketRef != "gh:org/repo#71" || rec.Issue != "org/repo#71" || rec.RequestPayload != before.RequestPayload || rec.acceptedRequest != before.acceptedRequest || rec.ResolvedAgent != "codex" || rec.ParentSession != before.ParentSession || rec.Generation != 1 {
		t.Fatalf("changed contract: %+v", rec)
	}
	again, err := s.MutateFleetTask(rec.ID, rec.Owner, link, time.Now())
	if err != nil || !again.UpdatedAt.Equal(rec.UpdatedAt) {
		t.Fatalf("lost link ack: %+v %v", again, err)
	}
	accepted, err := s.CreateFleetTask(input, "ticket-followup", time.Now())
	if err != nil || accepted.Ref != rec.Ref || accepted.TicketRef != "" {
		t.Fatalf("accept replay changed: %+v %v", accepted, err)
	}
	for _, tc := range []struct {
		name, owner string
		m           TaskMutation
	}{
		{"foreign account", "bob", link},
		{"changed ticket", "alice", ticketMutation("ticket_link", "ticket-link:g1", "gh:org/repo#72")},
		{"cross repo", "alice", ticketMutation("ticket_link", "ticket-link:g1", "gh:other/repo#71")},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if _, err := s.MutateFleetTask(rec.ID, tc.owner, tc.m, time.Now()); err == nil {
				t.Fatal("unfenced association")
			}
		})
	}
	foreign := prepare
	foreign.EndpointID = "node-b"
	if _, err = s.MutateFleetTask(rec.ID, rec.Owner, foreign, time.Now()); !errors.Is(err, ErrTaskConflict) {
		t.Fatalf("second filing owner: %v", err)
	}
	// A link after execution starts must never move a lease to another resource.
	running := startTask(t, s, rec)
	late := ticketMutation("ticket_link", "late", "gh:org/repo#72")
	late.ExpectedWorker = running.ExecutionOwner
	if _, err = s.MutateFleetTask(rec.ID, rec.Owner, late, time.Now()); err == nil {
		t.Fatal("late link moved execution lease")
	}
	stale := link
	stale.Key = "ticket-link:g2"
	stale.Generation = 2
	if _, err = s.MutateFleetTask(rec.ID, rec.Owner, stale, time.Now()); !errors.Is(err, ErrTaskFence) {
		t.Fatalf("generation: %v", err)
	}
	t.Log("ticket contract: same accepted input/provider/parent; one association; account, endpoint, repo, ticket and generation fenced")
}
