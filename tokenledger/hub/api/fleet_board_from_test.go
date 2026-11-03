package api

import (
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/hub/store/storetest"
)

// Task PV5W: a session another session opened is drawn under it. The relation
// is the node's @from_fid (inventory `from`), else the record's
// request_payload.from_fid; it is checked against this person's own sessions,
// never nests a live row under an ended one, and orders a tree by its newest
// activity.
func TestBoardFromNests(t *testing.T) {
	st := storetest.OpenFleet(t)
	s := &Server{Store: st}
	now := time.Now()
	pushID := func(owner, id string, lines ...map[string]any) {
		if _, err := st.ApplyFleetIDEvents(store.FleetIDPush{Owner: owner, EndpointID: "ep1", Machine: "mac-b",
			Login: "alice", ID: id, Events: lines}); err != nil {
			t.Fatal(err)
		}
	}
	ev := func(kind, id string, seq int, more ...string) map[string]any {
		m := map[string]any{"ev": kind, "id": id, "seq": float64(seq), "ts": float64(now.Unix() - 1000 + int64(seq))}
		for i := 0; i+1 < len(more); i += 2 {
			m[more[i]] = more[i+1]
		}
		return m
	}
	const (
		parent  = "0b7e8c1a-2222-4222-8333-000000000001"
		child   = "0b7e8c1a-2222-4222-8333-000000000002"
		grand   = "0b7e8c1a-2222-4222-8333-000000000003"
		orphan  = "0b7e8c1a-2222-4222-8333-000000000004" // opened by a session that has ended
		ended   = "0b7e8c1a-2222-4222-8333-000000000005"
		foreign = "0b7e8c1a-2222-4222-8333-000000000006" // opened by another person's session
		theirs  = "0b7e8c1a-2222-4222-8333-000000000007"
		loopA   = "0b7e8c1a-2222-4222-8333-000000000008"
		loopB   = "0b7e8c1a-2222-4222-8333-000000000009"
		other   = "0b7e8c1a-2222-4222-8333-00000000000a"
	)
	pushID("gh:1", ended, ev("opened", ended, 1, "agent", "claude", "title", "支付调研"), ev("closed", ended, 2, "reason", "reaped"))
	pushID("gh:2", theirs, ev("opened", theirs, 1, "agent", "claude", "title", "not yours"))
	rec, err := st.CreateFleetTask(store.FleetTask{Owner: "gh:1", Title: "补测试", AuthorityVersion: 1,
		RequestedAgent: "default", ResolvedAgent: "claude", RequestPayload: `{"title":"补测试","from_fid":"` + parent + `"}`}, "rec", now)
	if err != nil {
		t.Fatal(err)
	}
	fleet := "42f8e358-7cc0-5856-a353-8983a4b4c9a1"
	sess := func(ident, state string, born, act int64, extra map[string]any) FleetSession {
		wid := fleet + "/" + ident
		w := map[string]any{"identity": ident, "state": state, "name": ident[len(ident)-2:], "born": float64(born),
			"activity_at": float64(act), "worker_id": wid}
		for k, v := range extra {
			w[k] = v
		}
		return FleetSession{WorkerID: &wid, MachineName: "mac-b", OSUser: "alice", Availability: "online", Worker: w}
	}
	n := now.Unix()
	live := []FleetSession{
		sess(parent, "done", n-500, n-400, map[string]any{"title": "重构计费模块"}),
		sess(child, "working", n-300, n-10, map[string]any{"from": parent}),
		sess(grand, "needs", n-200, n-5, map[string]any{"from": child}),
		sess(orphan, "working", n-300, n-50, map[string]any{"from": ended}),
		sess(foreign, "working", n-300, n-60, map[string]any{"from": theirs}),
		sess(loopA, "done", n-300, n-70, map[string]any{"from": loopB}),
		sess(loopB, "done", n-300, n-80, map[string]any{"from": loopA}),
		sess(other, "working", n-100, n-30, map[string]any{"from": "not-an-id"}),
	}
	b, err := s.buildBoard("gh:1", live, now)
	if err != nil {
		t.Fatal(err)
	}
	got, at := map[string]BoardRow{}, map[string]int{}
	for i, r := range b.Rows {
		got[r.ID], at[r.ID] = r, i
	}
	if len(b.Rows) != 10 {
		t.Fatalf("rows = %d; want every session, the record and the ended opener listed once: %+v", len(b.Rows), b.Rows)
	}
	// a live child under its live opener, whatever its own group; a record by its payload
	if r := got[child]; r.From != parent || r.Parent != parent || r.Depth != 1 || r.FromTitle != "重构计费模块" || r.FromEnded {
		t.Errorf("child = %+v", r)
	}
	if r := got[grand]; r.Parent != child || r.Depth != 2 || r.Group != "ask" {
		t.Errorf("grandchild = %+v", r)
	}
	if r := got[rec.FID]; r.From != parent || r.Parent != parent || r.Depth != 1 {
		t.Errorf("record = %+v", r)
	}
	// the subtree right under its root, the newest tree first among siblings (the
	// record was made just now, the child's tree last moved 5 s ago)
	if at[rec.FID] != at[parent]+1 || at[child] != at[rec.FID]+1 || at[grand] != at[child]+1 {
		t.Errorf("order: parent %d record %d child %d grand %d", at[parent], at[rec.FID], at[child], at[grand])
	}
	// the tree's activity is its newest row's
	if got[parent].TreeAt != got[rec.FID].TreeAt || got[child].TreeAt != n-5 || got[grand].TreeAt != n-5 || got[parent].ActivityAt != n-400 {
		t.Errorf("tree_at parent %d child %d grand %d record %d", got[parent].TreeAt, got[child].TreeAt, got[grand].TreeAt, got[rec.FID].TreeAt)
	}
	// an ended opener (listed in 已收起): named, never nested under
	if r := got[orphan]; r.From != ended || !r.FromEnded || r.FromTitle != "支付调研" || r.Parent != "" || r.Depth != 0 {
		t.Errorf("orphan = %+v", r)
	}
	// another person's session, or a word that is no ID: nothing
	for _, id := range []string{foreign, other} {
		if r := got[id]; r.From != "" || r.Parent != "" || r.Depth != 0 {
			t.Errorf("%s = %+v", id, r)
		}
	}
	// a loop of openers is cut where it closes: both rows listed, one nested
	if a, c := got[loopA], got[loopB]; (a.Parent == "") == (c.Parent == "") {
		t.Errorf("loop: a %+v b %+v", a, c)
	}
	if r := got[other]; r.TreeAt != n-30 {
		t.Errorf("a row with no children: tree_at %d; want its own activity %d", r.TreeAt, n-30)
	}
	// the operator's door (everyone's rows) draws no relation
	all, err := s.buildBoard("", live, now)
	if err != nil {
		t.Fatal(err)
	}
	for _, r := range all.Rows {
		if r.From != "" || r.Parent != "" {
			t.Errorf("operator's door row %s = %+v", r.ID, r)
		}
	}
}

