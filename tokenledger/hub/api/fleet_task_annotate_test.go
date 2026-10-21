package api

import (
	"net/http"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

// claude-fleet T792: a dispatched (authoritative) record takes its session's ask
// and park — 「问过你」 / 「停放」 — and nothing else of a plain write.
func TestTaskAnnotateAuthoritative(t *testing.T) {
	h, _, nodes := peerHarness(t)
	h.srv.FleetAdmins = []string{"frank"}
	if _, err := h.srv.Store.RecordFleetSnapshot(nodes["verk4"].id, "verk4", "frank", "verk4",
		[]store.FleetReport{{FleetID: wrFleetM4, Name: "fleet", Repo: "org/repo", WorkersJSON: "[]"}}, time.Now()); err != nil {
		t.Fatal(err)
	}
	tok := nodes["verk4"].token
	code, rec := nodeTaskCall(t, h, tok, http.MethodPost, NodeTasksPath, map[string]any{"authority_version": 1, "token": "epic-1",
		"title": "EPIC 父任务", "requested_agent": "claude", "resolved_agent": "claude"})
	if code != 200 {
		t.Fatalf("accept: %d %v", code, rec)
	}
	ref, gen, state := rec["id"].(string), rec["generation"], rec["state"]
	post := func(body map[string]any) (int, map[string]any) {
		return nodeTaskCall(t, h, tok, http.MethodPost, NodeTasksPath+"/"+ref, body)
	}
	if code, rec := post(map[string]any{"asked": "⛔ blocked: 要不要合？"}); code != 200 || rec["asked"] != "⛔ blocked: 要不要合？" ||
		rec["generation"] != gen || rec["state"] != state {
		t.Fatalf("ask on an accepted record: %d %v", code, rec)
	}
	if code, rec := post(map[string]any{"parked": "停放：等 #12"}); code != 200 || rec["parked"] != "停放：等 #12" || rec["asked"] != "⛔ blocked: 要不要合？" {
		t.Fatalf("park: %d %v", code, rec)
	}
	if code, rec := post(map[string]any{"clear": []string{"asked", "parked"}}); code != 200 || rec["asked"] != "" || rec["parked"] != "" {
		t.Fatalf("clear: %d %v", code, rec)
	}
	// Anything beyond the annotations is still the fence.
	for _, body := range []map[string]any{
		{"asked": "x", "state": "open"},
		{"note": "x"},
		{"clear": []string{"note"}},
		{"asked": "x", "key": "scratch-7"},
	} {
		if code, rec := post(body); code != http.StatusConflict {
			t.Fatalf("%v on an authoritative record: %d %v, want 409", body, code, rec)
		}
	}
	// Another login's node cannot annotate it.
	if code, _ := nodeTaskCall(t, h, nodes["bob4"].token, http.MethodPost, NodeTasksPath+"/"+ref, map[string]any{"asked": "x"}); code == 200 {
		t.Fatalf("another owner's node annotated the record")
	}
}
