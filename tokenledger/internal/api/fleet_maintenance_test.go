package api

import (
	"bytes"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"
)

// 维护中 (claude-fleet#1427, EPIC #1419 C8): the operator's third node status.

func maintCall(t *testing.T, h *harness, token, method string, body map[string]any) (int, map[string]any) {
	t.Helper()
	var rd *bytes.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		rd = bytes.NewReader(b)
	} else {
		rd = bytes.NewReader(nil)
	}
	req, _ := http.NewRequest(method, h.http.URL+"/v1/node/maintenance", rd)
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var out map[string]any
	_ = json.NewDecoder(resp.Body).Decode(&out)
	return resp.StatusCode, out
}

func putSetting(t *testing.T, h *harness, key, value string, want int) map[string]any {
	t.Helper()
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
		t.Fatalf("PUT %s=%q: HTTP %d %v, want %d", key, value, resp.StatusCode, out, want)
	}
	return out
}

// nodeStatuses reads /v1/nodes as hostname → status for machines and nodes.
func nodeStatuses(t *testing.T, h *harness) (machines map[string]map[string]any, nodes map[string]map[string]any) {
	t.Helper()
	req, _ := http.NewRequest(http.MethodGet, h.http.URL+"/v1/nodes", nil)
	req.Header.Set("Authorization", "Bearer "+viewerToken)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var snap struct {
		Machines []map[string]any `json:"machines"`
		Nodes    []map[string]any `json:"nodes"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&snap); err != nil {
		t.Fatal(err)
	}
	machines, nodes = map[string]map[string]any{}, map[string]map[string]any{}
	for _, m := range snap.Machines {
		machines[m["hostname"].(string)] = m
	}
	for _, n := range snap.Nodes {
		nodes[n["hostname"].(string)] = n
	}
	return machines, nodes
}

func auditCount(t *testing.T, h *harness, where string) int {
	t.Helper()
	var n int
	if err := h.srv.Store.DB().QueryRow(`SELECT COUNT(*) FROM fleet_audit WHERE action = 'node_maintenance' AND ` + where).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n
}

// The degenerate case is sacred: with no flag set, the roster, the fleet
// views, the node's own status read and placement all say what they said
// before this issue — two words, no maintenance key anywhere.
func TestMaintenanceOffAddsNothing(t *testing.T) {
	h, _, _, _, _ := twoNodes(t)
	machines, nodes := nodeStatuses(t, h)
	for _, host := range []string{"mac-d", "mac-c"} {
		if machines[host]["status"] != "online" || nodes[host]["status"] != "online" {
			t.Fatalf("%s: machine %v node %v; want online", host, machines[host]["status"], nodes[host]["status"])
		}
		if _, has := machines[host]["maintenance"]; has {
			t.Fatalf("%s machine carries a maintenance key with nothing set: %v", host, machines[host])
		}
		if _, has := nodes[host]["maintenance"]; has {
			t.Fatalf("%s node carries a maintenance key with nothing set: %v", host, nodes[host])
		}
	}
	st, out := maintCall(t, h, h.tokens["mac-d"], http.MethodGet, nil)
	if st != 200 || out["status"] != "online" || out["maintenance"] != nil {
		t.Fatalf("GET maintenance = %d %v; want online, null", st, out)
	}
	sess := getFleet(t, h, "/v1/fleet/fleet_sessions", 200)
	for _, n := range sess["nodes"].([]any) {
		if n.(map[string]any)["availability"] != "online" {
			t.Fatalf("fleet_sessions nodes: %v; want every machine online", sess["nodes"])
		}
	}
	eff := putSetting(t, h, SpotWeightKey, "", 200)["effective"].(map[string]any)
	for k := range eff {
		if strings.HasPrefix(k, NodeMaintenancePrefix) {
			t.Fatalf("effective settings carry %s with nothing set", k)
		}
	}
	if pl, err := h.srv.PickNode("", writeRepo); err != nil || pl.Machine != "mac-c" {
		t.Fatalf("placement with nothing set: %q %v; want mac-c (mac-d is loaded)", pl.Machine, err)
	}
}

// The planned-outage half: a machine flags itself with its own token, the
// roster and the sidebar's machine line say 维护中, placement sends new work
// elsewhere — auto AND named — and `leave` puts everything back.
func TestNodeMaintenanceFlagsItselfAndPlacementAvoidsIt(t *testing.T) {
	h, macD, macC, f5, _ := twoNodes(t)
	// Make mac-d the better machine, so only the flag can keep work off it.
	macD.beatLoad("mac-d", "frank", machineA, 0.5, 0, f5)
	waitFor(t, 3*time.Second, "mac-d reports idle", func() bool {
		hb, _, _ := h.srv.nodeStatusOf("ep_mac-d", time.Now())
		return hb.Load1 == 0.5
	})
	if pl, err := h.srv.PickNode("", writeRepo); err != nil || pl.Machine != "mac-d" {
		t.Fatalf("before the flag: %q %v; want mac-d", pl.Machine, err)
	}

	st, out := maintCall(t, h, h.tokens["mac-d"], http.MethodPost, map[string]any{"action": "enter", "reason": "升级 macOS"})
	if st != 200 || out["status"] != "maintenance" {
		t.Fatalf("enter = %d %v; want status maintenance", st, out)
	}
	rec, _ := out["maintenance"].(map[string]any)
	if rec["reason"] != "升级 macOS" || rec["by"] != "node:frank@mac-d" || rec["machine"] != "mac-d" || rec["since"] == nil {
		t.Fatalf("record = %v", rec)
	}
	since := rec["since"]

	machines, nodes := nodeStatuses(t, h)
	if machines["mac-d"]["status"] != "maintenance" || nodes["mac-d"]["status"] != "maintenance" {
		t.Fatalf("roster: machine %v node %v; want maintenance", machines["mac-d"]["status"], nodes["mac-d"]["status"])
	}
	if mm, _ := machines["mac-d"]["maintenance"].(map[string]any); mm["reason"] != "升级 macOS" {
		t.Fatalf("machine record = %v", machines["mac-d"]["maintenance"])
	}
	// Heard, so its numbers are still there for the page.
	if machines["mac-d"]["logins_online"].(float64) != 1 || machines["mac-c"]["status"] != "online" {
		t.Fatalf("machines = %v", machines)
	}
	sess := getFleet(t, h, "/v1/fleet/fleet_sessions", 200)
	av := map[string]any{}
	for _, n := range sess["nodes"].([]any) {
		m := n.(map[string]any)
		av[m["machine_name"].(string)] = m["availability"]
	}
	if av["mac-d"] != "maintenance" || av["mac-c"] != "online" {
		t.Fatalf("fleet_sessions nodes = %v", av)
	}

	// Placement: auto goes to mac-c with the reason; naming mac-d is refused.
	wid := issueWID(f5.FleetID, 21)
	st, out = placeCall(t, h, h.tokens["mac-d"], map[string]any{"repo": writeRepo, "issue": 21, "worker_id": wid, "idempotency_key": "place-21"})
	if st != 200 || out["local"] != false {
		t.Fatalf("auto place = %d %v; want remote", st, out)
	}
	pl := out["placement"].(map[string]any)
	if pl["machine"] != "mac-c" || !strings.Contains(pl["reason"].(string), "mac-d excluded: maintenance: 升级 macOS") {
		t.Fatalf("placement = %v", pl)
	}
	st, out = placeCall(t, h, h.tokens["mac-d"], map[string]any{"repo": writeRepo, "issue": 22, "worker_id": issueWID(f5.FleetID, 22), "node": "mac-d"})
	e, _ := out["error"].(map[string]any)
	if st != 503 || e["code"] != "NO_ELIGIBLE_NODE" || !strings.Contains(e["message"].(string), "mac-d: maintenance: 升级 macOS") {
		t.Fatalf("named place = %d %v; want NO_ELIGIBLE_NODE naming the maintenance", st, out)
	}
	if macD.count() != 0 || macC.count() != 1 {
		t.Fatalf("writes: mac-d=%d mac-c=%d; want 0 and 1", macD.count(), macC.count())
	}

	// A second enter is idempotent: the clock stays, the reason may change.
	st, out = maintCall(t, h, h.tokens["mac-d"], http.MethodPost, map[string]any{"action": "enter", "reason": "升级 macOS，预计 40 分钟"})
	rec, _ = out["maintenance"].(map[string]any)
	if st != 200 || rec["since"] != since || rec["reason"] != "升级 macOS，预计 40 分钟" {
		t.Fatalf("re-enter = %d %v; want the first clock kept", st, out)
	}
	if n := auditCount(t, h, `actor = 'node:frank@mac-d' AND fleet_id = 'machine:mac-d' AND outcome LIKE 'ENTER: %'`); n != 1 {
		t.Fatalf("ENTER audit rows = %d, want 1", n)
	}
	if n := auditCount(t, h, `outcome LIKE 'ALREADY: %'`); n != 1 {
		t.Fatalf("ALREADY audit rows = %d, want 1", n)
	}

	// Leave: online again, placement comes back.
	st, out = maintCall(t, h, h.tokens["mac-d"], http.MethodPost, map[string]any{"action": "leave"})
	if st != 200 || out["status"] != "online" || out["maintenance"] != nil {
		t.Fatalf("leave = %d %v", st, out)
	}
	if pl, err := h.srv.PickNode("", writeRepo); err != nil || pl.Machine != "mac-d" {
		t.Fatalf("after leave: %q %v; want mac-d", pl.Machine, err)
	}
	if n := auditCount(t, h, `outcome = 'LEAVE'`); n != 1 {
		t.Fatalf("LEAVE audit rows = %d, want 1", n)
	}
	st, out = maintCall(t, h, h.tokens["mac-d"], http.MethodPost, map[string]any{"action": "leave"})
	if st != 200 || auditCount(t, h, `outcome = 'NOT_FLAGGED'`) != 1 {
		t.Fatalf("second leave = %d %v; want NOT_FLAGGED audited", st, out)
	}
	if st, _ := maintCall(t, h, h.tokens["mac-d"], http.MethodPost, map[string]any{"action": "drain"}); st != 400 {
		t.Fatalf("unknown action = %d, want 400", st)
	}
	if st, _ := maintCall(t, h, "not-a-token", http.MethodGet, nil); st != 401 {
		t.Fatalf("bad token = %d, want 401", st)
	}
}

// The operator's door: /v1/fleet/settings takes fleet.node_maintenance.<m>
// with a reason, "" ends it, the machine name is checked, and the roster
// shows the operator as the one who set it.
func TestMaintenanceOperatorSetsAndClears(t *testing.T) {
	h, _, _, _, _ := twoNodes(t)
	out := putSetting(t, h, NodeMaintenancePrefix+"mac-c", "换内存", 200)
	eff := out["effective"].(map[string]any)
	rec, _ := eff[NodeMaintenancePrefix+"mac-c"].(map[string]any)
	if rec["reason"] != "换内存" || rec["by"] != "operator" || rec["machine"] != "mac-c" {
		t.Fatalf("effective record = %v", eff)
	}
	machines, _ := nodeStatuses(t, h)
	if machines["mac-c"]["status"] != "maintenance" || machines["mac-d"]["status"] != "online" {
		t.Fatalf("roster after the operator's flag: %v", machines)
	}
	// The node on it reads its own status.
	if st, o := maintCall(t, h, h.tokens["mac-c"], http.MethodGet, nil); st != 200 || o["status"] != "maintenance" {
		t.Fatalf("mac-c's own read = %d %v", st, o)
	}
	// mac-d is loaded and mac-c is 维护中: nothing can take new work, and the
	// refusal names both reasons.
	if pl, err := h.srv.PickNode("", writeRepo); err == nil || pl.Machine != "" || !strings.Contains(err.Error(), "mac-c: maintenance: 换内存") {
		t.Fatalf("both out: %q %v; want NO_ELIGIBLE_NODE naming mac-c's maintenance", pl.Machine, err)
	}
	putSetting(t, h, NodeMaintenancePrefix+"mac-c", "", 200)
	machines, _ = nodeStatuses(t, h)
	if machines["mac-c"]["status"] != "online" {
		t.Fatalf("after clearing: %v", machines["mac-c"])
	}
	if n := auditCount(t, h, `actor = 'operator' AND fleet_id = 'machine:mac-c'`); n != 2 {
		t.Fatalf("operator audit rows = %d, want ENTER + LEAVE", n)
	}
	putSetting(t, h, NodeMaintenancePrefix+"bad name!", "x", 400)
	putSetting(t, h, NodeMaintenancePrefix+"mac-c", strings.Repeat("长", 201), 400)
}

// Lost still wins: the flag says nothing about a machine the hub cannot hear.
func TestMaintenanceLostStillLost(t *testing.T) {
	now := time.Now()
	fresh, stale := now.Add(-2*time.Second), now.Add(-time.Hour)
	flag := map[string]string{NodeMaintenancePrefix + "mac-d": `{"since":"2026-10-04T00:00:00Z","reason":"升级"}`}
	cases := []struct {
		name     string
		last     *time.Time
		settings map[string]string
		want     string
	}{
		{"heard, no flag", &fresh, map[string]string{}, "online"},
		{"heard, flagged", &fresh, flag, "maintenance"},
		{"heard, flagged by FQDN key", &fresh, map[string]string{NodeMaintenancePrefix + "mac-d.local": "x"}, "maintenance"},
		{"silent, flagged", &stale, flag, "lost"},
		{"never heard, flagged", nil, flag, "lost"},
		{"another machine flagged", &fresh, map[string]string{NodeMaintenancePrefix + "mac-c": "x"}, "online"},
	}
	for _, c := range cases {
		if got := nodeAvail("mac-d.local", c.last, 5000, c.settings, now); got != c.want {
			t.Errorf("%s: %q, want %q", c.name, got, c.want)
		}
	}
	// A value set by hand is a bare reason with no clock.
	if m := parseMaintenance("mac-d", "手工"); m.Reason != "手工" || !m.Since.IsZero() {
		t.Fatalf("bare value = %+v", m)
	}
}

// `fleet connect` with no machine named lands on the one that is staying up;
// only when every online machine is 维护中 does it pick one of those, and says so.
func TestHomePickAvoidsMaintenance(t *testing.T) {
	h, _, _, _, _ := twoNodes(t)
	h.srv.FleetRoutes = []FleetMachine{
		{Hostname: "mac-d", Routes: []FleetRoute{{Name: "lan", Host: "10.0.0.5"}}},
		{Hostname: "mac-c", Routes: []FleetRoute{{Name: "lan", Host: "10.0.0.4"}}},
	}
	now := time.Now()
	// Both online, mac-d loaded: load rule picks mac-c either way, so use "last" to
	// steer at mac-d and watch the flag override it.
	if out, err := h.srv.homePick("", "mac-d", now); err != nil || out.Machine == nil || out.Machine.Hostname != "mac-d" || out.Rule != "last" {
		t.Fatalf("baseline: %+v (%v); want mac-d by last", out, err)
	}
	putSetting(t, h, NodeMaintenancePrefix+"mac-d", "升级", 200)
	out, err := h.srv.homePick("", "mac-d", now)
	if err != nil || out.Machine == nil || out.Machine.Hostname != "mac-c" {
		t.Fatalf("mac-d flagged: %+v (%v); want mac-c", out, err)
	}
	for _, c := range out.Candidates {
		if c.Machine == "mac-d" && (c.Maintenance != "升级" || !c.Online) {
			t.Fatalf("mac-d candidate = %+v; want online with the reason", c)
		}
	}
	putSetting(t, h, NodeMaintenancePrefix+"mac-c", "也在升级", 200)
	out, err = h.srv.homePick("", "mac-d", now)
	if err != nil || out.Machine == nil || out.Machine.Hostname != "mac-d" || !strings.Contains(out.Reason, "维护中") {
		t.Fatalf("both flagged: %+v (%v); want mac-d (last) with the 维护中 note", out, err)
	}
}
