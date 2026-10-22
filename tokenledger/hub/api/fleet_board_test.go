package api

import (
	"strconv"
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
		if _, err := st.ApplyFleetIDEvents(store.FleetIDPush{Owner: "gh:1", EndpointID: "ep1", Machine: "mac-b",
			Login: "alice", ID: id, Events: lines}); err != nil {
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
	settled := v1("settled") // settled: state closed, an outcome word that is not an end
	if _, err := st.DB().Exec(`UPDATE fleet_tasks SET state = 'closed', outcome = 'exited' WHERE id = ?`, settled.ID); err != nil {
		t.Fatal(err)
	}
	failed := v1("fail") // a record that failed with no session left: put away, never 等你
	if _, err := st.DB().Exec(`UPDATE fleet_tasks SET state = 'failed', outcome = 'failed' WHERE id = ?`, failed.ID); err != nil {
		t.Fatal(err)
	}
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
		return FleetSession{WorkerID: &wid, MachineName: "mac-b", OSUser: "alice", Availability: "online", Worker: w}
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
		queued.FID: {"queue", "queued"}, ended.FID: {"gone", "ended_no_result"}, failed.FID: {"gone", "failed"}, settled.FID: {"gone", "ended"},
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
	if b.Count != 4 || b.Groups["gone"] != 4 {
		t.Fatalf("count = %d groups = %v; want 4 counted (pin · work · 2 queue), 4 put away", b.Count, b.Groups)
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

// T859: a machine lost past boardLostAfter puts its sessions away (gone · lost)
// instead of leaving them in 排队中; past boardGoneDays they are not listed. A
// machine lost a moment ago keeps its rows where they were.
func TestBoardLostMachineIsPutAway(t *testing.T) {
	st := storetest.OpenFleet(t)
	s := &Server{Store: st}
	now := time.Now()
	sess := func(key, state, avail string, heard time.Time) FleetSession {
		wid := "42f8e358-7cc0-5856-a353-8983a4b4c9a1/" + key
		w := map[string]any{"key": key, "state": state, "name": key, "worker_id": wid}
		return FleetSession{WorkerID: &wid, MachineName: "mac-b", OSUser: "drill1", Availability: avail,
			ObservedAt: heard, Worker: w}
	}
	live := []FleetSession{
		sess("scratch-1", "done", "lost", now.Add(-10*time.Minute)),   // a blip: stays
		sess("scratch-2", "done", "lost", now.Add(-8*time.Hour)),      // put away
		sess("scratch-3", "needs", "lost", now.Add(-2*24*time.Hour)),  // put away, asking or not
		sess("scratch-4", "done", "lost", now.Add(-9*24*time.Hour)),   // not listed
		sess("scratch-5", "done", "online", now.Add(-9*24*time.Hour)), // heard machine: as before
	}
	b, err := s.buildBoard("gh:1", live, now)
	if err != nil {
		t.Fatal(err)
	}
	got := map[string]string{}
	for _, r := range b.Rows {
		got[r.ID] = r.Group + ":" + r.Tag
	}
	p := "42f8e358-7cc0-5856-a353-8983a4b4c9a1/"
	want := map[string]string{p + "scratch-1": "queue:turn_done", p + "scratch-2": "gone:lost",
		p + "scratch-3": "gone:lost", p + "scratch-5": "queue:turn_done"}
	if len(got) != len(want) {
		t.Fatalf("rows = %v; want %v", got, want)
	}
	for id, w := range want {
		if got[id] != w {
			t.Fatalf("row %s = %s; want %s (all %v)", id, got[id], w, got)
		}
	}
	if b.Groups["queue"] != 2 || b.Groups["ask"] != 0 {
		t.Fatalf("groups = %v", b.Groups)
	}
}

// E101: a session that waits on you is 等你 even with its window up (its record
// asked, or the node says its ID's result waits); a parked record keeps its row
// in 等你 (a clock); a window its agent's error stopped is 等你 · 出错停住, never
// 已收起; each 等你 / 排队中 row carries the node's 「为什么还没收」 line — and a
// waiting row sits above a stopped one.
func TestBoardLiveAskedIsAsk(t *testing.T) {
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
	set := func(rec store.FleetTask, q string, args ...any) {
		if _, err := st.DB().Exec(q, append(args, rec.ID)...); err != nil {
			t.Fatal(err)
		}
	}
	asked, keep, stopped, parked, poster, busy := v1("asked"), v1("keep"), v1("stopped"), v1("parked"), v1("poster"), v1("busy")
	set(asked, `UPDATE fleet_tasks SET asked = ? WHERE id = ?`, "⛔ blocked: 请选一个 A / B")
	set(parked, `UPDATE fleet_tasks SET parked = ? WHERE id = ?`, "停放：等你回话满 4 小时")
	set(poster, `UPDATE fleet_tasks SET state = 'closed', outcome = 'succeeded' WHERE id = ?`)
	fleet := "42f8e358-7cc0-5856-a353-8983a4b4c9a1"
	sess := func(ident, key, state string, born int64, why string) FleetSession {
		wid := fleet + "/" + key
		w := map[string]any{"identity": ident, "key": key, "state": state, "name": key, "born": float64(born), "worker_id": wid}
		if why != "" {
			w["reap_why"] = why
		}
		return FleetSession{WorkerID: &wid, MachineName: "mac-b", OSUser: "alice", Availability: "online", Worker: w}
	}
	at := func(d time.Duration) string { return strconv.FormatInt(now.Add(d).Unix(), 10) }
	live := []FleetSession{
		sess(stopped.FID, "o-r:scratch-1", "exited", 900, "error-retry:"+at(4*time.Minute)),
		sess(asked.FID, "o-r:scratch-2", "done", 100, "waiting:"+at(3*time.Hour)),
		sess(keep.FID, "o-r:scratch-3", "done", 200, "waiting:"+at(90*time.Minute)),
		sess(poster.FID, "o-r:scratch-4", "looping", 300, "bg:"+at(18*time.Minute)),
		sess(busy.FID, "o-r:scratch-5", "working", 400, "timer:"+at(time.Minute)),
		sess("0b7e8c1a-1111-4222-8333-444455556699", "o-r:scratch-6", "exited", 500, ""),
	}
	b, err := s.buildBoard("gh:1", live, now)
	if err != nil {
		t.Fatal(err)
	}
	got := map[string]BoardRow{}
	var order []string
	for _, r := range b.Rows {
		got[r.ID] = r
		order = append(order, r.Group+":"+r.Tag)
	}
	want := map[string][3]string{
		asked.FID:                              {"ask", "waiting_you", "在等你回话 · 3 小时后停放，回话即唤醒"},
		keep.FID:                               {"ask", "waiting_you", "在等你回话 · 2 小时后停放，回话即唤醒"},
		parked.FID:                             {"ask", "parked", "已停放 · 在等你点头，回话即唤醒"},
		stopped.FID:                            {"ask", "stopped", "出错停住：服务端临时出错 · 4 分钟后自动重试"},
		poster.FID:                             {"queue", "completed", "还没收：做完了，后台的活还在跑 · 18 分钟后收"},
		busy.FID:                               {"work", "working", ""},
		"0b7e8c1a-1111-4222-8333-444455556699": {"gone", "exited", ""},
	}
	for id, w := range want {
		r := got[id]
		zh := ""
		if len(r.Why) == 2 {
			zh = r.Why[0]
		}
		if r.Group != w[0] || r.Tag != w[1] || zh != w[2] {
			t.Fatalf("row %s = %s/%s %q; want %s/%s %q (all %v)", id, r.Group, r.Tag, zh, w[0], w[1], w[2], order)
		}
	}
	if r := got[stopped.FID]; r.WhyTone != "red" || r.Why[1] != "Stopped on an error: a temporary server error · retrying in 4 min" {
		t.Fatalf("the stopped row = %+v", r)
	}
	if r := got[parked.FID]; r.WhyTone != "orange" || r.Words != [2]string{"已停放 · 等你", "Parked · waiting on you"} {
		t.Fatalf("the parked row = %+v", r)
	}
	// 等你: the waiting rows (newest first) and the parked one, then the stopped one
	if len(order) < 4 || order[3] != "ask:stopped" || order[0][:4] != "ask:" {
		t.Fatalf("order = %v", order)
	}
}

// E101's copy table, letter for letter: every code the node writes, both languages.
func TestBoardWhyCopy(t *testing.T) {
	now := time.Unix(1_800_000_000, 0)
	in := func(d time.Duration) string { return strconv.FormatInt(now.Add(d).Unix(), 10) }
	for _, c := range []struct{ raw, zh, en, tone string }{
		{"watched", "先不停放：有人正在看", "Not parking: someone is looking", "grey"},
		{"draft", "先不停放：输入框有草稿", "Not parking: a draft is in the input box", "grey"},
		{"park-bg", "先不停放：后台的活还在跑", "Not parking: background work is still running", "grey"},
		{"asking", "先不停放：选择框还开着", "Not parking: a choice dialog is open", "grey"},
		{"old-wrapper", "先不停放：旧外壳尚不支持", "Not parking: this older wrapper does not support it", "grey"},
		{"park-gate", "先不停放：尚未确认能安全停下", "Not parking: safe parking is not yet confirmed", "grey"},
		{"bg:" + in(18*time.Minute), "还没收：做完了，后台的活还在跑 · 18 分钟后收", "Not closed yet: done, but a background job is still running · closes in 18 min", "grey"},
		{"timer:" + in(5*time.Minute), "还没收：计时中 · 5 分钟后收", "Not closed yet: closes in 5 min", "grey"},
		{"dirty", "不会自动收：有没提交的改动", "Won't close on its own: uncommitted changes", "grey"},
		{"keep", "不会自动收：你设了保留", "Won't close on its own: kept by you", "grey"},
		{"task-open", "还没收：任务还没收口", "Not closed yet: its task is still open", "grey"},
		{"live", "先不收：有人正在看或在输入", "Not now: someone is looking or typing", "grey"},
		{"moving", "先不收：正在换机器", "Not now: moving to another machine", "grey"},
		{"waiting:" + in(3*time.Hour), "在等你回话 · 3 小时后停放，回话即唤醒", "Waiting for your reply · parks in 3 h — reply to wake it", "orange"},
		{"parked", "已停放 · 在等你点头，回话即唤醒", "Parked · waiting for your go-ahead — reply to wake it", "orange"},
		{"error-retry:" + in(4*time.Minute), "出错停住：服务端临时出错 · 4 分钟后自动重试", "Stopped on an error: a temporary server error · retrying in 4 min", "red"},
		{"error-retried", "出错停住：自动重试过 1 次仍出错 · 要你看一下", "Stopped on an error: retried once, still failing · needs a look", "red"},
		{"error", "出错停住：要你看一下", "Stopped on an error: needs a look", "red"},
		{"timer:" + in(-time.Hour), "还没收：计时中 · 1 分钟后收", "Not closed yet: closes in 1 min", "grey"},
	} {
		w, tone := boardWhy(c.raw, now)
		if len(w) != 2 || w[0] != c.zh || w[1] != c.en || tone != c.tone {
			t.Fatalf("boardWhy(%q) = %q %s; want %q %q %s", c.raw, w, tone, c.zh, c.en, c.tone)
		}
	}
	if w, tone := boardWhy("", now); w != nil || tone != "" {
		t.Fatalf("no reason = %q %s; want nothing", w, tone)
	}
}

// 会话合一 (task PQ41): a session the web opened is a row of the same list,
// marked origin web; a terminal's is origin terminal; a parked web session reads
// as idle (no difference to see); the web may talk to any live session not put
// away — never to a record with no session, an exited one, or one on a machine
// lost or in maintenance.
func TestBoardOriginAndCanTalk(t *testing.T) {
	st := storetest.OpenFleet(t)
	s := &Server{Store: st}
	now := time.Now()
	rec, err := st.CreateFleetTask(store.FleetTask{Owner: "gh:1", Title: "queued", AuthorityVersion: 1,
		RequestedAgent: "default", ResolvedAgent: "claude"}, "q", now)
	if err != nil {
		t.Fatal(err)
	}
	fleet := "42f8e358-7cc0-5856-a353-8983a4b4c9a1"
	sess := func(ident, state, avail string, extra map[string]any) FleetSession {
		wid := fleet + "/" + ident
		w := map[string]any{"identity": ident, "state": state, "name": ident, "born": float64(100), "worker_id": wid}
		for k, v := range extra {
			w[k] = v
		}
		return FleetSession{WorkerID: &wid, MachineName: "mac-b", OSUser: "alice", Availability: avail, Worker: w}
	}
	const web, parked, term, exited, maint = "0b7e8c1a-1111-4222-8333-444455550001", "0b7e8c1a-1111-4222-8333-444455550002",
		"0b7e8c1a-1111-4222-8333-444455550003", "0b7e8c1a-1111-4222-8333-444455550004", "0b7e8c1a-1111-4222-8333-444455550005"
	const gated = "0b7e8c1a-1111-4222-8333-444455550006" // the home's gate says no (HHV0 ①)
	live := []FleetSession{
		sess(web, "working", "online", map[string]any{"origin": "web"}),
		sess(parked, "parked", "online", map[string]any{"origin": "web"}),
		sess(term, "done", "online", nil),
		sess(exited, "exited", "online", nil),
		sess(maint, "idle", "maintenance", nil),
		sess(gated, "done", "online", map[string]any{"origin": "web", "can_talk": false}),
	}
	b, err := s.buildBoard("gh:1", live, now)
	if err != nil {
		t.Fatal(err)
	}
	got := map[string]BoardRow{}
	for _, r := range b.Rows {
		got[r.ID] = r
	}
	type want struct {
		origin, tag string
		talk        bool
	}
	for id, w := range map[string]want{
		web: {"web", "working", true}, parked: {"web", "idle", true}, term: {"terminal", "turn_done", true},
		exited: {"terminal", "exited", false}, maint: {"terminal", "idle", false}, rec.FID: {"", "queued", false},
		gated: {"web", "turn_done", false},
	} {
		r, ok := got[id]
		if !ok || r.Origin != w.origin || r.Tag != w.tag || r.CanTalk != w.talk {
			t.Errorf("row %s = %+v; want origin %q tag %s can_talk %v", id, r, w.origin, w.tag, w.talk)
		}
	}
	if got[parked].Words != got[maint].Words || got[parked].Group != "queue" {
		t.Errorf("a parked session does not read as idle: %+v", got[parked])
	}
	// origin and can_talk move the digest: the page redraws when a session parks or wakes
	live[0].Worker["origin"] = ""
	if b2, _ := s.buildBoard("gh:1", live, now); b2.Digest == b.Digest {
		t.Error("the digest ignores origin")
	}
}
