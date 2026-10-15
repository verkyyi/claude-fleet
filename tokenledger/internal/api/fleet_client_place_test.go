package api

import (
	"bytes"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
)

// Open a session from the client (claude-fleet#1777, EPIC #1776 C1).

// clientLeaseFor takes the operator's client lease (the viewer door) and
// returns its id and action key.
func clientLeaseFor(t *testing.T, h *harness) (string, string) {
	t.Helper()
	var acq ClientLeaseResponse
	if st := clientPost(t, h, control.ClientPath, ClientLeaseRequest{Action: "acquire", Device: "MacBook"}, &acq); st != 200 ||
		acq.State != "active" || acq.ActionKey == "" {
		t.Fatalf("acquire = %d %+v", st, acq)
	}
	return acq.Lease.ID, acq.ActionKey
}

func clientPost(t *testing.T, h *harness, path string, body, out any) int {
	t.Helper()
	b, _ := json.Marshal(body)
	req, _ := http.NewRequest(http.MethodPost, h.http.URL+path, bytes.NewReader(b))
	req.Header.Set("Authorization", "Bearer "+viewerToken)
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	if out != nil {
		_ = json.NewDecoder(res.Body).Decode(out)
	}
	return res.StatusCode
}

// clientPlace signs payload under key for lease and posts it.
func clientPlace(t *testing.T, h *harness, lease, key string, payload map[string]any) (int, ClientPlaceResponse) {
	t.Helper()
	if _, ok := payload["ts"]; !ok {
		payload["ts"] = time.Now().Unix()
	}
	if _, ok := payload["wait"]; !ok {
		payload["wait"] = 1
	}
	p, _ := json.Marshal(payload)
	var out ClientPlaceResponse
	st := clientPost(t, h, control.ClientPath+"/place", ClientPlaceEnvelope{Lease: lease, Payload: string(p),
		MAC: signClientAction(key, p)}, &out)
	return st, out
}

// The completion criterion's first two: a valid key opens (mac-d busy → mac-c, the
// line fleet_hub_place prints, the worker_id to switch to); a wrong key, a
// stale payload, a lease taken over → 401 and nothing sent.
func TestClientPlaceScratchWithValidKey(t *testing.T) {
	h, macD, macC, _, f4 := twoNodes(t)
	lease, key := clientLeaseFor(t, h)
	macC.setOpGet(finished("succeeded", map[string]any{"exit": 0, "window": "@3",
		"workers": []map[string]any{{"window_id": "@3", "worker_id": f4.FleetID + "/scratch-2"}}}))

	st, out := clientPlace(t, h, lease, key, map[string]any{"repo": writeRepo, "kind": "scratch", "node": "auto",
		"title": "看看日志", "idempotency_key": "c-1"})
	if st != 200 || out.Exit != 0 || out.State != "done" || out.WorkerID != f4.FleetID+"/scratch-2" {
		t.Fatalf("place = %d %+v; want done on mac-c with its worker_id", st, out)
	}
	want := "REMOTE mac-c " + out.OperationID + " done " + f4.FleetID + "/scratch-2\t"
	if !strings.HasPrefix(out.Line, want) || !strings.Contains(out.Line, "mac-d excluded: load 1.00/core") {
		t.Fatalf("line = %q; want %q… with mac-d's exclusion", out.Line, want)
	}
	if macD.count() != 0 || macC.count() != 1 {
		t.Fatalf("writes mac-d=%d mac-c=%d; want 0 and 1", macD.count(), macC.count())
	}
	params := macC.writes[0]["params"].(map[string]any)
	if params["kind"] != "scratch" || params["name"] != "看看日志" || params["repo"] != writeRepo {
		t.Fatalf("mac-c was sent %v; want a scratch named by the title", params)
	}

	// The same key, wrong: 401, nothing sent.
	if st, _ := clientPlace(t, h, lease, strings.Repeat("0", 64), map[string]any{"repo": writeRepo, "kind": "scratch"}); st != 401 {
		t.Fatalf("wrong key = %d; want 401", st)
	}
	// A replay from long ago: 401.
	if st, _ := clientPlace(t, h, lease, key, map[string]any{"repo": writeRepo, "kind": "scratch",
		"ts": time.Now().Add(-time.Hour).Unix()}); st != 401 {
		t.Fatalf("stale payload = %d; want 401", st)
	}
	// Another device opens beside it (#1932), and the person disconnects the
	// first one: the old lease and key open nothing.
	lease2, key2 := clientLeaseFor(t, h)
	if st := clientPost(t, h, control.ClientPath, ClientLeaseRequest{Action: "revoke", Target: lease}, nil); st != 200 {
		t.Fatalf("revoke = %d", st)
	}
	if st, _ := clientPlace(t, h, lease, key, map[string]any{"repo": writeRepo, "kind": "scratch"}); st != 401 {
		t.Fatalf("disconnected lease = %d; want 401", st)
	}
	if st, _ := clientPlace(t, h, lease2, key, map[string]any{"repo": writeRepo, "kind": "scratch"}); st != 401 {
		t.Fatalf("new lease with the old key = %d; want 401", st)
	}
	if macC.count() != 1 {
		t.Fatalf("a refused call sent a write (mac-c writes %d)", macC.count())
	}
	// The status of the first start, read back by the client that holds the
	// lease now (same person): done, same line.
	st, again := clientPlace(t, h, lease2, key2, map[string]any{"action": "status", "operation_id": out.OperationID})
	if st != 200 || again.Line != out.Line {
		t.Fatalf("status = %d %+v; want %q", st, again, out.Line)
	}
}

