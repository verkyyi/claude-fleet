package store

import (
	"errors"
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

// A dispatched task's record is its ticket (EPIC T497 C8): accepted, never
// claimed, no attempt journal, no lease — the same token answers the same
// record. Both CI dialect legs run it; fixture evidence, never live acceptance.
func TestTaskRecordIsATicket(t *testing.T) {
	s := taskStore(t)
	now := time.Now()
	rec := acceptedTask(t, s, "ticket", "gh:org/a#7")
	if rec.State != TaskAccepted || rec.AuthorityVersion != TaskAuthorityVersion || rec.ExecutionOwner != "" || rec.WorkerID != "" {
		t.Fatalf("accepted record: %+v", rec)
	}
	again := acceptedTask(t, s, "ticket", "gh:org/a#7")
	if again.ID != rec.ID || again.State != TaskAccepted {
		t.Fatalf("the same token again: %+v", again)
	}
	var n int
	if err := s.read.QueryRow(`SELECT COUNT(*) FROM fleet_operations WHERE action = 'task_attempt'`).Scan(&n); err != nil || n != 0 {
		t.Fatalf("an attempt journal: %d %v", n, err)
	}
	if err := s.read.QueryRow(`SELECT COUNT(*) FROM fleet_leases WHERE task_id <> 0`).Scan(&n); err != nil || n != 0 {
		t.Fatalf("a task lease: %d %v", n, err)
	}
	// A legacy (v0) record keeps its update road; a hub ticket is no backend
	// (claude-fleet#4898, T477); retired Parent input grants no relationship.
	legacy, err := s.CreateFleetTask(FleetTask{Owner: "alice", Title: "legacy"}, "legacy", now)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = s.UpdateFleetTask(legacy.ID, FleetTaskUpdate{State: TaskOpen}, now); err != nil {
		t.Fatal(err)
	}
	input := FleetTask{Owner: "alice", Title: "hub ticket", AuthorityVersion: 1, RequestedAgent: "codex", ResolvedAgent: "codex", TicketRef: "hub:foreign/repo#7"}
	if _, err = s.CreateFleetTask(input, "hub-ticket", now); !errors.Is(err, ErrTaskInvalid) {
		t.Fatalf("hub ticket: %v", err)
	}
	input.TicketRef, input.Owner, input.ParentTask = "", "bob", legacy.Ref
	if rec, err := s.CreateFleetTask(input, "foreign-parent", now); err != nil || rec.ParentTask != "" || rec.Owner != "bob" {
		t.Fatalf("ignored foreign Parent metadata: %+v %v", rec, err)
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
