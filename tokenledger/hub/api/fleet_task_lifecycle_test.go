package api

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

// A dispatched task's record is its ticket (EPIC T497 C8): the node accepts it,
// nothing claims it (a claim is 409 ID_SWITCH for an older node), another
// account neither reads nor writes it, and the same request answers the same
// record while a changed one is refused.
func TestNodeTaskAuthorityBoundary(t *testing.T) {
	h, _, nodes := peerHarness(t)
	h.srv.FleetAdmins = []string{"frank"}
	node := nodes["bob4"]
	if _, err := h.srv.Store.RecordFleetSnapshot(node.id, "fixture-node", "bob", "fixture-machine",
		[]store.FleetReport{{FleetID: wrFleetM4, Name: "fleet", Repo: "org/repo", WorkersJSON: "[]"}}, time.Now()); err != nil {
		t.Fatal(err)
	}
	worker := wrFleetM4 + "/" + wrFid
	input := map[string]any{"token": "authoritative", "title": "Keep my request", "authority_version": 1,
		"requested_agent": "codex", "resolved_agent": "codex", "request_payload": map[string]any{"body": "original"}}
	st, rec := nodeTaskCall(t, h, node.token, http.MethodPost, NodeTasksPath, input)
	if st != 200 || rec["state"] != "accepted" || rec["generation"] != float64(1) || rec["owner"] != pBob {
		t.Fatalf("accept: %d %v", st, rec)
	}
	ref := rec["id"].(string)
	path := NodeTasksPath + "/" + ref
	claim := map[string]any{"kind": "claim", "idempotency_key": "claim", "generation": 1, "worker_id": worker}
	if code, out := nodeTaskCall(t, h, node.token, http.MethodPost, path, map[string]any{"authority_version": 1, "mutation": claim}); code != 409 || out["code"] != "ID_SWITCH" {
		t.Fatalf("claim: %d %v", code, out)
	}
	if st, _ = nodeTaskCall(t, h, nodes["verk4"].token, http.MethodGet, path, nil); st != 404 {
		t.Fatalf("operator node read another account: %d", st)
	}
	if st, _ = nodeTaskCall(t, h, nodes["alice4"].token, http.MethodPost, path, map[string]any{"state": "done"}); st != 404 {
		t.Fatalf("foreign write: %d", st)
	}
	if st, _ = nodeTaskCall(t, h, node.token, http.MethodPost, path, map[string]any{"state": "done"}); st != 409 {
		t.Fatalf("downlevel write: %d", st)
	}
	found := false
	for _, row := range taskRecords(t, h) {
		if row["id"] == ref {
			found = true
			if row["state"] != "accepted" || row["execution_owner"] != nil {
				t.Fatalf("list: %v", row)
			}
		}
	}
	if !found {
		t.Fatal("task missing from viewer")
	}
	if st, _ = taskPost(t, h, FleetTasksPath+"/"+ref+"/issue", map[string]any{"repo": "org/repo"}); st != 404 {
		t.Fatalf("a record files no issue: %d", st)
	}
	if st, got := nodeTaskCall(t, h, node.token, http.MethodPost, NodeTasksPath, input); st != 200 || got["id"] != ref || got["state"] != "accepted" {
		t.Fatalf("accepted replay: %d %v", st, got)
	}
	input["request_payload"] = map[string]any{"body": "changed"}
	if st, _ = nodeTaskCall(t, h, node.token, http.MethodPost, NodeTasksPath, input); st != 409 {
		t.Fatalf("changed payload: %d", st)
	}
}