// The writing area (claude-fleet#1953): kind=new carries a title and a body to
// the chosen machine, which files the issue and opens its worker — no lease
// is taken here (there is no number yet); a missing title, an issue number or
// a forged marker in the body are refused before anything is sent.
func TestClientPlaceNewFilesOnTheMachine(t *testing.T) {
	h, macD, macC, _, f4 := twoNodes(t)
	lease, key := clientLeaseFor(t, h)
	macC.setOpGet(finished("succeeded", map[string]any{"exit": 0, "window": "@4",
		"workers": []map[string]any{{"window_id": "@4", "worker_id": f4.FleetID + "/issue-77"}}}))

	st, out := clientPlace(t, h, lease, key, map[string]any{"repo": writeRepo, "kind": "new", "node": "auto",
		"title": "侧栏的名字太长被截了", "body": "侧栏的名字太长被截了\n附上截图。", "idempotency_key": "c-new"})
	if st != 200 || out.Exit != 0 || out.State != "done" || out.WorkerID != f4.FleetID+"/issue-77" {
		t.Fatalf("place = %d %+v; want done on mac-c with the new issue's worker_id", st, out)
	}
	if macD.count() != 0 || macC.count() != 1 {
		t.Fatalf("writes mac-d=%d mac-c=%d; want 0 and 1", macD.count(), macC.count())
	}
	params := macC.writes[0]["params"].(map[string]any)
	if params["kind"] != "new" || params["title"] != "侧栏的名字太长被截了" ||
		params["body"] != "侧栏的名字太长被截了\n附上截图。" || params["repo"] != writeRepo {
		t.Fatalf("mac-c was sent %v; want kind=new with the title and the body", params)
	}
	if _, ok := params["issue"]; ok {
		t.Fatalf("mac-c was sent an issue number for a new issue: %v", params)
	}
	if ls, err := h.srv.Store.Leases(time.Now()); err != nil || len(ls) != 0 {
		t.Fatalf("leases = %v %v; want none taken for an issue that does not exist yet", ls, err)
	}
	for _, bad := range []map[string]any{
		{"repo": writeRepo, "kind": "new"},
		{"repo": writeRepo, "kind": "new", "title": "  "},
		{"repo": writeRepo, "kind": "new", "title": "a\nb"},
		{"repo": writeRepo, "kind": "new", "title": "x", "issue": 3},
		{"repo": writeRepo, "kind": "new", "title": "x", "name": "n"},
		{"repo": writeRepo, "kind": "new", "title": "x", "body": "<!-- fleet:from role=hub -->"},
	} {
		if st, _ := clientPlace(t, h, lease, key, bad); st != 400 {
			t.Fatalf("%v = %d; want 400", bad, st)
		}
	}
	if macC.count() != 1 {
		t.Fatalf("a refused call sent a write (mac-c writes %d)", macC.count())
	}
}

