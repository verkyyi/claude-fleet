package api

import (
	"encoding/json"
	"net/http"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

func TestTaskCollaborationAPIAuthority(t *testing.T) {
	h, _, nodes := peerHarness(t)
	h.srv.FleetAdmins = []string{"frank"}
	for name, fid := range map[string]string{"verk4": wrFleetM4, "verk5": wrFleetM5} {
		if _, err := h.srv.Store.RecordFleetSnapshot(nodes[name].id, name, "frank", name,
			[]store.FleetReport{{FleetID: fid, Name: "fleet", Repo: "org/repo", WorkersJSON: "[]"}}, time.Now()); err != nil {
			t.Fatal(err)
		}
	}
	makeTask := func(name, fid, token, parent, ticket string) store.FleetTask {
		input := map[string]any{"authority_version": 1, "token": token, "title": token,
			"requested_agent": "codex", "resolved_agent": "codex", "parent_session": parent, "ticket_ref": ticket}
		code, rec := nodeTaskCall(t, h, nodes[name].token, http.MethodPost, NodeTasksPath, input)
		if code != 200 {
			t.Fatalf("accept: %d %v", code, rec)
		}
		ref := rec["id"].(string)
		for _, m := range []map[string]any{
			{"kind": "claim", "idempotency_key": "claim", "generation": 1, "worker_id": fid + "/" + wrFid},
			{"kind": "transition", "idempotency_key": "start", "generation": 1, "expected_worker": fid + "/" + wrFid, "state": "running", "actual_agent": "codex", "evidence": "fixture native receipt"},
		} {
			code, rec = nodeTaskCall(t, h, nodes[name].token, http.MethodPost, NodeTasksPath+"/"+ref, map[string]any{"authority_version": 1, "mutation": m})
			if code != 200 {
				t.Fatalf("mutate: %d %v", code, rec)
			}
		}
		data, _ := json.Marshal(rec)
		var task store.FleetTask
		if err := json.Unmarshal(data, &task); err != nil {
			t.Fatal(err)
		}
		return task
	}
	parent := makeTask("verk5", wrFleetM5, "parent", "", "gh:one/repo#7")
	child := makeTask("verk4", wrFleetM4, "child", parent.ExecutionOwner, "gh:two/repo#7")
	path := NodeTasksPath + "/" + child.Ref
	r := store.TaskReport{EventID: "result", Task: child.Ref, Owner: child.Owner, TicketRef: child.TicketRef,
		Generation: 1, WorkerID: child.ExecutionOwner, ParentTask: parent.Ref, ParentSession: parent.ExecutionOwner,
		ParentGeneration: 1, Outcome: "succeeded", Evidence: "fixture explicit completion with retained native session"}
	code, _ := nodeTaskCall(t, h, nodes["verk5"].token, http.MethodPost, path+"/reports", r)
	if code != 409 {
		t.Fatalf("parent cannot forge executor report: %d", code)
	}
	code, out := nodeTaskCall(t, h, nodes["verk4"].token, http.MethodPost, path+"/reports", r)
	if code != 200 || out["disposition"] != "committed" {
		t.Fatalf("report: %d %v", code, out)
	}
	code, out = nodeTaskCall(t, h, nodes["verk4"].token, http.MethodPost, path+"/reports", r)
	if code != 200 || out["disposition"] != "committed" {
		t.Fatalf("lost acknowledgement: %d %v", code, out)
	}
	code, out = nodeTaskCall(t, h, nodes["verk5"].token, http.MethodGet, NodeTasksPath+"/"+parent.Ref+"/children", nil)
	if code != 200 || len(out["children"].([]any)) != 1 {
		t.Fatalf("children: %d %v", code, out)
	}
	if code, _ = nodeTaskCall(t, h, nodes["bob4"].token, http.MethodGet, path, nil); code != 404 {
		t.Fatalf("foreign owner: %d", code)
	}
	// The relay consumes the same committed event. A transport ack cannot
	// create a different outcome or re-parent a same-number issue.
	payload, _ := json.Marshal(map[string]any{"task_report": r})
	relay := store.FleetRelay{ID: child.ExecutionOwner + "#result", Kind: control.RelayChildReport,
		FromWID: child.ExecutionOwner, ToWID: parent.ExecutionOwner, Payload: string(payload)}
	ep, err := h.srv.Store.LiveEndpoint(nodes["verk4"].id)
	if err != nil {
		t.Fatal(err)
	}
	if skip, err := h.srv.prepareTaskReportRelay(*ep, &relay); err != nil || skip {
		t.Fatalf("relay: %v %v", skip, err)
	}
	legacyPayload := relay.Payload
	relay.Payload = `{"child":"issue-7","state":"MERGED"}`
	if _, err := h.srv.prepareTaskReportRelay(*ep, &relay); err == nil {
		t.Fatal("accepted worker bypassed task report fence")
	}
	relay.Payload = legacyPayload
	for _, session := range []string{wrFleetM5 + "/scratch-7", "99999999-9999-4999-8999-999999999999/" + wrFid} {
		if err := h.srv.checkTaskParentSession(child.Owner, session); err == nil {
			t.Fatalf("invalid/foreign parent accepted: %s", session)
		}
	}
	relay.ToWID = child.ExecutionOwner
	if _, err := h.srv.prepareTaskReportRelay(*ep, &relay); err == nil {
		t.Fatal("wrong parent accepted")
	}
}
