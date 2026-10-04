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
	for _, host := range []string{"m5", "m4"} {
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
	st, out := maintCall(t, h, h.tokens["m5"], http.MethodGet, nil)
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
	if pl, err := h.srv.PickNode("", writeRepo); err != nil || pl.Machine != "m4" {
		t.Fatalf("placement with nothing set: %q %v; want m4 (m5 is loaded)", pl.Machine, err)
	}
}

// The planned-outage half: a machine flags itself with its own token, the
// roster and the sidebar's machine line say 维护中, placement sends new work
// elsewhere — auto AND named — and `leave` puts everything back.
func TestNodeMaintenanceFlagsItselfAndPlacementAvoidsIt(t *testing.T) {
	h, m5, m4, f5, _ := twoNodes(t)
	// Make m5 the better machine, so only the flag can keep work off it.
	m5.beatLoad("m5", "verk", machineA, 0.5, 0, f5)
	waitFor(t, 3*time.Second, "m5 reports idle", func() bool {
		hb, _, _ := h.srv.nodeStatusOf("ep_m5", time.Now())
		return hb.Load1 == 0.5
	})
	if pl, err := h.srv.PickNode("", writeRepo); err != nil || pl.Machine != "m5" {
		t.Fatalf("before the flag: %q %v; want m5", pl.Machine, err)
	}

	st, out := maintCall(t, h, h.tokens["m5"], http.MethodPost, map[string]any{"action": "enter", "reason": "升级 macOS"})
	if st != 200 || out["status"] != "maintenance" {
		t.Fatalf("enter = %d %v; want status maintenance", st, out)
	}
	rec, _ := out["maintenance"].(map[string]any)
	if rec["reason"] != "升级 macOS" || rec["by"] != "node:verk@m5" || rec["machine"] != "m5" || rec["since"] == nil {
		t.Fatalf("record = %v", rec)
	}
	since := rec["since"]

	machines, nodes := nodeStatuses(t, h)
	if machines["m5"]["status"] != "maintenance" || nodes["m5"]["status"] != "maintenance" {
		t.Fatalf("roster: machine %v node %v; want maintenance", machines["m5"]["status"], nodes["m5"]["status"])
	}
	if mm, _ := machines["m5"]["maintenance"].(map[string]any); mm["reason"] != "升级 macOS" {
		t.Fatalf("machine record = %v", machines["m5"]["maintenance"])
	}
	// Heard, so its numbers are still there for the page.
	if machines["m5"]["logins_online"].(float64) != 1 || machines["m4"]["status"] != "online" {
		t.Fatalf("machines = %v", machines)
	}
	sess := getFleet(t, h, "/v1/fleet/fleet_sessions", 200)
	av := map[string]any{}
	for _, n := range sess["nodes"].([]any) {
		m := n.(map[string]any)
		av[m["machine_name"].(string)] = m["availability"]
	}
	if av["m5"] != "maintenance" || av["m4"] != "online" {
		t.Fatalf("fleet_sessions nodes = %v", av)
	}

	// Placement: auto goes to m4 with the reason; naming m5 is refused.
	wid := issueWID(f5.FleetID, 21)
	st, out = placeCall(t, h, h.tokens["m5"], map[string]any{"repo": writeRepo, "issue": 21, "worker_id": wid, "idempotency_key": "place-21"})
	if st != 200 || out["local"] != false {
		t.Fatalf("auto place = %d %v; want remote", st, out)
	}
	pl := out["placement"].(map[string]any)
	if pl["machine"] != "m4" || !strings.Contains(pl["reason"].(string), "m5 excluded: maintenance: 升级 macOS") {
		t.Fatalf("placement = %v", pl)
	}
	st, out = placeCall(t, h, h.tokens["m5"], map[string]any{"repo": writeRepo, "issue": 22, "worker_id": issueWID(f5.FleetID, 22), "node": "m5"})
	e, _ := out["error"].(map[string]any)
	if st != 503 || e["code"] != "NO_ELIGIBLE_NODE" || !strings.Contains(e["message"].(string), "m5: maintenance: 升级 macOS") {
		t.Fatalf("named place = %d %v; want NO_ELIGIBLE_NODE naming the maintenance", st, out)
	}
	if m5.count() != 0 || m4.count() != 1 {
		t.Fatalf("writes: m5=%d m4=%d; want 0 and 1", m5.count(), m4.count())
	}

	// A second enter is idempotent: the clock stays, the reason may change.
	st, out = maintCall(t, h, h.tokens["m5"], http.MethodPost, map[string]any{"action": "enter", "reason": "升级 macOS，预计 40 分钟"})
	rec, _ = out["maintenance"].(map[string]any)
	if st != 200 || rec["since"] != since || rec["reason"] != "升级 macOS，预计 40 分钟" {
		t.Fatalf("re-enter = %d %v; want the first clock kept", st, out)
	}
	if n := auditCount(t, h, `actor = 'node:verk@m5' AND fleet_id = 'machine:m5' AND outcome LIKE 'ENTER: %'`); n != 1 {
		t.Fatalf("ENTER audit rows = %d, want 1", n)
	}
	if n := auditCount(t, h, `outcome LIKE 'ALREADY: %'`); n != 1 {
		t.Fatalf("ALREADY audit rows = %d, want 1", n)
	}

	// Leave: online again, placement comes back.
	st, out = maintCall(t, h, h.tokens["m5"], http.MethodPost, map[string]any{"action": "leave"})
	if st != 200 || out["status"] != "online" || out["maintenance"] != nil {
		t.Fatalf("leave = %d %v", st, out)
	}
	if pl, err := h.srv.PickNode("", writeRepo); err != nil || pl.Machine != "m5" {
		t.Fatalf("after leave: %q %v; want m5", pl.Machine, err)
	}
	if n := auditCount(t, h, `outcome = 'LEAVE'`); n != 1 {
		t.Fatalf("LEAVE audit rows = %d, want 1", n)
	}
	st, out = maintCall(t, h, h.tokens["m5"], http.MethodPost, map[string]any{"action": "leave"})
	if st != 200 || auditCount(t, h, `outcome = 'NOT_FLAGGED'`) != 1 {
		t.Fatalf("second leave = %d %v; want NOT_FLAGGED audited", st, out)
	}
	if st, _ := maintCall(t, h, h.tokens["m5"], http.MethodPost, map[string]any{"action": "drain"}); st != 400 {
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
	out := putSetting(t, h, NodeMaintenancePrefix+"m4", "换内存", 200)
	eff := out["effective"].(map[string]any)
	rec, _ := eff[NodeMaintenancePrefix+"m4"].(map[string]any)
	if rec["reason"] != "换内存" || rec["by"] != "operator" || rec["machine"] != "m4" {
		t.Fatalf("effective record = %v", eff)
	}
	machines, _ := nodeStatuses(t, h)
	if machines["m4"]["status"] != "maintenance" || machines["m5"]["status"] != "online" {
		t.Fatalf("roster after the operator's flag: %v", machines)
	}
	// The node on it reads its own status.
	if st, o := maintCall(t, h, h.tokens["m4"], http.MethodGet, nil); st != 200 || o["status"] != "maintenance" {
		t.Fatalf("m4's own read = %d %v", st, o)
	}
	// m5 is loaded and m4 is 维护中: nothing can take new work, and the
	// refusal names both reasons.
	if pl, err := h.srv.PickNode("", writeRepo); err == nil || pl.Machine != "" || !strings.Contains(err.Error(), "m4: maintenance: 换内存") {
		t.Fatalf("both out: %q %v; want NO_ELIGIBLE_NODE naming m4's maintenance", pl.Machine, err)
	}
	putSetting(t, h, NodeMaintenancePrefix+"m4", "", 200)
	machines, _ = nodeStatuses(t, h)
	if machines["m4"]["status"] != "online" {
		t.Fatalf("after clearing: %v", machines["m4"])
	}
	if n := auditCount(t, h, `actor = 'operator' AND fleet_id = 'machine:m4'`); n != 2 {
		t.Fatalf("operator audit rows = %d, want ENTER + LEAVE", n)
	}
	putSetting(t, h, NodeMaintenancePrefix+"bad name!", "x", 400)
	putSetting(t, h, NodeMaintenancePrefix+"m4", strings.Repeat("长", 201), 400)
}

// Lost still wins: the flag says nothing about a machine the hub cannot hear.
func TestMaintenanceLostStillLost(t *testing.T) {
	now := time.Now()
	fresh, stale := now.Add(-2*time.Second), now.Add(-time.Hour)
	flag := map[string]string{NodeMaintenancePrefix + "m5": `{"since":"2026-10-04T00:00:00Z","reason":"升级"}`}
	cases := []struct {
		name     string
		last     *time.Time
		settings map[string]string
		want     string
	}{
		{"heard, no flag", &fresh, map[string]string{}, "online"},
		{"heard, flagged", &fresh, flag, "maintenance"},
		{"heard, flagged by FQDN key", &fresh, map[string]string{NodeMaintenancePrefix + "m5.local": "x"}, "maintenance"},
		{"silent, flagged", &stale, flag, "lost"},
		{"never heard, flagged", nil, flag, "lost"},
		{"another machine flagged", &fresh, map[string]string{NodeMaintenancePrefix + "m4": "x"}, "online"},
	}
	for _, c := range cases {
		if got := nodeAvail("m5.local", c.last, 5000, c.settings, now); got != c.want {
			t.Errorf("%s: %q, want %q", c.name, got, c.want)
		}
	}
	// A value set by hand is a bare reason with no clock.
	if m := parseMaintenance("m5", "手工"); m.Reason != "手工" || !m.Since.IsZero() {
		t.Fatalf("bare value = %+v", m)
	}
}

// `fleet connect` with no machine named lands on the one that is staying up;
// only when every online machine is 维护中 does it pick one of those, and says so.
func TestHomePickAvoidsMaintenance(t *testing.T) {
	h, _, _, _, _ := twoNodes(t)
	h.srv.FleetRoutes = []FleetMachine{
		{Hostname: "m5", Routes: []FleetRoute{{Name: "lan", Host: "10.0.0.5"}}},
		{Hostname: "m4", Routes: []FleetRoute{{Name: "lan", Host: "10.0.0.4"}}},
	}
	now := time.Now()
	// Both online, m5 loaded: load rule picks m4 either way, so use "last" to
	// steer at m5 and watch the flag override it.
	if out, err := h.srv.homePick("", "m5", now); err != nil || out.Machine == nil || out.Machine.Hostname != "m5" || out.Rule != "last" {
		t.Fatalf("baseline: %+v (%v); want m5 by last", out, err)
	}
	putSetting(t, h, NodeMaintenancePrefix+"m5", "升级", 200)
	out, err := h.srv.homePick("", "m5", now)
	if err != nil || out.Machine == nil || out.Machine.Hostname != "m4" {
		t.Fatalf("m5 flagged: %+v (%v); want m4", out, err)
	}
	for _, c := range out.Candidates {
		if c.Machine == "m5" && (c.Maintenance != "升级" || !c.Online) {
			t.Fatalf("m5 candidate = %+v; want online with the reason", c)
		}
	}
	putSetting(t, h, NodeMaintenancePrefix+"m4", "也在升级", 200)
	out, err = h.srv.homePick("", "m5", now)
	if err != nil || out.Machine == nil || out.Machine.Hostname != "m5" || !strings.Contains(out.Reason, "维护中") {
		t.Fatalf("both flagged: %+v (%v); want m5 (last) with the 维护中 note", out, err)
	}
}
