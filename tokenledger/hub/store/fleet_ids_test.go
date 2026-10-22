package store_test

import (
	"encoding/json"
	"errors"
	"reflect"
	"testing"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/hub/store/storetest"
)

// The hub's ID mirror (EPIC T497 C2): S10 (an outage, then the backlog in
// order, no duplicate, no gap — and the same record as one replay of the
// ledger), S12 (two machines' codes share 5 characters: the later one grows,
// a 5-character code names both), S13 (a cloned machine's full ID is refused).

const (
	idA = "3fa85f64-5717-4562-b3fc-2c963f66afa6" // code FF1W357V… (old 7ym5ys2q…)
	idB = "3fa85f74-5717-4562-b3fc-2c963f66afa6" // code FF1W37ZV… (old 7ym5yx2q…) — the same first 5
)

// ledger is a node's ledger lines as bin/fleet_id.py writes them.
func ledger(t *testing.T, lines ...string) []map[string]any {
	t.Helper()
	out := []map[string]any{}
	for _, l := range lines {
		var ev map[string]any
		if err := json.Unmarshal([]byte(l), &ev); err != nil {
			t.Fatalf("%s: %v", l, err)
		}
		out = append(out, ev)
	}
	return out
}

func sampleLedger(t *testing.T, id string) []map[string]any {
	return ledger(t,
		`{"ev":"opened","agent":"claude","window":"@7","repo":"acme/app","title":"S10 work","key":"issue-12","task":"T500","short":"`+store.FleetIDCode(id)[:4]+`","id":"`+id+`","seq":1,"ts":1000}`,
		`{"ev":"native","agent":"claude","native":"4f1c","trigger":"startup","source":"startup","seg":1,"id":"`+id+`","seq":2,"ts":1001}`,
		`{"ev":"native","compact":true,"agent":"claude","native":"4f1c","seg":1,"id":"`+id+`","seq":3,"ts":1002}`,
		`{"ev":"native","agent":"claude","native":"9a77","trigger":"clear","source":"clear","seg":2,"id":"`+id+`","seq":4,"ts":1003}`,
		`{"ev":"result","state":"succeeded","summary":"done","pr":"4970","issues":["acme/app#13"],"id":"`+id+`","seq":5,"ts":1004}`,
		`{"ev":"result","state":"failed","summary":"redo","id":"`+id+`","seq":6,"ts":1005}`,
		`{"ev":"closed","reason":"reaped","id":"`+id+`","seq":7,"ts":1006}`,
	)
}

func push(t *testing.T, st *store.Store, ep, id string, evs []map[string]any) (store.FleetIDPushed, error) {
	t.Helper()
	return st.ApplyFleetIDEvents(store.FleetIDPush{Owner: "operator", EndpointID: ep, Machine: "m-" + ep, Login: "alice", ID: id, Events: evs})
}

func TestFleetIDCodeMatchesNode(t *testing.T) {
	// bin/fleet_id.py encode / legacy_encode, byte for byte (EPIC T497 C11).
	for id, want := range map[string][2]string{
		idA:                                    {"FF1W357VVZZV7PXXBTKMQ5MRR8", "7ym5ys2q2x2p5czw5jb3ysnfmr"},
		"00000000-0000-4000-8000-000000000000": {"A000000000P00P000000000000", "00000000010010000000000000"},
		"ffffffff-ffff-4fff-bfff-ffffffffffff": {"ZZZZZZZZZY3FZMZZZZZZZZZZZX", "zzzzzzzzzx7zzfzzzzzzzzzzzw"},
	} {
		if got := store.FleetIDCode(id); got != want[0] {
			t.Fatalf("code(%s) = %s; want %s", id, got, want[0])
		}
		if got := store.FleetIDLegacyCode(id); got != want[1] {
			t.Fatalf("legacy code(%s) = %s; want %s", id, got, want[1])
		}
	}
	// a code is never a number: its first character is a letter
	if store.NormIDCode("#ff1w") != "FF1W" || store.NormIDCode("kilo") != "K110" || store.NormIDCode("4539") != "" ||
		store.NormIDCode("FF1") != "" || store.NormIDCode("FFUW") != "" || store.NormIDCode("T-7ym5y") != "" {
		t.Fatal("NormIDCode")
	}
	if store.LegacyIDCode("T-7YM5Y") != "7ym5y" || store.LegacyIDCode("t-7ym") != "" || store.LegacyIDCode("T-7ym5u") != "" ||
		store.LegacyIDCode("7ym5y") != "" {
		t.Fatal("LegacyIDCode")
	}
}

