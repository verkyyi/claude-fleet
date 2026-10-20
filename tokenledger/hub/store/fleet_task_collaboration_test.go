package store

import (
	"fmt"
	"testing"
	"time"
)

// The task graph after EPIC T497 C8: a child names its parent record directly,
// or — a session a pre-C8 launch proof ran — through that record's archived
// executor; children are the records that name the parent, whichever session
// dispatched them. Nothing claims, fences a generation or takes a report.
func TestTaskChildrenNameTheirParent(t *testing.T) {
	s := taskStore(t)
	now := time.Now()
	parent := acceptedTask(t, s, "parent", "")
	child := func(token, parentTask, session string) FleetTask {
		t.Helper()
		rec, err := s.CreateFleetTask(FleetTask{Owner: "alice", Title: token, AuthorityVersion: 1,
			RequestedAgent: "codex", ResolvedAgent: "codex", ParentTask: parentTask, ParentSession: session}, token, now)
		if err != nil {
			t.Fatal(err)
		}
		return rec
	}
	a := child("child-a", parent.Ref, "fleet-a/window-a")
	b := child("child-b", parent.Ref, "fleet-b/window-b")
	if a.ParentTask != parent.Ref || a.ParentSession != "fleet-a/window-a" || a.ParentGeneration != parent.Generation {
		t.Fatalf("parent link: %+v", a)
	}
	kids, err := s.FleetTaskChildren("alice", parent.Ref)
	if err != nil || len(kids) != 2 || kids[0].ID != a.ID || kids[1].ID != b.ID {
		t.Fatalf("children: %+v %v", kids, err)
	}
	if again := child("child-a", parent.Ref, "fleet-a/window-a"); again.ID != a.ID {
		t.Fatalf("the same token again: %+v", again)
	}

	// A pre-C8 parent: its record holds the executor a launch proof claimed;
	// a child that names only that session finds the record through it.
	old := acceptedTask(t, s, "old-parent", "")
	if _, err := s.write.Exec(fmt.Sprintf(`UPDATE fleet_tasks SET state = 'running', execution_owner = 'fleet-z/old-window', worker_id = 'fleet-z/old-window' WHERE id = %d`, old.ID)); err != nil {
		t.Fatal(err)
	}
	c := child("child-of-old", "", "fleet-z/old-window")
	if c.ParentTask != old.Ref {
		t.Fatalf("archived executor: %+v", c)
	}
	if kids, err := s.FleetTaskChildren("alice", old.Ref); err != nil || len(kids) != 1 {
		t.Fatalf("old parent's children: %+v %v", kids, err)
	}
	// A session alone that no record ever named names no record.
	if loose := child("loose", "", "fleet-q/nobody"); loose.ParentTask != "" {
		t.Fatalf("a bare session named a record: %+v", loose)
	}
	if kids, err := s.FleetTaskChildren("bob", parent.Ref); err != nil || len(kids) != 0 {
		t.Fatalf("another owner's children: %+v %v", kids, err)
	}
}
