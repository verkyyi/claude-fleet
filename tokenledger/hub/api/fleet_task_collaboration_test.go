package api

import (
	"net/http"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

// The task graph's node API after EPIC T497 C8: children name their parent
// record in historical fixtures; a fenced report an older node posts is
// answered ID_SWITCH. New writes do not bind a Parent.
func TestTaskCollaborationAPIAuthority(t *testing.T) {
	h, _, nodes := peerHarness(t)
	h.srv.FleetAdmins = []string{"frank"}
	for name, fid := range map[string]string{"verk4": wrFleetM4, "verk5": wrFleetM5} {
		if _, err := h.srv.Store.RecordFleetSnapshot(nodes[name].id, name, "frank", name,
			[]store.FleetReport{{FleetID: fid, Name: "fleet", Repo: "org/repo", WorkersJSON: "[]"}}, time.Now()); err != nil {
			t.Fatal(err)
		}
	}
	accept := func(name, token, parentTask, parentSession, ticket string) string {
		t.Helper()
		input := map[string]any{"authority_version": 1, "token": token, "title": token,
			"requested_agent": "codex", "resolved_agent": "codex", "parent_task": parentTask, "parent_session": parentSession, "ticket_ref": ticket}
		code, rec := nodeTaskCall(t, h, nodes[name].token, http.MethodPost, NodeTasksPath, input)
		if code != 200 {
			t.Fatalf("accept: %d %v", code, rec)
		}
		// Historical view fixture: acceptance no longer writes these columns.
		if rec["parent_task"] != nil || rec["parent_session"] != nil {
			t.Fatal("new acceptance bound a Parent")
		}
		if parentTask != "" || parentSession != "" {
			if _, err := h.srv.Store.DB().Exec(`UPDATE fleet_tasks SET parent_task=?, parent_session=? WHERE id=?`, parentTask, parentSession, store.ParseTaskRef(rec["id"].(string))); err != nil {
				t.Fatal(err)
			}
		}
		return rec["id"].(string)
	}
	parent := accept("verk5", "parent", "", "", "gh:one/repo#7")
	child := accept("verk4", "child", parent, wrFleetM5+"/"+wrFid, "gh:two/repo#7")
	path := NodeTasksPath + "/" + child
	code, out := nodeTaskCall(t, h, nodes["verk5"].token, http.MethodGet, NodeTasksPath+"/"+parent+"/children", nil)
	if code != 200 || len(out["children"].([]any)) != 1 {
		t.Fatalf("children: %d %v", code, out)
	}
	report := map[string]any{"event_id": "result", "task": child, "owner": "operator", "generation": 1, "outcome": "succeeded", "evidence": "x"}
	if code, out = nodeTaskCall(t, h, nodes["verk4"].token, http.MethodPost, path+"/reports", report); code != 409 || out["code"] != "ID_SWITCH" {
		t.Fatalf("a fenced report: %d %v", code, out)
	}
	if code, _ = nodeTaskCall(t, h, nodes["bob4"].token, http.MethodGet, path, nil); code != 404 {
		t.Fatalf("foreign owner: %d", code)
	}
}