// S10: three windows opened while the hub was away; the node pushes each
// ledger in pieces, resending what may already have landed. The hub ends with
// every event once, in order — the same record a single replay gives.
func TestFleetIDOutageBackfillIsReplay(t *testing.T) {
	st := storetest.OpenFleet(t)
	replay := storetest.OpenFleet(t)
	ids := []string{idA, "00000000-0000-4000-8000-000000000001", "ffffffff-ffff-4fff-bfff-fffffffffffe"}
	for _, id := range ids {
		evs := sampleLedger(t, id)
		// a gap first: the hub holds nothing, so seq 3.. is not applied
		if got, err := push(t, st, "e1", id, evs[2:4]); err != nil || got.Seq != 0 {
			t.Fatalf("gap push = %+v %v; want seq 0", got, err)
		}
		if got, err := push(t, st, "e1", id, evs[:3]); err != nil || got.Seq != 3 {
			t.Fatalf("first push = %+v %v", got, err)
		}
		// the answer was lost: the node resends from 1 with the rest
		if got, err := push(t, st, "e1", id, evs); err != nil || got.Seq != 7 {
			t.Fatalf("resend = %+v %v", got, err)
		}
		if got, err := push(t, st, "e1", id, evs[5:]); err != nil || got.Seq != 7 {
			t.Fatalf("resend of the tail = %+v %v", got, err)
		}
		if _, err := push(t, replay, "e1", id, evs); err != nil {
			t.Fatal(err)
		}
		a, err := st.FleetIDOf("operator", id)
		if err != nil {
			t.Fatal(err)
		}
		b, err := replay.FleetIDOf("operator", id)
		if err != nil {
			t.Fatal(err)
		}
		if !reflect.DeepEqual(a, b) {
			t.Fatalf("backfilled %+v\nreplayed   %+v", a, b)
		}
		if len(a.Natives) != 2 || a.Natives[0].Compactions != 1 || a.Natives[0].End != 1003 || a.Natives[1].Trigger != "clear" ||
			a.Natives[1].End != 1006 || len(a.Results) != 2 || a.Results[1].State != "failed" || a.ClosedAt != 1006 ||
			a.Title != "S10 work" || a.Agent != "claude" || a.Machine != "m-e1" || a.Seq != 7 ||
			!reflect.DeepEqual(a.Issues, []string{"acme/app#12", "acme/app#13"}) {
			t.Fatalf("record = %+v", a)
		}
	}
	list, err := st.FleetIDsOf("operator", "")
	if err != nil || len(list) != 3 {
		t.Fatalf("list = %v %v", list, err)
	}
}

// S12: two machines, offline, each opened a window whose code starts the same
// 5 characters. Both full IDs are kept; the one registered later grows to 6,
// and the 4-character code names both; the old `T-` code still resolves (compat-1v).
func TestFleetIDShortCollisionGrowsTheLater(t *testing.T) {
	st := storetest.OpenFleet(t)
	a, err := push(t, st, "e1", idA, sampleLedger(t, idA)[:2])
	if err != nil || a.Short != "FF1W" {
		t.Fatalf("A = %+v %v", a, err)
	}
	b, err := push(t, st, "e2", idB, sampleLedger(t, idB)[:2])
	if err != nil || b.Short != "FF1W37" {
		t.Fatalf("B = %+v %v; want FF1W37", b, err)
	}
	// the node writes the hub's code down: a `short` event is applied, never shortens
	if got, err := push(t, st, "e2", idB, ledger(t, `{"ev":"short","short":"FF1W3","id":"`+idB+`","seq":3,"ts":1}`)); err != nil || got.Short != "FF1W37" || got.Seq != 3 {
		t.Fatalf("short event = %+v %v", got, err)
	}
	if hits, _ := st.FleetIDsOf("operator", "FF1W"); len(hits) != 2 {
		t.Fatalf("4 characters name %v; want both", hits)
	}
	if hits, _ := st.FleetIDsOf("operator", "FF1W37"); len(hits) != 1 || hits[0].ID != idB {
		t.Fatalf("6 characters name %v; want B", hits)
	}
	if hits, _ := st.FleetIDsOf("operator", "T-7ym5y"); len(hits) != 2 {
		t.Fatalf("the old 5 name %v; want both", hits)
	}
	if hits, _ := st.FleetIDsOf("operator", "T-7ym5yx"); len(hits) != 1 || hits[0].ID != idB {
		t.Fatalf("the old 6 name %v; want B", hits)
	}
	// another owner's codes do not collide with this one's
	got, err := st.ApplyFleetIDEvents(store.FleetIDPush{Owner: "person:p", EndpointID: "e9", ID: "3fa85f64-5717-4562-b3fc-2c963f66afa7",
		Events: ledger(t, `{"ev":"opened","id":"3fa85f64-5717-4562-b3fc-2c963f66afa7","seq":1,"ts":1}`)})
	if err != nil || got.Short != "FF1W" {
		t.Fatalf("another owner = %+v %v", got, err)
	}
}

