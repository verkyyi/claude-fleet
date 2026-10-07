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

// The completion criterion's first two: a valid key opens (m5 busy → m4, the
// line fleet_hub_place prints, the worker_id to switch to); a wrong key, a
// stale payload, a lease taken over → 401 and nothing sent.
func TestClientPlaceScratchWithValidKey(t *testing.T) {
	h, m5, m4, _, f4 := twoNodes(t)
	lease, key := clientLeaseFor(t, h)
	m4.setOpGet(finished("succeeded", map[string]any{"exit": 0, "window": "@3",
		"workers": []map[string]any{{"window_id": "@3", "worker_id": f4.FleetID + "/scratch-2"}}}))

	st, out := clientPlace(t, h, lease, key, map[string]any{"repo": writeRepo, "kind": "scratch", "node": "auto",
		"title": "看看日志", "idempotency_key": "c-1"})
	if st != 200 || out.Exit != 0 || out.State != "done" || out.WorkerID != f4.FleetID+"/scratch-2" {
		t.Fatalf("place = %d %+v; want done on m4 with its worker_id", st, out)
	}
	want := "REMOTE m4 " + out.OperationID + " done " + f4.FleetID + "/scratch-2\t"
	if !strings.HasPrefix(out.Line, want) || !strings.Contains(out.Line, "m5 excluded: load 1.00/core") {
		t.Fatalf("line = %q; want %q… with m5's exclusion", out.Line, want)
	}
	if m5.count() != 0 || m4.count() != 1 {
		t.Fatalf("writes m5=%d m4=%d; want 0 and 1", m5.count(), m4.count())
	}
	params := m4.writes[0]["params"].(map[string]any)
	if params["kind"] != "scratch" || params["name"] != "看看日志" || params["repo"] != writeRepo {
		t.Fatalf("m4 was sent %v; want a scratch named by the title", params)
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
	if m4.count() != 1 {
		t.Fatalf("a refused call sent a write (m4 writes %d)", m4.count())
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
	h, m5, m4, _, f4 := twoNodes(t)
	lease, key := clientLeaseFor(t, h)
	m4.setOpGet(finished("succeeded", map[string]any{"exit": 0, "window": "@4",
		"workers": []map[string]any{{"window_id": "@4", "worker_id": f4.FleetID + "/issue-77"}}}))

	st, out := clientPlace(t, h, lease, key, map[string]any{"repo": writeRepo, "kind": "new", "node": "auto",
		"title": "侧栏的名字太长被截了", "body": "侧栏的名字太长被截了\n附上截图。", "idempotency_key": "c-new"})
	if st != 200 || out.Exit != 0 || out.State != "done" || out.WorkerID != f4.FleetID+"/issue-77" {
		t.Fatalf("place = %d %+v; want done on m4 with the new issue's worker_id", st, out)
	}
	if m5.count() != 0 || m4.count() != 1 {
		t.Fatalf("writes m5=%d m4=%d; want 0 and 1", m5.count(), m4.count())
	}
	params := m4.writes[0]["params"].(map[string]any)
	if params["kind"] != "new" || params["title"] != "侧栏的名字太长被截了" ||
		params["body"] != "侧栏的名字太长被截了\n附上截图。" || params["repo"] != writeRepo {
		t.Fatalf("m4 was sent %v; want kind=new with the title and the body", params)
	}
	if _, ok := params["issue"]; ok {
		t.Fatalf("m4 was sent an issue number for a new issue: %v", params)
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
	if m4.count() != 1 {
		t.Fatalf("a refused call sent a write (m4 writes %d)", m4.count())
	}
}

// The writing area's 「不关联仓库」 (claude-fleet#1956): a scratch with no_repo
// and no repo is placed among every fleet of the person (m5 busy → m4) and
// reaches the node as no_repo with its seed body — never a repo; no_repo
// beside a repo, or on anything but a scratch, is refused before a send.
func TestClientPlaceNoRepoScratch(t *testing.T) {
	h, m5, m4, _, f4 := twoNodes(t)
	lease, key := clientLeaseFor(t, h)
	m4.setOpGet(finished("succeeded", map[string]any{"exit": 0, "window": "@6",
		"workers": []map[string]any{{"window_id": "@6", "worker_id": f4.FleetID + "/@6"}}}))

	st, out := clientPlace(t, h, lease, key, map[string]any{"no_repo": true, "kind": "scratch", "node": "auto",
		"name": "整理这周的日报", "body": "整理这周的日报\n按天分。", "idempotency_key": "c-norepo"})
	if st != 200 || out.Exit != 0 || out.State != "done" {
		t.Fatalf("place = %d %+v; want done on m4", st, out)
	}
	if m5.count() != 0 || m4.count() != 1 {
		t.Fatalf("writes m5=%d m4=%d; want 0 and 1", m5.count(), m4.count())
	}
	params := m4.writes[0]["params"].(map[string]any)
	if params["kind"] != "scratch" || params["no_repo"] != true || params["body"] != "整理这周的日报\n按天分。" {
		t.Fatalf("m4 was sent %v; want a no-repo scratch with its seed", params)
	}
	if _, ok := params["repo"]; ok {
		t.Fatalf("m4 was sent a repo for a no-repo scratch: %v", params)
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
	if m4.count() != 1 {
		t.Fatalf("a refused call sent a write (m4 writes %d)", m4.count())
	}
}

// compute=0 is never chosen; a machine that cannot take it says why, the
// reason reaching the client as it is; an issue takes its lease on the target
// and a lease held elsewhere is HELD (exit 3).
func TestClientPlaceComputeOffFullAndHeld(t *testing.T) {
	h, m5, m4, f5, f4 := twoNodes(t)
	lease, key := clientLeaseFor(t, h)
	m4.beatCompute("m4", "verk", machineB, 0.5, computeOff(), f4)
	waitFor(t, 3*time.Second, "m4 reports compute off", func() bool {
		hb, _, _ := h.srv.nodeStatusOf("ep_m4", time.Now())
		return !control.ComputeOn(hb.Compute)
	})
	st, out := clientPlace(t, h, lease, key, map[string]any{"repo": writeRepo, "kind": "issue", "issue": 31})
	if st != 200 || out.Exit != 4 || !strings.HasPrefix(out.Line, "REFUSED NO_ELIGIBLE_NODE\t") ||
		!strings.Contains(out.Line, "m4: "+excludedComputeOff) || !strings.Contains(out.Line, "m5: load 1.00/core") {
		t.Fatalf("compute off + busy = %d %+v; want REFUSED with both reasons", st, out)
	}
	if m4.count()+m5.count() != 0 {
		t.Fatal("a refused placement sent a write")
	}

	// m4 back on; its spawn refuses at capacity: DECLINED with its own line.
	m4.beatLoad("m4", "verk", machineB, 1, 1, f4)
	waitFor(t, 3*time.Second, "m4 compute back on", func() bool {
		hb, _, _ := h.srv.nodeStatusOf("ep_m4", time.Now())
		return control.ComputeOn(hb.Compute)
	})
	two := 2
	m4.setOpGet(finished("failed", map[string]any{"error": map[string]any{"code": "AT_CAPACITY", "exit": two,
		"stderr1": "fleet-m4 is full: 8/8 sessions"}}))
	st, out = clientPlace(t, h, lease, key, map[string]any{"repo": writeRepo, "kind": "issue", "issue": 31})
	if st != 200 || out.Exit != 5 || out.Line != "DECLINED m4 "+out.OperationID+" 2\tfleet-m4 is full: 8/8 sessions" {
		t.Fatalf("full m4 = %d %+v; want DECLINED with m4's line", st, out)
	}
	if ls, _ := h.srv.Store.Leases(time.Now()); len(ls) != 0 {
		t.Fatalf("a declined start kept its lease: %+v", ls)
	}

	// #33 held by m5's own worker: HELD m5, exit 3, nothing sent.
	if st, _ := leaseCall(t, h, h.tokens["m5"], map[string]any{"action": "acquire", "repo": writeRepo, "issue": 33,
		"worker_id": issueWID(f5.FleetID, 33)}); st != 200 {
		t.Fatal("m5's lease")
	}
	n := m4.count()
	st, out = clientPlace(t, h, lease, key, map[string]any{"repo": writeRepo, "kind": "issue", "issue": 33})
	if st != 200 || out.Exit != 3 || !strings.HasPrefix(out.Line, "HELD m5\t") || m4.count() != n {
		t.Fatalf("held = %d %+v; want HELD m5 and nothing sent", st, out)
	}
}

// restore finds the machine whose /fleet-history holds the row (the record
// its node uploaded at the reap) and resumes the key there; a key no machine
// has is refused, never guessed.
func TestClientPlaceRestoreFindsHistoryRow(t *testing.T) {
	h, m5, m4, _, f4 := twoNodes(t)
	lease, key := clientLeaseFor(t, h)
	up := map[string]any{"worker_id": f4.FleetID + "/issue-21", "repo": writeRepo, "issue": 21, "key": "issue-21",
		"records": []map[string]any{{"kind": "history", "name": "landed", "stage": "landed",
			"content": []byte("2026-10-05T01:00:00Z\t21\ttitle\t-\t-\t-\t-\t-\t-\tunlanded\t-\n")}}}
	if st, _, raw := workerRecordsDo(t, h, h.tokens["m4"], http.MethodPost, "", up); st != 200 {
		t.Fatalf("m4's history upload = %d %s", st, raw)
	}
	m4.setOpGet(finished("succeeded", map[string]any{"workers": []map[string]any{{"window_id": "@9",
		"worker_id": f4.FleetID + "/issue-21"}}}))

	st, out := clientPlace(t, h, lease, key, map[string]any{"repo": writeRepo, "kind": "restore", "key": "issue-21"})
	if st != 200 || out.Exit != 0 || !strings.HasPrefix(out.Line, "REMOTE m4 "+out.OperationID+" done "+f4.FleetID+"/issue-21\t") {
		t.Fatalf("restore = %d %+v; want resumed on m4", st, out)
	}
	if m5.count() != 0 || m4.count() != 1 || m4.writes[0]["action"] != "worker_resume" {
		t.Fatalf("writes m5=%d m4=%d %v; want one worker_resume on m4", m5.count(), m4.count(), m4.writes)
	}
	if p := m4.writes[0]["params"].(map[string]any); p["worker_id"] != f4.FleetID+"/issue-21" {
		t.Fatalf("resume params = %v", p)
	}

	st, out = clientPlace(t, h, lease, key, map[string]any{"repo": writeRepo, "kind": "restore", "key": "scratch-404"})
	if st != 200 || out.Exit != 4 || !strings.HasPrefix(out.Line, "REFUSED NOT_FOUND\t") || m4.count() != 1 {
		t.Fatalf("unknown key = %d %+v; want REFUSED NOT_FOUND", st, out)
	}
}

// No lease at all: 401 — a viewer token alone opens nothing.
func TestClientPlaceNeedsALease(t *testing.T) {
	h, _, m4, _, _ := twoNodes(t)
	if st, _ := clientPlace(t, h, "", strings.Repeat("a", 64), map[string]any{"repo": writeRepo, "kind": "scratch"}); st != 401 {
		t.Fatalf("no lease = %d; want 401", st)
	}
	if m4.count() != 0 {
		t.Fatal("sent a write without a lease")
	}
}
