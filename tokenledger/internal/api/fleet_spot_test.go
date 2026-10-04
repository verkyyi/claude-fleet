package api

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/spot"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/spot/spottest"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// SPOT nodes (claude-fleet#1428): the hub starts a node when placement finds
// nothing, uses it, releases it when idle, and closes the record when the
// cloud takes it back.

const machineC = "33333333-3333-4333-8333-333333333333"

// newSpotHarness is newFleetHarness with a fake cluster and SPOT on.
func newSpotHarness(t *testing.T, cfg SpotConfig) (*harness, *spottest.Server) {
	t.Helper()
	h := newFleetHarness(t)
	k8s := spottest.New()
	t.Cleanup(k8s.Close)
	if cfg.Image == "" {
		cfg.Image = "registry.example/ccquota-node:test"
	}
	if cfg.HubURL == "" {
		cfg.HubURL = h.http.URL
	}
	if cfg.Max == 0 {
		cfg.Max = 1
	}
	if cfg.Idle == 0 {
		cfg.Idle = 30 * time.Minute
	}
	if cfg.Boot == 0 {
		cfg.Boot = 10 * time.Minute
	}
	if cfg.Weight == 0 {
		cfg.Weight = DefaultSpotWeight
	}
	if cfg.Grace == 0 {
		cfg.Grace = 300
	}
	cfg.Tick = time.Hour // tests tick by hand
	cfg.Kube = spot.Config{APIServer: k8s.URL, Token: "t", Namespace: "fleet"}
	sc, err := NewSpotController(h.srv, cfg)
	if err != nil {
		t.Fatal(err)
	}
	sc.logf = t.Logf
	h.srv.Spot = sc
	return h, k8s
}

