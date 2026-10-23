package api

import (
	"net/http"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

func TestNodeTaskWorktreeReadPreservesCurrentBinding(t *testing.T) {
	h, _, nodes := peerHarness(t)
	h.srv.FleetAdmins = []string{"frank"}
	now := time.Now()
	task, err := h.srv.Store.CreateFleetTask(store.FleetTask{Owner: pBob, Title: "retained workspace", AuthorityVersion: 1, RequestedAgent: "codex", ResolvedAgent: "codex"}, "worktree-read", now)
	if err != nil {
		t.Fatal(err)
	}
	stamp := now.UTC().Format(time.RFC3339Nano)
	_, err = h.srv.Store.DB().Exec(`INSERT INTO fleet_operations (id,fleet_id,action,request,actor,idem,status,created,updated) VALUES ('workspace-start','','worker_start','{"control_version":1}',?,'workspace-start','succeeded',?,?)`, pBob, stamp, stamp)
	if err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		name, endpoint, worker, op string
		controlled                 bool
	}{
		{"legacy", "", "", "", false}, {"pending", "node-a", "", "workspace-start", true},
		{"current", "node-a", "fleet/current", "workspace-start", true}, {"released", "", "", "workspace-start", true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			_, err := h.srv.Store.DB().Exec(`UPDATE fleet_tasks SET execution_endpoint = ?, execution_owner = ?, operation_id = ?, outcome = 'succeeded' WHERE id = ?`, tc.endpoint, tc.worker, tc.op, task.ID)
			if err != nil {
				t.Fatal(err)
			}
			code, body := nodeTaskCall(t, h, nodes["bob4"].token, http.MethodGet, NodeTasksPath+"/"+task.Ref, nil)
			got, ok := body["task"].(map[string]any)
			if code != 200 || !ok || got["outcome"] != "succeeded" {
				t.Fatalf("read=%d %v", code, body)
			}
			worker, present := got["execution_owner"]
			if present != tc.controlled || present && worker != tc.worker {
				t.Fatalf("controlled binding lost: %v", body)
			}
			if code, _ := nodeTaskCall(t, h, nodes["alice4"].token, http.MethodGet, NodeTasksPath+"/"+task.Ref, nil); code != 404 {
				t.Fatalf("foreign owner read binding: %d", code)
			}
		})
	}
}
