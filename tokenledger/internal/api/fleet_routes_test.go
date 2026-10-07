package api

import (
	"bytes"
	"encoding/json"
	"net/http"
	"testing"
	"time"

	"golang.org/x/crypto/ssh"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/sshca"
)

// The route list `fleet connect` measures (claude-fleet#1414).

// beatRoutes records a node on host whose newest heartbeat advertises routes.
func beatRoutes(t *testing.T, h *harness, label, host string, routes []control.NodeRoute) {
	t.Helper()
	h.enroll(t, label)
	now := time.Now()
	if err := h.srv.Store.NodeConnected("ep_"+label, host, "op", "test", control.Proto, 1000, now); err != nil {
		t.Fatal(err)
	}
	b, _ := json.Marshal(control.Heartbeat{Hostname: host, Routes: routes})
	if err := h.srv.Store.NodeHeartbeat("ep_"+label, host, "op", "", control.Proto, string(b), now); err != nil {
		t.Fatal(err)
	}
}

func routeNames(m FleetMachine) []string {
	var out []string
	for _, r := range m.Routes {
		out = append(out, r.Name+"="+r.Host)
	}
	return out
}

// The operator's static routes come first and win by name; a node's heartbeat
// adds the rest, and a machine only a heartbeat mentions is listed too. A
// route that is not a plain token never reaches an ssh config.
func TestFleetMachinesMergesHeartbeatRoutes(t *testing.T) {
	h := newFleetHarness(t)
	h.srv.FleetRoutes = []FleetMachine{{Hostname: "mini", Alias: "m4",
		Routes: []FleetRoute{{Name: "public", Host: "gw.static", Port: 22022}}}}
	beatRoutes(t, h, "a", "mini", []control.NodeRoute{
		{Name: "public", Host: "gw.node", Port: 22023},
		{Name: "tailnet", Host: "mini.tail.ts.net"},
		{Name: "bad name", Host: "x"},
		{Name: "evil", Host: "x\n  ProxyCommand sh"},
	})
	beatRoutes(t, h, "b", "m9", []control.NodeRoute{{Name: "tailnet", Host: "m9.tail.ts.net"}})

	ms := h.srv.fleetMachines()
	if len(ms) != 2 || ms[0].Hostname != "mini" || ms[1].Hostname != "m9" {
		t.Fatalf("machines = %+v", ms)
	}
	if got := routeNames(ms[0]); len(got) != 2 || got[0] != "public=gw.static" || got[1] != "tailnet=mini.tail.ts.net" {
		t.Fatalf("mini routes = %v", got)
	}
	if got := routeNames(ms[1]); len(got) != 1 || got[0] != "tailnet=m9.tail.ts.net" {
		t.Fatalf("m9 routes = %v", got)
	}
	// The static list itself is never written through.
	if len(h.srv.FleetRoutes[0].Routes) != 1 {
		t.Fatalf("static routes mutated: %+v", h.srv.FleetRoutes)
	}
	// The ssh config `fleet login` writes carries the advertised routes too.
	if cfg := h.srv.sshConfigFor("alice", nil); !bytes.Contains([]byte(cfg), []byte("HostName mini.tail.ts.net")) {
		t.Fatalf("ssh config lacks the heartbeat's route:\n%s", cfg)
	}
}

// fleet.machine_names is the hub's one place for the short name
// (claude-fleet#1706): it labels a machine that only a heartbeat mentions,
// wins over CCQUOTA_FLEET_ROUTES' alias, and rides /v1/nodes' machine rows.
// Unset, every alias is what the route lists said.
func TestFleetMachinesNamesFromSetting(t *testing.T) {
	h := newFleetHarness(t)
	h.srv.FleetRoutes = []FleetMachine{{Hostname: "mini", Alias: "old",
		Routes: []FleetRoute{{Name: "public", Host: "gw.static", Port: 22022}}}}
	beatRoutes(t, h, "a", "mini", []control.NodeRoute{{Name: "tailnet", Host: "mini.tail.ts.net"}})
	beatRoutes(t, h, "b", "macmini.local", []control.NodeRoute{{Name: "tailnet", Host: "macmini.tail.ts.net"}})

	aliases := func() map[string]string {
		out := map[string]string{}
		for _, m := range h.srv.fleetMachines() {
			out[m.Hostname] = m.Alias
		}
		return out
	}
	if got := aliases(); got["mini"] != "old" || got["macmini.local"] != "" {
		t.Fatalf("unset: aliases = %v", got)
	}
	if err := h.srv.Store.SetFleetSetting(MachineNamesKey, "macmini=m5,mini=m4", time.Now()); err != nil {
		t.Fatal(err)
	}
	if got := aliases(); got["mini"] != "m4" || got["macmini.local"] != "m5" {
		t.Fatalf("set: aliases = %v", got)
	}
	snap, err := h.srv.nodesWhere(time.Now(), nil)
	if err != nil {
		t.Fatal(err)
	}
	got := map[string]string{}
	for _, m := range snap.Machines {
		got[m.Hostname] = m.Alias
	}
	if got["mini"] != "m4" || got["macmini.local"] != "m5" {
		t.Fatalf("/v1/nodes machines = %+v", snap.Machines)
	}
}