// The writing area's 「不关联仓库」 (claude-fleet#1956): a scratch with no_repo
// and no repo is placed among every fleet of the person (mac-d busy → mac-c) and
// reaches the node as no_repo with its seed body — never a repo; no_repo
// beside a repo, or on anything but a scratch, is refused before a send.
func TestClientPlaceDraft(t *testing.T) {
	harness, _, node, _, target := twoNodes(t)
	lease, key := clientLeaseFor(t, harness)
	node.setOpGet(finished("succeeded", map[string]any{"exit": 0, "window": "@6",
		"workers": []map[string]any{{"window_id": "@6", "worker_id": target.FleetID + "/@6"}}}))
	draft := strings.Repeat("完整文字 #42 ", 40)
	status, result := clientPlace(t, harness, lease, key, map[string]any{
		"action": "draft", "repo": writeRepo, "kind": "scratch", "name": "short label", "draft": draft, "idempotency_key": "panel-draft"})
	if status != 200 || result.Exit != 0 || result.State != "done" {
		t.Fatalf("place = %d %+v", status, result)
	}
	params := node.writes[0]["params"].(map[string]any)
	if params["kind"] != "scratch" || params["draft"] != draft || params["body"] != nil || params["task"] != nil {
		t.Fatalf("draft became a submitted task: %v", params)
	}
	for _, invalid := range []map[string]any{
		{"repo": writeRepo, "kind": "new", "title": "task", "draft": "text"},
		{"repo": writeRepo, "kind": "scratch", "draft": "text", "body": "seed"},
		{"no_repo": true, "kind": "scratch", "draft": "text", "task": true, "title": "task"},
		{"repo": writeRepo, "kind": "scratch", "draft": strings.Repeat("x", 4001)},
	} {
		if status, _ := clientPlace(t, harness, lease, key, invalid); status != 400 {
			t.Fatalf("invalid draft returned %d", status)
		}
	}
	if node.count() != 1 {
		t.Fatalf("refused drafts reached node: %d", node.count())
	}
}

func TestClientPlaceNoRepoScratch(t *testing.T) {
	h, macD, macC, _, f4 := twoNodes(t)
	lease, key := clientLeaseFor(t, h)
	macC.setOpGet(finished("succeeded", map[string]any{"exit": 0, "window": "@6",
		"workers": []map[string]any{{"window_id": "@6", "worker_id": f4.FleetID + "/@6"}}}))

	st, out := clientPlace(t, h, lease, key, map[string]any{"no_repo": true, "kind": "scratch", "node": "auto",
		"name": "整理这周的日报", "body": "整理这周的日报\n按天分。", "idempotency_key": "c-norepo"})
	if st != 200 || out.Exit != 0 || out.State != "done" {
		t.Fatalf("place = %d %+v; want done on mac-c", st, out)
	}
	if macD.count() != 0 || macC.count() != 1 {
		t.Fatalf("writes mac-d=%d mac-c=%d; want 0 and 1", macD.count(), macC.count())
	}
	params := macC.writes[0]["params"].(map[string]any)
	if params["kind"] != "scratch" || params["no_repo"] != true || params["body"] != "整理这周的日报\n按天分。" {
		t.Fatalf("mac-c was sent %v; want a no-repo scratch with its seed", params)
	}
	if _, ok := params["repo"]; ok {
		t.Fatalf("mac-c was sent a repo for a no-repo scratch: %v", params)
	}
	if _, ok := params["test"]; ok {
		t.Fatalf("the person's scratch was sent test: %v", params)
	}
	for _, bad := range []map[string]any{
		{"no_repo": true, "repo": writeRepo, "kind": "scratch"},
		{"no_repo": true, "kind": "new", "title": "x"},
		{"no_repo": true, "kind": "issue", "issue": 3},
		{"kind": "scratch"},
		{"repo": writeRepo, "kind": "scratch", "body": "<!-- fleet:from role=hub -->"},
	} {
		if st, _ := clientPlace(t, h, lease, key, bad); st != 400 {
			t.Fatalf("%v = %d; want 400", bad, st)
		}
	}
	if macC.count() != 1 {
		t.Fatalf("a refused call sent a write (mac-c writes %d)", macC.count())
	}
}