// No relation anywhere: the list as before — no parent, depth or from; tree_at
// is each row's own activity.
func TestBoardFromNothingSaid(t *testing.T) {
	rows := []BoardRow{{ID: "a", Group: "work", At: 200, ActivityAt: 300}, {ID: "b", Group: "work", At: 100}}
	b := finishBoard(rows)
	for _, r := range b.Rows {
		if r.Parent != "" || r.Depth != 0 || r.From != "" || r.FromEnded {
			t.Errorf("row %s = %+v", r.ID, r)
		}
	}
	if b.Rows[0].ID != "a" || b.Rows[0].TreeAt != 300 || b.Rows[1].TreeAt != 100 {
		t.Errorf("rows = %+v", b.Rows)
	}
}

// A record from before from_fid names its caller by key in its dispatch
// request_id (`orch:<slug>:<key>:<hash>`): the one live session that held that
// key before the record was made is its opener; a key two live sessions answer
// to, or whose holder is younger than the record (a recycled scratch number),
// draws nothing.
func TestBoardFromByKey(t *testing.T) {
	st := storetest.OpenFleet(t)
	s := &Server{Store: st}
	now := time.Now()
	n := now.Unix()
	const (
		opener = "0b7e8c1a-3333-4222-8333-000000000001"
		young  = "0b7e8c1a-3333-4222-8333-000000000002" // holds scratch-9, born after the record
		twinA  = "0b7e8c1a-3333-4222-8333-000000000003"
		twinB  = "0b7e8c1a-3333-4222-8333-000000000004"
		byID   = "0b7e8c1a-3333-4222-8333-000000000005" // a keyless caller: its ID in the key
	)
	rec := func(token, title, key string) store.FleetTask {
		p := `{"title":"` + title + `","dispatch":{"request_id":"orch:` + key + `:6d6375550bb5d74e"}}`
		r, err := st.CreateFleetTask(store.FleetTask{Owner: "gh:1", Title: title, AuthorityVersion: 1,
			RequestedAgent: "default", ResolvedAgent: "claude", RequestPayload: p}, token, now)
		if err != nil {
			t.Fatal(err)
		}
		return r
	}
	viaKey := rec("a", "by key", "o-r:scratch-1")
	viaBare := rec("b", "bare key", "scratch-1")
	viaYoung := rec("c", "recycled", "o-r:scratch-9")
	viaTwin := rec("d", "twin", "o-r:scratch-5")
	viaID := rec("e", "by id", byID)
	viaHub := rec("f", "the person", "hub")
	fleet := "42f8e358-7cc0-5856-a353-8983a4b4c9a1"
	sess := func(ident, key string, born int64) FleetSession {
		wid := fleet + "/" + ident
		w := map[string]any{"identity": ident, "key": key, "state": "working", "name": key, "born": float64(born), "worker_id": wid}
		return FleetSession{WorkerID: &wid, MachineName: "mac-b", OSUser: "alice", Availability: "online", Worker: w}
	}
	live := []FleetSession{
		sess(opener, "o-r:scratch-1", n-600),
		sess(young, "o-r:scratch-9", n+60),
		sess(twinA, "o-r:scratch-5", n-600),
		sess(twinB, "o-r:scratch-5", n-300),
		sess(byID, "", n-600),
	}
	b, err := s.buildBoard("gh:1", live, now)
	if err != nil {
		t.Fatal(err)
	}
	got := map[string]BoardRow{}
	for _, r := range b.Rows {
		got[r.ID] = r
	}
	for id, want := range map[string]string{viaKey.FID: opener, viaBare.FID: opener, viaID.FID: byID,
		viaYoung.FID: "", viaTwin.FID: "", viaHub.FID: ""} {
		if r := got[id]; r.From != want || (want != "" && r.Parent != want) {
			t.Errorf("%s: from %q parent %q; want %q", r.Title, r.From, r.Parent, want)
		}
	}
	// the new from_fid wins over the key
	p := `{"from_fid":"` + twinA + `","dispatch":{"request_id":"orch:o-r:scratch-1:6d6375550bb5d74e"}}`
	both, err := st.CreateFleetTask(store.FleetTask{Owner: "gh:1", Title: "both", AuthorityVersion: 1,
		RequestedAgent: "default", ResolvedAgent: "claude", RequestPayload: p}, "g", now)
	if err != nil {
		t.Fatal(err)
	}
	b, _ = s.buildBoard("gh:1", live, now)
	for _, r := range b.Rows {
		if r.ID == both.FID && r.From != twinA {
			t.Errorf("from_fid and key: from %q; want %q", r.From, twinA)
		}
	}
}
