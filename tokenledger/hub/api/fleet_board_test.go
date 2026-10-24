package api

import (
	"encoding/json"
	"fmt"
	"strconv"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/hub/store/storetest"
)

func TestBoardConversationActivity(t *testing.T) {
	st := storetest.OpenFleet(t)
	s := &Server{Store: st}
	now := time.Now()
	id := "00000000-0000-4000-8000-000000000123"
	wid := "fleet/" + id
	worker := map[string]any{"identity": id, "state": "done", "born": float64(now.Unix() - 100), "activity_at": float64(now.Unix() - 10)}
	board, err := s.buildBoard("alice", []FleetSession{{WorkerID: &wid, Worker: worker, Availability: "online"}}, now)
	if err != nil || len(board.Rows) != 1 || board.Rows[0].ActivityAt != now.Unix()-10 {
		t.Fatalf("live activity: %+v %v", board, err)
	}
	worker["activity_at"] = float64(now.Unix() + 100)
	board, err = s.buildBoard("alice", []FleetSession{{WorkerID: &wid, Worker: worker, Availability: "online"}}, now)
	if err != nil || len(board.Rows) != 1 || board.Rows[0].ActivityAt != 0 {
		t.Fatalf("future activity: %+v %v", board, err)
	}
	rows := []BoardRow{{ID: "recent-turn", Group: "gone", At: 100, ActivityAt: 300}, {ID: "recent-close", Group: "gone", At: 200, ActivityAt: 50}}
	if got := finishBoard(rows).Rows[0].ID; got != "recent-turn" {
		t.Fatalf("history must order and cap by latest turn, got %s", got)
	}
}

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
		asked.FID:                              {"queue", "turn_done", ""},
		keep.FID:                               {"queue", "turn_done", ""},
		parked.FID:                             {"ask", "parked", "已停放 · 在等你点头，回话即唤醒"},
		stopped.FID:                            {"ask", "stopped", "出错停住：服务端临时出错 · 4 分钟后自动重试"},
		poster.FID:                             {"work", "looping", ""},
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
	if len(order) < 2 || order[1] != "ask:stopped" || order[0][:4] != "ask:" {
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
		web: {"web", "working", true}, parked: {"web", "session_parked", true}, term: {"terminal", "turn_done", true},
		exited: {"terminal", "exited", false}, maint: {"terminal", "idle", false}, rec.FID: {"", "queued", false},
		gated: {"web", "turn_done", false},
	} {
		r, ok := got[id]
		if !ok || r.Origin != w.origin || r.Tag != w.tag || r.CanTalk != w.talk {
			t.Errorf("row %s = %+v; want origin %q tag %s can_talk %v", id, r, w.origin, w.tag, w.talk)
		}
	}
	if got[parked].Words != [2]string{"已停放", "Parked"} || got[parked].Group != "queue" {
		t.Errorf("a parked session must be explicit: %+v", got[parked])
	}
	// origin and can_talk move the digest: the page redraws when a session parks or wakes
	live[0].Worker["origin"] = ""
	if b2, _ := s.buildBoard("gh:1", live, now); b2.Digest == b.Digest {
		t.Error("the digest ignores origin")
	}
}

