package api

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/pricing"
)

// Two hub replicas over one database (claude-fleet#2124, EPIC #2119 C5).

const replicaTestToken = "replica-shared-secret"

// newReplicaPair is two hub processes as two replicas would run them: one
// database, each its own node links, each reachable by the other at its URL.
// tokens is shared, so an endpoint enrolled through either dials either.
func newReplicaPair(t *testing.T) (a, b *harness) {
	t.Helper()
	st := openTestStore(t)
	if err := st.EnsureNodes(); err != nil {
		t.Fatal(err)
	}
	tokens := map[string]string{}
	mk := func(name string) *harness {
		srv := &Server{Store: st, Pricing: pricing.Default(), ViewerToken: viewerToken,
			LiveStore: NewLive(), Fleet: true, Replica: &Replica{Name: name, Token: replicaTestToken}}
		ts := httptest.NewUnstartedServer(srv.Handler())
		srv.Replica.URL = "http://" + ts.Listener.Addr().String()
		ts.Start()
		t.Cleanup(ts.Close)
		if err := srv.StartReplica(); err != nil {
			t.Fatal(err)
		}
		return &harness{srv: srv, http: ts, tokens: tokens}
	}
	return mk("hub-a"), mk("hub-b")
}

// holder names the replica whose row says it holds endpoint ("" none).
func holder(t *testing.T, h *harness, endpoint string) string {
	t.Helper()
	c, ok, err := h.srv.Store.NodeConnOf(endpoint)
	if err != nil {
		t.Fatal(err)
	}
	if !ok {
		return ""
	}
	return c.Replica
}

// The issue's 完成判据: two replicas, two nodes each on one; 100 writes from
// each replica to each node all arrive; a node that reconnects to the other
// replica keeps receiving; a node gone everywhere is still UNAVAILABLE.
func TestNodeRouteTwoReplicas(t *testing.T) {
	ha, hb := newReplicaPair(t)
	macD := connectWriteNode(t, ha, "mac-d") // held by hub-a
	macC := connectWriteNode(t, hb, "mac-c") // held by hub-b
	f5 := fakeFleet(t, machineA, "fleet-mac-d", writeRepo, "/u/frank/claude-fleet", 1)
	f4 := fakeFleet(t, machineB, "fleet-mac-c", writeRepo, "/u/frank/claude-fleet", 2)
	macD.beatLoad("mac-d", "frank", machineA, 1, 1, f5)
	macC.beatLoad("mac-c", "frank", machineB, 1, 1, f4)
	for _, h := range []*harness{ha, hb} {
		h := h
		waitFor(t, 3*time.Second, "both fleets registered", func() bool {
			return len(getFleet(t, h, "/v1/fleet/fleet_list", 200)["fleets"].([]any)) == 2
		})
	}
	if holder(t, ha, "ep_mac-d") != "hub-a" || holder(t, ha, "ep_mac-c") != "hub-b" {
		t.Fatalf("link rows: mac-d=%q mac-c=%q; want hub-a and hub-b", holder(t, ha, "ep_mac-d"), holder(t, ha, "ep_mac-c"))
	}

	// The roster of either replica shows both connected.
	for _, h := range []*harness{ha, hb} {
		for _, n := range roster(t, h).Nodes {
			if !n.Connected {
				t.Fatalf("%s's roster shows %s not connected", h.srv.Replica.Name, n.EndpointID)
			}
		}
	}

	const perPair = 100
	send := func(label string, from *harness, f control.Fleet) int {
		t.Helper()
		ok := 0
		for i := 0; i < perPair; i++ {
			op := postFleet(t, from, "worker_start", map[string]any{"issue": 7, "fleet_id": f.FleetID,
				"idempotency_key": fmt.Sprintf("%s-%s-%d", label, from.srv.Replica.Name, i)}, 200)
			if op["status"] == "accepted" {
				ok++
			} else {
				t.Errorf("%s from %s #%d: %v", label, from.srv.Replica.Name, i, op)
			}
		}
		return ok
	}
	before := ha.srv.forwarded.Load() + hb.srv.forwarded.Load()
	got := map[string]int{}
	for _, from := range []*harness{ha, hb} {
		got[from.srv.Replica.Name+"→mac-d"] = send("mac-d", from, f5)
		got[from.srv.Replica.Name+"→mac-c"] = send("mac-c", from, f4)
	}
	t.Logf("送达（两份入口 × 两台机器 × %d 次派活）：hub-a→mac-d %d · hub-a→mac-c %d · hub-b→mac-d %d · hub-b→mac-c %d",
		perPair, got["hub-a→mac-d"], got["hub-a→mac-c"], got["hub-b→mac-d"], got["hub-b→mac-c"])
	for k, n := range got {
		if n != perPair {
			t.Errorf("%s: %d/%d delivered", k, n, perPair)
		}
	}
	if macD.count() != 2*perPair || macC.count() != 2*perPair {
		t.Fatalf("writes the nodes received: mac-d=%d mac-c=%d; want %d each", macD.count(), macC.count(), 2*perPair)
	}
	if fw := ha.srv.forwarded.Load() + hb.srv.forwarded.Load() - before; fw != 2*perPair {
		t.Fatalf("%d calls forwarded; want exactly the %d that landed on the replica without the link", fw, 2*perPair)
	}

	// A live read forwards too: hub-a asks mac-c (on hub-b) for an operation.
	op := postFleet(t, ha, "worker_start", map[string]any{"issue": 8, "fleet_id": f4.FleetID, "idempotency_key": "read-1"}, 200)
	res, machine, err := ha.srv.NodeRead(context.Background(), "ep_mac-c", "operation_get",
		map[string]any{"operation_id": op["operation_id"]})
	if err != nil {
		t.Fatalf("NodeRead through hub-b: %v", err)
	}
	var rec map[string]any
	_ = json.Unmarshal(res, &rec)
	if rec["operation_id"] != op["operation_id"] || rec["status"] != "accepted" {
		t.Fatalf("forwarded read answered %s (machine %q)", res, machine)
	}

	// mac-c drops hub-b and comes back through hub-a.
	macC.conn.Close(websocket.StatusNormalClosure, "moving")
	back := connectWriteNodeTok(t, ha, ha.tokens["mac-c"])
	waitFor(t, 3*time.Second, "mac-c held by hub-a", func() bool {
		return ha.srv.nodes.get("ep_mac-c") != nil && hb.srv.nodes.get("ep_mac-c") == nil && holder(t, ha, "ep_mac-c") == "hub-a"
	})
	moved := 0
	for _, from := range []*harness{ha, hb} {
		moved += send("mac-c-back", from, f4)
	}
	t.Logf("重连到另一份后：送达 %d/%d", moved, 2*perPair)
	if back.count() != 2*perPair {
		t.Fatalf("after the reconnect mac-c received %d; want %d", back.count(), 2*perPair)
	}

	// Gone from both: refused before anything is journalled, as before.
	back.conn.Close(websocket.StatusNormalClosure, "gone")
	waitFor(t, 3*time.Second, "mac-c gone", func() bool {
		return ha.srv.nodes.get("ep_mac-c") == nil && holder(t, ha, "ep_mac-c") == ""
	})
	for _, from := range []*harness{ha, hb} {
		e := postFleet(t, from, "worker_start", map[string]any{"issue": 9, "fleet_id": f4.FleetID,
			"idempotency_key": "gone-" + from.srv.Replica.Name}, 503)["error"].(map[string]any)
		if e["code"] != "UNAVAILABLE" {
			t.Fatalf("start on a node no replica holds, from %s: %v", from.srv.Replica.Name, e)
		}
	}
}

