package api

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// claude-fleet#4886: the backfill is by fact — a machine with a node program
// or a managed login is managed whole, everything else a client.
func TestProposeNodeRoles(t *testing.T) {
	got := proposeNodeRoles([]NodeView{
		{EndpointID: "e1", Hostname: "mini", OSUser: "a", MachineLink: true},
		{EndpointID: "e2", Hostname: "mini", OSUser: "b"},
		{EndpointID: "e3", Hostname: "pod-1", OSUser: "w", Role: store.NodeRoleManaged},
		{EndpointID: "e4", Hostname: "laptop", OSUser: "me"},
	})
	want := map[string]string{"e1": "managed", "e2": "managed", "e3": "managed", "e4": "client"}
	for _, r := range got {
		if want[r.EndpointID] != r.Proposed {
			t.Errorf("%s (%s) proposed %s; want %s", r.EndpointID, r.Hostname, r.Proposed, want[r.EndpointID])
		}
	}
	if len(got) != 4 || got[0].Hostname != "laptop" {
		t.Fatalf("rows: %+v", got)
	}
}

// The route: an admin reads the proposal and writes one role (audited); a
// bad role is 400, an unknown endpoint 404, a node token 401/403.
func TestNodeRoleRoute(t *testing.T) {
	h := newFleetHarness(t)
	tok := h.enroll(t, "mac-z")
	ep, err := h.srv.Store.EndpointByTokenHash(HashToken(tok))
	if err != nil {
		t.Fatal(err)
	}
	post := func(bearer string, body map[string]any) (int, string) {
		b, _ := json.Marshal(body)
		r, _ := http.NewRequest(http.MethodPost, h.http.URL+NodeRolePath, bytes.NewReader(b))
		r.Header.Set("Authorization", "Bearer "+bearer)
		r.Header.Set("Content-Type", "application/json")
		resp, err := http.DefaultClient.Do(r)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		out, _ := io.ReadAll(resp.Body)
		return resp.StatusCode, string(out)
	}
	if resp, b := getWithToken(t, h, NodeRolePath, viewerToken); resp.StatusCode != 200 || !strings.Contains(string(b), `"nodes"`) {
		t.Fatalf("GET: %d %s", resp.StatusCode, b)
	}
	if code, _ := post(tok, map[string]any{"endpoint_id": ep.ID, "role": "client"}); code != 401 && code != 403 {
		t.Fatalf("a node set its own role: %d", code)
	}
	if code, _ := post(viewerToken, map[string]any{"endpoint_id": ep.ID, "role": "boss"}); code != 400 {
		t.Fatalf("bad role: %d", code)
	}
	if code, _ := post(viewerToken, map[string]any{"endpoint_id": "ep_nope", "role": "client"}); code != 404 {
		t.Fatalf("unknown endpoint: %d", code)
	}
	if code, b := post(viewerToken, map[string]any{"endpoint_id": ep.ID, "role": "client"}); code != 200 || !strings.Contains(b, `"was":""`) {
		t.Fatalf("set: %d %s", code, b)
	}
	if et, _ := h.srv.Store.EndpointTrustOf(ep.ID); et.Role != store.NodeRoleClient {
		t.Fatalf("role = %q", et.Role)
	}
	if resp, b := getWithToken(t, h, "/v1/node/self", tok); resp.StatusCode != 200 || !strings.Contains(string(b), `"role":"client"`) {
		t.Fatalf("self does not say client: %d %s", resp.StatusCode, b)
	}
}

// A client is out of placement (claude-fleet#4886): auto and named alike, and a
// worker_start named at its fleet is refused; typing it managed again lets it in.
func TestPlacementPassesOverClient(t *testing.T) {
	h, _, _, _, f4 := twoNodes(t)
	if err := h.srv.Store.SetEndpointRole("ep_mac-c", store.NodeRoleClient); err != nil {
		t.Fatal(err)
	}
	if _, err := h.srv.pickNode(fleetPrincipal{}, writeRepo, "mac-c", "", time.Now()); err == nil || !strings.Contains(err.Error(), "client") {
		t.Fatalf("pickNode(mac-c) on a client: err = %v; want refused naming client", err)
	}
	out := postFleet(t, h, "worker_start", map[string]any{"issue": 81, "fleet_id": f4.FleetID, "idempotency_key": "client-81"}, 503)
	if e, _ := out["error"].(map[string]any); e["code"] != "NO_ELIGIBLE_NODE" || !strings.Contains(e["message"].(string), "客户端") {
		t.Fatalf("worker_start at a client's fleet = %v; want NO_ELIGIBLE_NODE naming the client", out)
	}
	if err := h.srv.Store.SetEndpointRole("ep_mac-c", store.NodeRoleManaged); err != nil {
		t.Fatal(err)
	}
	if _, err := h.srv.pickNode(fleetPrincipal{}, writeRepo, "mac-c", "", time.Now()); err != nil {
		t.Fatalf("pickNode(mac-c) managed: %v", err)
	}
}