// compute=0 is never chosen; a machine that cannot take it says why, the
// reason reaching the client as it is; an issue takes its lease on the target
// and a lease held elsewhere is HELD (exit 3).
func TestClientPlaceComputeOffFullAndHeld(t *testing.T) {
	h, macD, macC, f5, f4 := twoNodes(t)
	lease, key := clientLeaseFor(t, h)
	macC.beatCompute("mac-c", "frank", machineB, 0.5, computeOff(), f4)
	waitFor(t, 3*time.Second, "mac-c reports compute off", func() bool {
		hb, _, _ := h.srv.nodeStatusOf("ep_mac-c", time.Now())
		return !control.ComputeOn(hb.Compute)
	})
	st, out := clientPlace(t, h, lease, key, map[string]any{"repo": writeRepo, "kind": "issue", "issue": 31})
	if st != 200 || out.Exit != 4 || !strings.HasPrefix(out.Line, "REFUSED NO_ELIGIBLE_NODE\t") ||
		!strings.Contains(out.Line, "mac-c: "+excludedComputeOff) || !strings.Contains(out.Line, "mac-d: load 1.00/core") {
		t.Fatalf("compute off + busy = %d %+v; want REFUSED with both reasons", st, out)
	}
	if macC.count()+macD.count() != 0 {
		t.Fatal("a refused placement sent a write")
	}

	// mac-c back on; its spawn refuses at capacity: DECLINED with its own line.
	macC.beatLoad("mac-c", "frank", machineB, 1, 1, f4)
	waitFor(t, 3*time.Second, "mac-c compute back on", func() bool {
		hb, _, _ := h.srv.nodeStatusOf("ep_mac-c", time.Now())
		return control.ComputeOn(hb.Compute)
	})
	two := 2
	macC.setOpGet(finished("failed", map[string]any{"error": map[string]any{"code": "AT_CAPACITY", "exit": two,
		"stderr1": "fleet-mac-c is full: 8/8 sessions"}}))
	st, out = clientPlace(t, h, lease, key, map[string]any{"repo": writeRepo, "kind": "issue", "issue": 31})
	if st != 200 || out.Exit != 5 || out.Line != "DECLINED mac-c "+out.OperationID+" 2\tfleet-mac-c is full: 8/8 sessions" {
		t.Fatalf("full mac-c = %d %+v; want DECLINED with mac-c's line", st, out)
	}
	if ls, _ := h.srv.Store.Leases(time.Now()); len(ls) != 0 {
		t.Fatalf("a declined start kept its lease: %+v", ls)
	}

	// #33 held by mac-d's own worker: HELD mac-d, exit 3, nothing sent.
	if st, _ := leaseCall(t, h, h.tokens["mac-d"], map[string]any{"action": "acquire", "repo": writeRepo, "issue": 33,
		"worker_id": issueWID(f5.FleetID, 33)}); st != 200 {
		t.Fatal("mac-d's lease")
	}
	n := macC.count()
	st, out = clientPlace(t, h, lease, key, map[string]any{"repo": writeRepo, "kind": "issue", "issue": 33})
	if st != 200 || out.Exit != 3 || !strings.HasPrefix(out.Line, "HELD mac-d\t") || macC.count() != n {
		t.Fatalf("held = %d %+v; want HELD mac-d and nothing sent", st, out)
	}
}

