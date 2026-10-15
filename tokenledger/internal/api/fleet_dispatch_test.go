package api

import (
	"encoding/json"
	"testing"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

func TestAcceptedCodingAgentDispatch(t *testing.T) {
	h, _, target, _, _ := twoNodes(t)
	args := map[string]any{"issue": 7, "repo": writeRepo, "idempotency_key": "provider-choice", "coding_agent": "codex"}
	op := postFleet(t, h, "worker_start", args, 200)
	if target.count() != 1 {
		t.Fatalf("writes=%d", target.count())
	}
	params := target.writes[0]["params"].(map[string]any)
	d := params["dispatch"].(map[string]any)
	if params["agent"] != "codex" || d["requested_agent"] != "codex" || d["resolved_agent"] != "codex" || d["agent_source"] != "explicit" || d["generation"] != float64(1) || params["task"] != d["task"] {
		t.Fatalf("provider/identity lost: %v", params)
	}
	task, err := h.srv.Store.FleetTask(store.ParseTaskRef(d["task"].(string)))
	if err != nil || task.AuthorityVersion != 1 || task.ActualAgent != "" || task.State != "accepted" || task.AttemptID == "" {
		t.Fatalf("accepted task (not execution proof): %+v %v", task, err)
	}
	journal, err := h.srv.Store.FleetOperation(op["operation_id"].(string))
	if err != nil {
		t.Fatal(err)
	}
	var recorded map[string]any
	if err = json.Unmarshal([]byte(journal.Request), &recorded); err != nil {
		t.Fatal(err)
	}
	if recorded["params"].(map[string]any)["task"] != task.Ref {
		t.Fatal("journal lost accepted task")
	}
	again := postFleet(t, h, "worker_start", args, 200)
	if again["operation_id"] != op["operation_id"] || target.count() != 1 {
		t.Fatal("replay launched twice")
	}
	args["coding_agent"] = "claude"
	postFleet(t, h, "worker_start", args, 409)
	if target.count() != 1 {
		t.Fatal("changed provider launched work")
	}
	t.Logf("fixture request -> journal: task=%s generation=%d requested=%s resolved=%s source=explicit attempt=%s; one launch, replay unchanged, changed payload refused; actual provider unverified", task.Ref, task.Generation, task.RequestedAgent, task.ResolvedAgent, task.AttemptID)
}

func TestCodingAgentRejectsBeforeWork(t *testing.T) {
	h, first, second, _, _ := twoNodes(t)
	for _, pair := range [][2]string{{"unknown", ""}, {"codex", "claude"}, {"", "unknown"}} {
		postFleet(t, h, "worker_start", map[string]any{"issue": 7, "repo": writeRepo, "idempotency_key": "invalid-provider", "coding_agent": pair[0], "agent": pair[1]}, 400)
	}
	if first.count()+second.count() != 0 {
		t.Fatal("invalid provider opened work")
	}
}

func TestClientCodingAgentKeepsAcceptedChoice(t *testing.T) {
	h, _, target, _, _ := twoNodes(t)
	lease, key := clientLeaseFor(t, h)
	target.setOpGet(finished("succeeded", map[string]any{"exit": 0, "window": "@3"}))
	input := map[string]any{"repo": writeRepo, "kind": "scratch", "coding_agent": "codex", "idempotency_key": "client-provider"}
	status, out := clientPlace(t, h, lease, key, input)
	if status != 200 || out.Task == "" {
		t.Fatalf("client accepted identity: %d %+v", status, out)
	}
	p := target.writes[0]["params"].(map[string]any)
	if p["agent"] != "codex" || p["task"] != out.Task {
		t.Fatalf("client envelope: %v", p)
	}
	input["agent"] = "claude"
	if status, _ = clientPlace(t, h, lease, key, input); status != 400 {
		t.Fatalf("contradiction HTTP %d", status)
	}
	if target.count() != 1 {
		t.Fatal("contradiction opened work")
	}
}
