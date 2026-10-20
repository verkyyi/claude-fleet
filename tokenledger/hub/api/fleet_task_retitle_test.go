package api

import (
	"net/http"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

// A blank new session's record opens on a placeholder title and its first
// prompt's first line replaces it — ONCE (claude-fleet T652, EPIC T651 C1): the
// rename compares on the placeholder, so a second one changes nothing, a wrong
// `from` changes nothing, and an empty title is refused.
func TestTaskRetitleOnce(t *testing.T) {
	h, _, nodes := peerHarness(t)
	h.srv.FleetAdmins = []string{"frank"}
	if _, err := h.srv.Store.RecordFleetSnapshot(nodes["verk4"].id, "verk4", "frank", "verk4",
		[]store.FleetReport{{FleetID: wrFleetM4, Name: "fleet", Repo: "org/repo", WorkersJSON: "[]"}}, time.Now()); err != nil {
		t.Fatal(err)
	}
	tok := nodes["verk4"].token
	code, rec := nodeTaskCall(t, h, tok, http.MethodPost, NodeTasksPath, map[string]any{"authority_version": 1, "token": "blank-1",
		"title": "新会话", "requested_agent": "claude", "resolved_agent": "claude"})
	if code != 200 {
		t.Fatalf("accept: %d %v", code, rec)
	}
	ref := rec["id"].(string)
	retitle := func(key, from, title string) (int, map[string]any) {
		return nodeTaskCall(t, h, tok, http.MethodPost, NodeTasksPath+"/"+ref, map[string]any{"authority_version": 1,
			"mutation": map[string]any{"kind": "retitle", "idempotency_key": key, "from": from, "title": title}})
	}
	title := func() any {
		_, got := nodeTaskCall(t, h, tok, http.MethodGet, NodeTasksPath+"/"+ref, nil)
		return got["task"].(map[string]any)["title"]
	}
	if code, rec := retitle("r0", "新会话", "  "); code != 400 || title() != "新会话" {
		t.Fatalf("an empty title: %d %v, title %v", code, rec, title())
	}
	if code, rec := retitle("r1", "别的", "修一下面板"); code != 200 || title() != "新会话" {
		t.Fatalf("a wrong from: %d %v, title %v", code, rec, title())
	}
	if code, rec := retitle("r2", "新会话", "修一下面板读取变慢"); code != 200 || rec["title"] != "修一下面板读取变慢" {
		t.Fatalf("retitle: %d %v", code, rec)
	}
	if code, rec := retitle("r3", "新会话", "第二句"); code != 200 || title() != "修一下面板读取变慢" {
		t.Fatalf("a second retitle changed it: %d %v, title %v", code, rec, title())
	}
}