// restore finds the machine whose /fleet-history holds the row (the record
// its node uploaded at the reap) and resumes the key there; a key no machine
// has is refused, never guessed.
func TestClientPlaceRestoreFindsHistoryRow(t *testing.T) {
	h, macD, macC, _, f4 := twoNodes(t)
	lease, key := clientLeaseFor(t, h)
	up := map[string]any{"worker_id": f4.FleetID + "/issue-21", "repo": writeRepo, "issue": 21, "key": "issue-21",
		"records": []map[string]any{{"kind": "history", "name": "landed", "stage": "landed",
			"content": []byte("2026-10-05T01:00:00Z\t21\ttitle\t-\t-\t-\t-\t-\t-\tunlanded\t-\n")}}}
	if st, _, raw := workerRecordsDo(t, h, h.tokens["mac-c"], http.MethodPost, "", up); st != 200 {
		t.Fatalf("mac-c's history upload = %d %s", st, raw)
	}
	macC.setOpGet(finished("succeeded", map[string]any{"workers": []map[string]any{{"window_id": "@9",
		"worker_id": f4.FleetID + "/issue-21"}}}))

	st, out := clientPlace(t, h, lease, key, map[string]any{"repo": writeRepo, "kind": "restore", "key": "issue-21"})
	if st != 200 || out.Exit != 0 || !strings.HasPrefix(out.Line, "REMOTE mac-c "+out.OperationID+" done "+f4.FleetID+"/issue-21\t") {
		t.Fatalf("restore = %d %+v; want resumed on mac-c", st, out)
	}
	if macD.count() != 0 || macC.count() != 1 || macC.writes[0]["action"] != "worker_resume" {
		t.Fatalf("writes mac-d=%d mac-c=%d %v; want one worker_resume on mac-c", macD.count(), macC.count(), macC.writes)
	}
	if p := macC.writes[0]["params"].(map[string]any); p["worker_id"] != f4.FleetID+"/issue-21" {
		t.Fatalf("resume params = %v", p)
	}

	st, out = clientPlace(t, h, lease, key, map[string]any{"repo": writeRepo, "kind": "restore", "key": "scratch-404"})
	if st != 200 || out.Exit != 4 || !strings.HasPrefix(out.Line, "REFUSED NOT_FOUND\t") || macC.count() != 1 {
		t.Fatalf("unknown key = %d %+v; want REFUSED NOT_FOUND", st, out)
	}
}

// No lease at all: 401 — a viewer token alone opens nothing.
func TestClientPlaceNeedsALease(t *testing.T) {
	h, _, macC, _, _ := twoNodes(t)
	if st, _ := clientPlace(t, h, "", strings.Repeat("a", 64), map[string]any{"repo": writeRepo, "kind": "scratch"}); st != 401 {
		t.Fatalf("no lease = %d; want 401", st)
	}
	if macC.count() != 0 {
		t.Fatal("sent a write without a lease")
	}
}

