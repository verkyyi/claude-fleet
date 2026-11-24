package store_test

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/hub/store/storetest"
)

// Task T9AQ: a dispatched task tells its dispatcher when it ends or waits, as
// ONE ordinary relay per state — late and repeated events say nothing twice.

const (
	noticeDispFleet = "5f0c2d4e-aaaa-4bbb-8ccc-000000000001"
	noticeDispFID   = "5f0c2d4e-aaaa-4bbb-8ccc-0000000000d1"
)

func noticeRig(t *testing.T) *store.Store {
	t.Helper()
	st := storetest.OpenFleet(t)
	// the dispatcher's machine (mac-b): its fleet lists the dispatching window
	workers := `[{"worker_id":"` + noticeDispFleet + `/scratch-134","identity":"` + noticeDispFID + `"}]`
	if _, err := st.RecordFleetSnapshot("ep-d", "mac-b", "alice", "m-d",
		[]store.FleetReport{{FleetID: noticeDispFleet, Name: "fleet", State: "up", WorkersJSON: workers}}, time.Now()); err != nil {
		t.Fatal(err)
	}
	if _, err := push(t, st, "ep-d", noticeDispFID, ledger(t,
		`{"ev":"opened","agent":"claude","id":"`+noticeDispFID+`","seq":1,"ts":900}`)); err != nil {
		t.Fatal(err)
	}
	return st
}

func dispatched(t *testing.T, st *store.Store, token string, extra map[string]any) store.FleetTask {
	t.Helper()
	rec := newV1Task(t, st, token, "")
	p := map[string]any{"title": rec.Title, "from_fid": noticeDispFID}
	for k, v := range extra {
		p[k] = v
	}
	b, _ := json.Marshal(p)
	if _, err := st.DB().Exec(`UPDATE fleet_tasks SET request_payload=? WHERE id=?`, string(b), rec.ID); err != nil {
		t.Fatal(err)
	}
	return rec
}

func notices(t *testing.T, st *store.Store, fid string) []store.FleetRelay {
	t.Helper()
	rows, err := st.DB().Query(`SELECT id FROM fleet_relays WHERE from_wid = ? ORDER BY created, id`, noticeDispFleet+"/"+fid)
	if err != nil {
		t.Fatal(err)
	}
	var ids []string
	for rows.Next() {
		var id string
		_ = rows.Scan(&id)
		ids = append(ids, id)
	}
	rows.Close()
	var out []store.FleetRelay
	for _, id := range ids {
		r, err := st.FleetRelay(id)
		if err != nil {
			t.Fatal(err)
		}
		out = append(out, r)
	}
	return out
}

func TestTaskNoticeOncePerState(t *testing.T) {
	st := noticeRig(t)
	task := dispatched(t, st, "n1", nil)
	w := task.FID
	ev := func(seq int, body string) {
		t.Helper()
		got, err := push(t, st, "ep-w", w, ledger(t, `{"id":"`+w+`","seq":`+itoa(seq)+`,"ts":`+itoa(1000+seq)+`,`+body+`}`))
		if err != nil {
			t.Fatal(err)
		}
		_ = got
	}
	ev(1, `"ev":"opened","agent":"claude"`)
	// the agent's startup idle (a done with no reply, from an older node): nothing
	if got, err := push(t, st, "ep-w", w, ledger(t, `{"id":"`+w+`","seq":2,"ts":1001,"ev":"turn","state":"done","mark":"e0","summary":""}`)); err != nil || len(got.Notify) != 0 {
		t.Fatalf("an empty done raised a notice: %v %v", got.Notify, err)
	}
	if n := notices(t, st, w); len(n) != 0 {
		t.Fatalf("opened raised %d notices", len(n))
	}
	// the turn ends: one notice, down the DISPATCHER's endpoint, to its window
	got, err := push(t, st, "ep-w", w, ledger(t, `{"id":"`+w+`","seq":3,"ts":1003,"ev":"turn","state":"done","mark":"aa11","summary":"调研完成，报告在 ~/.claude/handoff/x-report.md","pr":"o/r#7","artifacts":["https://example.com/p"]}`))
	if err != nil {
		t.Fatal(err)
	}
	if len(got.Notify) != 1 || got.Notify[0] != "ep-d" {
		t.Fatalf("Notify = %v; want [ep-d]", got.Notify)
	}
	n := notices(t, st, w)
	if len(n) != 1 {
		t.Fatalf("notices = %d; want 1", len(n))
	}
	r := n[0]
	if r.ToWID != noticeDispFleet+"/"+noticeDispFID || r.TargetEndpoint != "ep-d" || r.FromEndpoint != store.TaskNoticeEndpoint ||
		r.Kind != "message" || r.Status != store.RelayPending || !strings.HasSuffix(r.ID, "#tn-done-aa11") {
		t.Fatalf("relay = %+v", r)
	}
	var p struct {
		Text   string            `json:"text"`
		Notice map[string]string `json:"task_notice"`
	}
	if err := json.Unmarshal([]byte(r.Payload), &p); err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"[任务通知]", "完成", "结论：调研完成", "PR o/r#7", "https://example.com/p", "在 m-ep-w"} {
		if !strings.Contains(p.Text, want) {
			t.Fatalf("text %q lacks %q", p.Text, want)
		}
	}
	if p.Notice["state"] != "done" || p.Notice["fid"] != w {
		t.Fatalf("task_notice = %v", p.Notice)
	}
	// the record carries the conclusion and the PR (seen after the worker parks)
	if rec, _ := st.FleetTask(task.ID); !strings.HasPrefix(rec.Note, "调研完成") || rec.PR != "o/r#7" {
		t.Fatalf("record note %q pr %q", rec.Note, rec.PR)
	}

	// the same reply said again (the Stop hook AND the agent's OSC 7501): nothing new
	ev(4, `"ev":"turn","state":"done","mark":"aa11","summary":"调研完成"`)
	// a resend of what landed: nothing new
	if _, err := push(t, st, "ep-w", w, ledger(t, `{"id":"`+w+`","seq":3,"ts":1003,"ev":"turn","state":"done","mark":"zz","summary":"x"}`)); err != nil {
		t.Fatal(err)
	}
	if n := notices(t, st, w); len(n) != 1 {
		t.Fatalf("a repeated turn raised a second notice: %d", len(n))
	}
	// it waits on a person: one 等人
	ev(5, `"ev":"turn","state":"waiting","mark":"bb22","summary":"要不要合并？"`)
	ev(6, `"ev":"turn","state":"waiting","mark":"bb22","summary":"要不要合并？"`)
	// the explicit result after it: a done again (the state changed)
	ev(7, `"ev":"result","state":"succeeded","summary":"merged"`)
	// …and a second result in the same state, then the close: nothing
	ev(8, `"ev":"result","state":"merged","summary":"merged"`)
	ev(9, `"ev":"closed","reason":"reaped"`)
	n = notices(t, st, w)
	var states []string
	for _, r := range n {
		_, suf, _ := strings.Cut(r.ID, "#tn-")
		states = append(states, suf)
	}
	if strings.Join(states, ",") != "done-aa11,waiting-bb22,done-r7" {
		t.Fatalf("notices = %v", states)
	}
	if !strings.Contains(n[1].Payload, "在等：要不要合并") || !strings.Contains(n[1].Payload, "等人") {
		t.Fatalf("waiting payload = %s", n[1].Payload)
	}
}

