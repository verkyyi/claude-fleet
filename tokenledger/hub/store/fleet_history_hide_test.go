package store_test

import (
	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/hub/store/storetest"
	"testing"
	"time"
)

func TestHistoryHideIsReversibleAndConservative(t *testing.T) {
	st := storetest.OpenFleet(t)
	now := time.Now()
	_, err := push(t, st, "a", idA, sampleLedger(t, idA))
	if err != nil {
		t.Fatal(err)
	}
	m := store.HistoryHideManifest{Owner: "operator", ID: idA, Seq: 7, Machine: "m-a", Login: "alice", CheckedAt: now.Unix(), Online: true, Complete: true, Natives: []string{"4f1c", "9a77"}, NativeEvidence: "absent_verified", Backups: "absent_verified", Inputs: "empty_verified", Evidence: "reviewed all placements and recovery copies"}
	hide := func(m store.HistoryHideManifest, apply bool) error {
		return st.HideHistory(m, "admin", false, apply, now, nil)
	}
	for _, change := range []func(*store.HistoryHideManifest){
		func(m *store.HistoryHideManifest) { m.Online = false }, func(m *store.HistoryHideManifest) { m.Complete = false },
		func(m *store.HistoryHideManifest) { m.Seq-- }, func(m *store.HistoryHideManifest) { m.Natives = nil },
		func(m *store.HistoryHideManifest) { m.Backups = "unknown" }, func(m *store.HistoryHideManifest) { m.Inputs = "queued" },
		func(m *store.HistoryHideManifest) { m.Owner = "other" }, func(m *store.HistoryHideManifest) { m.CheckedAt -= 301 },
	} {
		bad := m
		change(&bad)
		if hide(bad, true) == nil {
			t.Fatalf("accepted incomplete evidence: %+v", bad)
		}
	}
	if err := hide(m, false); err != nil {
		t.Fatal(err)
	}
	h, _ := st.HiddenHistory("operator", nil)
	if h[idA] {
		t.Fatal("dry run hid a row")
	}
	// An undecodable owner view cache prevents hiding; attribution is unknown.
	if err := st.PutChatMirrorOf("operator", "view:fleet/scratch-1", []byte("sealed"), now.Add(time.Hour), now); err != nil {
		t.Fatal(err)
	}
	if hide(m, true) == nil {
		t.Fatal("hid cached history")
	}
	if _, err := st.DB().Exec(`DELETE FROM hub_chat_mirrors`); err != nil {
		t.Fatal(err)
	}
	task, err := st.CreateFleetTask(store.FleetTask{Owner: "operator", Title: "pending input", AuthorityVersion: 1, RequestedAgent: "default", ResolvedAgent: "claude"}, "pending", now)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = st.DB().Exec(`UPDATE fleet_tasks SET worker_id=?,state='blocked',asked='unanswered' WHERE id=?`, "fleet/"+idA, task.ID); err != nil {
		t.Fatal(err)
	}
	if hide(m, true) == nil {
		t.Fatal("hid blocked backlog")
	}
	if _, err = st.DB().Exec(`UPDATE fleet_tasks SET worker_id='',fid='' WHERE id=?`, task.ID); err != nil {
		t.Fatal(err)
	}
	if err := st.InsertFleetOperation(store.FleetOperation{ID: "queued-input", FleetID: "fleet", Action: "worker_message", Request: `{"params":{"worker_id":"fleet/` + idA + `","text":"waiting"}}`, Actor: "operator", Idem: "queued-input", Status: "pending", Created: now, Updated: now}); err != nil {
		t.Fatal(err)
	}
	if hide(m, true) == nil {
		t.Fatal("hid queued input")
	}
	if err := st.UpdateFleetOperation("queued-input", "failed", "{}", now); err != nil {
		t.Fatal(err)
	}
	if err := hide(m, true); err != nil {
		t.Fatal(err)
	}
	h, _ = st.HiddenHistory("operator", nil)
	if !h[idA] {
		t.Fatal("apply did not hide")
	}
	other, _ := st.HiddenHistory("other", nil)
	if len(other) != 0 {
		t.Fatal("cross-owner hide")
	}
	rec, err := st.FleetIDOf("operator", idA)
	if err != nil || len(rec.Natives) != 2 || len(rec.Results) != 2 {
		t.Fatal("identity or recovery data lost")
	}
	if err := st.HideHistory(store.HistoryHideManifest{Owner: "operator", ID: idA}, "admin", true, true, now, nil); err != nil {
		t.Fatal(err)
	}
	h, _ = st.HiddenHistory("operator", nil)
	if h[idA] {
		t.Fatal("undo did not restore")
	}
	var audit int
	if err := st.DB().QueryRow(`SELECT COUNT(*) FROM fleet_history_hide_audit`).Scan(&audit); err != nil || audit != 2 {
		t.Fatalf("audit=%d err=%v", audit, err)
	}
	if err := hide(m, true); err != nil {
		t.Fatal(err)
	}
	_, err = push(t, st, "a", idA, ledger(t, `{"ev":"reopened","seq":8,"ts":2000}`))
	if err != nil {
		t.Fatal(err)
	}
	h, _ = st.HiddenHistory("operator", nil)
	if h[idA] {
		t.Fatal("reopened session remained hidden")
	}
}