// PV4D: a record is a plan, not evidence of a running agent or a scheduler.
func TestBoardPlanFacts(t *testing.T) {
	st := storetest.OpenFleet(t)
	s := &Server{Store: st}
	now := time.Now()
	parent, err := st.CreateFleetTask(store.FleetTask{Owner: "gh:1", Title: "coordinator", RequestedAgent: "codex", ResolvedAgent: "codex", AuthorityVersion: 1}, "parent-plan", now)
	if err != nil {
		t.Fatal(err)
	}
	child, err := st.CreateFleetTask(store.FleetTask{Owner: "gh:1", Title: "dependency words do not schedule", RequestedAgent: "codex", AuthorityVersion: 1, ResolvedAgent: "codex", ParentTask: parent.Ref}, "child-plan", now)
	if err != nil {
		t.Fatal(err)
	}

	// This board compatibility test reads a historical relationship. New
	// acceptance no longer binds a Parent, so seed the archived columns directly.
	if _, err := st.DB().Exec(`UPDATE fleet_tasks SET parent_task=? WHERE id=?`, parent.Ref, child.ID); err != nil {
		t.Fatal(err)
	}

	read := func(live []FleetSession) BoardRow {
		t.Helper()
		b, err := s.buildBoard("gh:1", live, now)
		if err != nil {
			t.Fatal(err)
		}
		for _, r := range b.Rows {
			if r.ID == child.FID {
				return r
			}
		}
		t.Fatal("missing record")
		return BoardRow{}
	}
	r := read(nil)
	if r.Agent != "codex" || r.AgentBasis != "planned" || r.Words[1] != "Not dispatched" || r.Coordinator != parent.Short || r.Parent != parent.FID {
		data, _ := json.Marshal(r)
		t.Fatalf("planned record: %s", data)
	}
	set := func(sql string, args ...any) {
		t.Helper()
		if _, err := st.DB().Exec(sql, args...); err != nil {
			t.Fatal(err)
		}
	}
	set("UPDATE fleet_tasks SET operation_id='op-accepted' WHERE id=?", child.ID)
	if r = read(nil); r.Tag != "not_seen" || r.Context[0] != "" || r.AgentBasis == "planned" {
		t.Fatalf("accepted dispatch without a worker is not undispatched: %+v", r)
	}
	set(`INSERT INTO fleet_operations (id,fleet_id,action,request,actor,idem,status,created,updated,task_owner,task_ref,task_generation) VALUES ('op-accepted','','worker_start','{}','gh:1','accepted-plan','pending',?,?,'gh:1',?,?)`, now.UTC().Format(time.RFC3339Nano), now.UTC().Format(time.RFC3339Nano), child.Ref, child.Generation)
	set("UPDATE fleet_tasks SET state='starting' WHERE id=?", child.ID)
	if r = read(nil); r.Tag != "starting" || r.AgentBasis != "planned" {
		t.Fatalf("starting: %+v", r)
	}
	set("UPDATE fleet_tasks SET resolved_agent='', requested_agent='', agent='' WHERE id=?", child.ID)
	if r = read(nil); r.Agent != "" || r.AgentWords[1] != "Unknown" {
		t.Fatalf("unknown: %+v", r)
	}
	set("UPDATE fleet_tasks SET resolved_agent='codex', requested_agent='codex', state='accepted', operation_id='' WHERE id=?", child.ID)
	set("UPDATE fleet_tasks SET worker_id='fleet/existing' WHERE id=?", child.ID)
	if r = read(nil); r.Tag != "not_seen" || r.AgentBasis == "planned" {
		t.Fatalf("accepted with worker but no inventory: %+v", r)
	}
	set("UPDATE fleet_tasks SET worker_id='' WHERE id=?", child.ID)
	// Reserving a task stamps opened_at even though no worker has started.
	if r = read(nil); r.Tag != "queued" || r.AgentBasis != "planned" {
		t.Fatalf("reserved ID timestamp is not runtime evidence: %+v", r)
	}
	push := func(events ...map[string]any) {
		t.Helper()
		if _, err := st.ApplyFleetIDEvents(store.FleetIDPush{Owner: "gh:1", EndpointID: "ep-plan", Machine: "test-machine", Login: "alice", ID: child.FID, Events: events}); err != nil {
			t.Fatal(err)
		}
	}
	event := func(kind string, seq int, agent string) map[string]any {
		return map[string]any{"ev": kind, "id": child.FID, "seq": float64(seq), "ts": float64(now.Unix()), "agent": agent, "native": "native-test"}
	}
	push(event("opened", 1, "codex"), event("native", 2, "claude"))
	// The placement state may remain accepted after native startup.
	if r = read(nil); r.Tag != "not_seen" || r.AgentBasis != "native" {
		t.Fatalf("accepted with native startup is not undispatched: %+v", r)
	}
	wid := "fleet/" + child.FID
	live := []FleetSession{{WorkerID: &wid, Availability: "online", Worker: map[string]any{"identity": child.FID, "state": "working", "agent": "codex"}}}
	if r = read(live); r.Agent != "claude" || r.AgentBasis != "native" || r.Group != "work" {
		t.Fatalf("native wins plan and inventory: %+v", r)
	}
	set("UPDATE fleet_tasks SET outcome='succeeded' WHERE id=?", child.ID)
	if r = read(live); r.Group != "work" || r.Outcome != "succeeded" {
		t.Fatalf("new work after result: %+v", r)
	}
	live[0].Worker["state"] = "idle"
	live[0].Worker["reap_why"] = "keep"
	if r = read(live); r.Tag != "retained_completed" || r.Words[0] != "已完成 · 保留中" || r.Why[0] != "不会自动收：你设了保留" {
		t.Fatalf("completed retained: %+v", r)
	}
	push(event("closed", 3, "claude"))
	if r = read(nil); r.Group != "gone" || r.Agent != "claude" || r.AgentBasis != "native" {
		t.Fatalf("history: %+v", r)
	}
}

