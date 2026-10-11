package api

import (
	"bytes"
	"encoding/json"
	"net/http"
	"strings"
	"testing"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// The task record (claude-fleet#3325, EPIC #3178).

func taskRecords(t *testing.T, h *harness) []map[string]any {
	t.Helper()
	out := getFleet(t, h, FleetTasksPath, 200)
	var ts []map[string]any
	for _, x := range out["tasks"].([]any) {
		ts = append(ts, x.(map[string]any))
	}
	return ts
}

func taskPost(t *testing.T, h *harness, path string, body any) (int, map[string]any) {
	t.Helper()
	b, _ := json.Marshal(body)
	req, _ := http.NewRequest(http.MethodPost, h.http.URL+path, bytes.NewReader(b))
	req.Header.Set("Authorization", "Bearer "+viewerToken)
	req.Header.Set("Content-Type", "application/json")
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	var out map[string]any
	_ = json.NewDecoder(res.Body).Decode(&out)
	return res.StatusCode, out
}

// A task with no repo: the record T1 is written, the machine that says
// CapTask is sent `task: T1` with the no-repo scratch, the record says where
// it landed — and there is no issue anywhere.
func TestTaskNoRepoIsARecordOnly(t *testing.T) {
	h, m5, m4, f4, _, _ := capNodes(t, control.CapTask)
	lease, key := clientLeaseFor(t, h)
	m4.setOpGet(finished("succeeded", map[string]any{"exit": 0, "window": "@6",
		"workers": []map[string]any{{"window_id": "@6", "worker_id": f4.FleetID + "/" + machineB}}}))

	st, out := clientPlace(t, h, lease, key, map[string]any{"no_repo": true, "kind": "scratch", "node": "auto",
		"task": true, "via": "⌘P", "body": "看看这台机器风扇为什么一直转\n顺便看看温度。", "idempotency_key": "c-task-1"})
	if st != 200 || out.State != "done" || out.Task != "T1" {
		t.Fatalf("place = %d %+v; want done with task T1", st, out)
	}
	if m5.count() != 0 || m4.count() != 1 {
		t.Fatalf("writes m5=%d m4=%d; want 0 and 1", m5.count(), m4.count())
	}
	params := m4.writes[0]["params"].(map[string]any)
	if params["task"] != "T1" || params["kind"] != "scratch" || params["no_repo"] != true {
		t.Fatalf("m4 was sent %v; want a no-repo scratch carrying task T1", params)
	}
	ts := taskRecords(t, h)
	if len(ts) != 1 {
		t.Fatalf("records = %v; want one", ts)
	}
	r := ts[0]
	if r["id"] != "T1" || r["title"] != "看看这台机器风扇为什么一直转" || r["via"] != "⌘P" || r["device"] != "MacBook" ||
		r["state"] != store.TaskOpen || r["worker_id"] != f4.FleetID+"/"+machineB || r["issue"] != "" || r["repo"] != "" {
		t.Fatalf("record = %v; want T1 open on m4 with the words' first line and no issue", r)
	}
	if !strings.HasPrefix(r["machine"].(string), "m4") {
		t.Fatalf("record machine = %v; want m4", r["machine"])
	}
	// the same idempotency key again is the same record, never a second
	if st, out := clientPlace(t, h, lease, key, map[string]any{"no_repo": true, "kind": "scratch", "node": "auto",
		"task": true, "body": "看看这台机器风扇为什么一直转", "idempotency_key": "c-task-1"}); st != 200 || out.Task != "T1" {
		t.Fatalf("again = %d %+v; want T1 again", st, out)
	}
	if n := len(taskRecords(t, h)); n != 1 {
		t.Fatalf("records after a retry = %d; want 1", n)
	}
}

// A task that chose a repo is a new start: the machine files its issue, and
// the issue hangs on the record (from the session's key, issue-77).
func TestTaskWithRepoHangsItsIssue(t *testing.T) {
	h, _, m4, f4, _, _ := capNodes(t, control.CapTask)
	lease, key := clientLeaseFor(t, h)
	m4.setOpGet(finished("succeeded", map[string]any{"exit": 0, "window": "@4", "key": "issue-77",
		"workers": []map[string]any{{"window_id": "@4", "worker_id": f4.FleetID + "/issue-77"}}}))

	st, out := clientPlace(t, h, lease, key, map[string]any{"repo": writeRepo, "kind": "new", "node": "auto",
		"task": true, "title": "给 hub 加一个 /healthz", "body": "给 hub 加一个 /healthz", "idempotency_key": "c-task-2"})
	if st != 200 || out.State != "done" || out.Task != "T1" {
		t.Fatalf("place = %d %+v; want done with T1", st, out)
	}
	params := m4.writes[0]["params"].(map[string]any)
	if params["task"] != "T1" || params["kind"] != "new" || params["title"] != "给 hub 加一个 /healthz" {
		t.Fatalf("m4 was sent %v; want kind=new carrying task T1", params)
	}
	r := taskRecords(t, h)[0]
	if r["issue"] != writeRepo+"#77" || r["session_key"] != "issue-77" || r["repo"] != writeRepo || r["state"] != store.TaskOpen {
		t.Fatalf("record = %v; want issue %s#77 on it", r, writeRepo)
	}
}

// 「建 GitHub 单」 on a record with none: the task's own machine files it
// (task_issue, bound to its session) and the issue hangs on the record; a
// second ask answers the same issue and sends nothing.
func TestTaskIssueOnDemand(t *testing.T) {
	h, _, m4, f4, _, _ := capNodes(t, control.CapTask)
	lease, key := clientLeaseFor(t, h)
	wid := f4.FleetID + "/" + machineB
	m4.setOpGet(finished("succeeded", map[string]any{"exit": 0, "window": "@6",
		"workers": []map[string]any{{"window_id": "@6", "worker_id": wid}}}))
	if st, out := clientPlace(t, h, lease, key, map[string]any{"no_repo": true, "kind": "scratch", "node": "auto",
		"task": true, "body": "整理一下这周的账单", "idempotency_key": "c-task-3"}); st != 200 || out.Task != "T1" {
		t.Fatalf("place = %d %+v", st, out)
	}
	m4.setOpGet(finished("succeeded", map[string]any{"issue_url": "https://github.com/" + writeRepo + "/issues/3312"}))

	st, rec := taskPost(t, h, FleetTasksPath+"/T1/issue", map[string]any{"repo": writeRepo})
	if st != 200 || rec["issue"] != writeRepo+"#3312" {
		t.Fatalf("建 GitHub 单 = %d %v; want the issue on the record", st, rec)
	}
	if m4.count() != 2 {
		t.Fatalf("m4 writes = %d; want the start and the filing", m4.count())
	}
	env := m4.writes[1]
	params := env["params"].(map[string]any)
	if env["action"] != "task_issue" || env["fleet_id"] != f4.FleetID || params["task"] != "T1" ||
		params["repo"] != writeRepo || params["worker_id"] != wid || params["title"] != "整理一下这周的账单" {
		t.Fatalf("m4 was sent %v; want task_issue for T1 on the task's own fleet, bound to its session", env)
	}
	if st, rec := taskPost(t, h, FleetTasksPath+"/T1/issue", map[string]any{"repo": writeRepo}); st != 200 ||
		rec["issue"] != writeRepo+"#3312" || m4.count() != 2 {
		t.Fatalf("again = %d %v (writes %d); want the same issue, nothing sent", st, rec, m4.count())
	}
	// the client's road: the signed place request's action task_issue
	st2, out := clientPlace(t, h, lease, key, map[string]any{"action": "task_issue", "task_ref": "T1"})
	if st2 != 200 || out.Exit != 0 || out.Line != "FILED "+writeRepo+"#3312\tT1" {
		t.Fatalf("client 建 GitHub 单 = %d %+v", st2, out)
	}
	if st, _ := taskPost(t, h, FleetTasksPath+"/T9/issue", map[string]any{"repo": writeRepo}); st != 404 {
		t.Fatalf("an unknown task = %d; want 404", st)
	}
}

// A refused start leaves its record, refused, with the reason.
func TestTaskRefusedIsRecorded(t *testing.T) {
	h := newFleetHarness(t)
	lease, key := clientLeaseFor(t, h)
	st, out := clientPlace(t, h, lease, key, map[string]any{"no_repo": true, "kind": "scratch", "node": "auto",
		"task": true, "body": "没有机器能开", "idempotency_key": "c-task-4"})
	if st != 200 || out.Exit != 4 || out.Task != "T1" {
		t.Fatalf("place = %d %+v; want REFUSED with T1", st, out)
	}
	r := taskRecords(t, h)[0]
	if r["state"] != store.TaskRefused || r["note"] == "" {
		t.Fatalf("record = %v; want refused with its reason", r)
	}
	for _, bad := range []map[string]any{
		{"repo": writeRepo, "kind": "scratch", "task": true, "body": "x"},
		{"repo": writeRepo, "kind": "issue", "issue": 3, "task": true},
		{"no_repo": true, "kind": "scratch", "task": true},
		{"no_repo": true, "kind": "scratch", "home": true, "task": true, "body": "x"},
		{"no_repo": true, "kind": "scratch", "via": "⌘P", "body": "x"},
	} {
		if st, _ := clientPlace(t, h, lease, key, bad); st != 400 {
			t.Fatalf("%v = %d; want 400", bad, st)
		}
	}
	if n := len(taskRecords(t, h)); n != 1 {
		t.Fatalf("records = %d after refused calls; want 1", n)
	}
}

// No task asked: no record, no `task` sent, no `task` in the answer — byte for
// byte the place it was. And a machine that does not say CapTask is never
// sent one: its start opens as before (the record still stands).
func TestTaskOffAddsNothing(t *testing.T) {
	h, _, m4, f4, _, _ := capNodes(t)
	lease, key := clientLeaseFor(t, h)
	m4.setOpGet(finished("succeeded", map[string]any{"exit": 0, "window": "@6",
		"workers": []map[string]any{{"window_id": "@6", "worker_id": f4.FleetID + "/" + machineB}}}))
	st, out := clientPlace(t, h, lease, key, map[string]any{"no_repo": true, "kind": "scratch", "node": "auto",
		"body": "整理这周的日报", "idempotency_key": "c-plain"})
	if st != 200 || out.State != "done" || out.Task != "" {
		t.Fatalf("place = %d %+v; want done, no task", st, out)
	}
	if _, ok := m4.writes[0]["params"].(map[string]any)["task"]; ok {
		t.Fatalf("a plain start was sent a task: %v", m4.writes[0])
	}
	if ts := taskRecords(t, h); len(ts) != 0 {
		t.Fatalf("records = %v; want none", ts)
	}
	raw, _ := json.Marshal(out)
	if strings.Contains(string(raw), `"task"`) {
		t.Fatalf("a plain answer names a task: %s", raw)
	}
	// m4 predates the task record: the record is written, m4 is sent none
	if st, out := clientPlace(t, h, lease, key, map[string]any{"no_repo": true, "kind": "scratch", "node": "auto",
		"task": true, "body": "看看风扇", "idempotency_key": "c-old"}); st != 200 || out.Task != "T1" {
		t.Fatalf("place = %d %+v", st, out)
	}
	if _, ok := m4.writes[1]["params"].(map[string]any)["task"]; ok {
		t.Fatalf("a node without CapTask was sent a task: %v", m4.writes[1])
	}
}
