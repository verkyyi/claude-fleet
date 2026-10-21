package store_test

import (
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/hub/store/storetest"
)

// A4G2: a record ends when its session ends — the ID closing with no result
// cancels it (結束·没交回结果), the same ID going on puts it back, a later result
// still wins, and the sweep catches what closed before and what never started.
func TestTaskEndsWhenItsSessionCloses(t *testing.T) {
	st := storetest.OpenFleet(t)
	rec := newV1Task(t, st, "close", "")
	if _, err := push(t, st, "ep1", rec.FID, ledger(t,
		`{"ev":"opened","agent":"claude","id":"`+rec.FID+`","seq":1,"ts":1000}`,
		`{"ev":"result","state":"waiting","id":"`+rec.FID+`","seq":2,"ts":1001}`)); err != nil {
		t.Fatal(err)
	}
	wantEverywhere(t, st, rec, "accepted/")
	if _, err := push(t, st, "ep1", rec.FID, ledger(t,
		`{"ev":"closed","reason":"reaped","id":"`+rec.FID+`","seq":3,"ts":1002}`)); err != nil {
		t.Fatal(err)
	}
	wantEverywhere(t, st, rec, "cancelled/cancelled")
	got, _ := st.FleetTask(rec.ID)
	if got.Evidence != store.TaskEndedNoResult+"（reaped）" || got.Observation != store.ObsIDClosed+rec.FID+":accepted" {
		t.Fatalf("ended record = evidence %q observation %q", got.Evidence, got.Observation)
	}
	// the same ID goes on: the record is open again, as it was
	if _, err := push(t, st, "ep1", rec.FID, ledger(t,
		`{"ev":"reopened","window":"@9","id":"`+rec.FID+`","seq":4,"ts":1003}`)); err != nil {
		t.Fatal(err)
	}
	wantEverywhere(t, st, rec, "accepted/")
	if got, _ := st.FleetTask(rec.ID); got.Evidence != "" || got.Observation != "" {
		t.Fatalf("reopened record = evidence %q observation %q", got.Evidence, got.Observation)
	}
	// closed again, then a late result: the result wins
	if _, err := push(t, st, "ep1", rec.FID, ledger(t,
		`{"ev":"closed","reason":"reaped","id":"`+rec.FID+`","seq":5,"ts":1004}`,
		`{"ev":"result","state":"merged","pr":"o/r#5","id":"`+rec.FID+`","seq":6,"ts":1005}`)); err != nil {
		t.Fatal(err)
	}
	wantEverywhere(t, st, rec, "succeeded/succeeded")
	if got, _ := st.FleetTask(rec.ID); got.Evidence != "" || got.PR != "o/r#5" {
		t.Fatalf("result after close = evidence %q pr %q", got.Evidence, got.PR)
	}

	// a result before the close: the close changes nothing
	done := newV1Task(t, st, "done", "")
	if _, err := push(t, st, "ep1", done.FID, ledger(t,
		`{"ev":"opened","agent":"claude","id":"`+done.FID+`","seq":1,"ts":2000}`,
		`{"ev":"result","state":"failed","id":"`+done.FID+`","seq":2,"ts":2001}`,
		`{"ev":"closed","reason":"reaped","id":"`+done.FID+`","seq":3,"ts":2002}`)); err != nil {
		t.Fatal(err)
	}
	wantEverywhere(t, st, done, "failed/failed")

	// an old record is never ended off an ID
	leg := newLegacyTask(t, st, "operator", "legacy")
	lw := "0b7e8c1a-1111-4222-8333-444455556699"
	if _, err := push(t, st, "ep1", lw, ledger(t,
		`{"ev":"opened","agent":"claude","task":"`+leg.Ref+`","id":"`+lw+`","seq":1,"ts":3000}`,
		`{"ev":"closed","reason":"reaped","id":"`+lw+`","seq":2,"ts":3001}`)); err != nil {
		t.Fatal(err)
	}
	wantEverywhere(t, st, leg, "placing/")
}

func TestSweepEndsWhatIsOver(t *testing.T) {
	st := storetest.OpenFleet(t)
	db := st.DB()
	now := time.Now()
	// closed before the write-through existed (its row never heard)
	before := newV1Task(t, st, "before", "")
	if _, err := push(t, st, "ep1", before.FID, ledger(t,
		`{"ev":"opened","agent":"claude","id":"`+before.FID+`","seq":1,"ts":1000}`,
		`{"ev":"closed","reason":"exited","id":"`+before.FID+`","seq":2,"ts":1001}`)); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`UPDATE fleet_tasks SET state = 'accepted', outcome = '', evidence = '', observation = '' WHERE id = ?`, before.ID); err != nil {
		t.Fatal(err)
	}
	// still running
	running := newV1Task(t, st, "running", "")
	if _, err := push(t, st, "ep1", running.FID, ledger(t,
		`{"ev":"opened","agent":"claude","id":"`+running.FID+`","seq":1,"ts":1100}`)); err != nil {
		t.Fatal(err)
	}
	// never came up: one fresh, one two days old
	fresh := newV1Task(t, st, "fresh", "")
	stale := newV1Task(t, st, "stale", "")
	if _, err := db.Exec(`UPDATE fleet_tasks SET created_at = ? WHERE id = ?`,
		now.Add(-48*time.Hour).UTC().Format(time.RFC3339Nano), stale.ID); err != nil {
		t.Fatal(err)
	}
	dry, err := st.ReconcileClosedTasks("operator", false, now)
	if err != nil {
		t.Fatal(err)
	}
	if dry.Unfinished != 4 || dry.Closed != 1 || dry.NeverStarted != 1 {
		t.Fatalf("dry = %+v", dry)
	}
	wantEverywhere(t, st, before, "accepted/")
	if _, err := st.ReconcileClosedTasks("operator", true, now); err != nil {
		t.Fatal(err)
	}
	wantEverywhere(t, st, before, "cancelled/cancelled")
	wantEverywhere(t, st, running, "accepted/")
	wantEverywhere(t, st, fresh, "accepted/")
	wantEverywhere(t, st, stale, "cancelled/cancelled")
	again, err := st.ReconcileClosedTasks("operator", true, now)
	if err != nil || again.Closed != 0 || again.NeverStarted != 0 || again.Unfinished != 2 {
		t.Fatalf("second sweep = %+v %v", again, err)
	}
}
