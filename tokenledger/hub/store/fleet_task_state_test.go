package store_test

import (
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/hub/store/storetest"
)

// EPIC T644 C6 «记录的状态和实际一致»: a record ends the moment its ID's result
// lands, so its single read, the list and the children all say the same; the
// reconcile catches what ended before that, once.

func newV1Task(t *testing.T, st *store.Store, token, parent string) store.FleetTask {
	t.Helper()
	rec, err := st.CreateFleetTask(store.FleetTask{Owner: "operator", Title: "v1 " + token, AuthorityVersion: 1,
		RequestedAgent: "default", ResolvedAgent: "claude", ParentTask: parent}, token, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	return rec
}

// threeReads is the record as the single read, the owner's list and its
// parent's children each give its state.
func threeReads(t *testing.T, st *store.Store, rec store.FleetTask) [3]string {
	t.Helper()
	var out [3]string
	one, err := st.FleetTask(rec.ID)
	if err != nil {
		t.Fatal(err)
	}
	out[0] = one.State + "/" + one.Outcome
	list, err := st.FleetTasksFor("operator", 500)
	if err != nil {
		t.Fatal(err)
	}
	for _, x := range list {
		if x.ID == rec.ID {
			out[1] = x.State + "/" + x.Outcome
		}
	}
	out[2] = out[1]
	if rec.ParentTask != "" {
		kids, err := st.FleetTaskChildren("operator", rec.ParentTask)
		if err != nil {
			t.Fatal(err)
		}
		out[2] = ""
		for _, x := range kids {
			if x.ID == rec.ID {
				out[2] = x.State + "/" + x.Outcome
			}
		}
	}
	return out
}

func wantEverywhere(t *testing.T, st *store.Store, rec store.FleetTask, want string) {
	t.Helper()
	if got := threeReads(t, st, rec); got != [3]string{want, want, want} {
		t.Fatalf("%s reads (single, list, children) = %v; want %s everywhere", rec.Ref, got, want)
	}
}

func TestTaskEndsWhenItsIDResultLands(t *testing.T) {
	st := storetest.OpenFleet(t)
	parent := newV1Task(t, st, "p", "")
	child := newV1Task(t, st, "c", parent.Ref)
	wantEverywhere(t, st, child, "accepted/")

	// a window opened for the task (it names T<n>); a word that is not an end changes nothing
	win := "0b7e8c1a-1111-4222-8333-444455556601"
	if _, err := push(t, st, "ep1", win, ledger(t,
		`{"ev":"opened","agent":"claude","task":"`+child.Ref+`","id":"`+win+`","seq":1,"ts":1000}`,
		`{"ev":"result","state":"blocked","summary":"waiting on you","id":"`+win+`","seq":2,"ts":1001}`)); err != nil {
		t.Fatal(err)
	}
	wantEverywhere(t, st, child, "accepted/")

	// its failure, then a retry's success: the newest end wins, written on the row
	if _, err := push(t, st, "ep1", win, ledger(t,
		`{"ev":"result","state":"failed","summary":"red","id":"`+win+`","seq":3,"ts":1002}`)); err != nil {
		t.Fatal(err)
	}
	wantEverywhere(t, st, child, "failed/failed")
	if _, err := push(t, st, "ep1", win, ledger(t,
		`{"ev":"result","state":"merged","pr":"o/r#9","id":"`+win+`","seq":4,"ts":1003}`)); err != nil {
		t.Fatal(err)
	}
	wantEverywhere(t, st, child, "succeeded/succeeded")
	if got, _ := st.FleetTask(child.ID); got.PR != "o/r#9" || got.Observation != store.ObsIDResult+win+"#4" {
		t.Fatalf("written-through record = pr %q observation %q", got.PR, got.Observation)
	}
	// ended on its result: no cancel ends it again
	if _, err := st.CancelUnopenedTask(child.ID, "operator", "late cancel", time.Now()); err == nil {
		t.Fatal("cancelling a record its ID's result ended was taken")
	}

	// a result on the task's OWN ID (C1's reserved one, taken by its window) ends it too
	own := newV1Task(t, st, "own", "")
	if _, err := push(t, st, "ep1", own.FID, ledger(t,
		`{"ev":"opened","agent":"claude","id":"`+own.FID+`","seq":1,"ts":2000}`,
		`{"ev":"result","state":"succeeded","id":"`+own.FID+`","seq":2,"ts":2001}`)); err != nil {
		t.Fatal(err)
	}
	wantEverywhere(t, st, own, "succeeded/succeeded")

	// a record cancelled before its window said anything keeps its cancel
	gone := newV1Task(t, st, "gone", "")
	if _, err := st.CancelUnopenedTask(gone.ID, "operator", "never opened", time.Now()); err != nil {
		t.Fatal(err)
	}
	late := "0b7e8c1a-1111-4222-8333-444455556602"
	if _, err := push(t, st, "ep1", late, ledger(t,
		`{"ev":"opened","agent":"claude","task":"`+gone.Ref+`","id":"`+late+`","seq":1,"ts":3000}`,
		`{"ev":"result","state":"merged","id":"`+late+`","seq":2,"ts":3001}`)); err != nil {
		t.Fatal(err)
	}
	wantEverywhere(t, st, gone, "cancelled/cancelled")

	// another owner's ID naming the same number never touches this owner's record
	other := newV1Task(t, st, "other", "")
	if _, err := st.ApplyFleetIDEvents(store.FleetIDPush{Owner: "someone", EndpointID: "ep9", Machine: "m9", Login: "bob",
		ID: "0b7e8c1a-1111-4222-8333-444455556603", Events: ledger(t,
			`{"ev":"opened","agent":"claude","task":"`+other.Ref+`","id":"0b7e8c1a-1111-4222-8333-444455556603","seq":1,"ts":4000}`,
			`{"ev":"result","state":"merged","id":"0b7e8c1a-1111-4222-8333-444455556603","seq":2,"ts":4001}`)}); err != nil {
		t.Fatal(err)
	}
	wantEverywhere(t, st, other, "accepted/")

	// a legacy record that ended this way is not reopened by a late word
	leg := newLegacyTask(t, st, "operator", "leg")
	lw := "0b7e8c1a-1111-4222-8333-444455556604"
	if _, err := push(t, st, "ep1", lw, ledger(t,
		`{"ev":"opened","agent":"claude","task":"`+leg.Ref+`","id":"`+lw+`","seq":1,"ts":5000}`,
		`{"ev":"result","state":"done","id":"`+lw+`","seq":2,"ts":5001}`)); err != nil {
		t.Fatal(err)
	}
	if got, err := st.UpdateFleetTask(leg.ID, store.FleetTaskUpdate{State: store.TaskOpen}, time.Now()); err != nil || got.State != store.TaskSucceeded {
		t.Fatalf("a late `open` on an ended legacy record = %q %v", got.State, err)
	}
}

func TestReconcileTaskStates(t *testing.T) {
	st := storetest.OpenFleet(t)
	db := st.DB()
	now := time.Now()
	// ended before C6: its ID has the result, its row never heard
	ended := newV1Task(t, st, "e", "")
	w1 := "0b7e8c1a-1111-4222-8333-444455556611"
	if _, err := push(t, st, "ep1", w1, ledger(t,
		`{"ev":"opened","agent":"claude","task":"`+ended.Ref+`","id":"`+w1+`","seq":1,"ts":1000}`,
		`{"ev":"result","state":"merged","pr":"o/r#1","id":"`+w1+`","seq":2,"ts":1001}`)); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`UPDATE fleet_tasks SET state = 'accepted', outcome = '', pr = '', observation = '' WHERE id = ?`, ended.ID); err != nil {
		t.Fatal(err)
	}
	// legacy records: one nobody holds, one whose window is still open
	dead := newLegacyTask(t, st, "operator", "dead")
	alive := newLegacyTask(t, st, "operator", "alive")
	w2 := "0b7e8c1a-1111-4222-8333-444455556612"
	if _, err := push(t, st, "ep1", w2, ledger(t,
		`{"ev":"opened","agent":"claude","task":"`+alive.Ref+`","id":"`+w2+`","seq":1,"ts":1100}`)); err != nil {
		t.Fatal(err)
	}
	// and one after the cutoff, untouched however it looks
	recent := newLegacyTask(t, st, "operator", "recent")
	before := recent.ID

	dry, err := st.ReconcileTaskStates("operator", before, false, now)
	if err != nil {
		t.Fatal(err)
	}
	if dry.Unfinished != 4 || dry.Ended != 1 || dry.Cancelled != 1 || dry.Kept["open ID"] != 1 || dry.Left != 2 {
		t.Fatalf("dry = %+v", dry)
	}
	wantEverywhere(t, st, ended, "accepted/") // dry wrote nothing
	app, err := st.ReconcileTaskStates("operator", before, true, now)
	if err != nil {
		t.Fatal(err)
	}
	if app.Ended != dry.Ended || app.Cancelled != dry.Cancelled || app.Left != dry.Left {
		t.Fatalf("apply %+v differs from its dry run %+v", app, dry)
	}
	wantEverywhere(t, st, ended, "succeeded/succeeded")
	if got, _ := st.FleetTask(ended.ID); got.PR != "o/r#1" {
		t.Fatalf("backfilled pr = %q", got.PR)
	}
	wantEverywhere(t, st, dead, "cancelled/cancelled")
	wantEverywhere(t, st, alive, "placing/")
	wantEverywhere(t, st, recent, "placing/")
	// idempotent
	again, err := st.ReconcileTaskStates("operator", before, true, now)
	if err != nil || again.Ended != 0 || again.Cancelled != 0 || again.Unfinished != 2 {
		t.Fatalf("second run = %+v %v", again, err)
	}
	// and undoable
	if n, err := st.UndoReconcileCancel("operator", now); err != nil || n != 1 {
		t.Fatalf("undo = %d %v", n, err)
	}
	wantEverywhere(t, st, dead, "placing/")
}