// A row pointing at a replica that is gone (a crashed pod): the write is
// definitely not sent — failed, never unknown — and the stale holder answering
// NOT_HERE releases its row.
func TestNodeRouteHolderGone(t *testing.T) {
	ha, hb := newReplicaPair(t)
	macC := connectWriteNode(t, hb, "mac-c")
	f4 := fakeFleet(t, machineB, "fleet-mac-c", writeRepo, "/u/frank/claude-fleet", 2)
	macC.beatLoad("mac-c", "frank", machineB, 1, 1, f4)
	waitFor(t, 3*time.Second, "fleet registered", func() bool {
		return len(getFleet(t, ha, "/v1/fleet/fleet_list", 200)["fleets"].([]any)) == 1
	})
	row, _, _ := ha.srv.Store.NodeConnOf("ep_mac-c")

	// The holder's address no longer answers.
	dead := row
	dead.Replica, dead.URL, dead.Epoch = "hub-dead", "http://127.0.0.1:1", "e-dead"
	if err := ha.srv.Store.ClaimNodeConn(dead); err != nil {
		t.Fatal(err)
	}
	op := postFleet(t, ha, "worker_start", map[string]any{"issue": 7, "fleet_id": f4.FleetID, "idempotency_key": "dead-1"}, 200)
	if op["status"] != "failed" || !strings.Contains(fmt.Sprint(op["result"]), "UNAVAILABLE") {
		t.Fatalf("write through an unreachable holder = %v; want failed UNAVAILABLE", op)
	}
	if macC.count() != 0 {
		t.Fatalf("mac-c received %d writes", macC.count())
	}

	// A holder that answers but has no such link: NOT_HERE, row released.
	gone := row
	gone.Replica, gone.Epoch = "hub-x", "e-x" // hub-b's URL, another name
	if err := ha.srv.Store.ClaimNodeConn(gone); err != nil {
		t.Fatal(err)
	}
	macC.conn.Close(websocket.StatusNormalClosure, "gone")
	waitFor(t, 3*time.Second, "hub-b dropped mac-c", func() bool { return hb.srv.nodes.get("ep_mac-c") == nil })
	if got := holder(t, ha, "ep_mac-c"); got != "hub-x" {
		t.Fatalf("hub-b's drop deleted a row it did not write (holder %q)", got)
	}
	op = postFleet(t, ha, "worker_start", map[string]any{"issue": 7, "fleet_id": f4.FleetID, "idempotency_key": "gone-1"}, 200)
	if op["status"] != "failed" {
		t.Fatalf("write to a holder without the link = %v; want failed", op)
	}
	if got := holder(t, ha, "ep_mac-c"); got != "" {
		t.Fatalf("NOT_HERE left the stale row (holder %q)", got)
	}
}

