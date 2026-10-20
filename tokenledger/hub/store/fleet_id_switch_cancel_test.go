package store_test

import (
	"errors"
	"fmt"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/hub/store/storetest"
)

// A record nobody ever claimed and no open ID carries is closed by a person's
// cancel (EPIC T497 C13, the one change C8 keeps) — the dead record of a dispatch
// whose window never opened, or whose window is gone without a result; one a
// pre-C8 launch proof claimed, or with a live window, stays refused. And the
// migration lists only the old records: one written after the switch, or never
// claimed but carried by an ID, is the ID world's.
func TestIDSwitchCancelsDeadRecords(t *testing.T) {
	st := storetest.OpenFleet(t)
	now := time.Now()
	before := now.Add(-time.Minute)
	mk := func(token string, at time.Time) store.FleetTask {
		t.Helper()
		rec, err := st.CreateFleetTask(store.FleetTask{Owner: "alice", Title: token, AuthorityVersion: store.TaskAuthorityVersion,
			RequestedAgent: "claude", ResolvedAgent: "claude", RequestPayload: `{"body":"` + token + `"}`}, "tok:"+token, at)
		if err != nil {
			t.Fatal(err)
		}
		return rec
	}
	push := func(id string, lines ...string) {
		t.Helper()
		if _, err := st.ApplyFleetIDEvents(store.FleetIDPush{Owner: "alice", EndpointID: "ep1", Machine: "mac-a", Login: "alice", ID: id,
			Events: ledger(t, lines...)}); err != nil {
			t.Fatal(err)
		}
	}
	noID := mk("never-opened", before)
	gone := mk("window-gone", before)
	live := mk("window-live", before)
	ended := mk("ended-on-id", before)
	owned := mk("claimed", before)
	push(fid351, `{"ev":"opened","agent":"claude","task":"`+gone.Ref+`","id":"`+fid351+`","seq":1,"ts":1}`,
		`{"ev":"closed","reason":"recycled","id":"`+fid351+`","seq":2,"ts":2}`)
	push(fid354, `{"ev":"opened","agent":"claude","task":"`+live.Ref+`","id":"`+fid354+`","seq":1,"ts":1}`)
	push(fid355, `{"ev":"opened","agent":"claude","task":"`+ended.Ref+`","id":"`+fid355+`","seq":1,"ts":1}`,
		`{"ev":"result","state":"merged","pr":"5030","id":"`+fid355+`","seq":2,"ts":2}`,
		`{"ev":"closed","reason":"merged","id":"`+fid355+`","seq":3,"ts":3}`)
	// a pre-C8 claim: the archived executor a launch proof wrote
	if _, err := st.DB().Exec(fmt.Sprintf(`UPDATE fleet_tasks SET state = 'starting', execution_owner = '%s', worker_id = '%s' WHERE id = %d`,
		migFleet+"/"+fid364, migFleet+"/"+fid364, owned.ID)); err != nil {
		t.Fatal(err)
	}
	owned, _ = st.FleetTask(owned.ID)
	if err := st.SetIDSwitch(true, now); err != nil {
		t.Fatal(err)
	}
	after := mk("after-switch", now.Add(time.Minute))

	cancel := func(rec store.FleetTask, _ string) (store.FleetTask, error) {
		return st.CancelUnopenedTask(rec.ID, "alice", "explicit cancel request; no window ever opened it", now)
	}
	for _, rec := range []store.FleetTask{noID, gone} {
		got, err := cancel(rec, "cancel")
		if err != nil || got.State != store.TaskCancelled || got.Outcome != store.TaskCancelled {
			t.Fatalf("%s (%s): cancel with the switch on = %s/%s %v; want cancelled", rec.Ref, rec.Title, got.State, got.Outcome, err)
		}
		if again, err := cancel(rec, "cancel"); err != nil || again.Outcome != store.TaskCancelled {
			t.Fatalf("%s: the same cancel again = %v; want the first answer", rec.Ref, err)
		}
	}
	if _, err := cancel(live, "cancel"); !errors.Is(err, store.ErrIDSwitch) {
		t.Fatalf("a record whose ID is open: cancel = %v; want ErrIDSwitch", err)
	}
	if _, err := cancel(ended, "cancel"); !errors.Is(err, store.ErrTaskConflict) {
		t.Fatalf("a record that ended on its ID: cancel = %v; want ErrTaskConflict", err)
	}
	if _, err := cancel(owned, "c3"); !errors.Is(err, store.ErrIDSwitch) {
		t.Fatalf("a pre-C8 claimed record: cancel = %v; want ErrIDSwitch", err)
	}
	if got, _ := st.FleetTask(owned.ID); got.Outcome != "" || got.ExecutionOwner == "" {
		t.Fatalf("the owned record moved: %+v", got)
	}

	cands, err := st.IDMigrateCandidates("", nil)
	if err != nil {
		t.Fatal(err)
	}
	listed := map[string]bool{}
	for _, c := range cands {
		listed[c.Ref] = true
	}
	if listed[after.Ref] || listed[live.Ref] || listed[gone.Ref] || listed[ended.Ref] {
		t.Fatalf("migration lists the ID world's records: %v", listed)
	}
	if !listed[noID.Ref] || !listed[owned.Ref] {
		t.Fatalf("migration dropped an old record: %v", listed)
	}
	if err := st.SetIDSwitch(false, now); err != nil {
		t.Fatal(err)
	}
	if cands, _ := st.IDMigrateCandidates("", nil); len(cands) != 3 {
		t.Fatalf("switch off: candidates = %d; want 3 (the never-opened, the claimed, the one written later)", len(cands))
	}
}