// joinSpotPod plays the pod: reads the join code the hub put in its env and
// redeems it, returning the node's token and endpoint id.
func joinSpotPod(t *testing.T, h *harness, k8s *spottest.Server, host string) (token, endpointID string) {
	t.Helper()
	code := podEnv(t, k8s.LastCreate, "FLEET_JOIN_CODE")
	if !strings.HasPrefix(code, "fj_") {
		t.Fatalf("pod env FLEET_JOIN_CODE = %q", code)
	}
	if podEnv(t, k8s.LastCreate, "FLEET_NODE_KIND") != store.NodeKindEphemeral {
		t.Fatalf("pod env FLEET_NODE_KIND = %q", podEnv(t, k8s.LastCreate, "FLEET_NODE_KIND"))
	}
	body, _ := json.Marshal(map[string]string{"code": code, "hostname": host, "os_user": "fleet"})
	resp, err := http.Post(h.http.URL+"/v1/node/join", "application/json", bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var out NodeJoinResponse
	_ = json.NewDecoder(resp.Body).Decode(&out)
	if resp.StatusCode != 200 || out.Token == "" || out.Kind != store.NodeKindEphemeral {
		t.Fatalf("join: HTTP %d %+v; want 200 with a token and kind ephemeral", resp.StatusCode, out)
	}
	return out.Token, out.EndpointID
}

func podEnv(t *testing.T, pod map[string]any, name string) string {
	t.Helper()
	spec, _ := pod["spec"].(map[string]any)
	containers, _ := spec["containers"].([]any)
	if len(containers) == 0 {
		t.Fatalf("pod has no container: %v", pod)
	}
	c, _ := containers[0].(map[string]any)
	env, _ := c["env"].([]any)
	for _, e := range env {
		m, _ := e.(map[string]any)
		if m["name"] == name {
			s, _ := m["value"].(string)
			return s
		}
	}
	return ""
}

func spotNodes(t *testing.T, h *harness) *SpotSummary {
	t.Helper()
	return roster(t, h).Spot
}

func postSpot(t *testing.T, h *harness, body map[string]any, wantStatus int) map[string]any {
	t.Helper()
	raw, _ := json.Marshal(body)
	req, _ := http.NewRequest(http.MethodPost, h.http.URL+"/v1/fleet/spot", bytes.NewReader(raw))
	req.Header.Set("Authorization", "Bearer "+viewerToken)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Origin", h.http.URL)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var out map[string]any
	_ = json.NewDecoder(resp.Body).Decode(&out)
	if resp.StatusCode != wantStatus {
		t.Fatalf("POST /v1/fleet/spot %v: HTTP %d %v, want %d", body, resp.StatusCode, out, wantStatus)
	}
	return out
}

func nodeSelf(t *testing.T, h *harness, token string) int {
	t.Helper()
	req, _ := http.NewRequest(http.MethodGet, h.http.URL+"/v1/node/self", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	return resp.StatusCode
}

// The issue's record, end to end: every fixed machine is busy → a
// placement asks for a node → the tick starts a pod with a join code → the
// pod joins (kind ephemeral, from the code) and reports → it appears in the
// roster and takes the next start → it sits idle past the limit → the hub
// deletes the pod → once the pod is gone the roster row, the endpoint and
// its token are retired, and the ledger keeps the whole story.
func TestSpotPeakStartsNodeAndIdleReleasesIt(t *testing.T) {
	h, k8s := newSpotHarness(t, SpotConfig{Idle: 150 * time.Millisecond})
	ctx := context.Background()
	m5 := connectWriteNode(t, h, "m5")
	f5 := fakeFleet(t, machineA, "fleet-m5", writeRepo, "/u/verk/claude-fleet", 1)
	m5.beatLoad("m5", "verk", machineA, 10, 3, f5) // 1.0 load/core: out
	waitFor(t, 3*time.Second, "m5 registered", func() bool {
		return len(getFleet(t, h, "/v1/fleet/fleet_list", 200)["fleets"].([]any)) == 1
	})

	// 1. Peak: no machine, and the refusal says a node was requested.
	e := postFleet(t, h, "worker_start", map[string]any{"issue": 7, "repo": writeRepo, "idempotency_key": "s7"}, 503)["error"].(map[string]any)
	if e["code"] != "NO_ELIGIBLE_NODE" || !strings.Contains(e["message"].(string), "a SPOT node has been requested") {
		t.Fatalf("refusal = %v", e)
	}
	if k8s.Created != 0 {
		t.Fatal("a pod was created before the tick")
	}
	did := h.srv.Spot.Tick(ctx, time.Now())
	if k8s.Created != 1 || len(did) != 1 || !strings.HasPrefix(did[0], "start: placement for "+writeRepo) {
		t.Fatalf("tick: created=%d did=%v", k8s.Created, did)
	}
	if got := podEnv(t, k8s.LastCreate, "CCQUOTA_HUB_URL"); got != h.http.URL {
		t.Fatalf("pod CCQUOTA_HUB_URL = %q, want %q", got, h.http.URL)
	}
	// 2. It appears in the roster's SPOT block before it has joined.
	sum := spotNodes(t, h)
	if sum == nil || !sum.Enabled || len(sum.Nodes) != 1 || sum.Nodes[0].State != store.SpotProvisioning {
		t.Fatalf("spot block after start: %+v", sum)
	}
	id, podName := sum.Nodes[0].ID, sum.Nodes[0].PodName
	// A second request while one is starting does not start another.
	e = postFleet(t, h, "worker_start", map[string]any{"issue": 8, "repo": writeRepo, "idempotency_key": "s8"}, 503)["error"].(map[string]any)
	if !strings.Contains(e["message"].(string), "already starting") {
		t.Fatalf("second refusal = %v", e)
	}
	h.srv.Spot.Tick(ctx, time.Now())
	if k8s.Created != 1 {
		t.Fatalf("a second pod was created: %d", k8s.Created)
	}

	// 3. The pod joins and reports, idle.
	tok, ep := joinSpotPod(t, h, k8s, "spot-a1")
	sn := connectWriteNodeTok(t, h, tok)
	fs := fakeFleet(t, machineC, "fleet-spot", writeRepo, "/home/fleet/claude-fleet")
	sn.beatLoad("spot-a1", "fleet", machineC, 0.5, 0, fs)
	waitFor(t, 3*time.Second, "spot fleet registered and online", func() bool {
		s := spotNodes(t, h)
		return s != nil && len(s.Nodes) == 1 && s.Nodes[0].State == store.SpotOnline &&
			len(getFleet(t, h, "/v1/fleet/fleet_list", 200)["fleets"].([]any)) == 2
	})
	snap := roster(t, h)
	var row *NodeView
	for i := range snap.Nodes {
		if snap.Nodes[i].EndpointID == ep {
			row = &snap.Nodes[i]
		}
	}
	if row == nil || row.Kind != store.NodeKindEphemeral || row.Spot != store.SpotOnline || row.Hostname != "spot-a1" {
		t.Fatalf("roster row for the SPOT node: %+v", row)
	}
	var mc *MachineView
	for i := range snap.Machines {
		if snap.Machines[i].Hostname == "spot-a1" {
			mc = &snap.Machines[i]
		}
	}
	if mc == nil || mc.Kind != store.NodeKindEphemeral {
		t.Fatalf("machine card: %+v", mc)
	}

	// 4. 派活: the next start lands on it, at the SPOT weight.
	op := postFleet(t, h, "worker_start", map[string]any{"issue": 9, "repo": writeRepo, "idempotency_key": "s9"}, 200)
	pl := op["placement"].(map[string]any)
	if op["fleet_id"] != fs.FleetID || pl["machine"] != "spot-a1" || !strings.Contains(pl["reason"].(string), "SPOT node") {
		t.Fatalf("placement = %v (fleet %v)", pl, op["fleet_id"])
	}
	for _, c := range pl["candidates"].([]any) {
		cm := c.(map[string]any)
		if cm["machine"] == "spot-a1" {
			if cm["kind"] != store.NodeKindEphemeral || cm["score"].(float64) > 0.5 {
				t.Fatalf("SPOT candidate = %v; want kind ephemeral and a score halved by the weight", cm)
			}
		}
	}
	if sn.count() != 1 {
		t.Fatalf("writes to the SPOT node: %d", sn.count())
	}
	sn.beatLoad("spot-a1", "fleet", machineC, 0.5, 1, fakeFleet(t, machineC, "fleet-spot", writeRepo, "/home/fleet/claude-fleet", 9))
	waitFor(t, 3*time.Second, "the beat with a session recorded", func() bool {
		n, err := h.srv.Store.SpotNodeByID(id)
		return err == nil && n.PeakSessions == 1
	})
	// Busy: a tick past the idle limit does nothing while a session runs.
	time.Sleep(200 * time.Millisecond)
	if did := h.srv.Spot.Tick(ctx, time.Now()); len(did) != 0 || len(k8s.Deleted) != 0 {
		t.Fatalf("tick on a busy node: %v deleted=%v", did, k8s.Deleted)
	}

	// 5. Idle past the limit: released.
	sn.beatLoad("spot-a1", "fleet", machineC, 0.5, 0, fs)
	waitFor(t, 3*time.Second, "the idle beat recorded", func() bool {
		for _, n := range roster(t, h).Nodes {
			if n.EndpointID == ep {
				return n.Sessions == 0
			}
		}
		return false
	})
	time.Sleep(200 * time.Millisecond)
	did = h.srv.Spot.Tick(ctx, time.Now())
	if len(k8s.Deleted) != 1 || k8s.Deleted[0] != podName || len(did) != 1 || !strings.Contains(did[0], "idle for") {
		t.Fatalf("idle tick: did=%v deleted=%v", did, k8s.Deleted)
	}
	if s := spotNodes(t, h); s.Nodes[0].State != store.SpotReleasing {
		t.Fatalf("state after the delete: %s", s.Nodes[0].State)
	}
	// The delete reaches the agent as SIGTERM, and it reports a reclaim:
	// the hub's own reason stands, the state stays releasing.
	req, _ := http.NewRequest(http.MethodPost, h.http.URL+"/v1/node/reclaim", strings.NewReader("{}"))
	req.Header.Set("Authorization", "Bearer "+tok)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	var rr map[string]any
	_ = json.NewDecoder(resp.Body).Decode(&rr)
	resp.Body.Close()
	if resp.StatusCode != 200 || rr["state"] != store.SpotReleasing {
		t.Fatalf("reclaim during a release: HTTP %d %v", resp.StatusCode, rr)
	}
	// Placement avoids a node on its way out. (Asked by name: an `auto`
	// refusal is demand, and would rightly have the next tick start a
	// replacement — not this test's story.)
	if _, err := h.srv.pickNode(fleetPrincipal{}, writeRepo, "spot-a1", time.Now()); err == nil || !strings.Contains(err.Error(), "spot-a1: SPOT node releasing") {
		t.Fatalf("placement on a releasing node: %v", err)
	}

	// 6. The pod is gone (the fake deletes at once): the record closes, the
	// roster row disappears, the token dies, the ledger keeps the story.
	did = h.srv.Spot.Tick(ctx, time.Now())
	if len(did) != 1 || !strings.Contains(did[0], "RELEASED "+podName) || !strings.Contains(did[0], "idle for") {
		t.Fatalf("final tick: %v", did)
	}
	snap = roster(t, h)
	for _, n := range snap.Nodes {
		if n.EndpointID == ep {
			t.Fatalf("released node still on the roster: %+v", n)
		}
	}
	for _, m := range snap.Machines {
		if m.Hostname == "spot-a1" {
			t.Fatalf("released node still a machine card: %+v", m)
		}
	}
	if len(snap.Spot.Nodes) != 0 || len(snap.Spot.History) != 1 {
		t.Fatalf("spot block after release: nodes=%d history=%d", len(snap.Spot.Nodes), len(snap.Spot.History))
	}
	rec := snap.Spot.History[0]
	if rec.ID != id || rec.State != store.SpotReleased || rec.PeakSessions != 1 || rec.SessionsLost != 0 ||
		rec.JoinedAt == nil || rec.ReleasedAt == nil || !strings.Contains(rec.Reason, "idle for") {
		t.Fatalf("record = %+v", rec)
	}
	if st := nodeSelf(t, h, tok); st != http.StatusUnauthorized {
		t.Fatalf("the released node's token still works: /v1/node/self HTTP %d", st)
	}
	// The join code it was given cannot be reused either.
	body, _ := json.Marshal(map[string]string{"code": podEnv(t, k8s.LastCreate, "FLEET_JOIN_CODE"), "hostname": "x", "os_user": "y"})
	if resp, err := http.Post(h.http.URL+"/v1/node/join", "application/json", bytes.NewReader(body)); err != nil || resp.StatusCode != 401 {
		t.Fatalf("spent join code: %v %v", resp.StatusCode, err)
	}
	// m5 is untouched by all of it.
	if m5.count() != 0 {
		t.Fatalf("m5 received %d writes", m5.count())
	}
}

// The cloud takes the machine: the node says so, placement avoids it at
// once, and when the pod vanishes (nobody deleted it) the leases it still
// held go immediately — not after the 30-minute lost TTL — and the record
// says how many sessions were on it.
func TestSpotReclaimReleasesLeasesAtOnce(t *testing.T) {
	h, k8s := newSpotHarness(t, SpotConfig{})
	ctx := context.Background()
	out := postSpot(t, h, map[string]any{"action": "start", "reason": "test"}, 200)
	node := out["node"].(map[string]any)
	id, podName := node["id"].(string), node["pod_name"].(string)
	if k8s.Created != 1 || k8s.Pod(podName) == nil {
		t.Fatalf("start by hand: created=%d pod=%v", k8s.Created, k8s.Pod(podName))
	}
	// The cap: a second start is refused.
	if e := postSpot(t, h, map[string]any{"action": "start"}, 429)["error"].(map[string]any); e["code"] != "AT_CAPACITY" {
		t.Fatalf("second start: %v", e)
	}

	tok, ep := joinSpotPod(t, h, k8s, "spot-b2")
	sn := connectWriteNodeTok(t, h, tok)
	fs := fakeFleet(t, machineC, "fleet-spot", writeRepo, "/home/fleet/claude-fleet", 7)
	sn.beatLoad("spot-b2", "fleet", machineC, 0.5, 1, fs)
	waitFor(t, 3*time.Second, "spot node online", func() bool {
		s := spotNodes(t, h)
		return s != nil && len(s.Nodes) == 1 && s.Nodes[0].State == store.SpotOnline
	})
	// It holds #7's lease, as a node that opened the session would.
	wid := fs.FleetID + "/issue-7"
	granted, _, _, err := h.srv.Store.AcquireLease(store.LeaseClaim{Repo: writeRepo, Issue: 7, WorkerID: wid,
		FleetID: fs.FleetID, EndpointID: ep, Hostname: "spot-b2", OSUser: "fleet"}, leaseStartGrace, time.Now())
	if err != nil || !granted {
		t.Fatalf("lease: %v %v", granted, err)
	}

	// The node reports the reclaim.
	req, _ := http.NewRequest(http.MethodPost, h.http.URL+"/v1/node/reclaim", strings.NewReader("{}"))
	req.Header.Set("Authorization", "Bearer "+tok)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	var rec map[string]any
	_ = json.NewDecoder(resp.Body).Decode(&rec)
	resp.Body.Close()
	if resp.StatusCode != 200 || rec["state"] != store.SpotReclaiming || rec["grace_seconds"].(float64) != 300 {
		t.Fatalf("reclaim: HTTP %d %v", resp.StatusCode, rec)
	}
	if pl, err := h.srv.pickNode(fleetPrincipal{}, writeRepo, "spot-b2", time.Now()); err == nil || !strings.Contains(err.Error(), "SPOT node reclaiming") {
		t.Fatalf("placement during reclaim: %v %v", pl, err)
	}
	// Demand while it drains starts a replacement: that is the point of
	// a cap counted over nodes that are staying.
	e := postFleet(t, h, "worker_start", map[string]any{"issue": 8, "repo": writeRepo, "idempotency_key": "s8"}, 503)["error"].(map[string]any)
	if !strings.Contains(e["message"].(string), "a SPOT node has been requested") {
		t.Fatalf("refusal during the reclaim = %v", e)
	}
	// A fixed machine's token gets a clean refusal.
	req, _ = http.NewRequest(http.MethodPost, h.http.URL+"/v1/node/reclaim", strings.NewReader("{}"))
	req.Header.Set("Authorization", "Bearer "+h.enroll(t, "m4"))
	if resp, err := http.DefaultClient.Do(req); err != nil || resp.StatusCode != 404 {
		t.Fatalf("reclaim from a fixed machine: %v %v", resp.StatusCode, err)
	}

	// The machine goes: the pod is simply not there any more.
	k8s.Vanish(podName)
	did := h.srv.Spot.Tick(ctx, time.Now())
	if len(did) != 2 || !strings.Contains(did[0], "reclaimed by the cloud") || !strings.Contains(did[0], "1 session(s) were still on it") ||
		!strings.Contains(did[0], "1 lease(s) released") || !strings.HasPrefix(did[1], "start: ") || k8s.Created != 2 {
		t.Fatalf("tick after the reclaim: %v (created %d)", did, k8s.Created)
	}
	if leases, _ := h.srv.Store.Leases(time.Now()); len(leases) != 0 {
		t.Fatalf("leases after the reclaim: %v", leases)
	}
	n, err := h.srv.Store.SpotNodeByID(id)
	if err != nil || n.State != store.SpotReleased || n.SessionsLost != 1 || n.LeasesReleased != 1 {
		t.Fatalf("record: %+v %v", n, err)
	}
	if len(k8s.Deleted) != 0 {
		t.Fatalf("the hub deleted a pod the cloud had already taken: %v", k8s.Deleted)
	}
	if s := spotNodes(t, h); len(s.Nodes) != 1 || s.Nodes[0].State != store.SpotProvisioning || len(s.History) != 1 {
		t.Fatalf("spot block after the reclaim: %+v", s)
	}
	// The issue is free again — nothing re-dispatched it, but the next
	// acquire from anywhere succeeds.
	granted, _, _, err = h.srv.Store.AcquireLease(store.LeaseClaim{Repo: writeRepo, Issue: 7, WorkerID: "x/issue-7",
		FleetID: "x", EndpointID: "ep_m4", Hostname: "m4", OSUser: "verk"}, leaseStartGrace, time.Now())
	if err != nil || !granted {
		t.Fatalf("#7 after the reclaim: granted=%v err=%v", granted, err)
	}
}

// A pod that never joins is given up on after the boot window, and a
// cluster that cannot be asked changes nothing.
func TestSpotBootTimeoutAndClusterOutage(t *testing.T) {
	h, k8s := newSpotHarness(t, SpotConfig{Boot: 100 * time.Millisecond})
	ctx := context.Background()
	n, err := h.srv.Spot.Start(ctx, "test", time.Now())
	if err != nil {
		t.Fatal(err)
	}
	k8s.Refuse = 503
	did := h.srv.Spot.Tick(ctx, time.Now())
	if len(did) != 1 || !strings.Contains(did[0], "cluster unreachable") {
		t.Fatalf("tick under an outage: %v", did)
	}
	if got, _ := h.srv.Store.SpotNodeByID(n.ID); got.State != store.SpotProvisioning {
		t.Fatalf("an outage changed the state to %s", got.State)
	}
	k8s.Refuse = 0
	time.Sleep(150 * time.Millisecond)
	did = h.srv.Spot.Tick(ctx, time.Now())
	if len(did) != 1 || !strings.Contains(did[0], "boot timeout") || len(k8s.Deleted) != 1 {
		t.Fatalf("tick past the boot window: %v deleted=%v", did, k8s.Deleted)
	}
	did = h.srv.Spot.Tick(ctx, time.Now())
	if len(did) != 1 || !strings.Contains(did[0], "RELEASED") {
		t.Fatalf("tick after the delete: %v", did)
	}
	got, _ := h.srv.Store.SpotNodeByID(n.ID)
	if got.State != store.SpotReleased || !strings.Contains(got.Reason, "boot timeout") || got.EndpointID != "" {
		t.Fatalf("record: %+v", got)
	}
	// Its join code is dead with it.
	body, _ := json.Marshal(map[string]string{"code": podEnv(t, k8s.LastCreate, "FLEET_JOIN_CODE"), "hostname": "x", "os_user": "y"})
	if resp, err := http.Post(h.http.URL+"/v1/node/join", "application/json", bytes.NewReader(body)); err != nil || resp.StatusCode != 401 {
		t.Fatalf("expired join code: %v %v", resp.StatusCode, err)
	}
}

// The weight: an ephemeral node with the same room as a fixed one loses at
// the default, wins when the setting says so, and the setting is bounded.
func TestSpotWeightPrefersFixedMachines(t *testing.T) {
	h, k8s := newSpotHarness(t, SpotConfig{Max: 2})
	m4 := connectWriteNode(t, h, "m4")
	f4 := fakeFleet(t, machineB, "fleet-m4", writeRepo, "/u/verk/claude-fleet")
	m4.beatLoad("m4", "verk", machineB, 1, 0, f4)
	if _, err := h.srv.Spot.Start(context.Background(), "test", time.Now()); err != nil {
		t.Fatal(err)
	}
	tok, _ := joinSpotPod(t, h, k8s, "spot-c3")
	sn := connectWriteNodeTok(t, h, tok)
	fs := fakeFleet(t, machineC, "fleet-spot", writeRepo, "/home/fleet/claude-fleet")
	sn.beatLoad("spot-c3", "fleet", machineC, 1, 0, fs)
	waitFor(t, 3*time.Second, "both fleets registered, spot online", func() bool {
		s := spotNodes(t, h)
		return len(getFleet(t, h, "/v1/fleet/fleet_list", 200)["fleets"].([]any)) == 2 &&
			s != nil && len(s.Nodes) == 1 && s.Nodes[0].State == store.SpotOnline
	})
	pl, err := h.srv.PickNode("", writeRepo)
	if err != nil || pl.Machine != "m4" {
		t.Fatalf("default weight: chose %q (%v)", pl.Machine, err)
	}
	for _, c := range pl.Candidates {
		if c.Machine == "spot-c3" && c.Score >= 0.5 {
			t.Fatalf("SPOT score %v not halved", c.Score)
		}
	}
	put := func(key, value string, want int) map[string]any {
		raw, _ := json.Marshal(map[string]string{"key": key, "value": value})
		req, _ := http.NewRequest(http.MethodPut, h.http.URL+"/v1/fleet/settings", bytes.NewReader(raw))
		req.Header.Set("Authorization", "Bearer "+viewerToken)
		req.Header.Set("Content-Type", "application/json")
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		var out map[string]any
		_ = json.NewDecoder(resp.Body).Decode(&out)
		if resp.StatusCode != want {
			t.Fatalf("PUT %s=%s: HTTP %d %v, want %d", key, value, resp.StatusCode, out, want)
		}
		return out
	}
	put(SpotWeightKey, "3", 400)
	put(SpotWeightKey, "x", 400)
	out := put(SpotWeightKey, "2", 200)
	if eff := out["effective"].(map[string]any); eff[SpotWeightKey].(float64) != 2 {
		t.Fatalf("effective after the put: %v", eff)
	}
	if pl, err := h.srv.PickNode("", writeRepo); err != nil || pl.Machine != "spot-c3" {
		t.Fatalf("weight 2: chose %q (%v)", pl.Machine, err)
	}
	out = put(SpotWeightKey, "", 200)
	if eff := out["effective"].(map[string]any); eff[SpotWeightKey].(float64) != DefaultSpotWeight {
		t.Fatalf("effective after clearing: %v", eff)
	}
}

// Off is today's hub: no SPOT block, no start, the refusal text unchanged,
// a join code fixed by default — and a hand-minted ephemeral code still
// stamps the kind, for a SPOT box the operator runs outside the cluster.
func TestSpotOffAddsNothing(t *testing.T) {
	h := newFleetHarness(t)
	m5 := connectWriteNode(t, h, "m5")
	f5 := fakeFleet(t, machineA, "fleet-m5", writeRepo, "/u/verk/claude-fleet", 1)
	m5.beatLoad("m5", "verk", machineA, 10, 3, f5)
	waitFor(t, 3*time.Second, "m5 registered", func() bool {
		return len(getFleet(t, h, "/v1/fleet/fleet_list", 200)["fleets"].([]any)) == 1
	})
	if snap := roster(t, h); snap.Spot != nil {
		t.Fatalf("spot block on a hub without SPOT: %+v", snap.Spot)
	}
	e := postFleet(t, h, "worker_start", map[string]any{"issue": 7, "repo": writeRepo, "idempotency_key": "s7"}, 503)["error"].(map[string]any)
	if e["code"] != "NO_ELIGIBLE_NODE" || strings.Contains(e["message"].(string), "SPOT") {
		t.Fatalf("refusal = %v", e)
	}
	postSpot(t, h, map[string]any{"action": "start"}, 501)
	req, _ := http.NewRequest(http.MethodGet, h.http.URL+"/v1/fleet/spot", nil)
	req.Header.Set("Authorization", "Bearer "+viewerToken)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	var sum SpotSummary
	_ = json.NewDecoder(resp.Body).Decode(&sum)
	resp.Body.Close()
	if resp.StatusCode != 200 || sum.Enabled || len(sum.Nodes) != 0 {
		t.Fatalf("GET /v1/fleet/spot: HTTP %d %+v", resp.StatusCode, sum)
	}

	mint := func(body string) JoinCodeView {
		req, _ := http.NewRequest(http.MethodPost, h.http.URL+"/v1/fleet/join-codes", strings.NewReader(body))
		req.Header.Set("Authorization", "Bearer "+viewerToken)
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("Origin", h.http.URL)
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		var v JoinCodeView
		_ = json.NewDecoder(resp.Body).Decode(&v)
		if resp.StatusCode != 200 {
			t.Fatalf("mint %s: HTTP %d", body, resp.StatusCode)
		}
		return v
	}
	if v := mint(`{}`); v.Kind != store.NodeKindFixed {
		t.Fatalf("default kind = %q", v.Kind)
	}
	v := mint(`{"kind":"ephemeral","label":"spot-box"}`)
	body, _ := json.Marshal(map[string]string{"code": v.Code, "hostname": "spot-box", "os_user": "fleet"})
	jr, err := http.Post(h.http.URL+"/v1/node/join", "application/json", bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	var joined NodeJoinResponse
	_ = json.NewDecoder(jr.Body).Decode(&joined)
	jr.Body.Close()
	if jr.StatusCode != 200 || joined.Kind != store.NodeKindEphemeral {
		t.Fatalf("join with an ephemeral code: HTTP %d kind %q", jr.StatusCode, joined.Kind)
	}
	codes := getFleet(t, h, "/v1/fleet/join-codes", 200)["codes"].([]any)
	if codes[0].(map[string]any)["kind"] != store.NodeKindEphemeral || codes[1].(map[string]any)["kind"] != store.NodeKindFixed {
		t.Fatalf("join-codes list kinds: %v", codes)
	}
	// Its roster row says so, with no SPOT state (the hub did not start it).
	sn := connectWriteNodeTok(t, h, joined.Token)
	sn.beatLoad("spot-box", "fleet", machineC, 1, 0)
	waitFor(t, 3*time.Second, "the box on the roster", func() bool {
		for _, n := range roster(t, h).Nodes {
			if n.Hostname == "spot-box" {
				return n.Kind == store.NodeKindEphemeral && n.Spot == ""
			}
		}
		return false
	})
}

// ParseSpotConfig: off without an image, every knob checked, the public URL
// standing in for the pod's hub address.
func TestParseSpotConfig(t *testing.T) {
	env := map[string]string{}
	get := func(k string) string { return env[k] }
	if _, on, err := ParseSpotConfig(get, ""); on || err != nil {
		t.Fatalf("no image: on=%v err=%v", on, err)
	}
	env["CCQUOTA_FLEET_SPOT_IMAGE"] = "img"
	if _, _, err := ParseSpotConfig(get, ""); err == nil {
		t.Fatal("an image with no hub URL was accepted")
	}
	cfg, on, err := ParseSpotConfig(get, "https://hub.example/")
	if err != nil || !on || cfg.HubURL != "https://hub.example" || cfg.Max != 1 || cfg.Idle != 30*time.Minute ||
		cfg.Boot != 10*time.Minute || cfg.Weight != DefaultSpotWeight || cfg.Grace != 300 || cfg.Tick != 30*time.Second {
		t.Fatalf("defaults: %+v on=%v err=%v", cfg, on, err)
	}
	env["CCQUOTA_FLEET_SPOT_HUB_URL"] = "http://ccquota-hub.new-deploy.svc:8787/"
	env["CCQUOTA_FLEET_SPOT_MAX"] = "3"
	env["CCQUOTA_FLEET_SPOT_IDLE_MINUTES"] = "45"
	env["CCQUOTA_FLEET_SPOT_WEIGHT"] = "0.7"
	env["CCQUOTA_FLEET_SPOT_NODE_SELECTOR"] = "pool=spot"
	env["CCQUOTA_FLEET_SPOT_TOLERATIONS"] = "spot:NoSchedule"
	env["CCQUOTA_FLEET_SPOT_CPU"] = "2"
	cfg, _, err = ParseSpotConfig(get, "")
	if err != nil || cfg.HubURL != "http://ccquota-hub.new-deploy.svc:8787" || cfg.Max != 3 || cfg.Idle != 45*time.Minute ||
		cfg.Weight != 0.7 || cfg.NodeSelector["pool"] != "spot" || len(cfg.Tolerations) != 1 || cfg.CPU != "2" {
		t.Fatalf("knobs: %+v %v", cfg, err)
	}
	for k, bad := range map[string]string{"CCQUOTA_FLEET_SPOT_MAX": "-1", "CCQUOTA_FLEET_SPOT_IDLE_MINUTES": "0",
		"CCQUOTA_FLEET_SPOT_WEIGHT": "5", "CCQUOTA_FLEET_SPOT_GRACE_SECONDS": "5", "CCQUOTA_FLEET_SPOT_CPU": "lots",
		"CCQUOTA_FLEET_SPOT_NODE_SELECTOR": "nokey", "CCQUOTA_FLEET_SPOT_POD_JSON": "/nonexistent.json"} {
		save := env[k]
		env[k] = bad
		if _, _, err := ParseSpotConfig(get, ""); err == nil || !strings.Contains(err.Error(), k) {
			t.Errorf("%s=%q accepted (%v)", k, bad, err)
		}
		env[k] = save
	}
}