// The writing area's machine and agent (claude-fleet#2232, EPIC #2230 C2): a
// request with neither is today's (auto, no agent sent); naming mac-c with codex
// lands there even when auto would pick mac-d, and the agent rides the write to
// the node as it was asked; naming a machine in maintenance is refused with
// its reason and nothing is sent.
func TestClientPlaceNamedNodeAndAgent(t *testing.T) {
	h, macD, macC, f5, f4 := twoNodes(t)
	lease, key := clientLeaseFor(t, h)
	macC.setOpGet(finished("succeeded", map[string]any{"exit": 0, "window": "@4",
		"workers": []map[string]any{{"window_id": "@4", "worker_id": f4.FleetID + "/issue-77"}}}))

	// An older client: no node, no agent — auto (mac-d busy → mac-c), no agent key.
	st, out := clientPlace(t, h, lease, key, map[string]any{"repo": writeRepo, "kind": "new", "title": "老客户端"})
	if st != 200 || out.Exit != 0 || macC.count() != 1 {
		t.Fatalf("old request = %d %+v (mac-c writes %d); want done on mac-c", st, out, macC.count())
	}
	params := macC.writes[0]["params"].(map[string]any)
	if _, ok := params["agent"]; ok {
		t.Fatalf("an older client's start carried an agent: %v", params)
	}

	// mac-d idle now: auto would pick it — naming mac-c still lands on mac-c, with codex.
	macD.beatLoad("mac-d", "frank", machineA, 0.5, 0, f5)
	waitFor(t, 3*time.Second, "mac-d reports idle", func() bool {
		hb, _, _ := h.srv.nodeStatusOf("ep_mac-d", time.Now())
		return hb.Load1 == 0.5
	})
	if pl, err := h.srv.PickNode("", writeRepo); err != nil || pl.Machine != "mac-d" {
		t.Fatalf("auto now = %q %v; want mac-d", pl.Machine, err)
	}
	st, out = clientPlace(t, h, lease, key, map[string]any{"repo": writeRepo, "kind": "new", "title": "在 mac-c 上用 codex",
		"node": "mac-c", "agent": "codex"})
	if st != 200 || out.Exit != 0 || !strings.HasPrefix(out.Line, "REMOTE mac-c ") || out.Placement == nil ||
		out.Placement.Requested != "mac-c" {
		t.Fatalf("named mac-c = %d %+v; want REMOTE mac-c as requested", st, out)
	}
	if macD.count() != 0 || macC.count() != 2 {
		t.Fatalf("writes mac-d=%d mac-c=%d; want 0 and 2", macD.count(), macC.count())
	}
	if params := macC.writes[1]["params"].(map[string]any); params["agent"] != "codex" || params["kind"] != "new" {
		t.Fatalf("mac-c was sent %v; want agent=codex", params)
	}
	if st, _ := clientPlace(t, h, lease, key, map[string]any{"repo": writeRepo, "kind": "new", "title": "x",
		"agent": "gpt"}); st != 400 {
		t.Fatalf("agent=gpt = %d; want 400", st)
	}

	// mac-d in maintenance: naming it is refused, saying why; nothing is sent.
	if st, mo := maintCall(t, h, h.tokens["mac-d"], http.MethodPost, map[string]any{"action": "enter", "reason": "升级 macOS"}); st != 200 {
		t.Fatalf("enter = %d %v", st, mo)
	}
	st, out = clientPlace(t, h, lease, key, map[string]any{"repo": writeRepo, "kind": "new", "title": "开到 mac-d",
		"node": "mac-d", "agent": "codex"})
	if st != 200 || out.Exit != 4 || !strings.HasPrefix(out.Line, "REFUSED NO_ELIGIBLE_NODE\t") ||
		!strings.Contains(out.Line, "mac-d: maintenance: 升级 macOS") {
		t.Fatalf("named mac-d in maintenance = %d %+v; want REFUSED with the maintenance reason", st, out)
	}
	if macD.count() != 0 || macC.count() != 2 {
		t.Fatalf("a refused start sent a write: mac-d=%d mac-c=%d", macD.count(), macC.count())
	}
}

