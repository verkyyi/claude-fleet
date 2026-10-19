package store_test

import (
	"errors"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/hub/store/storetest"
)

// The migration's rule (EPIC T497 C6, design page §5): the sample table, row by
// row, as the hub held those records on 2026-10-19 — and the counter-example, a
// machine that does not answer moves none of its records.
const (
	migFleet = "42f8e358-7cc0-5856-a353-8983a4b4c9a1"
	fid351   = "86a316d7-8917-4bb2-a7ec-f0a91c89a298"
	fid354   = "81c7af71-9695-4396-bfc1-9697b64d822d"
	fid355   = "851422c7-6d77-4eb4-954a-b6a4092d6a08"
	fid364   = "881cc321-da65-4365-9bd3-06dea5068d00"
	fid478   = "2885d869-5948-4273-9d00-48d861e5a946"
	fid488   = "2a3d60d7-b6e1-4736-a744-46232728cd3c"
	fid489   = "7c723d7e-b7ff-4aec-9f85-80af0ad05e36"
)

func sampleRecords() []store.FleetTask {
	v1 := func(ref, state, outcome, agent, fid, cancel string) store.FleetTask {
		t := store.FleetTask{Ref: ref, Owner: "operator", State: state, Outcome: outcome, Agent: agent,
			AuthorityVersion: 1, CancelRequest: cancel}
		if fid != "" {
			t.WorkerID, t.ExecutionOwner = migFleet+"/"+fid, migFleet+"/"+fid
		}
		return t
	}
	return []store.FleetTask{
		v1("T351", "starting", "", "codex", fid351, "codex-4972-T351"),
		v1("T354", "starting", "", "codex", fid354, "codex-4972-T354"),
		v1("T355", "starting", "", "codex", fid355, "codex-4972-T355"),
		v1("T364", "starting", "", "codex", fid364, "codex-4972-T364"),
		v1("T478", "succeeded", "succeeded", "claude", fid478, ""),
		v1("T489", "succeeded", "succeeded", "codex", fid489, ""),
		v1("T480", "cancelled", "cancelled", "claude", "", ""),
		v1("T488", "running", "", "claude", fid488, ""),
	}
}

func TestIDMigrateSampleTable(t *testing.T) {
	// The machine answers: tmux up, and only T488's window carries its @fleet_id.
	answer := &store.IDPresence{Answered: true, Windows: map[string]string{fid488: "fleet:@12", "issue-9": "fleet:@3"},
		Evidence: "mini2/verky · fleet fleet tmux 正常 · 17 个窗口"}
	want := map[string][2]string{
		"T351": {store.IDMigCancelled, "已取消、已关闭"},
		"T354": {store.IDMigCancelled, "已取消、已关闭"},
		"T355": {store.IDMigCancelled, "已取消、已关闭"},
		"T364": {store.IDMigCancelled, "已取消、已关闭"},
		"T478": {store.IDMigSucceeded, "已完成、已关闭"},
		"T489": {store.IDMigSucceeded, "已完成、已关闭"},
		"T480": {store.IDMigCancelled, "已取消、已关闭"},
		"T488": {store.IDMigLive, "活着"},
	}
	for _, rec := range sampleRecords() {
		it := store.ClassifyIDMigration(rec, answer)
		if w := want[rec.Ref]; it.Verdict != w[0] || it.Label != w[1] {
			t.Errorf("%s (%s) → %s %q; want %s %q", rec.Ref, it.Before, it.Verdict, it.Label, w[0], w[1])
		}
		if it.Evidence == "" {
			t.Errorf("%s has no evidence", rec.Ref)
		}
	}
	live := store.ClassifyIDMigration(sampleRecords()[7], answer)
	if live.ID != fid488 || live.Short != "T-"+store.FleetIDCode(fid488)[:5] {
		t.Fatalf("T488 → %+v; want its own @fleet_id and its short code", live)
	}
	// Today T488's record says succeeded while its window still runs: alive, the
	// result copied beside it — never closed under a live window.
	done := sampleRecords()[7]
	done.State, done.Outcome = "succeeded", "succeeded"
	if it := store.ClassifyIDMigration(done, answer); it.Verdict != store.IDMigLive || it.Result != store.IDMigSucceeded {
		t.Fatalf("a terminal record whose window lives → %+v; want live with the result", it)
	}

	// The counter-example: the machine is silent (or its tmux is down) — every
	// record that names a worker there waits, ended or not; T480 names none.
	for _, silent := range []*store.IDPresence{nil, {Evidence: "mini2/verky 没有回答（TIMEOUT）"}} {
		for _, rec := range sampleRecords() {
			it := store.ClassifyIDMigration(rec, silent)
			if rec.Ref == "T480" {
				if it.Verdict != store.IDMigCancelled {
					t.Fatalf("T480 (no worker) → %s; want cancelled off the record alone", it.Verdict)
				}
				continue
			}
			if it.Verdict != store.IDMigWait || it.Label != "等节点回答（不迁）" {
				t.Fatalf("%s with a silent machine → %s %q; want wait", rec.Ref, it.Verdict, it.Label)
			}
		}
	}
	// Never claimed, not ended: closed as never started. A machine that no longer
	// runs the fleet at all is an answer: the window is not there.
	if it := store.ClassifyIDMigration(store.FleetTask{Ref: "T9", State: "accepted", AuthorityVersion: 1}, nil); it.Verdict != store.IDMigNotStarted {
		t.Fatalf("never claimed → %s", it.Verdict)
	}
	gone := &store.IDPresence{Answered: true, Gone: true, Evidence: "fleet 不在"}
	if it := store.ClassifyIDMigration(sampleRecords()[7], gone); it.Verdict != store.IDMigExited {
		t.Fatalf("fleet gone → %s; want exited", it.Verdict)
	}
}

