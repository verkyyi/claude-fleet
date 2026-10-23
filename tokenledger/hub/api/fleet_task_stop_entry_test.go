package api

import (
	"github.com/coder/websocket"
	"net/http"
	"strconv"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

func TestNodeTaskStopSameOwnerSiblingCanonical(t *testing.T) {
	h, sibling, target, _, _ := twoNodesCaps(t, control.CapTaskExecution)
	postFleet(t, h, "worker_start", map[string]any{"kind": "scratch", "repo": writeRepo, "idempotency_key": "stop-entry", "coding_agent": "codex", "control_version": 1}, 200)
	target.mu.Lock()
	snap := target.writes[0]["task_execution"].(map[string]any)
	target.mu.Unlock()
	ref := snap["task_ref"].(string)
	route := NodeTasksPath + "/" + ref + "/stop"
	for _, tc := range []struct {
		token, method string
		body          any
		want          int
	}{
		{"", http.MethodPost, map[string]any{"idempotency_key": "stop"}, 401},
		{"bad", http.MethodPost, map[string]any{"idempotency_key": "stop"}, 401},
		{h.tokens["mac-d"], http.MethodGet, nil, 405},
		{h.tokens["mac-d"], http.MethodPost, map[string]any{"idempotency_key": "stop", "owner": "operator"}, 400},
	} {
		if st, out := nodeTaskCall(t, h, tc.token, tc.method, route, tc.body); st != tc.want {
			t.Fatalf("refuse: %d %v want %d", st, out, tc.want)
		}
	}
	task, e := h.srv.Store.FleetTask(store.ParseTaskRef(ref))
	if e != nil {
		t.Fatal(e)
	}
	if task.CancelRequest != "" {
		t.Fatal("invalid request changed task")
	}
	var canonical any
	for _, key := range []string{"node-stop-1", "node-stop-2", "node-stop-1"} {
		st, out := nodeTaskCall(t, h, h.tokens["mac-d"], http.MethodPost, route, map[string]any{"idempotency_key": key})
		if st != 202 || out["stop_requested"] != true || out["execution_exit_confirmed"] != false {
			t.Fatalf("sibling stop: %d %v", st, out)
		}
		op := out["operation"].(map[string]any)
		if canonical != nil && canonical != op["operation_id"] {
			t.Fatal("stop replay changed canonical operation")
		}
		canonical = op["operation_id"]
	}
	if sibling.count() != 0 {
		t.Fatal("stop delivered to requesting sibling instead of reserved endpoint")
	}
	task, _ = h.srv.Store.FleetTask(task.ID)
	if task.CancelRequest != canonical || task.ExecutionEndpoint != "ep_mac-c" {
		t.Fatalf("stop binding: %+v", task)
	}
	board, e := h.srv.buildBoard(task.Owner, nil, time.Now())
	if e != nil {
		t.Fatal(e)
	}
	found := false
	for _, row := range board.Rows {
		if row.Task == ref {
			found = true
			if row.ExecutionEndpoint != task.ExecutionEndpoint {
				t.Fatalf("offline binding absent: %+v", row)
			}
		}
	}
	if !found {
		t.Fatal("controlled task missing from offline board")
	}
}

func TestNodeTaskStopRejectsForeignAndLegacyReadException(t *testing.T) {
	h, _, _, _, _ := twoNodesCaps(t, control.CapTaskExecution)
	for _, version := range []int{0, 1} {
		rec, e := h.srv.Store.CreateFleetTask(store.FleetTask{Owner: "gh:foreign", Title: "foreign", AuthorityVersion: version,
			RequestedAgent: "default", ResolvedAgent: "claude"}, "foreign-stop-"+strconv.Itoa(version), time.Now())
		if e != nil {
			t.Fatal(e)
		}
		if version == 0 {
			if _, e := h.srv.nodeOwnTask("operator", rec.Ref); e != nil {
				t.Fatalf("fixture must exercise legacy read exception: %v", e)
			}
		}
		st, out := nodeTaskCall(t, h, h.tokens["mac-d"], http.MethodPost, NodeTasksPath+"/"+rec.Ref+"/stop", map[string]any{"idempotency_key": "foreign-stop"})
		if st != 404 {
			t.Fatalf("foreign owner version %d: %d %v", version, st, out)
		}
		latest, _ := h.srv.Store.FleetTask(rec.ID)
		if latest.CancelRequest != "" {
			t.Fatal("foreign stop changed record")
		}
	}
}

func TestNodeTaskStopOfflinePersists(t *testing.T) {
	h, _, target, _, _ := twoNodesCaps(t, control.CapTaskExecution)
	postFleet(t, h, "worker_start", map[string]any{"kind": "scratch", "repo": writeRepo, "idempotency_key": "node-offline-stop", "coding_agent": "codex", "control_version": 1}, 200)
	target.mu.Lock()
	ref := target.writes[0]["task_execution"].(map[string]any)["task_ref"].(string)
	target.mu.Unlock()
	target.conn.Close(websocket.StatusNormalClosure, "gone")
	waitFor(t, 3*time.Second, "target offline", func() bool { return h.srv.nodes.get("ep_mac-c") == nil })
	st, out := nodeTaskCall(t, h, h.tokens["mac-d"], http.MethodPost, NodeTasksPath+"/"+ref+"/stop", map[string]any{"idempotency_key": "offline-stop-click"})
	if st != 202 || out["stop_requested"] != true || out["execution_exit_confirmed"] != false {
		t.Fatalf("offline: %d %v", st, out)
	}
	rec, e := h.srv.Store.FleetTask(store.ParseTaskRef(ref))
	if e != nil {
		t.Fatal(e)
	}
	if rec.CancelRequest == "" || rec.ExecutionEndpoint != "ep_mac-c" {
		t.Fatalf("stop or reservation lost: %+v", rec)
	}
}
