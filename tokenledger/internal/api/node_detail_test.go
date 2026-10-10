package api

import (
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// detailRig is m4 as one machine link carrying alpha, beta and gamma — the
// issue's macmini with its three logins — each with a session, and a
// register entry per login; plus m5, one login of the operator's. alice
// holds alpha on m4 and nothing on m5.
func detailRig(t *testing.T) *harness {
	t.Helper()
	h := newFleetHarness(t)
	h.srv.FleetAdmins = []string{"alpha"}
	enablePeople(t, h, pAlice, pCarol)
	h.enroll(t, "mach")
	logins := []string{"alpha", "beta", "gamma"}
	for _, l := range logins {
		h.enroll(t, l)
		identify(t, h, l, "m4", l)
	}
	n := dialMachine(t, h, h.tokens["mach"])
	n.beat("", control.Heartbeat{Hostname: "m4", OSUser: "root", NCPU: 10, ObservedAt: time.Now()})
	for _, l := range logins {
		if r := n.login(l, h.tokens[l], l == "alpha", control.CapRead); r.Type != control.TypeWelcome {
			t.Fatalf("%s's hello answered %+v", l, r)
		}
		n.beat(l, control.Heartbeat{Hostname: "m4", OSUser: l, NCPU: 10, Load1: 5, MemTotalBytes: 16 << 30, MemFreeBytes: 4 << 30, ObservedAt: time.Now()})
	}
	started := time.Now().Add(-time.Hour).UTC()
	var svcs []control.ServiceStatus
	for _, l := range logins {
		svcs = append(svcs, control.ServiceStatus{Name: l + "-svc", Kind: "service", Login: l, State: "running", StartedAt: &started})
	}
	// The machine link reads the same kernel as its logins: the same load and
	// memory. foldSys takes the newest row whole, so a link row without memory
	// would blank it whenever its beat lands last (claude-fleet#2824).
	n.beat("", control.Heartbeat{Hostname: "m4", OSUser: "root", NCPU: 10, Load1: 5, MemTotalBytes: 16 << 30, MemFreeBytes: 4 << 30, ObservedAt: time.Now(), Services: svcs})
	if code := operatorPost(t, h, FleetAccountRequest{Action: "adopt", PrincipalID: pAlice, Hostname: "m4", Login: "alpha"}); code != 200 {
		t.Fatalf("adopt alice: HTTP %d", code)
	}
	connectNode(t, h, "m5-op", "m5", "verkyyi", false)
	waitFor(t, 3*time.Second, "m4's logins, register and m5", func() bool {
		snap := roster(t, h)
		for _, m := range snap.Machines {
			if m.Hostname == "m4" && (m.Online != 3 || len(m.Services) != 3) {
				return false
			}
		}
		return len(snap.Machines) == 2
	})
	now := time.Now()
	for i, l := range logins {
		fid := []string{"11111111-1111-4111-8111-111111111111", "22222222-2222-4222-8222-222222222222", "33333333-3333-4333-8333-333333333333"}[i]
		w, _ := json.Marshal([]map[string]any{{"key": "issue-" + l, "state": "working", "worker_id": fid + "/w"}})
		if _, err := h.srv.Store.RecordFleetSnapshot("ep_"+l, "m4", l, "mach-m4-"+l, []store.FleetReport{{FleetID: fid,
			Name: "fleet", Repo: "o/r", Checkout: "/c", WorkerCount: 1, WorkersJSON: string(w)}}, now); err != nil {
			t.Fatal(err)
		}
	}
	return h
}

func getDetail(t *testing.T, h *harness, path, principal string) (int, NodeDetail) {
	t.Helper()
	var code int
	var body []byte
	if principal == "" {
		req, _ := http.NewRequest(http.MethodGet, h.http.URL+path, nil)
		req.Header.Set("Authorization", "Bearer "+viewerToken)
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		code = resp.StatusCode
		var d NodeDetail
		_ = json.NewDecoder(resp.Body).Decode(&d)
		return code, d
	}
	code, body = asPerson(t, h, http.MethodGet, path, principal, nil)
	var d NodeDetail
	_ = json.Unmarshal(body, &d)
	return code, d
}

// claude-fleet#2796's 完成判据: the admin sees m4's three logins; a user sees
// their own row + 「另有 2 个登录」, only their own services and sessions; a
// machine with none of their logins is 404, like one that does not exist.
func TestNodeDetailIsCutLikeTheRoster(t *testing.T) {
	h := detailRig(t)

	code, d := getDetail(t, h, "/v1/nodes/m4", "")
	if code != 200 {
		t.Fatalf("operator /v1/nodes/m4: HTTP %d", code)
	}
	if len(d.Logins) != 3 || d.OtherLogins != 0 || len(d.Services) != 3 || len(d.Sessions) != 3 {
		t.Fatalf("operator's m4 = logins %d (+%d), services %d, sessions %d", len(d.Logins), d.OtherLogins, len(d.Services), len(d.Sessions))
	}
	for _, l := range d.Logins {
		if l.MachineLink {
			t.Fatalf("the machine link is listed as a login: %+v", l)
		}
	}
	if d.Machine.Hostname != "m4" || d.Load.NCPU != 10 || d.Load.Now != 5 || d.Mem.Total != 16<<30 || d.Mem.Used != 12<<30 {
		t.Fatalf("operator's m4 machine/load/mem = %+v %+v %+v", d.Machine.Hostname, d.Load, d.Mem)
	}
	if d.Mem.Pressure == nil || *d.Mem.Pressure != 0.75 {
		t.Fatalf("memory pressure = %v, want 0.75", d.Mem.Pressure)
	}
	if d.LoginsAt == nil || d.ServicesAt == nil || d.SessionsAt == nil {
		t.Fatalf("a block has no time: logins %v services %v sessions %v", d.LoginsAt, d.ServicesAt, d.SessionsAt)
	}
	if d.Version.Agent != "test" {
		t.Fatalf("agent version = %q", d.Version.Agent)
	}
	// An old node says nothing of when it measured its load: 时间未知.
	if d.Load.At != nil || d.Mem.At != nil {
		t.Fatalf("load/mem time invented: %v %v", d.Load.At, d.Mem.At)
	}

	code, d = getDetail(t, h, "/v1/nodes/m4", pAlice)
	if code != 200 {
		t.Fatalf("alice /v1/nodes/m4: HTTP %d", code)
	}
	if len(d.Logins) != 1 || d.Logins[0].OSUser != "alpha" || d.OtherLogins != 2 {
		t.Fatalf("alice's m4 logins = %+v (+%d); want alpha only + 2 others", d.Logins, d.OtherLogins)
	}
	if len(d.Services) != 1 || d.Services[0].Login != "alpha" {
		t.Fatalf("alice sees services %+v", d.Services)
	}
	if len(d.Sessions) != 1 || d.Sessions[0].OSUser != "alpha" {
		t.Fatalf("alice sees sessions %+v", d.Sessions)
	}
	raw, _ := json.Marshal(d)
	for _, other := range []string{"beta", "gamma"} {
		if strings.Contains(string(raw), other) {
			t.Fatalf("alice's answer names %s: %s", other, raw)
		}
	}

	for _, path := range []string{"/v1/nodes/m5", "/v1/nodes/nosuch"} {
		if code, _ := getDetail(t, h, path, pAlice); code != http.StatusNotFound {
			t.Fatalf("alice %s: HTTP %d, want 404", path, code)
		}
	}
	// carol has no login anywhere: m4 is 404 for her too.
	if code, _ := getDetail(t, h, "/v1/nodes/m4", pCarol); code != http.StatusNotFound {
		t.Fatalf("carol /v1/nodes/m4: HTTP %d, want 404", code)
	}
	// The operator opens m5; the name is matched case aside.
	if code, d := getDetail(t, h, "/v1/nodes/M5", ""); code != 200 || d.Machine.Hostname != "m5" {
		t.Fatalf("operator /v1/nodes/M5: HTTP %d %+v", code, d.Machine)
	}
}

// The page path answers the app document, for a user too; a deeper path
// under /v1/nodes/ is no machine.
func TestNodeDetailRoutes(t *testing.T) {
	h := detailRig(t)
	if code, _ := getDetail(t, h, "/v1/nodes/m4/extra", ""); code != http.StatusNotFound {
		t.Fatalf("/v1/nodes/m4/extra: HTTP %d, want 404", code)
	}
	if code, _ := getDetail(t, h, "/v1/nodes/", ""); code != http.StatusNotFound {
		t.Fatalf("/v1/nodes/: HTTP %d, want 404", code)
	}
	// /v1/nodes itself is unchanged.
	if snap := roster(t, h); len(snap.Machines) != 2 {
		t.Fatalf("/v1/nodes machines = %d", len(snap.Machines))
	}
}

// machineMatches: the hostname, its first label, its alias — case aside.
func TestMachineMatches(t *testing.T) {
	m := MachineView{Hostname: "macmini.tail435588.ts.net", Alias: "mini"}
	for _, n := range []string{"macmini.tail435588.ts.net", "macmini", "MacMini", "mini"} {
		if !machineMatches(m, n) {
			t.Fatalf("%q does not match %+v", n, m)
		}
	}
	for _, n := range []string{"mac", "m4", ""} {
		if machineMatches(m, n) {
			t.Fatalf("%q matches %+v", n, m)
		}
	}
}
