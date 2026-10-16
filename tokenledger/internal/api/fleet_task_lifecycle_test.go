package api

import (
	"encoding/json"
	"net/http"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

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
	command := func(tok string, want int, m map[string]any) map[string]any {
		t.Helper()
		code, out := nodeTaskCall(t, h, tok, http.MethodPost, path, map[string]any{"authority_version": 1, "mutation": m})
		if code != want {
			t.Fatalf("%v: HTTP %d %v, want %d", m, code, out, want)
		}
		return out
	}
	claim := map[string]any{"kind": "claim", "idempotency_key": "claim", "generation": 1, "worker_id": worker}
	rec = command(node.token, 200, claim)
	if rec["execution_owner"] != worker || rec["state"] != "starting" {
		t.Fatalf("claim: %v", rec)
	}
	// Same owner is not permission to speak for another endpoint's fleet.
	command(nodes["alice4"].token, 400, claim)
	if st, _ = nodeTaskCall(t, h, nodes["verk4"].token, http.MethodGet, path, nil); st != 404 {
		t.Fatalf("operator node read another account: %d", st)
	}
	if st, _ = nodeTaskCall(t, h, nodes["alice4"].token, http.MethodPost, path, map[string]any{"state": "done"}); st != 404 {
		t.Fatalf("foreign write: %d", st)
	}
	if st, _ = nodeTaskCall(t, h, node.token, http.MethodPost, path, map[string]any{"state": "done"}); st != 409 {
		t.Fatalf("downlevel write: %d", st)
	}
	wrong := map[string]any{"kind": "transition", "idempotency_key": "wrong-agent", "generation": 1, "expected_worker": worker, "state": "running", "actual_agent": "claude", "evidence": "fixture"}
	command(node.token, 409, wrong)
	run := map[string]any{"kind": "transition", "idempotency_key": "running", "generation": 1, "expected_worker": worker, "state": "running", "actual_agent": "codex", "evidence": "fixture native receipt"}
	rec = command(node.token, 200, run)
	// A successful operation reply or empty inventory is never terminal success.
	if st, got := nodeTaskCall(t, h, node.token, http.MethodGet, path, nil); st != 200 || got["task"].(map[string]any)["state"] != "running" {
		t.Fatalf("inventory absence: %d %v", st, got)
	}
	rows := taskRecords(t, h)
	found := false
	for _, row := range rows {
		if row["id"] == ref {
			found = true
			if row["state"] != "running" {
				t.Fatalf("list inferred success: %v", row)
			}
		}
	}
	if !found {
		t.Fatalf("task missing from viewer: %v", rows)
	}
	if st, _ = taskPost(t, h, FleetTasksPath+"/"+ref+"/issue", map[string]any{"repo": "org/repo"}); st != 409 {
		t.Fatalf("unfenced ticket side effect: %d", st)
	}
	end := map[string]any{"kind": "transition", "idempotency_key": "done", "generation": 1, "expected_worker": worker, "state": "succeeded", "execution_stopped": true, "evidence": "fixture stopped + result"}
	rec = command(node.token, 200, end)
	again := command(node.token, 200, end)
	if rec["updated_at"] != again["updated_at"] || rec["outcome"] != "succeeded" {
		t.Fatalf("terminal replay: %v %v", rec, again)
	}
	end["state"] = "failed"
	command(node.token, 409, end)
	end["idempotency_key"] = "late"
	command(node.token, 409, end)
	// Accepted input replay gives the original result, not the mutable current row.
	if st, got := nodeTaskCall(t, h, node.token, http.MethodPost, NodeTasksPath, input); st != 200 || got["id"] != ref || got["state"] != "accepted" {
		t.Fatalf("accepted replay: %d %v", st, got)
	}
	input["request_payload"] = map[string]any{"body": "changed"}
	if st, _ = nodeTaskCall(t, h, node.token, http.MethodPost, NodeTasksPath, input); st != 409 {
		t.Fatalf("changed payload: %d", st)
	}
	retry := map[string]any{"kind": "retry", "idempotency_key": "retry", "generation": 1, "expected_worker": worker, "requested_agent": "claude", "resolved_agent": "claude", "evidence": "explicit retry"}
	newer := command(node.token, 200, retry)
	if newer["generation"] != float64(2) || newer["state"] != "accepted" {
		t.Fatalf("new generation: %v", newer)
	}
	end["idempotency_key"] = "old-generation"
	command(node.token, 409, end)
	rec["owner"] = "<redacted>"
	rec["execution_endpoint"] = "<redacted>"
	b, _ := json.Marshal(rec)
	t.Logf("fixture API after: %s", b)
}

// The Tasks page uses committed work results even with no live inventory, and
// separately sees a later, fenced landing report without changing that result.
func TestTaskPageConfirmedOutcomeAndLanding(t *testing.T) {
	h, _, nodes := peerHarness(t)
	h.srv.FleetAdmins = []string{"frank"}
	node := nodes["verk4"]
	if _, err := h.srv.Store.RecordFleetSnapshot(node.id, "fixture-node", "frank", "fixture-machine",
		[]store.FleetReport{{FleetID: wrFleetM4, Name: "fleet", Repo: "org/repo", WorkersJSON: "[]"}}, time.Now()); err != nil {
		t.Fatal(err)
	}
	worker := wrFleetM4 + "/" + wrFid
	code, rec := nodeTaskCall(t, h, node.token, http.MethodPost, NodeTasksPath, map[string]any{
		"authority_version": 1, "token": "page-landing", "title": "Page landing", "ticket_ref": "gh:org/repo#7",
		"requested_agent": "codex", "resolved_agent": "codex"})
	if code != 200 {
		t.Fatal(code, rec)
	}
	ref := rec["id"].(string)
	path := NodeTasksPath + "/" + ref
	for _, mutation := range []map[string]any{
		{"kind": "claim", "idempotency_key": "claim", "generation": 1, "worker_id": worker},
		{"kind": "transition", "idempotency_key": "run", "generation": 1, "expected_worker": worker, "state": "running", "actual_agent": "codex", "evidence": "fixture verified native process"},
	} {
		if code, out := nodeTaskCall(t, h, node.token, http.MethodPost, path, map[string]any{"authority_version": 1, "mutation": mutation}); code != 200 {
			t.Fatal(code, out)
		}
	}
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
	if row := read(); row["state"] != "running" || row["outcome"] != nil || row["pr_state"] != "unverified" || row["actual_agent"] != "codex" || row["live"] != nil {
		t.Fatal("inventory absence changed work", row)
	}
	report := map[string]any{"event_id": "work", "task": ref, "owner": rec["owner"], "ticket_ref": "gh:org/repo#7",
		"generation": 1, "worker_id": worker, "outcome": "succeeded", "status": "waiting", "evidence": `{"pr":"51","pr_state":"waiting"}`}
	if code, out := nodeTaskCall(t, h, node.token, http.MethodPost, path+"/reports", report); code != 200 {
		t.Fatal(code, out)
	}
	before := read()
	if before["outcome"] != "succeeded" || before["pr_state"] != "waiting" || before["pr"] != "51" {
		t.Fatal(before)
	}
	report["event_id"], report["status"], report["evidence"] = "land", "merged", `{"pr":"51","pr_state":"merged"}`
	if code, out := nodeTaskCall(t, h, node.token, http.MethodPost, path+"/reports", report); code != 200 {
		t.Fatal(code, out)
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