func postRoutes(t *testing.T, h *harness, auth func(http.Header), body any) (int, RoutesResponse, string) {
	t.Helper()
	var rd *bytes.Reader
	method := http.MethodGet
	if body != nil {
		b, _ := json.Marshal(body)
		rd, method = bytes.NewReader(b), http.MethodPost
	} else {
		rd = bytes.NewReader(nil)
	}
	req, _ := http.NewRequest(method, h.http.URL+control.RoutesPath, rd)
	if auth != nil {
		auth(req.Header)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var out RoutesResponse
	var raw bytes.Buffer
	raw.ReadFrom(resp.Body)
	_ = json.Unmarshal(raw.Bytes(), &out)
	return resp.StatusCode, out, raw.String()
}

// A connection certificate, proven by signing a fresh timestamp, reads its
// holder's own machines and nothing else; the operator reads every machine.
func TestFleetRoutesEndpoint(t *testing.T) {
	h := newFleetHarness(t)
	k := newCertKit(t)
	h.srv.SSHCA = sshca.New(k.ca)
	h.srv.FleetRoutes = []FleetMachine{
		{Hostname: "mini", Alias: "m4", Routes: []FleetRoute{{Name: "public", Host: "gw", Port: 22023}}},
		{Hostname: "macmini", Alias: "m5", Routes: []FleetRoute{{Name: "public", Host: "gw", Port: 22022}}},
	}
	beatRoutes(t, h, "a", "mini", []control.NodeRoute{{Name: "tailnet", Host: "mini.ts.net"}})
	p, _ := h.srv.Store.AdoptPrincipal("wx-alice", "alice", "Alice", time.Now())
	h.srv.Store.AdoptAccount(p, "mini", time.Now())

	now := time.Now()
	good := k.cert(t, "person:wx-alice", []string{"alice"}, now.Add(-time.Minute), now.Add(12*time.Hour))
	signed := func(c *ssh.Certificate, ns string, ts int64) RoutesRequest {
		return RoutesRequest{Cert: string(ssh.MarshalAuthorizedKey(c)), TS: ts,
			Sig: sshsig(t, k.user, ns, []byte(control.RoutesSigMessage(ts)))}
	}

	code, out, raw := postRoutes(t, h, nil, signed(good, control.RoutesSigNamespace, now.Unix()))
	if code != 200 {
		t.Fatalf("a valid certificate: HTTP %d %s", code, raw)
	}
	if out.Login != "alice" || len(out.Machines) != 1 || out.Machines[0].Alias != "m4" {
		t.Fatalf("alice sees %+v, want only m4 as alice", out)
	}
	if got := routeNames(out.Machines[0].FleetMachine); len(got) != 2 || got[1] != "tailnet=mini.ts.net" {
		t.Fatalf("m4 routes = %v", got)
	}
	if out.Machines[0].Relay {
		t.Fatal("relay offered with no agent connected")
	}

	for name, req := range map[string]RoutesRequest{
		"stale timestamp": signed(good, control.RoutesSigNamespace, now.Add(-10*time.Minute).Unix()),
		"relay namespace": signed(good, control.SSHRelaySigNamespace, now.Unix()),
		"expired cert":    signed(k.cert(t, "wx-alice", []string{"alice"}, now.Add(-13*time.Hour), now.Add(-time.Hour)), control.RoutesSigNamespace, now.Unix()),
		"no signature":    {Cert: string(ssh.MarshalAuthorizedKey(good)), TS: now.Unix()},
	} {
		if code, _, raw := postRoutes(t, h, nil, req); code != http.StatusUnauthorized {
			t.Errorf("%s: HTTP %d %s, want 401", name, code, raw)
		}
	}
	if code, _, _ := postRoutes(t, h, nil, nil); code != http.StatusUnauthorized {
		t.Errorf("no credential: HTTP %d, want 401", code)
	}

	// Someone with no account anywhere is told so, not handed an empty list.
	h.srv.Store.AdoptPrincipal("wx-bob", "bob", "Bob", time.Now())
	bob := k.cert(t, "person:wx-bob", []string{"bob"}, now.Add(-time.Minute), now.Add(time.Hour))
	if code, _, raw := postRoutes(t, h, nil, signed(bob, control.RoutesSigNamespace, now.Unix())); code != http.StatusForbidden {
		t.Errorf("no account: HTTP %d %s, want 403", code, raw)
	}

	code, out, _ = postRoutes(t, h, asOperator, nil)
	if code != 200 || out.Login != "" || len(out.Machines) != 2 {
		t.Fatalf("operator: HTTP %d %+v, want both machines", code, out)
	}
}

// The relay flag follows a connected agent that can carry one.
func TestFleetRoutesRelayFlag(t *testing.T) {
	h := newFleetHarness(t)
	host, stop := startSSHRelayAgent(t, h, "m4", testSSHD(t))
	h.srv.FleetRoutes = []FleetMachine{{Hostname: host, Routes: []FleetRoute{{Name: "lan", Host: "10.0.0.2"}}}}
	_, out, _ := postRoutes(t, h, asOperator, nil)
	if len(out.Machines) != 1 || !out.Machines[0].Relay {
		t.Fatalf("connected relay agent: %+v, want relay=true", out.Machines)
	}
	stop()
	waitFor(t, 5*time.Second, "relay flag cleared", func() bool {
		_, out, _ := postRoutes(t, h, asOperator, nil)
		return len(out.Machines) == 1 && !out.Machines[0].Relay
	})
}