func TestBoardHistoryTitles(t *testing.T) {
	st := storetest.OpenFleet(t)
	s := &Server{Store: st}
	now := time.Now()
	for i, title := range []string{"", " \t", "original"} {
		id := "11111111-1111-4111-8111-11111111111" + strconv.Itoa(i)
		evs := []map[string]any{{"ev": "opened", "seq": float64(1), "ts": float64(now.Unix()), "title": title}}
		if i == 2 {
			evs = append(evs, map[string]any{"ev": "named", "seq": float64(2), "title": "chosen", "source": "manual"})
		}
		evs = append(evs, map[string]any{"ev": "closed", "seq": float64(len(evs) + 1), "ts": float64(now.Unix()), "reason": "reaped"})
		if _, err := st.ApplyFleetIDEvents(store.FleetIDPush{Owner: "gh:1", EndpointID: "ep1", ID: id, Events: evs}); err != nil {
			t.Fatal(err)
		}
	}
	b, err := s.buildBoard("gh:1", nil, now)
	if err != nil || len(b.Rows) != 3 {
		t.Fatalf("board: %+v %v", b, err)
	}
	for _, r := range b.Rows {
		want := "会话 " + r.Code
		if r.ID[len(r.ID)-1:] == "2" {
			want = "chosen"
		}
		if r.Title != want || r.Group != "gone" {
			t.Fatalf("history title: %+v want %q", r, want)
		}
	}
	other, err := s.buildBoard("gh:2", nil, now)
	if err != nil || len(other.Rows) != 0 {
		t.Fatalf("other owner: %+v %v", other, err)
	}
}

func TestBoardManualTitleBeatsTaskAndLive(t *testing.T) {
	st := storetest.OpenFleet(t)
	s := &Server{Store: st}
	now := time.Now()
	task, err := st.CreateFleetTask(store.FleetTask{Owner: "gh:1", Title: "task title", AuthorityVersion: 1, RequestedAgent: "default", ResolvedAgent: "claude"}, "manual-title", now)
	if err != nil {
		t.Fatal(err)
	}
	evs := []map[string]any{{"ev": "opened", "seq": float64(1), "ts": float64(now.Unix()), "title": "task title"}, {"ev": "named", "seq": float64(2), "title": "chosen name", "source": "manual"}}
	if _, err := st.ApplyFleetIDEvents(store.FleetIDPush{Owner: "gh:1", EndpointID: "ep1", ID: task.FID, Events: evs}); err != nil {
		t.Fatal(err)
	}
	live := []FleetSession{{Worker: map[string]any{"identity": task.FID, "title": "stale inventory", "state": "working"}, Availability: "online"}}
	for _, sessions := range [][]FleetSession{live, nil} {
		b, err := s.buildBoard("gh:1", sessions, now)
		if err != nil || len(b.Rows) != 1 || b.Rows[0].Title != "chosen name" {
			t.Fatalf("manual board: %+v %v", b, err)
		}
	}
}

// Every closed row resolves its own FID, including row 201+, independently of
// the legacy ended list. An unstarted accepted task remains visible.
func TestBoardHistoryBeyondEndedCap(t *testing.T) {
	st := storetest.OpenFleet(t)
	s := &Server{Store: st}
	now := time.Now()
	for i := 0; i < 205; i++ {
		id := fmt.Sprintf("11111111-1111-4111-8111-%012d", i)
		_, err := st.ApplyFleetIDEvents(store.FleetIDPush{Owner: "gh:1", EndpointID: "ep", Machine: "machine-a", Login: "alice", ID: id,
			Events: []map[string]any{{"ev": "opened", "seq": float64(1), "ts": float64(now.Unix()), "key": "scratch-1"},
				{"ev": "native", "seq": float64(2), "ts": float64(now.Unix()), "native": "sid", "agent": "claude"},
				{"ev": "closed", "seq": float64(3), "ts": float64(now.Unix()), "reason": "done"}}})
		if err != nil {
			t.Fatal(err)
		}
	}
	pending, err := st.CreateFleetTask(store.FleetTask{Owner: "gh:1", Title: "not started", AuthorityVersion: 1, RequestedAgent: "default", ResolvedAgent: "claude"}, "queued", now)
	if err != nil {
		t.Fatal(err)
	}
	b, err := s.buildBoard("gh:1", nil, now)
	if err != nil {
		t.Fatal(err)
	}
	n := 0
	for _, r := range b.Rows {
		if r.History != nil {
			n++
			if r.History.ID != r.ID {
				t.Fatal("history identity mismatch")
			}
		}
		if r.ID == pending.FID && r.Group == "gone" {
			t.Fatal("pending task hidden")
		}
	}
	if n != 205 {
		t.Fatalf("history rows=%d", n)
	}
	other, err := s.buildBoard("gh:2", nil, now)
	if err != nil || len(other.Rows) != 0 {
		t.Fatalf("tenant rows=%+v err=%v", other, err)
	}
}

