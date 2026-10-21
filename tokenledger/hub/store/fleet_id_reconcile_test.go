package store_test

import (
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/hub/store/storetest"
)

const (
	idC = "4fa85f64-5717-4562-b3fc-2c963f66afa6"
	idD = "5fa85f64-5717-4562-b3fc-2c963f66afa6"
)

func openLedger(t *testing.T, id, title string) []map[string]any {
	return ledger(t, `{"ev":"opened","agent":"claude","window":"@3","title":"`+title+`","id":"`+id+`","seq":1,"ts":1000}`)
}

// BCYB: a node's live list closes the endpoint's absent open IDs (a probe's as
// hub:probe), leaves the live, the young and another endpoint's alone, and a
// later list naming a hub-closed ID reopens it; a node's own close wins.
func TestFleetIDReconcile(t *testing.T) {
	st := storetest.OpenFleet(t)
	for id, title := range map[string]string{idA: "real work", idB: "T672 放置演示 A1（空会话，可关）", idC: "kept"} {
		if _, err := push(t, st, "e1", id, openLedger(t, id, title)); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := push(t, st, "e2", idD, openLedger(t, idD, "other machine")); err != nil {
		t.Fatal(err)
	}
	now := time.Now().Add(time.Hour)
	dry, err := st.ReconcileFleetIDs("operator", "e1", []string{idC}, now, store.IDLiveGrace, false)
	if err != nil || len(dry.Closed) != 2 || dry.Kept != 1 {
		t.Fatalf("dry = %+v %v", dry, err)
	}
	if a, _ := st.FleetIDOf("operator", idA); a.ClosedAt != 0 {
		t.Fatalf("a dry run wrote: %+v", a)
	}
	// within the grace nothing closes (a window just spawned)
	if got, _ := st.ReconcileFleetIDs("operator", "e1", []string{idC}, time.Now(), store.IDLiveGrace, true); len(got.Closed) != 0 {
		t.Fatalf("young closed: %+v", got)
	}
	got, err := st.ReconcileFleetIDs("operator", "e1", []string{idC}, now, store.IDLiveGrace, true)
	if err != nil || len(got.Closed) != 2 {
		t.Fatalf("apply = %+v %v", got, err)
	}
	a, _ := st.FleetIDOf("operator", idA)
	b, _ := st.FleetIDOf("operator", idB)
	c, _ := st.FleetIDOf("operator", idC)
	d, _ := st.FleetIDOf("operator", idD)
	if a.CloseReason != "hub:gone" || b.CloseReason != "hub:probe" || c.ClosedAt != 0 || d.ClosedAt != 0 {
		t.Fatalf("after = %+v / %+v / %+v / %+v", a, b, c, d)
	}
	open, _ := st.FleetIDOpenCount("operator")
	if open["m-e1"] != 1 || open["m-e2"] != 1 {
		t.Fatalf("open = %v", open)
	}
	// seen again: reopened
	got, _ = st.ReconcileFleetIDs("operator", "e1", []string{idA, idC}, now, store.IDLiveGrace, true)
	if a, _ = st.FleetIDOf("operator", idA); len(got.Reopened) != 1 || a.ClosedAt != 0 {
		t.Fatalf("reopen = %+v %+v", got, a)
	}
	// the node's own close replaces the hub's
	if _, err := push(t, st, "e1", idB, ledger(t, `{"ev":"closed","reason":"reaped","id":"`+idB+`","seq":2,"ts":2000}`)); err != nil {
		t.Fatal(err)
	}
	if b, _ = st.FleetIDOf("operator", idB); b.CloseReason != "reaped" {
		t.Fatalf("node close = %+v", b)
	}
	// never reopened by the hub once the node closed it
	if got, _ = st.ReconcileFleetIDs("operator", "e1", []string{idA, idB, idC}, now, store.IDLiveGrace, true); len(got.Reopened) != 0 {
		t.Fatalf("node close reopened: %+v", got)
	}
}

// BCYB: a task's reserved ID no window took closes once its task has ended
// (hub:task-over), never while it runs; a machine taking it after all clears it.
func TestFleetIDReconcileReserved(t *testing.T) {
	st := storetest.OpenFleet(t)
	now := time.Now()
	run, err := st.CreateFleetTask(store.FleetTask{Owner: "operator", Title: "running"}, "tok-run", now)
	if err != nil {
		t.Fatal(err)
	}
	done, err := st.CreateFleetTask(store.FleetTask{Owner: "operator", Title: "done"}, "tok-done", now)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := st.UpdateFleetTask(done.ID, store.FleetTaskUpdate{State: store.TaskSucceeded}, now); err != nil {
		t.Fatal(err)
	}
	later := now.Add(time.Hour)
	got, err := st.ReconcileFleetIDs("operator", "e1", []string{}, later, store.IDLiveGrace, true)
	if err != nil || len(got.Closed) != 1 || got.Closed[0].ID != done.FID || got.Closed[0].Reason != "hub:task-over" {
		t.Fatalf("reserved = %+v %v", got, err)
	}
	if r, _ := st.FleetIDOf("operator", run.FID); r.ClosedAt != 0 {
		t.Fatalf("a running task's ID closed: %+v", r)
	}
	if _, err := push(t, st, "e1", done.FID, openLedger(t, done.FID, "done")); err != nil {
		t.Fatal(err)
	}
	if r, _ := st.FleetIDOf("operator", done.FID); r.ClosedAt != 0 {
		t.Fatalf("taken after all, still closed: %+v", r)
	}
}