// C11 (EPIC T497): rows an older hub wrote (the ID's lowercase base32 in `code`,
// `7ym5y` in `short`) move onto today's display code at start — recomputed from the
// ID, oldest first, a collision lengthening the later — and the move is idempotent.
func TestFleetIDCodeBackfill(t *testing.T) {
	st := storetest.OpenFleet(t)
	for _, id := range []string{idA, idB} {
		if _, err := push(t, st, "e1", id, sampleLedger(t, id)[:2]); err != nil {
			t.Fatal(err)
		}
	}
	for id, short := range map[string]string{idA: "7ym5y", idB: "7ym5yx"} {
		if _, err := st.DB().Exec(`UPDATE fleet_ids SET code = ?, short = ? WHERE id = ?`, store.FleetIDLegacyCode(id), short, id); err != nil {
			t.Fatal(err)
		}
	}
	for i := 0; i < 2; i++ {
		if err := st.EnsureNodes(); err != nil {
			t.Fatal(err)
		}
		a, _ := st.FleetIDOf("operator", idA)
		b, _ := st.FleetIDOf("operator", idB)
		if a.Short != "FF1W" || b.Short != "FF1W37" {
			t.Fatalf("pass %d: shorts %q %q; want FF1W FF1W37", i, a.Short, b.Short)
		}
	}
	if hits, _ := st.FleetIDsOf("operator", "FF1W37"); len(hits) != 1 || hits[0].ID != idB {
		t.Fatalf("after the backfill FF1W37 names %v", hits)
	}
}

// S13: a cloned machine comes online carrying an ID the first already
// registered. The first keeps it; the clone is refused — whatever seq it is
// at — and a new window on it is not affected. A fleet-move's `moved` re-homes.
func TestFleetIDCloneRefused(t *testing.T) {
	st := storetest.OpenFleet(t)
	evs := sampleLedger(t, idA)
	if _, err := push(t, st, "e1", idA, evs[:4]); err != nil {
		t.Fatal(err)
	}
	for _, from := range [][]map[string]any{evs[:2], evs} {
		if _, err := push(t, st, "e2", idA, from); !errors.Is(err, store.ErrIDDuplicate) {
			t.Fatalf("clone push = %v; want ErrIDDuplicate", err)
		}
	}
	if rec, _ := st.FleetIDOf("operator", idA); rec.Seq != 4 || rec.Machine != "m-e1" {
		t.Fatalf("the clone changed the record: %+v", rec)
	}
	if _, err := st.ApplyFleetIDEvents(store.FleetIDPush{Owner: "person:x", EndpointID: "e3", ID: idA, Events: evs}); !errors.Is(err, store.ErrIDDuplicate) {
		t.Fatalf("another owner's push = %v; want ErrIDDuplicate", err)
	}
	if _, err := push(t, st, "e2", idB, sampleLedger(t, idB)); err != nil {
		t.Fatalf("a new window on the clone: %v", err)
	}
	moved := append(append([]map[string]any{}, evs[:4]...), ledger(t, `{"ev":"moved","id":"`+idA+`","seq":5,"ts":2000}`)...)
	got, err := push(t, st, "e2", idA, moved)
	if err != nil || got.Seq != 5 {
		t.Fatalf("moved = %+v %v", got, err)
	}
	if rec, _ := st.FleetIDOf("operator", idA); rec.Machine != "m-e2" || store.NormIDCode(rec.Short) != rec.Short {
		t.Fatalf("after the move = %+v", rec)
	}
	if _, err := push(t, st, "e1", idA, evs); !errors.Is(err, store.ErrIDDuplicate) {
		t.Fatalf("the old machine after the move = %v; want refused", err)
	}
}