func TestTaskNoticeCloseAndOff(t *testing.T) {
	st := noticeRig(t)
	// closed before saying anything: one 结束 notice
	gone := dispatched(t, st, "gone", nil)
	if _, err := push(t, st, "ep-w", gone.FID, ledger(t,
		`{"ev":"opened","agent":"claude","id":"`+gone.FID+`","seq":1,"ts":1000}`,
		`{"ev":"closed","reason":"killed","id":"`+gone.FID+`","seq":2,"ts":1001}`)); err != nil {
		t.Fatal(err)
	}
	if n := notices(t, st, gone.FID); len(n) != 1 || !strings.Contains(n[0].Payload, "没交回结果") {
		t.Fatalf("close notices = %+v", n)
	}
	// notify=off: nothing at all
	off := dispatched(t, st, "off", map[string]any{"notify": "off"})
	if _, err := push(t, st, "ep-w", off.FID, ledger(t,
		`{"ev":"opened","agent":"claude","id":"`+off.FID+`","seq":1,"ts":1000}`,
		`{"ev":"turn","state":"done","mark":"m","summary":"done","id":"`+off.FID+`","seq":2,"ts":1001}`)); err != nil {
		t.Fatal(err)
	}
	if n := notices(t, st, off.FID); len(n) != 0 {
		t.Fatalf("notify=off raised %d", len(n))
	}
	// the note is still written: the record is the person's either way
	if rec, _ := st.FleetTask(off.ID); rec.Note != "done" {
		t.Fatalf("notify=off note = %q", rec.Note)
	}
	// a person's own task (no from_fid): nothing
	own := newV1Task(t, st, "own", "")
	if _, err := push(t, st, "ep-w", own.FID, ledger(t,
		`{"ev":"opened","agent":"claude","id":"`+own.FID+`","seq":1,"ts":1000}`,
		`{"ev":"turn","state":"done","mark":"m","summary":"done","id":"`+own.FID+`","seq":2,"ts":1001}`)); err != nil {
		t.Fatal(err)
	}
	if n := notices(t, st, own.FID); len(n) != 0 {
		t.Fatalf("an undispatched task raised %d", len(n))
	}
}

func TestTaskNoticeDispatcherMovedLogin(t *testing.T) {
	// the dispatcher's window is gone from its fleet's list (closed / cleared):
	// the notice still goes to its machine, whose node puts it in 「✦ 消息」.
	st := noticeRig(t)
	if _, err := st.RecordFleetSnapshot("ep-d", "mac-b", "alice", "m-d",
		[]store.FleetReport{{FleetID: noticeDispFleet, Name: "fleet", State: "up", WorkersJSON: `[]`}}, time.Now()); err != nil {
		t.Fatal(err)
	}
	task := dispatched(t, st, "late", nil)
	got, err := push(t, st, "ep-w", task.FID, ledger(t,
		`{"ev":"opened","agent":"claude","id":"`+task.FID+`","seq":1,"ts":1000}`,
		`{"ev":"turn","state":"done","mark":"m1","summary":"ok","id":"`+task.FID+`","seq":2,"ts":1001}`))
	if err != nil {
		t.Fatal(err)
	}
	if len(got.Notify) != 1 || got.Notify[0] != "ep-d" {
		t.Fatalf("Notify = %v", got.Notify)
	}
}

func itoa(n int) string {
	b, _ := json.Marshal(n)
	return string(b)
}
