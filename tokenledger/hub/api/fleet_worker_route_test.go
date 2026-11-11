package api

import (
	"encoding/json"
	"net/http"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

func TestNodeWorkerRoute(t *testing.T) {
	h, _, nodes := peerHarness(t)
	h.srv.FleetAdmins = []string{"frank"}
	const localFleet = "11111111-1111-4111-8111-111111111111"
	const remoteFleet = "22222222-2222-4222-8222-222222222222"
	const parent = "33333333-3333-4333-8333-333333333333"
	const unknown = "44444444-4444-4444-8444-444444444444"
	now := time.Now()
	register := func(node, host, fleet, workers string) {
		t.Helper()
		if _, err := h.srv.Store.RecordFleetSnapshot(nodes[node].id, host, "frank", "route-"+node,
			[]store.FleetReport{{FleetID: fleet, Name: "fleet", State: "running", WorkersJSON: workers}}, now); err != nil {
			t.Fatal(err)
		}
	}
	register("verk5", "node-a", localFleet, "[]")
	register("verk4", "u-test", remoteFleet, "[]")
	call := func(node, id string, status int, wid, source, reason string) {
		t.Helper()
		code, got := nodeTaskCall(t, h, nodes[node].token, http.MethodGet, NodeWorkerRoutePath+"?id="+id, nil)
		if code != status || (wid != "" && got["worker_id"] != wid) ||
			(source != "" && got["source"] != source) || (reason != "" && got["reason"] != reason) {
			t.Fatalf("%s -> %s: %d %v; want %d %s %s %s", node, id, code, got, status, wid, source, reason)
		}
	}
	// Placement has returned its worker identity before either ID push or
	// worker inventory has arrived. The pod hostname has no special treatment.
	task, err := h.srv.Store.CreateFleetTask(store.FleetTask{Owner: "operator", Title: "remote route"}, "route-task", now)
	if err != nil {
		t.Fatal(err)
	}
	wid := remoteFleet + "/" + task.FID
	if _, err := h.srv.Store.UpdateFleetTask(task.ID, store.FleetTaskUpdate{WorkerID: wid, SessionKey: "scratch-7", State: store.TaskAccepted}, now); err != nil {
		t.Fatal(err)
	}
	call("verk5", task.FID, 200, wid, "placement", "")
	call("alice5", task.FID, 404, "", "", "not_found")
	call("verk5", unknown, 404, "", "", "not_found")
	// A task which has never been placed is known, but has no invented route.
	unplaced, err := h.srv.Store.CreateFleetTask(store.FleetTask{Owner: "operator", Title: "unplaced"}, "unplaced-route", now)
	if err != nil {
		t.Fatal(err)
	}
	call("verk5", unplaced.FID, 404, "", "", "no_route")
	// The remote worker can resolve its scratch dispatcher through its ID
	// mirror even while that machine's worker inventory is still empty.
	if _, err := h.srv.Store.ApplyFleetIDEvents(store.FleetIDPush{Owner: "operator", EndpointID: nodes["verk5"].id,
		Machine: "node-a", Login: "frank", ID: parent, Events: []map[string]any{{"ev": "opened", "id": parent, "seq": float64(1), "ts": float64(now.Unix()), "key": "scratch-8"}}}); err != nil {
		t.Fatal(err)
	}
	call("verk4", parent, 200, localFleet+"/"+parent, "identity", "")
	// Both newly resolved routes are admissible to the real hub relay before
	// an inventory update, including the worker's reply to its dispatcher.
	for _, route := range []struct{ node, from, to, target string }{
		{"verk5", localFleet + "/" + parent, wid, nodes["verk4"].id},
		{"verk4", wid, localFleet + "/" + parent, nodes["verk5"].id},
	} {
		ep, err := h.srv.Store.EndpointByTokenHash(HashToken(nodes[route.node].token))
		if err != nil {
			t.Fatal(err)
		}
		msg, err := control.New(control.TypeRelay, control.Relay{ID: route.from + "#route-test", Kind: control.RelayMessage,
			From: route.from, To: route.to, Payload: json.RawMessage(`{"body":"route round trip"}`)})
		if err != nil {
			t.Fatal(err)
		}
		got, err := h.srv.checkRelay(*ep, msg)
		if err != nil || got.TargetEndpoint != route.target {
			t.Fatalf("relay %s -> %s: %+v %v", route.from, route.to, got, err)
		}
	}
	// Once inventory catches up it is authoritative, including a moved
	// identity whose old task placement still points to the other machine.
	workers, _ := json.Marshal([]map[string]string{{"worker_id": localFleet + "/scratch-9", "identity": task.FID, "key": "scratch-9"}})
	register("verk5", "node-a", localFleet, string(workers))
	call("verk4", task.FID, 200, localFleet+"/"+task.FID, "inventory", "")
	workers, _ = json.Marshal([]map[string]string{{"worker_id": wid}})
	register("verk4", "u-test", remoteFleet, string(workers))
	call("verk5", task.FID, 409, "", "", "")
	register("verk5", "node-a", localFleet, "[]")
	call("verk5", task.FID, 200, wid, "inventory", "")
	// A completed, vanished window must never turn into a permanent queue.
	register("verk4", "u-test", remoteFleet, "[]")
	if _, err := h.srv.Store.UpdateFleetTask(task.ID, store.FleetTaskUpdate{State: store.TaskClosed}, now); err != nil {
		t.Fatal(err)
	}
	call("verk5", task.FID, 404, "", "", "closed")
	// An identity mirror also refuses a vanished, explicitly closed scratch.
	if _, err := h.srv.Store.ApplyFleetIDEvents(store.FleetIDPush{Owner: "operator", EndpointID: nodes["verk5"].id,
		Machine: "node-a", Login: "frank", ID: parent, Events: []map[string]any{{"ev": "closed", "id": parent, "seq": float64(2), "ts": float64(now.Unix())}}}); err != nil {
		t.Fatal(err)
	}
	call("verk4", parent, 404, "", "", "closed")
	if st, _ := nodeTaskCall(t, h, "", http.MethodGet, NodeWorkerRoutePath+"?id="+parent, nil); st != 401 {
		t.Fatalf("unauthenticated: %d", st)
	}
	call("verk5", "scratch-8", 400, "", "", "")
}
