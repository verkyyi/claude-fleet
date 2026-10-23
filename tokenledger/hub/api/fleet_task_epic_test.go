package api

import (
	"net/http"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

// An EPIC is a parent task and its children (claude-fleet#4957). Since EPIC T497
// C8 the driver's tick is a progress word on its window's ID (C12) and each
// member's end its ID's result: the parent's read and the person's list carry
// the tick, the children read one count per outcome.
func TestTaskEpicParentProgressAndChildrenSummary(t *testing.T) {
	h, _, nodes := peerHarness(t)
	h.srv.FleetAdmins = []string{"frank"}
	for name, fid := range map[string]string{"verk4": wrFleetM4, "verk5": wrFleetM5} {
		if _, err := h.srv.Store.RecordFleetSnapshot(nodes[name].id, name, "frank", name,
			[]store.FleetReport{{FleetID: fid, Name: "fleet", Repo: "org/repo", WorkersJSON: "[]"}}, time.Now()); err != nil {
			t.Fatal(err)
		}
	}
	push := func(name, id string, events ...map[string]any) {
		t.Helper()
		ep, err := h.srv.Store.LiveEndpoint(nodes[name].id)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := h.srv.Store.ApplyFleetIDEvents(store.FleetIDPush{Owner: "operator", EndpointID: ep.ID, Machine: name, Login: "frank", ID: id, Events: events}); err != nil {
			t.Fatal(err)
		}
	}
	accept := func(name, token, parentTask, parentSession string) string {
		t.Helper()
		code, rec := nodeTaskCall(t, h, nodes[name].token, http.MethodPost, NodeTasksPath, map[string]any{
			"authority_version": 1, "token": token, "title": "EPIC · " + token, "requested_agent": "claude", "resolved_agent": "claude",
			"parent_task": parentTask, "parent_session": parentSession})
		if code != 200 {
			t.Fatalf("accept %s: %d %v", token, code, rec)
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
	const fidP, fidA, fidB = "aaaaaaaa-1111-4111-8111-111111111111", "bbbbbbbb-2222-4222-8222-222222222222", "cccccccc-3333-4333-8333-333333333333"
	parent := accept("verk5", "epic", "", "")
	push("verk5", fidP, map[string]any{"ev": "opened", "task": parent, "id": fidP, "seq": 1.0, "ts": 1.0})
	ok := accept("verk4", "c1-lands", parent, wrFleetM5+"/"+fidP)
	bad := accept("verk4", "c2-fails", parent, wrFleetM5+"/"+fidP)
	push("verk4", fidA, map[string]any{"ev": "opened", "task": ok, "id": fidA, "seq": 1.0, "ts": 1.0})
	push("verk4", fidB, map[string]any{"ev": "opened", "task": bad, "id": fidB, "seq": 1.0, "ts": 1.0})

	// No tick yet: no progress on the parent's read.
	if code, out := nodeTaskCall(t, h, nodes["verk5"].token, http.MethodGet, NodeTasksPath+"/"+parent, nil); code != 200 || out["progress"] != nil {
		t.Fatalf("progress before any tick: %d %v", code, out["progress"])
	}
	push("verk5", fidP, map[string]any{"ev": "progress", "state": "waiting", "summary": "tick 1 · slots 2/4", "id": fidP, "seq": 2.0, "ts": 2.0},
		map[string]any{"ev": "progress", "state": "waiting", "summary": "tick 2 · landed C1", "id": fidP, "seq": 3.0, "ts": 3.0})
	code, out := nodeTaskCall(t, h, nodes["verk5"].token, http.MethodGet, NodeTasksPath+"/"+parent, nil)
	p, _ := out["progress"].(map[string]any)
	if code != 200 || p == nil || p["summary"] != "tick 2 · landed C1" || p["status"] != "waiting" {
		t.Fatalf("parent progress: %d %v", code, out["progress"])
	}
	rec, err := h.srv.Store.FleetTask(store.ParseTaskRef(parent))
	if err != nil {
		t.Fatal(err)
	}
	if views, err := h.srv.taskViews([]store.FleetTask{rec}); err != nil || views[0].Progress == nil || views[0].Progress.Summary != "tick 2 · landed C1" {
		t.Fatalf("list progress: %v %+v", err, views)
	}

	push("verk4", fidA, map[string]any{"ev": "result", "state": "merged", "pr": "1", "id": fidA, "seq": 2.0, "ts": 4.0})
	push("verk4", fidB, map[string]any{"ev": "result", "state": "failed", "id": fidB, "seq": 2.0, "ts": 4.0})
	code, out = nodeTaskCall(t, h, nodes["verk5"].token, http.MethodGet, NodeTasksPath+"/"+parent+"/children", nil)
	sum, _ := out["summary"].(map[string]any)
	if code != 200 || len(out["children"].([]any)) != 2 || sum["succeeded"] != float64(1) || sum["failed"] != float64(1) || sum["open"] != float64(0) {
		t.Fatalf("children summary: %d %v", code, out)
	}
	// A child's result is never the parent's progress, and has no progress word.
	if _, out = nodeTaskCall(t, h, nodes["verk5"].token, http.MethodGet, NodeTasksPath+"/"+parent, nil); out["progress"].(map[string]any)["summary"] != "tick 2 · landed C1" {
		t.Fatalf("parent progress moved: %v", out["progress"])
	}
	if _, out = nodeTaskCall(t, h, nodes["verk4"].token, http.MethodGet, NodeTasksPath+"/"+ok, nil); out["progress"] != nil {
		t.Fatalf("a result projected as progress: %v", out["progress"])
	}
}

// 「起来了」 is the record's window's ID having a native segment (claude-fleet T629,
// EPIC T580 C5) — the same read for both agents: a Codex window's runtime writes
// its first thread's segment before the first turn, as Claude's SessionStart does.
func TestTaskStartedIsTheIDsFirstSegment(t *testing.T) {
	h, _, nodes := peerHarness(t)
	if _, err := h.srv.Store.RecordFleetSnapshot(nodes["verk4"].id, "verk4", "frank", "verk4",
		[]store.FleetReport{{FleetID: wrFleetM4, Name: "fleet", Repo: "org/repo", WorkersJSON: "[]"}}, time.Now()); err != nil {
		t.Fatal(err)
	}
	ep, err := h.srv.Store.LiveEndpoint(nodes["verk4"].id)
	if err != nil {
		t.Fatal(err)
	}
	push := func(id string, events ...map[string]any) {
		t.Helper()
		if _, err := h.srv.Store.ApplyFleetIDEvents(store.FleetIDPush{Owner: "operator", EndpointID: ep.ID, Machine: "verk4", Login: "frank", ID: id, Events: events}); err != nil {
			t.Fatal(err)
		}
	}
	for i, agent := range []string{"claude", "codex"} {
		fid := []string{"dddddddd-4444-4444-8444-444444444444", "eeeeeeee-5555-4555-8555-555555555555"}[i]
		code, rec := nodeTaskCall(t, h, nodes["verk4"].token, http.MethodPost, NodeTasksPath, map[string]any{
			"authority_version": 1, "token": "start-" + agent, "title": "start · " + agent, "requested_agent": agent, "resolved_agent": agent})
		if code != 200 {
			t.Fatalf("accept %s: %d %v", agent, code, rec)
		}
		ref := rec["id"].(string)
		push(fid, map[string]any{"ev": "opened", "task": ref, "agent": agent, "id": fid, "seq": 1.0, "ts": 10.0})
		if code, out := nodeTaskCall(t, h, nodes["verk4"].token, http.MethodGet, NodeTasksPath+"/"+ref, nil); code != 200 || out["started"] != nil {
			t.Fatalf("%s: started before any segment: %d %v", agent, code, out["started"])
		}
		push(fid, map[string]any{"ev": "native", "agent": agent, "native": "n1-" + agent, "trigger": "startup", "id": fid, "seq": 2.0, "ts": 11.0},
			map[string]any{"ev": "native", "agent": agent, "native": "n2-" + agent, "trigger": "clear", "id": fid, "seq": 3.0, "ts": 12.0})
		code, out := nodeTaskCall(t, h, nodes["verk4"].token, http.MethodGet, NodeTasksPath+"/"+ref, nil)
		st, _ := out["started"].(map[string]any)
		if code != 200 || st == nil || st["agent"] != agent || st["segments"] != float64(2) || st["at"] != "1970-01-01T00:00:11Z" {
			t.Fatalf("%s: started: %d %v", agent, code, out["started"])
		}
	}
}
