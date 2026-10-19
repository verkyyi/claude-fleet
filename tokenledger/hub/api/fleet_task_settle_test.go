package api

import (
	"context"
	"errors"
	"net/http"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

// fakeIssueStates answers IssueMeta (nothing) and IssueState off a map; an
// issue not in it is GitHub not answering.
type fakeIssueStates map[string]string

func (f fakeIssueStates) IssueMeta(context.Context, string, int) (IssueMeta, error) {
	return IssueMeta{}, errors.New("unused")
}

func (f fakeIssueStates) IssueState(_ context.Context, repo string, n int) (string, error) {
	if st, ok := f[repo+"#"+strconv.Itoa(n)]; ok {
		return st, nil
	}
	return "", errors.New("HTTP 404")
}

func unverified(t *testing.T, h *harness) int {
	t.Helper()
	// Task authority is a person's (claude-fleet#4896): count each owner's.
	fs, err := h.srv.Store.Fleets()
	if err != nil {
		t.Fatal(err)
	}
	n, seen := 0, map[string]bool{}
	for _, f := range fs {
		owner := h.srv.endpointOwner(f.EndpointID)
		if owner == "" || seen[owner] {
			continue
		}
		seen[owner] = true
		bs, _, err := h.srv.Store.OwnerAuthorityBlockers(owner, nil, false)
		if err != nil {
			t.Fatal(err)
		}
		for _, b := range bs {
			if strings.HasPrefix(b, "legacy task owner is unverified") {
				n++
			}
		}
	}
	return n
}

// claude-fleet#4867: a legacy record ends only when its issue is closed AND its
// worker holds nothing; dry by default; the blocker query honours the end; a
// late node write never reopens it, and a node cannot write `closed` itself.
func TestNodeTaskSettleLegacy(t *testing.T) {
	h, _, nodes := peerHarness(t)
	h.srv.FleetAdmins = []string{"frank"}
	h.srv.IssueMeta = fakeIssueStates{"org/repo#1": "closed", "org/repo#2": "open"}
	gone := wrFleetM4 + "/" + wrFid
	live := wrFleetM4 + "/44444444-4444-4444-8444-444444444444"
	if _, err := h.srv.Store.RecordFleetSnapshot(nodes["verk4"].id, "verk4", "frank", "verk4", []store.FleetReport{{FleetID: wrFleetM4, Name: "fleet", Repo: "org/repo",
		WorkersJSON: `[{"worker_id":"` + live + `","key":"issue-9"}]`}}, time.Now()); err != nil {
		t.Fatal(err)
	}
	tok := nodes["verk4"].token
	mk := func(token, worker, issue string) string {
		t.Helper()
		body := map[string]any{"token": token, "title": token, "repo": "org/repo", "worker_id": worker, "state": "open"}
		if issue != "" {
			body["issue"] = issue
		}
		st, rec := nodeTaskCall(t, h, tok, http.MethodPost, NodeTasksPath, body)
		if st != 200 {
			t.Fatalf("create %s = %d %v", token, st, rec)
		}
		return rec["id"].(string)
	}
	done := mk("done", gone, "org/repo#1")
	mk("open-issue", gone, "org/repo#2")
	mk("live-worker", live, "org/repo#1")
	mk("unknown-issue", gone, "org/repo#3")
	mk("no-issue", gone, "")
	if n := unverified(t, h); n != 5 {
		t.Fatalf("blockers before = %d; want 5", n)
	}
	settle := func(apply bool) map[string]any {
		t.Helper()
		st, out := nodeTaskCall(t, h, tok, http.MethodPost, NodeTasksPath+"/settle", map[string]any{"repo": "org/repo", "apply": apply})
		if st != 200 {
			t.Fatalf("settle = %d %v", st, out)
		}
		return out
	}
	out := settle(false)
	kept, _ := out["kept"].(map[string]any)
	if out["settled"] != float64(1) || out["candidates"] != float64(5) || kept["issue open"] != float64(1) ||
		kept["worker live: in inventory"] != float64(1) || kept["issue state unknown: HTTP 404"] != float64(1) || kept["no issue on the record"] != float64(1) {
		t.Fatalf("dry = %v", out)
	}
	if n := unverified(t, h); n != 5 {
		t.Fatalf("a dry run wrote: blockers = %d", n)
	}
	if out = settle(true); out["settled"] != float64(1) {
		t.Fatalf("apply = %v", out)
	}
	if n := unverified(t, h); n != 4 {
		t.Fatalf("blockers after = %d; want 4", n)
	}
	if out = settle(true); out["settled"] != float64(0) || out["candidates"] != float64(4) {
		t.Fatalf("again = %v", out)
	}
	st, rec := nodeTaskCall(t, h, tok, http.MethodPost, NodeTasksPath+"/"+done, map[string]any{"state": "open"})
	if st != 200 || rec["state"] != "closed" || !strings.Contains(rec["note"].(string), "org/repo#1 closed") {
		t.Fatalf("late write = %d %v", st, rec)
	}
	if st, _ := nodeTaskCall(t, h, tok, http.MethodPost, NodeTasksPath+"/T2", map[string]any{"state": "closed"}); st != 400 {
		t.Fatalf("a node writing closed itself: HTTP %d; want 400", st)
	}
	if st, _ := nodeTaskCall(t, h, tok, http.MethodPost, NodeTasksPath+"/settle", map[string]any{"repo": "nope"}); st != 400 {
		t.Fatalf("no repo: HTTP %d; want 400", st)
	}
	// Another account's machine settles nothing of this one's.
	if out := func() map[string]any {
		_, o := nodeTaskCall(t, h, nodes["bob4"].token, http.MethodPost, NodeTasksPath+"/settle", map[string]any{"repo": "org/repo", "apply": true})
		return o
	}(); out["candidates"] != float64(0) {
		t.Fatalf("foreign settle = %v", out)
	}
}

// claude-fleet T479 (#4830's cutover): drained ends a legacy record whose
// worker is gone even while its issue is still open — GitHub not asked, the
// issue left as it is — and keeps one whose worker is live.
func TestNodeTaskSettleDrained(t *testing.T) {
	h, _, nodes := peerHarness(t)
	h.srv.FleetAdmins = []string{"frank"}
	h.srv.IssueMeta = fakeIssueStates{"org/repo#2": "open"}
	gone := wrFleetM4 + "/" + wrFid
	live := wrFleetM4 + "/44444444-4444-4444-8444-444444444444"
	if _, err := h.srv.Store.RecordFleetSnapshot(nodes["verk4"].id, "verk4", "frank", "verk4", []store.FleetReport{{FleetID: wrFleetM4, Name: "fleet", Repo: "org/repo",
		WorkersJSON: `[{"worker_id":"` + live + `","key":"issue-9"}]`}}, time.Now()); err != nil {
		t.Fatal(err)
	}
	tok := nodes["verk4"].token
	mk := func(token, worker string) string {
		t.Helper()
		st, rec := nodeTaskCall(t, h, tok, http.MethodPost, NodeTasksPath,
			map[string]any{"token": token, "title": token, "repo": "org/repo", "issue": "org/repo#2", "worker_id": worker, "state": "open"})
		if st != 200 {
			t.Fatalf("create %s = %d %v", token, st, rec)
		}
		return rec["id"].(string)
	}
	stopped := mk("stopped", gone)
	running := mk("running", live)
	settle := func(body map[string]any) map[string]any {
		t.Helper()
		body["repo"] = "org/repo"
		st, out := nodeTaskCall(t, h, tok, http.MethodPost, NodeTasksPath+"/settle", body)
		if st != 200 {
			t.Fatalf("settle = %d %v", st, out)
		}
		return out
	}
	// Without drained an open issue keeps both.
	if out := settle(map[string]any{"apply": true}); out["settled"] != float64(0) {
		t.Fatalf("undrained = %v", out)
	}
	if out := settle(map[string]any{"drained": true}); out["settled"] != float64(1) || out["drained"] != true {
		t.Fatalf("drained dry = %v", out)
	}
	if n := unverified(t, h); n != 2 {
		t.Fatalf("a dry drain wrote: blockers = %d", n)
	}
	out := settle(map[string]any{"drained": true, "apply": true})
	kept, _ := out["kept"].(map[string]any)
	if out["settled"] != float64(1) || kept["worker live: in inventory"] != float64(1) {
		t.Fatalf("drained apply = %v", out)
	}
	if n := unverified(t, h); n != 1 {
		t.Fatalf("blockers after drain = %d; want 1", n)
	}
	read := func(ref string) map[string]any {
		t.Helper()
		_, rec := nodeTaskCall(t, h, tok, http.MethodGet, NodeTasksPath+"/"+ref, nil)
		task, _ := rec["task"].(map[string]any)
		return task
	}
	if rec := read(stopped); rec["state"] != "closed" || !strings.Contains(rec["note"].(string), "drained for authority cutover; issue org/repo#2 still open") {
		t.Fatalf("drained record = %v", rec)
	}
	if rec := read(running); rec["state"] != "open" {
		t.Fatalf("a live worker's record was drained: %v", rec)
	}
}

// claude-fleet#4963: a record keeps its repo as written — `Org/Repo` is found by
// a settle of `org/repo` (or any case), and the records that name no repo are
// settled by owner through no_repo, never by a repo settle.
func TestNodeTaskSettleRepoCaseAndNoRepo(t *testing.T) {
	h, _, nodes := peerHarness(t)
	h.srv.FleetAdmins = []string{"frank"}
	h.srv.IssueMeta = fakeIssueStates{"Org/Repo#1": "closed", "org/repo#1": "closed", "Org/Epic#7": "closed"}
	gone := wrFleetM4 + "/" + wrFid
	tok := nodes["verk4"].token
	mk := func(token, repo, issue string) {
		t.Helper()
		body := map[string]any{"token": token, "title": token, "worker_id": gone, "state": "open", "issue": issue}
		if repo != "" {
			body["repo"] = repo
		}
		if st, rec := nodeTaskCall(t, h, tok, http.MethodPost, NodeTasksPath, body); st != 200 {
			t.Fatalf("create %s = %d %v", token, st, rec)
		}
	}
	mk("mixed", "Org/Repo", "Org/Repo#1")
	mk("norepo", "", "Org/Epic#7")
	if n := unverified(t, h); n != 2 {
		t.Fatalf("blockers before = %d; want 2", n)
	}
	settle := func(body map[string]any) (int, map[string]any) {
		t.Helper()
		return nodeTaskCall(t, h, tok, http.MethodPost, NodeTasksPath+"/settle", body)
	}
	if st, out := settle(map[string]any{"repo": "org/REPO"}); st != 200 || out["candidates"] != float64(1) || out["settled"] != float64(1) {
		t.Fatalf("mixed-case dry = %d %v", st, out)
	}
	if st, out := settle(map[string]any{"repo": "org/repo", "apply": true}); st != 200 || out["settled"] != float64(1) {
		t.Fatalf("mixed-case apply = %d %v", st, out)
	}
	if n := unverified(t, h); n != 1 {
		t.Fatalf("blockers after the repo settle = %d; want 1", n)
	}
	if st, _ := settle(map[string]any{"repo": "org/repo", "no_repo": true}); st != 400 {
		t.Fatalf("no_repo with a repo: HTTP %d; want 400", st)
	}
	if st, _ := settle(map[string]any{}); st != 400 {
		t.Fatalf("neither repo nor no_repo: HTTP %d; want 400", st)
	}
	// Another account's machine settles none of this one's no-repo records.
	if _, out := nodeTaskCall(t, h, nodes["bob4"].token, http.MethodPost, NodeTasksPath+"/settle", map[string]any{"no_repo": true, "apply": true}); out["candidates"] != float64(0) {
		t.Fatalf("foreign no_repo settle = %v", out)
	}
	if st, out := settle(map[string]any{"no_repo": true, "apply": true}); st != 200 || out["candidates"] != float64(1) || out["settled"] != float64(1) {
		t.Fatalf("no_repo apply = %d %v", st, out)
	}
	if n := unverified(t, h); n != 0 {
		t.Fatalf("blockers after = %d; want 0", n)
	}
}