// Apply writes once, audited, only where the record had no end; the switch flips
// both ways and the execution authority follows it.
func TestIDMigrateApplyAndSwitch(t *testing.T) {
	st := storetest.OpenFleet(t)
	now := time.Now()
	mk := func(token, worker, state string) store.FleetTask {
		t.Helper()
		rec, err := st.CreateFleetTask(store.FleetTask{Owner: "operator", Title: token, WorkerID: worker, State: state}, "tok:"+token, now)
		if err != nil {
			t.Fatal(err)
		}
		return rec
	}
	gone := mk("gone", migFleet+"/"+fid351, "open")
	alive := mk("alive", migFleet+"/"+fid488, "open")
	waits := mk("waits", "11111111-1111-4111-8111-111111111111/"+fid354, "open")
	never := mk("never", "", "placing")
	if _, err := st.ApplyFleetIDEvents(store.FleetIDPush{Owner: "operator", EndpointID: "ep1", Machine: "mini2", Login: "verky", ID: fid488,
		Events: ledger(t, `{"ev":"opened","agent":"claude","title":"T488","id":"`+fid488+`","seq":1,"ts":1}`)}); err != nil {
		t.Fatal(err)
	}
	cands, err := st.IDMigrateCandidates("", nil)
	if err != nil || len(cands) != 4 {
		t.Fatalf("candidates = %d %v; want 4", len(cands), err)
	}
	pres := map[string]*store.IDPresence{migFleet: {Answered: true, Windows: map[string]string{fid488: "fleet:@12"}, Evidence: "ok"}}
	verdict := map[string]string{}
	for _, c := range cands {
		f, _ := store.IDMigWorker(c)
		it := store.ClassifyIDMigration(c, pres[f])
		verdict[c.Ref] = it.Verdict
		if it.Verdict == store.IDMigWait {
			if err := st.ApplyIDMigration(c, it, "test", now); !errors.Is(err, store.ErrTaskConflict) {
				t.Fatalf("a wait applied: %v", err)
			}
			continue
		}
		if err := st.ApplyIDMigration(c, it, "test", now); err != nil {
			t.Fatalf("%s: %v", c.Ref, err)
		}
		if err := st.ApplyIDMigration(c, it, "test", now); !errors.Is(err, store.ErrTaskConflict) {
			t.Fatalf("%s applied twice: %v", c.Ref, err)
		}
	}
	if verdict[gone.Ref] != store.IDMigExited || verdict[alive.Ref] != store.IDMigLive ||
		verdict[waits.Ref] != store.IDMigWait || verdict[never.Ref] != store.IDMigNotStarted {
		t.Fatalf("verdicts = %v", verdict)
	}
	if g, _ := st.FleetTask(store.ParseTaskRef(gone.Ref)); g.State != store.TaskClosed || g.Outcome != store.IDMigExited {
		t.Fatalf("exited record = %s/%s", g.State, g.Outcome)
	}
	if a, _ := st.FleetTask(store.ParseTaskRef(alive.Ref)); a.State != "open" || a.Outcome != "" {
		t.Fatalf("a live record was ended: %s/%s", a.State, a.Outcome)
	}
	if w, _ := st.FleetTask(store.ParseTaskRef(waits.Ref)); w.State != "open" {
		t.Fatalf("a waiting record moved: %s", w.State)
	}
	if v, _ := st.IDMigrated(alive.Ref); v != store.IDMigLive {
		t.Fatalf("audit row of %s = %q", alive.Ref, v)
	}
	rec, err := st.FleetIDOf("operator", fid488)
	if err != nil || len(rec.Aliases) != 1 || rec.Aliases[0] != alive.Ref {
		t.Fatalf("the live ID's aliases = %v %v; want [%s]", rec.Aliases, err, alive.Ref)
	}
	if left, _ := st.IDMigrateCandidates("", nil); len(left) != 1 || left[0].Ref != waits.Ref {
		t.Fatalf("left after apply = %v; want only the waiting one", left)
	}

	// The switch, twice round: off by default, on refuses the execution
	// authority, off gives it back — and a record's end follows its ID.
	if st.IDSwitchOn() {
		t.Fatal("the switch is on before anyone turned it on")
	}
	m := store.TaskMutation{Key: "k1", Kind: "claim", Generation: 1, WorkerID: migFleet + "/" + fid355}
	for round := 0; round < 2; round++ {
		if err := st.SetIDSwitch(true, now); err != nil || !st.IDSwitchOn() {
			t.Fatalf("switch on: %v", err)
		}
		if _, err := st.MutateFleetTask(1, "operator", m, now); !errors.Is(err, store.ErrIDSwitch) {
			t.Fatalf("round %d: a claim with the switch on = %v; want ErrIDSwitch", round, err)
		}
		if _, err := st.RecordFleetTaskReport("operator", "ep1", store.TaskReport{Task: "T1"}, now); !errors.Is(err, store.ErrIDSwitch) {
			t.Fatalf("round %d: a fenced report with the switch on = %v", round, err)
		}
		if err := st.SetIDSwitch(false, now); err != nil || st.IDSwitchOn() {
			t.Fatalf("switch off: %v", err)
		}
		if _, err := st.MutateFleetTask(1, "operator", m, now); errors.Is(err, store.ErrIDSwitch) {
			t.Fatalf("round %d: the switch off still refuses", round)
		}
	}
	if out, id, err := st.IDTaskOutcome("operator", alive.Ref); err != nil || id != fid488 || out != "" {
		t.Fatalf("no result yet = %q %q %v", out, id, err)
	}
	if _, err := st.ApplyFleetIDEvents(store.FleetIDPush{Owner: "operator", EndpointID: "ep1", Machine: "mini2", Login: "verky", ID: fid488,
		Events: ledger(t, `{"ev":"result","state":"waiting","id":"`+fid488+`","seq":2,"ts":2}`,
			`{"ev":"result","state":"merged","pr":"4990","id":"`+fid488+`","seq":3,"ts":3}`)}); err != nil {
		t.Fatal(err)
	}
	if out, _, _ := st.IDTaskOutcome("operator", alive.Ref); out != store.TaskSucceeded {
		t.Fatalf("merged on the ID → %q; want succeeded", out)
	}
}