// The Tasks page reads a record's end off its window's ID (EPIC T497 C8) with no
// live inventory, and a pre-C8 landing off the archived report journal without
// changing that end.
func TestTaskPageConfirmedOutcomeAndLanding(t *testing.T) {
	h, _, nodes := peerHarness(t)
	h.srv.FleetAdmins = []string{"frank"}
	node := nodes["verk4"]
	if _, err := h.srv.Store.RecordFleetSnapshot(node.id, "fixture-node", "frank", "fixture-machine",
		[]store.FleetReport{{FleetID: wrFleetM4, Name: "fleet", Repo: "org/repo", WorkersJSON: "[]"}}, time.Now()); err != nil {
		t.Fatal(err)
	}
	code, rec := nodeTaskCall(t, h, node.token, http.MethodPost, NodeTasksPath, map[string]any{
		"authority_version": 1, "token": "page-landing", "title": "Page landing", "ticket_ref": "gh:org/repo#7",
		"requested_agent": "codex", "resolved_agent": "codex"})
	if code != 200 {
		t.Fatal(code, rec)
	}
	ref := rec["id"].(string)
	read := func() map[string]any {
		t.Helper()
		list := getFleet(t, h, FleetTasksPath, 200)
		if list["observed_at"] == "" {
			t.Fatal("missing observation time", list)
		}
		for _, item := range list["tasks"].([]any) {
			row := item.(map[string]any)
			if row["id"] == ref {
				return row
			}
		}
		t.Fatal("missing task", list)
		return nil
	}
	if row := read(); row["state"] != "accepted" || row["outcome"] != nil || row["pr_state"] != "unverified" || row["live"] != nil {
		t.Fatal("inventory absence changed work", row)
	}
	ep, err := h.srv.Store.LiveEndpoint(node.id)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := h.srv.Store.ApplyFleetIDEvents(store.FleetIDPush{Owner: "operator", EndpointID: ep.ID, Machine: "verk4", Login: "frank", ID: wrFid,
		Events: []map[string]any{{"ev": "opened", "task": ref, "id": wrFid, "seq": 1.0, "ts": 1.0},
			{"ev": "result", "state": "merged", "pr": "51", "id": wrFid, "seq": 2.0, "ts": 2.0}}}); err != nil {
		t.Fatal(err)
	}
	before := read()
	if before["outcome"] != "succeeded" {
		t.Fatal(before)
	}
	body, _ := json.Marshal(map[string]any{"report": map[string]any{"task": ref, "ticket_ref": "gh:org/repo#7", "generation": 1,
		"status": "merged", "evidence": `{"pr":"51","pr_state":"merged"}`}})
	if _, err := h.srv.Store.DB().Exec(fmt.Sprintf(`INSERT INTO fleet_operations (id, fleet_id, action, request, actor, idem, status, created, updated, result, worker_id)
		VALUES ('archived-land', '', 'task_report', '{}', 'operator', 'task-report:%s:land', 'recorded', '2026-10-19T00:00:00Z', '2026-10-19T00:00:00Z', '%s', '')`,
		ref, strings.ReplaceAll(string(body), "'", "''"))); err != nil {
		t.Fatal(err)
	}
	after := read()
	if after["pr_state"] != "merged" || after["outcome"] != before["outcome"] || after["evidence"] != before["evidence"] {
		t.Fatal("landing changed result", after)
	}
	detail := getFleet(t, h, FleetTasksPath+"/"+ref, 200)
	if detail["pr_state"] != "merged" || detail["outcome"] != "succeeded" {
		t.Fatal("detail disagrees with list", detail)
	}
}

func TestNodeTaskAuthorityRejectsMalformedContract(t *testing.T) {
	h, _, nodes := peerHarness(t)
	h.srv.FleetAdmins = []string{"frank"}
	for _, in := range []map[string]any{
		{"token": "a", "title": "test", "authority_version": 2},
		{"token": "a", "title": "test", "authority_version": 1, "requested_agent": "codex"},
		{"token": "a", "title": "test", "requested_agent": "codex", "resolved_agent": "codex"},
		{"token": "a", "title": "test", "authority_version": 1, "requested_agent": "codex", "resolved_agent": "codex", "ticket_ref": "7"},
		{"token": "a", "title": "test", "authority_version": 1, "requested_agent": "codex", "resolved_agent": "codex", "state": "done"},
		{"authority_version": 1, "mutation": map[string]any{"kind": "claim", "idempotency_key": "a", "generation": 1}},
	} {
		if st, out := nodeTaskCall(t, h, nodes["bob4"].token, http.MethodPost, NodeTasksPath, in); st != 400 {
			t.Fatalf("%v: %d %v", in, st, out)
		}
	}
}

// Native inventory is a separate last-known fact, including when its fleet is
// absent. Repeated Tasks reads do not renew the original inventory timestamp.
func TestTaskLastKnownInventoryEvidence(t *testing.T) {
	h, _, nodes := peerHarness(t)
	node := nodes["verk4"]
	at := time.Now().UTC().Add(-3 * time.Minute).Truncate(time.Second)
	worker := wrFleetM4 + "/" + wrFid
	raw, _ := json.Marshal([]map[string]any{nil, {"worker_id": worker, "state": "done", "needs": "perm"}})
	if _, err := h.srv.Store.RecordFleetSnapshot(node.id, "fixture-node", "frank", "fixture-machine",
		[]store.FleetReport{{FleetID: wrFleetM4, Name: "fleet", State: "ok", WorkersJSON: string(raw)}}, at); err != nil {
		t.Fatal(err)
	}
	task := store.FleetTask{WorkerID: worker, AuthorityVersion: 1}
	for pass := 0; pass < 2; pass++ {
		live := h.srv.taskLive(&task, map[string][]map[string]any{})
		if live["state"] != "done" || live["needs"] != "perm" || live["stale"] != true || live["observed_at"] != at.Format(time.RFC3339Nano) || live["source"] != "inventory" {
			t.Fatal(live)
		}
		if _, err := h.srv.Store.RecordFleetSnapshot(node.id, "fixture-node", "frank", "fixture-machine", nil, time.Now()); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := h.srv.Store.RecordFleetSnapshot(node.id, "fixture-node", "frank", "fixture-machine",
		[]store.FleetReport{{FleetID: wrFleetM4, Name: "fleet", State: "unknown", WorkersJSON: "[]"}}, time.Now()); err != nil {
		t.Fatal(err)
	}
	live := h.srv.taskLive(&task, map[string][]map[string]any{})
	if live["state"] != "done" || live["observed_at"] != nil || live["stale"] != true {
		t.Fatal("unknown inventory renewed the worker observation", live)
	}
	if task.Outcome != "" {
		t.Fatal("inventory became outcome", task)
	}
}
