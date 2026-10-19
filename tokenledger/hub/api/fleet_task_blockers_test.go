package api

import (
	"encoding/json"
	"net/http"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

func TestNodeTaskBlockerContract(t *testing.T) {
	h, _, nodes := peerHarness(t)
	h.srv.FleetAdmins = []string{"frank"}
	for name, fid := range map[string]string{"verk4": wrFleetM4, "verk5": wrFleetM5} {
		if _, err := h.srv.Store.RecordFleetSnapshot(nodes[name].id, name, "frank", name, []store.FleetReport{{FleetID: fid, Name: "fleet", Repo: "org/repo", WorkersJSON: "[]"}}, time.Now()); err != nil {
			t.Fatal(err)
		}
	}
	makeTask := func(name, fid, ticket string) store.FleetTask {
		t.Helper()
		code, rec := nodeTaskCall(t, h, nodes[name].token, http.MethodPost, NodeTasksPath, map[string]any{"authority_version": 1, "token": name, "title": name, "requested_agent": "codex", "resolved_agent": "codex", "ticket_ref": ticket})
		if code != 200 {
			t.Fatalf("create: %d %v", code, rec)
		}
		path := NodeTasksPath + "/" + rec["id"].(string)
		for _, m := range []map[string]any{
			{"kind": "claim", "idempotency_key": "claim", "generation": 1, "worker_id": fid + "/" + wrFid},
			{"kind": "transition", "idempotency_key": "run", "generation": 1, "expected_worker": fid + "/" + wrFid, "state": "running", "actual_agent": "codex", "evidence": "fixture native receipt"},
		} {
			code, rec = nodeTaskCall(t, h, nodes[name].token, http.MethodPost, path, map[string]any{"authority_version": 1, "mutation": m})
			if code != 200 {
				t.Fatalf("mutate: %d %v", code, rec)
			}
		}
		b, _ := json.Marshal(rec)
		var task store.FleetTask
		if err := json.Unmarshal(b, &task); err != nil {
			t.Fatal(err)
		}
		return task
	}
	work := makeTask("verk4", wrFleetM4, "gh:one/repo#7")
	dep := makeTask("verk5", wrFleetM5, "gh:two/repo#7")
	path := NodeTasksPath + "/" + work.Ref
	blocker := map[string]any{"version": 1, "action": "create", "blocker_id": "dependency-one", "repo": work.Repo, "ticket_ref": work.TicketRef, "reason": "explicit dependency", "evidence": "fixture evidence",
		"dependency": map[string]any{"task": dep.Ref, "owner": dep.Owner, "repo": dep.Repo, "ticket_ref": dep.TicketRef, "generation": dep.Generation, "worker_id": dep.ExecutionOwner}}
	m := map[string]any{"kind": "blocker", "idempotency_key": "create", "generation": work.Generation, "expected_worker": work.ExecutionOwner, "blocker": blocker}
	for i := 0; i < 2; i++ {
		if code, rec := nodeTaskCall(t, h, nodes["verk4"].token, http.MethodPost, path, map[string]any{"authority_version": 1, "mutation": m}); code != 200 || rec["task_blockers"] == nil {
			t.Fatalf("blocker create/replay: %d %v", code, rec)
		}
	}
	if code, _ := nodeTaskCall(t, h, nodes["bob4"].token, http.MethodGet, path, nil); code != 404 {
		t.Fatalf("foreign account read: %d", code)
	}
	// A report cannot mix clearing a blocker with a terminal result, nor speak
	// for the other node even within the same account.
	report := map[string]any{"event_id": "resolve", "task": work.Ref, "owner": work.Owner, "ticket_ref": work.TicketRef, "generation": work.Generation, "worker_id": work.ExecutionOwner, "status": "waiting", "evidence": "explicit owner resolve", "blocker": blocker}
	blocker["action"] = "resolve"
	if code, _ := nodeTaskCall(t, h, nodes["verk5"].token, http.MethodPost, path+"/reports", report); code != 409 {
		t.Fatalf("foreign endpoint: %d", code)
	}
	report["outcome"] = "succeeded"
	if code, _ := nodeTaskCall(t, h, nodes["verk4"].token, http.MethodPost, path+"/reports", report); code != 400 {
		t.Fatalf("mixed outcome: %d", code)
	}
	delete(report, "outcome")
	blocker["version"] = 2
	if code, _ := nodeTaskCall(t, h, nodes["verk4"].token, http.MethodPost, path+"/reports", report); code != 400 {
		t.Fatalf("unknown version: %d", code)
	}
	blocker["version"] = 1
	for i := 0; i < 2; i++ {
		if code, rec := nodeTaskCall(t, h, nodes["verk4"].token, http.MethodPost, path+"/reports", report); code != 200 || rec["disposition"] != "progress" {
			t.Fatalf("resolve/replay: %d %v", code, rec)
		}
	}
	code, rec := nodeTaskCall(t, h, nodes["verk4"].token, http.MethodGet, path, nil)
	if code != 200 {
		t.Fatal(code)
	}
	task := rec["task"].(map[string]any)
	items := task["task_blockers"].(map[string]any)["items"].([]any)
	if len(items) != 1 || items[0].(map[string]any)["state"] != "resolved" || task["state"] != "running" || task["outcome"] != nil {
		t.Fatalf("projection/lifecycle: %v", task)
	}
	t.Log("fixture API: task mutation + report replay, foreign account/endpoint rejected, version refused, read-only projection independent of outcome")
}