// The test identity's scratch (claude-fleet#2505) is marked `test` on a node
// that says CapTestIdentity, keeps a policy it asks for, and the person's
// scratch is never marked.
func TestClientPlaceTestIdentityMarked(t *testing.T) {
	h, _, macC, f4, _, _ := capNodes(t, control.CapTestIdentity)
	var acq ClientLeaseResponse
	if st := clientPost(t, h, control.ClientPath, ClientLeaseRequest{Action: "acquire", Device: "mac-c-drill", Identity: "test"}, &acq); st != 200 {
		t.Fatalf("test acquire = %d %+v", st, acq)
	}
	macC.setOpGet(finished("succeeded", map[string]any{"exit": 0, "window": "@3",
		"workers": []map[string]any{{"window_id": "@3", "worker_id": f4.FleetID + "/@3"}}}))
	if st, out := clientPlace(t, h, acq.Lease.ID, acq.ActionKey, map[string]any{"no_repo": true, "kind": "scratch", "node": "auto",
		"idempotency_key": "tm-1"}); st != 200 || out.State != "done" {
		t.Fatalf("test-identity home place = %d %+v; want done", st, out)
	}
	if params := macC.writes[0]["params"].(map[string]any); params["test"] != true || params["reap"] != "done:10m" {
		t.Fatalf("test-identity home was sent %v; want test=true reap=done:10m", params)
	}
	if st, out := clientPlace(t, h, acq.Lease.ID, acq.ActionKey, map[string]any{"no_repo": true, "kind": "scratch", "node": "auto",
		"reap": "keep", "idempotency_key": "tm-2"}); st != 200 || out.State != "done" {
		t.Fatalf("test-identity keep place = %d %+v; want done", st, out)
	}
	if params := macC.writes[1]["params"].(map[string]any); params["test"] != true || params["reap"] != "keep" {
		t.Fatalf("test-identity keep was sent %v; want test=true reap=keep", params)
	}
	lease, key := clientLeaseFor(t, h)
	if st, out := clientPlace(t, h, lease, key, map[string]any{"no_repo": true, "kind": "scratch", "node": "auto",
		"idempotency_key": "tm-3"}); st != 200 || out.State != "done" {
		t.Fatalf("person's home place = %d %+v; want done", st, out)
	}
	if params := macC.writes[2]["params"].(map[string]any); params["test"] != nil || params["reap"] != nil {
		t.Fatalf("the person's scratch was sent %v; want no test, no reap", params)
	}
}

// The test identity's lease (claude-fleet#2460, #1931) lives in its own slot:
// place finds it there, as the action poll does, instead of 401 forever.
func TestClientPlaceTestIdentityLease(t *testing.T) {
	h, _, macC, _, f4 := twoNodes(t)
	var acq ClientLeaseResponse
	if st := clientPost(t, h, control.ClientPath, ClientLeaseRequest{Action: "acquire", Device: "mac-c-drill", Identity: "test"}, &acq); st != 200 ||
		acq.State != "active" || acq.Identity != "test" || acq.ActionKey == "" {
		t.Fatalf("test acquire = %d %+v", st, acq)
	}
	macC.setOpGet(finished("succeeded", map[string]any{"exit": 0, "window": "@3",
		"workers": []map[string]any{{"window_id": "@3", "worker_id": f4.FleetID + "/scratch-2"}}}))
	st, out := clientPlace(t, h, acq.Lease.ID, acq.ActionKey, map[string]any{"repo": writeRepo, "kind": "scratch", "node": "auto",
		"title": "drill", "idempotency_key": "t-1"})
	if st != 200 || out.State != "done" || out.WorkerID != f4.FleetID+"/scratch-2" {
		t.Fatalf("test-identity place = %d %+v; want done", st, out)
	}
	// claude-fleet#2505: asking no policy, its scratch closes 10 minutes after
	// it is done; mac-c does not say CapTestIdentity, so it is sent no `test`
	if params := macC.writes[0]["params"].(map[string]any); params["test"] != nil || params["reap"] != "done:10m" {
		t.Fatalf("test-identity scratch to an older node was sent %v; want no test, reap=done:10m", params)
	}
	if st, _ := clientPlace(t, h, acq.Lease.ID, strings.Repeat("0", 64), map[string]any{"repo": writeRepo, "kind": "scratch"}); st != 401 {
		t.Fatalf("test lease with a wrong key = %d; want 401", st)
	}
}
