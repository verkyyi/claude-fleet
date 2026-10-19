package api

import (
	"encoding/json"
	"net/http"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

// An EPIC is a parent task and its children (claude-fleet#4957): the driver's
// tick is a progress report on the parent, projected on the parent's read and
// the person's list; the children read carries one count per outcome.
func TestTaskEpicParentProgressAndChildrenSummary(t *testing.T) {
	h, _, nodes := peerHarness(t)
	h.srv.FleetAdmins = []string{"frank"}
	for name, fid := range map[string]string{"verk4": wrFleetM4, "verk5": wrFleetM5} {
		if _, err := h.srv.Store.RecordFleetSnapshot(nodes[name].id, name, "frank", name,
			[]store.FleetReport{{FleetID: fid, Name: "fleet", Repo: "org/repo", WorkersJSON: "[]"}}, time.Now()); err != nil {
			t.Fatal(err)
		}
	}
	start := func(name, fid, sid, token, parentTask, parentSession string) store.FleetTask {
		code, rec := nodeTaskCall(t, h, nodes[name].token, http.MethodPost, NodeTasksPath, map[string]any{
			"authority_version": 1, "token": token, "title": "EPIC · " + token, "requested_agent": "claude", "resolved_agent": "claude",
			"parent_task": parentTask, "parent_session": parentSession})
		if code != 200 {
			t.Fatalf("accept %s: %d %v", token, code, rec)
		}
		ref := rec["id"].(string)
		for _, m := range []map[string]any{
			{"kind": "claim", "idempotency_key": "claim", "generation": 1, "worker_id": fid + "/" + sid},
			{"kind": "transition", "idempotency_key": "start", "generation": 1, "expected_worker": fid + "/" + sid, "state": "running", "actual_agent": "claude", "evidence": "fixture native receipt"},
		} {
			if code, rec = nodeTaskCall(t, h, nodes[name].token, http.MethodPost, NodeTasksPath+"/"+ref, map[string]any{"authority_version": 1, "mutation": m}); code != 200 {
				t.Fatalf("mutate %s: %d %v", token, code, rec)
			}
		}
		data, _ := json.Marshal(rec)
		var task store.FleetTask
		if err := json.Unmarshal(data, &task); err != nil {
			t.Fatal(err)
		}
		return task
	}
	report := func(name string, task store.FleetTask, event, outcome, status, summary string) {
		r := store.TaskReport{EventID: event, Task: task.Ref, Owner: task.Owner, Generation: 1, WorkerID: task.ExecutionOwner,
			ParentTask: task.ParentTask, ParentSession: task.ParentSession, ParentGeneration: task.ParentGeneration,
			Outcome: outcome, Status: status, Summary: summary, Evidence: "fixture " + event}
		if code, out := nodeTaskCall(t, h, nodes[name].token, http.MethodPost, NodeTasksPath+"/"+task.Ref+"/reports", r); code != 200 {
			t.Fatalf("report %s: %d %v", event, code, out)
		}
	}
	parent := start("verk5", wrFleetM5, wrFid, "epic", "", "")
	ok := start("verk4", wrFleetM4, wrFid, "c1-lands", parent.Ref, parent.ExecutionOwner)
	bad := start("verk4", wrFleetM4, "33333333-3333-4333-8333-333333333333", "c2-fails", parent.Ref, parent.ExecutionOwner)
	if ok.ParentTask != parent.Ref || bad.ParentTask != parent.Ref {
		t.Fatalf("children not bound to the parent: %q %q", ok.ParentTask, bad.ParentTask)
	}

	// No tick yet: no progress on the parent's read.
	if code, out := nodeTaskCall(t, h, nodes["verk5"].token, http.MethodGet, NodeTasksPath+"/"+parent.Ref, nil); code != 200 || out["progress"] != nil {
		t.Fatalf("progress before any tick: %d %v", code, out["progress"])
	}
	report("verk5", parent, "tick-1", "", "waiting", "tick 1 · slots 2/4 · spawned C1 C2")
	report("verk5", parent, "tick-2", "", "waiting", "tick 2 · landed C1")
	code, out := nodeTaskCall(t, h, nodes["verk5"].token, http.MethodGet, NodeTasksPath+"/"+parent.Ref, nil)
	p, _ := out["progress"].(map[string]any)
	if code != 200 || p == nil || p["summary"] != "tick 2 · landed C1" || p["status"] != "waiting" {
		t.Fatalf("parent progress: %d %v", code, out["progress"])
	}
	// The person's list carries the same word.
	views, err := h.srv.taskViews([]store.FleetTask{parent})
	if err != nil || views[0].Progress == nil || views[0].Progress.Summary != "tick 2 · landed C1" {
		t.Fatalf("list progress: %v %+v", err, views)
	}

	report("verk4", ok, "done", "succeeded", "merged", "C1 merged")
	report("verk4", bad, "fail", "failed", "failed", "C2 red twice")
	code, out = nodeTaskCall(t, h, nodes["verk5"].token, http.MethodGet, NodeTasksPath+"/"+parent.Ref+"/children", nil)
	sum, _ := out["summary"].(map[string]any)
	if code != 200 || len(out["children"].([]any)) != 2 || sum["succeeded"] != float64(1) || sum["failed"] != float64(1) || sum["open"] != float64(0) {
		t.Fatalf("children summary: %d %v", code, out)
	}
	// A child's terminal report is never the parent's progress.
	if _, out = nodeTaskCall(t, h, nodes["verk5"].token, http.MethodGet, NodeTasksPath+"/"+parent.Ref, nil); out["progress"].(map[string]any)["summary"] != "tick 2 · landed C1" {
		t.Fatalf("parent progress moved: %v", out["progress"])
	}
	// A child with only an outcome has no progress word.
	if _, out = nodeTaskCall(t, h, nodes["verk4"].token, http.MethodGet, NodeTasksPath+"/"+ok.Ref, nil); out["progress"] != nil {
		t.Fatalf("terminal report projected as progress: %v", out["progress"])
	}
}