// The internal route admits only the replicas' token.
func TestNodeRouteNeedsReplicaToken(t *testing.T) {
	_, hb := newReplicaPair(t)
	for _, tok := range []string{"", "wrong", viewerToken} {
		req, _ := http.NewRequest(http.MethodPost, hb.http.URL+NodeRoutePath, strings.NewReader(`{"kind":"send","endpoint_id":"ep_x"}`))
		if tok != "" {
			req.Header.Set(replicaTokenHeader, tok)
		}
		req.Header.Set("Authorization", "Bearer "+viewerToken)
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		if resp.StatusCode != http.StatusUnauthorized {
			t.Fatalf("token %q: HTTP %d; want 401", tok, resp.StatusCode)
		}
	}
}

// EPIC #2119 共同约定 1: a single hub (no CCQUOTA_REPLICA) has no route, no
// table, and never forwards — every write goes down its own link as before.
func TestNodeRouteSingleNeverForwards(t *testing.T) {
	h, macD, macC, f5, f4 := twoNodes(t)
	if h.srv.Replica != nil {
		t.Fatal("the single-hub harness is a replica")
	}
	for i, f := range []control.Fleet{f5, f4} {
		op := postFleet(t, h, "worker_start", map[string]any{"issue": 7, "fleet_id": f.FleetID,
			"idempotency_key": fmt.Sprintf("single-%d", i)}, 200)
		if op["status"] != "accepted" {
			t.Fatalf("single-hub write: %v", op)
		}
	}
	if macD.count() != 1 || macC.count() != 1 {
		t.Fatalf("writes: mac-d=%d mac-c=%d", macD.count(), macC.count())
	}
	if n := h.srv.forwarded.Load(); n != 0 {
		t.Fatalf("a single hub forwarded %d calls", n)
	}
	if _, err := h.srv.Store.NodeConns(); err == nil {
		t.Fatal("a single hub created fleet_node_conns")
	}
	req, _ := http.NewRequest(http.MethodPost, h.http.URL+NodeRoutePath, strings.NewReader(`{}`))
	req.Header.Set(replicaTokenHeader, replicaTestToken)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode == http.StatusOK || resp.StatusCode == http.StatusUnauthorized {
		t.Fatalf("a single hub answers %s with HTTP %d; the route must not exist", NodeRoutePath, resp.StatusCode)
	}
}

func TestParseReplica(t *testing.T) {
	env := func(kv map[string]string) func(string) string { return func(k string) string { return kv[k] } }
	if r, err := ParseReplica(env(nil), ""); r != nil || err != nil {
		t.Fatalf("nothing set = %v, %v; want a single hub", r, err)
	}
	full := map[string]string{"CCQUOTA_REPLICA": "hub-0", "CCQUOTA_REPLICA_URL": "http://10.0.0.5:8787/"}
	r, err := ParseReplica(env(full), "tok")
	if err != nil || r.Name != "hub-0" || r.URL != "http://10.0.0.5:8787" || r.Token != "tok" {
		t.Fatalf("full = %+v, %v", r, err)
	}
	for name, c := range map[string]struct {
		kv  map[string]string
		tok string
	}{
		"no url":   {map[string]string{"CCQUOTA_REPLICA": "hub-0"}, "tok"},
		"no token": {full, ""},
		"no name":  {map[string]string{"CCQUOTA_REPLICA_URL": "http://x"}, "tok"},
	} {
		if _, err := ParseReplica(env(c.kv), c.tok); err == nil {
			t.Fatalf("%s: accepted a half-configured replica", name)
		}
	}
}