// One list fact projection, without confusing a reserved record, an expired
// start, or background activity with a recurring plan.
func TestBoardTaskListFacts(t *testing.T) {
	st := storetest.OpenFleet(t)
	s := &Server{Store: st}
	now := time.Now()
	task, err := st.CreateFleetTask(store.FleetTask{Owner: "gh:1", Title: "queued work", AuthorityVersion: 1, RequestedAgent: "default", ResolvedAgent: "claude"}, "list-facts", now)
	if err != nil {
		t.Fatal(err)
	}
	read := func(live []FleetSession) BoardRow {
		t.Helper()
		b, err := s.buildBoard("gh:1", live, now)
		if err != nil || len(b.Rows) != 1 {
			t.Fatalf("board: %+v %v", b, err)
		}
		return b.Rows[0]
	}
	if read(nil).PendingStart {
		t.Fatal("reserved record is not submitted execution")
	}
	_, err = st.DB().Exec(`INSERT INTO fleet_operations (id,fleet_id,action,request,actor,idem,status,created,updated,task_owner,task_ref,task_generation) VALUES ('start-list','','worker_start','{}','gh:1','list-start','pending',?,?,'gh:1',?,?)`, now.UTC().Format(time.RFC3339Nano), now.UTC().Format(time.RFC3339Nano), task.Ref, task.Generation)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = st.DB().Exec(`UPDATE fleet_tasks SET operation_id = 'start-list' WHERE id = ?`, task.ID); err != nil {
		t.Fatal(err)
	}
	if r := read(nil); !r.PendingStart || r.Tag != "starting" {
		t.Fatalf("accepted request: %+v", r)
	}
	for _, state := range []string{"failed", "succeeded", "unknown"} {
		if err = st.UpdateFleetOperation("start-list", state, "", now); err != nil {
			t.Fatal(err)
		}
		if read(nil).PendingStart {
			t.Fatalf("%s start shown as pending", state)
		}
	}
	if err = st.UpdateFleetOperation("start-list", "pending", "", now); err != nil {
		t.Fatal(err)
	}
	if _, err = st.DB().Exec(`UPDATE fleet_tasks SET cancel_request = 'stop' WHERE id = ?`, task.ID); err != nil {
		t.Fatal(err)
	}
	if read(nil).PendingStart {
		t.Fatal("cancelled request shown as pending")
	}
	for _, c := range []struct {
		state, wait   string
		loop, running bool
	}{
		{"working", "", false, true}, {"working", "", true, true},
		{"looping", "human", false, false}, {"looping", "children", false, false},
		{"looping", "loop", true, false}, {"looping", "bg,tool", false, true},
		{"idle", "", true, false}, {"needs", "human", true, false},
	} {
		r := read([]FleetSession{{Availability: "online", Worker: map[string]any{"identity": task.FID, "state": c.state, "native_wait": c.wait, "loop": c.loop}}})
		if r.Running != c.running || r.Loop == nil || *r.Loop != c.loop || r.PendingStart || r.NativeWait != c.wait {
			t.Fatalf("%+v: %+v", c, r)
		}
		wire, _ := json.Marshal(r)
		var fields map[string]any
		if err := json.Unmarshal(wire, &fields); err != nil {
			t.Fatal(err)
		}
		if _, ok := fields["pending_start"]; !ok {
			t.Fatal("false pending fact omitted")
		}
	}
	old := read([]FleetSession{{Availability: "online", Worker: map[string]any{"identity": task.FID, "state": "looping"}}})
	if old.Loop != nil || old.Running {
		t.Fatalf("legacy looping guessed as recurring plan/activity: %+v", old)
	}
}
