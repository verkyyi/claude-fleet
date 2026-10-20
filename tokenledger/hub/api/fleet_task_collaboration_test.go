package api

import (
	"net/http"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

// The task graph's node API after EPIC T497 C8: children name their parent
// record (no claim, no fenced report); a fenced report an older node posts is
// answered ID_SWITCH; a parent session must be a stable session of this account.
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
	for _, session := range []string{wrFleetM5 + "/scratch-7", "99999999-9999-4999-8999-999999999999/" + wrFid} {
		if err := h.srv.checkTaskParentSession("operator", session); err == nil {
			t.Fatalf("invalid/foreign parent accepted: %s", session)
		}
	}
}
