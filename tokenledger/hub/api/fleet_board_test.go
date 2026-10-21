package api

import (
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/hub/store/storetest"
)

// A4G2: the one session list. A record and the session doing it are one row
// (joined by the session's identity, the record's own ID — the record never
// learned a worker_id); groups, order and the count are the hub's.
func TestBoardOneRowPerTask(t *testing.T) {
	st := storetest.OpenFleet(t)
	s := &Server{Store: st}
	now := time.Now()
	v1 := func(token string) store.FleetTask {
		rec, err := st.CreateFleetTask(store.FleetTask{Owner: "gh:1", Title: "task " + token, AuthorityVersion: 1,
			RequestedAgent: "default", ResolvedAgent: "claude"}, token, now)
		if err != nil {
			t.Fatal(err)
		}
		return rec
	}
	pushID := func(id string, lines ...map[string]any) {
		if _, err := st.ApplyFleetIDEvents(store.FleetIDPush{Owner: "gh:1", EndpointID: "ep1", Machine: "mini2",
			Login: "verky", ID: id, Events: lines}); err != nil {
			t.Fatal(err)
		}
	}
	ev := func(kind, id string, seq int, more ...string) map[string]any {
		m := map[string]any{"ev": kind, "id": id, "seq": float64(seq), "ts": float64(now.Unix() - 100 + int64(seq))}
		for i := 0; i+1 < len(more); i += 2 {
			m[more[i]] = more[i+1]
		}
		return m
	}
	running, queued, exited, ended := v1("run"), v1("queue"), v1("exit"), v1("end")
	pushID(running.FID, ev("opened", running.FID, 1, "agent", "claude"))
	pushID(exited.FID, ev("opened", exited.FID, 1, "agent", "claude"))
	pushID(ended.FID, ev("opened", ended.FID, 1, "agent", "claude"), ev("closed", ended.FID, 2, "reason", "reaped"))
	plain := "0b7e8c1a-1111-4222-8333-444455556677" // a session with no record
	pushID(plain, ev("opened", plain, 1, "agent", "claude", "title", "my session"))

	fleet := "42f8e358-7cc0-5856-a353-8983a4b4c9a1"
	sess := func(ident, key, state string, born int64, extra map[string]any) FleetSession {
		wid := fleet + "/" + key
		w := map[string]any{"identity": ident, "key": key, "state": state, "name": key, "born": float64(born), "worker_id": wid}
		for k, v := range extra {
			w[k] = v
		}
		return FleetSession{WorkerID: &wid, MachineName: "mini2", OSUser: "verky", Availability: "online", Worker: w}
	}
	live := []FleetSession{
		sess(running.FID, "o-r:scratch-1", "working", 300, nil),
		sess(exited.FID, "o-r:scratch-2", "exited", 200, nil),
		sess(plain, "", "looping", 400, map[string]any{"pin": true}),
		sess("0b7e8c1a-1111-4222-8333-444455556688", "o-r:scratch-3", "done", 100, nil),
		sess("0b7e8c1a-1111-4222-8333-444455556689", "o-r:scratch-4", "working", 50, map[string]any{"test": true}),
	}
	b, err := s.buildBoard("gh:1", live, now)
	if err != nil {
		t.Fatal(err)
	}
	got := map[string]BoardRow{}
	var order []string
	for _, r := range b.Rows {
		if _, dup := got[r.ID]; dup {
			t.Fatalf("row %s twice", r.ID)
		}
		got[r.ID] = r
		order = append(order, r.Group+":"+r.Tag)
	}
	want := map[string][2]string{
		running.FID: {"work", "working"}, plain: {"pin", "looping"}, exited.FID: {"gone", "exited"},
		queued.FID: {"queue", "queued"}, ended.FID: {"gone", "ended_no_result"},
		"0b7e8c1a-1111-4222-8333-444455556688": {"queue", "turn_done"},
	}
	for id, w := range want {
		if r := got[id]; r.Group != w[0] || r.Tag != w[1] {
			t.Fatalf("row %s = %s/%s; want %s/%s (all: %v)", id, r.Group, r.Tag, w[0], w[1], order)
		}
	}
	if len(b.Rows) != len(want) {
		t.Fatalf("rows = %v; want %d (a test session is never listed)", order, len(want))
	}
	if r := got[running.FID]; r.Task != running.Ref || r.Title != "task run" || r.WorkerID != fleet+"/o-r:scratch-1" {
		t.Fatalf("the running task's row = %+v", r)
	}
	if b.Count != 4 || b.Groups["gone"] != 2 {
		t.Fatalf("count = %d groups = %v; want 4 counted (pin · work · 2 queue), 2 put away", b.Count, b.Groups)
	}
	if order[0] != "pin:looping" || order[1] != "work:working" || order[len(order)-1][:5] != "gone:" {
		t.Fatalf("order = %v", order)
	}
	// the same inputs, the same list (and digest)
	b2, _ := s.buildBoard("gh:1", live, now)
	if b2.Digest != b.Digest {
		t.Fatal("the digest is not stable")
	}
	// another owner's records never show
	if o, _ := s.buildBoard("gh:2", nil, now); len(o.Rows) != 0 {
		t.Fatalf("another owner's list = %+v", o.Rows)
	}
}
