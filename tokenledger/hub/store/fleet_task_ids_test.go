package store_test

import (
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/hub/store/storetest"
)

// EPIC T644 C1 «任务一建好就有编号»: a task record has its ID from its first
// moment, and every reference — its code, its full ID, T<n> — reads the same
// record; a code that names several is refused with them, never picked.

func newLegacyTask(t *testing.T, st *store.Store, owner, token string) store.FleetTask {
	t.Helper()
	rec, err := st.CreateFleetTask(store.FleetTask{Owner: owner, Title: "probe " + token}, token, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	return rec
}

func TestTaskHasItsIDFromItsFirstMoment(t *testing.T) {
	st := storetest.OpenFleet(t)
	now := time.Now()
	// the legacy road (⌘P's place, a coordinator's record)
	a := newLegacyTask(t, st, "operator", "k1")
	if !store.IsFleetID(a.FID) || len(a.Short) < store.IDShortMin || !strings.HasPrefix(store.FleetIDCode(a.FID), a.Short) || a.Task != a.Ref {
		t.Fatalf("legacy create = fid %q short %q task %q", a.FID, a.Short, a.Task)
	}
	again := newLegacyTask(t, st, "operator", "k1")
	if again.ID != a.ID || again.FID != a.FID || again.Short != a.Short {
		t.Fatalf("the same token again = %+v; want the same ID %s", again, a.FID)
	}
	// the dispatch road (version 1), minted in the same transaction
	b, err := st.CreateFleetTask(store.FleetTask{Owner: "operator", Title: "v1", AuthorityVersion: 1,
		RequestedAgent: "default", ResolvedAgent: "claude"}, "k2", now)
	if err != nil {
		t.Fatal(err)
	}
	if !store.IsFleetID(b.FID) || b.FID == a.FID || b.Short == "" {
		t.Fatalf("v1 create = fid %q short %q", b.FID, b.Short)
	}
	if b2, err := st.CreateFleetTask(store.FleetTask{Owner: "operator", Title: "v1", AuthorityVersion: 1,
		RequestedAgent: "default", ResolvedAgent: "claude"}, "k2", now); err != nil || b2.FID != b.FID {
		t.Fatalf("v1 replay = %v %v; want %s", b2.FID, err, b.FID)
	}
	// the ID is a reserved mirror row: the owner's, no machine, carrying no T<n>
	id, err := st.FleetIDOf("operator", a.FID)
	if err != nil || id.Short != a.Short || id.Seq != 0 || id.Machine != "" || id.Task != "" {
		t.Fatalf("reserved row = %+v %v", id, err)
	}
	// so nothing reads it as «a window carries T<n>»: an accepted record no
	// window opened can still be cancelled
	if _, err := st.CancelUnopenedTask(b.ID, "operator", "nobody opened it", now); err != nil {
		t.Fatalf("cancel an unopened v1 record with its reserved ID: %v", err)
	}
	// the owner's first machine to push it takes it (the window opened for it)
	got, err := push(t, st, "ep1", a.FID, ledger(t,
		`{"ev":"opened","agent":"claude","window":"@3","title":"probe","task":"`+a.Ref+`","id":"`+a.FID+`","seq":1,"ts":2000}`))
	if err != nil || got.Seq != 1 || got.Short != a.Short || got.Machine != "m-ep1" {
		t.Fatalf("first push of the task's ID = %+v %v", got, err)
	}
	if _, err := push(t, st, "ep2", a.FID, ledger(t, `{"ev":"native","agent":"claude","native":"x","id":"`+a.FID+`","seq":2,"ts":2001}`)); !errors.Is(err, store.ErrIDDuplicate) {
		t.Fatalf("another machine on a taken task ID = %v; want ErrIDDuplicate", err)
	}
}

func TestResolveTaskByCodeIDOrT(t *testing.T) {
	st := storetest.OpenFleet(t)
	a := newLegacyTask(t, st, "operator", "r1")
	newLegacyTask(t, st, "someone", "r2")
	for _, ref := range []string{a.Ref, fmt.Sprint(a.ID), a.FID, a.Short, strings.ToLower(a.Short), "#" + a.Short, store.FleetIDCode(a.FID)} {
		got, err := st.ResolveFleetTask("operator", ref)
		if err != nil || got.ID != a.ID {
			t.Fatalf("resolve %q = %v %v; want %s", ref, got.Ref, err, a.Ref)
		}
	}
	// another owner's code is not this owner's
	if _, err := st.ResolveFleetTask("someone", a.Short); !errors.Is(err, sql.ErrNoRows) {
		t.Fatalf("another owner's code = %v; want ErrNoRows", err)
	}
	// a window's ID that belongs to the task answers the task
	win := "0b7e8c1a-1111-4222-8333-444455556666"
	if _, err := push(t, st, "ep1", win, ledger(t,
		`{"ev":"opened","agent":"claude","task":"`+a.Ref+`","id":"`+win+`","seq":1,"ts":3000}`)); err != nil {
		t.Fatal(err)
	}
	if got, err := st.ResolveFleetTask("operator", win); err != nil || got.ID != a.ID {
		t.Fatalf("a window ID of the task = %v %v", got.Ref, err)
	}
	for _, bad := range []string{"", "1x", "4539", "K", "T-7ym5y"} {
		if _, err := st.ResolveFleetTask("operator", bad); !errors.Is(err, sql.ErrNoRows) {
			t.Fatalf("resolve %q = %v; want ErrNoRows", bad, err)
		}
	}
}

// Two tasks whose IDs share their first two places: the two-place code names
// both across the whole history (409's candidates). Historical outcomes
// cannot select a different Task for the same prefix.
func TestResolveTaskCodeNeverGuesses(t *testing.T) {
	st := storetest.OpenFleet(t)
	seen := map[string]store.FleetTask{}
	var x, y store.FleetTask
	for i := 0; i < 3000 && x.ID == 0; i++ {
		r := newLegacyTask(t, st, "operator", fmt.Sprintf("a%d", i))
		p := store.FleetIDCode(r.FID)[:2]
		if store.ParseTaskRef(p) > 0 {
			continue // `T8` reads as the alias T8, never a code
		}
		if o, ok := seen[p]; ok {
			x, y = o, r
		}
		seen[p] = r
	}
	if x.ID == 0 {
		t.Fatal("no two IDs shared two places in 3000 tries")
	}
	// every other task ends, so the two are the only unfinished ones under p
	if _, err := st.DB().Exec(`UPDATE fleet_tasks SET state = 'closed' WHERE id NOT IN (?, ?)`, x.ID, y.ID); err != nil {
		t.Fatal(err)
	}
	p := store.FleetIDCode(x.FID)[:2]
	_, err := st.ResolveFleetTask("operator", p)
	var amb *store.TaskAmbiguity
	if !errors.As(err, &amb) || len(amb.Candidates) != 2 || amb.Candidates[0].ID != x.FID || amb.Candidates[1].Task != y.Ref {
		t.Fatalf("two unfinished under %s = %v; want both as candidates", p, err)
	}
	if _, err := st.DB().Exec(`UPDATE fleet_tasks SET state = 'closed' WHERE id = ?`, x.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := st.ResolveFleetTask("operator", p); !errors.As(err, &amb) || len(amb.Candidates) != 2 {
		t.Fatalf("historical result must not select a prefix winner: %v", err)
	}
	if _, err := st.DB().Exec(`UPDATE fleet_tasks SET state = 'cancelled' WHERE id = ?`, y.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := st.ResolveFleetTask("operator", p); !errors.As(err, &amb) || len(amb.Candidates) < 2 {
		t.Fatalf("none unfinished under %s = %v; want the history's candidates", p, err)
	}
	// the written code stays unique in the whole history
	if got, err := st.ResolveFleetTask("operator", x.Short); err != nil || got.ID != x.ID {
		t.Fatalf("written code %s = %v %v", x.Short, got.Ref, err)
	}
}

// A record from before C1: the dry run says what it would do and changes
// nothing; apply links the earliest ID already carrying its number, mints one
// where none does, and is a no-op the second time.
func TestBackfillTaskIDs(t *testing.T) {
	st := storetest.OpenFleet(t)
	now := time.Now()
	old1 := newLegacyTask(t, st, "operator", "b1")
	old2 := newLegacyTask(t, st, "operator", "b2")
	if _, err := st.DB().Exec(`UPDATE fleet_tasks SET fid = '' WHERE id IN (?, ?)`, old1.ID, old2.ID); err != nil {
		t.Fatal(err)
	}
	early, late := "1a2b3c4d-0000-4000-8000-000000000001", "1a2b3c4d-0000-4000-8000-000000000002"
	for i, id := range []string{late, early} {
		if _, err := push(t, st, "ep1", id, ledger(t, fmt.Sprintf(
			`{"ev":"opened","agent":"claude","task":"%s","id":"%s","seq":1,"ts":%d}`, old1.Ref, id, 5000-i*100))); err != nil {
			t.Fatal(err)
		}
	}
	dry, err := st.BackfillTaskIDs("operator", false, now)
	if err != nil || dry.Total != 2 || dry.Linked != 1 || dry.Minted != 1 || len(dry.Items) != 2 || dry.Items[0].ID != early {
		t.Fatalf("dry = %+v %v", dry, err)
	}
	if r, _ := st.FleetTask(old1.ID); r.FID != "" {
		t.Fatalf("a dry run wrote %s", r.FID)
	}
	done, err := st.BackfillTaskIDs("operator", true, now)
	if err != nil || done.Linked != 1 || done.Minted != 1 {
		t.Fatalf("apply = %+v %v", done, err)
	}
	r1, _ := st.FleetTask(old1.ID)
	r2, _ := st.FleetTask(old2.ID)
	if r1.FID != early || r1.Short == "" || !store.IsFleetID(r2.FID) || r2.FID == early || r2.FID == late {
		t.Fatalf("after apply: %s=%s %s=%s", r1.Ref, r1.FID, r2.Ref, r2.FID)
	}
	// both windows that carry T<n> now name the task by its ID too
	var n int
	if err := st.DB().QueryRow(`SELECT COUNT(*) FROM fleet_ids WHERE task_id = ?`, early).Scan(&n); err != nil || n != 2 {
		t.Fatalf("task_id carried by %d IDs (%v); want 2", n, err)
	}
	if again, err := st.BackfillTaskIDs("operator", true, now); err != nil || again.Already != 2 || again.Linked+again.Minted != 0 {
		t.Fatalf("second apply = %+v %v", again, err)
	}
	if got, err := st.ResolveFleetTask("operator", r1.Short); err != nil || got.ID != old1.ID {
		t.Fatalf("resolve the backfilled code = %v %v", got.Ref, err)
	}
}

func TestResolveTaskWrittenCodeSurvivesNewPrefixAndOutcome(t *testing.T) {
	st := storetest.OpenFleet(t)
	old := newLegacyTask(t, st, "operator", "stable-old")
	next := newLegacyTask(t, st, "operator", "stable-new")
	// A newly minted ID may extend a previously written prefix. The old short
	// remains an exact address, independently of either task's historical state.
	for _, row := range []struct{ id, code, short string }{{old.FID, "FDMQ6PHPNRY42YF888A0Z7K322", "FDMQ"}, {next.FID, "FDMQ6PE0000000000000000000", "FDMQ6PE"}} {
		if _, err := st.DB().Exec(`UPDATE fleet_ids SET code = ?, short = ? WHERE id = ?`, row.code, row.short, row.id); err != nil {
			t.Fatal(err)
		}
	}
	for _, state := range []string{"open", "closed", "failed", "cancelled"} {
		if _, err := st.DB().Exec(`UPDATE fleet_tasks SET state = ? WHERE id = ?`, state, old.ID); err != nil {
			t.Fatal(err)
		}
		got, err := st.ResolveFleetTask("operator", "FDMQ")
		if err != nil || got.ID != old.ID {
			t.Fatalf("written code moved: %v %v", got, err)
		}
		var amb *store.TaskAmbiguity
		if _, err := st.ResolveFleetTask("operator", "FD"); !errors.As(err, &amb) || len(amb.Candidates) != 2 {
			t.Fatalf("prefix guessed: %v", err)
		}
	}
}