// C4 (EPIC T497): 「恢复这个窗口」 reopens a closed ID in a new window — the
// mirror forgets the close, and a later close ends it again.
func TestFleetIDReopened(t *testing.T) {
	st := storetest.OpenFleet(t)
	evs := append(sampleLedger(t, idA), ledger(t,
		`{"ev":"reopened","window":"@9","id":"`+idA+`","seq":8,"ts":1010}`)...)
	if _, err := push(t, st, "e1", idA, evs); err != nil {
		t.Fatal(err)
	}
	a, err := st.FleetIDOf("operator", idA)
	if err != nil || a.ClosedAt != 0 || a.CloseReason != "" || a.Window != "@9" {
		t.Fatalf("reopened = %+v %v", a, err)
	}
	if _, err := push(t, st, "e1", idA, ledger(t, `{"ev":"closed","reason":"exited","id":"`+idA+`","seq":9,"ts":1020}`)); err != nil {
		t.Fatal(err)
	}
	if a, _ = st.FleetIDOf("operator", idA); a.ClosedAt != 1020 || a.CloseReason != "exited" {
		t.Fatalf("closed again = %+v", a)
	}
}

// C12: a `progress` event is the ID's newest progress word — kept on the record,
// never a result; a resend keeps the newest.
func TestFleetIDProgress(t *testing.T) {
	st := storetest.OpenFleet(t)
	evs := ledger(t,
		`{"ev":"opened","agent":"claude","title":"EPIC driver","id":"`+idA+`","seq":1,"ts":1000}`,
		`{"ev":"progress","state":"progress","summary":"tick 1 · 核心 3","id":"`+idA+`","seq":2,"ts":1001}`,
		`{"ev":"progress","state":"progress","summary":"tick 2 · report: pending","id":"`+idA+`","seq":3,"ts":1002}`)
	if _, err := push(t, st, "e1", idA, evs[:2]); err != nil {
		t.Fatal(err)
	}
	if _, err := push(t, st, "e1", idA, evs); err != nil {
		t.Fatal(err)
	}
	a, err := st.FleetIDOf("operator", idA)
	if err != nil || a.Progress == nil || a.Progress.Summary != "tick 2 · report: pending" || a.Progress.Seq != 3 ||
		a.Progress.At != 1002 || len(a.Results) != 0 {
		t.Fatalf("progress = %+v %v", a.Progress, err)
	}
	b, err := st.FleetIDOf("operator", idA)
	if err != nil || !reflect.DeepEqual(a, b) {
		t.Fatalf("reread %+v %v", b, err)
	}
}

// Named events have their own semantics; opened stays first-value-wins.
func TestFleetIDNamedSurvivesCloseMoveAndReplay(t *testing.T) {
	st := storetest.OpenFleet(t)
	evs := ledger(t,
		`{"ev":"opened","seq":1,"ts":100,"title":"initial"}`,
		`{"ev":"named","seq":2,"ts":101,"title":"automatic","source":"auto"}`,
		`{"ev":"named","seq":3,"ts":102,"title":"chosen","source":"manual"}`,
		`{"ev":"named","seq":4,"ts":99,"title":"late auto","source":"auto"}`,
		`{"ev":"closed","seq":5,"ts":105,"reason":"reaped"}`)
	for _, e := range evs {
		if _, err := push(t, st, "e1", idA, []map[string]any{e}); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := push(t, st, "e1", idA, evs); err != nil {
		t.Fatal(err)
	}
	r, err := st.FleetIDOf("operator", idA)
	if err != nil || r.Title != "chosen" || r.ClosedAt != 105 {
		t.Fatalf("named close: %+v %v", r, err)
	}
	moved := ledger(t, `{"ev":"moved","seq":6,"ts":106}`, `{"ev":"reopened","seq":7,"ts":107}`, `{"ev":"named","seq":8,"ts":108,"title":"new manual","source":"manual"}`)
	if _, err := push(t, st, "e2", idA, moved); err != nil {
		t.Fatal(err)
	}
	r, err = st.FleetIDOf("operator", idA)
	if err != nil || r.Title != "new manual" || r.ClosedAt != 0 {
		t.Fatalf("move: %+v %v", r, err)
	}
	if _, err := st.ApplyFleetIDEvents(store.FleetIDPush{Owner: "other", EndpointID: "e2", ID: idA, Events: ledger(t, `{"ev":"named","seq":9,"title":"stolen","source":"manual"}`)}); !errors.Is(err, store.ErrIDDuplicate) {
		t.Fatalf("owner: %v", err)
	}
	if _, err := push(t, st, "e2", idA, ledger(t, `{"ev":"named","seq":9,"id":"`+idB+`","title":"wrong identity","source":"manual"}`)); err == nil {
		t.Fatal("accepted another FID")
	}
}
