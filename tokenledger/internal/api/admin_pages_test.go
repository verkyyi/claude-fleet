package api

import (
	"net/http"
	"strings"
	"testing"
	"testing/fstest"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/credvault"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// The admin pages (claude-fleet#1990): every write an admin makes from them
// lands in the one audit the Audit page reads, sorted into its filter; a
// pool subscription can be paused; a user gets the 403 page.

func auditOf(t *testing.T, h *harness, q string) []AuditEvent {
	t.Helper()
	var out struct {
		Events []AuditEvent   `json:"events"`
		Counts map[string]int `json:"counts"`
	}
	h.getJSON(t, AuditPath+q, &out)
	return out.Events
}

func findEvent(evs []AuditEvent, kind, action, target string) *AuditEvent {
	for i, e := range evs {
		if e.Kind == kind && e.Action == action && strings.Contains(e.Target, target) {
			return &evs[i]
		}
	}
	return nil
}

func TestAdminAudit_EveryWriteHasItsRow(t *testing.T) {
	h, tok, _ := newVaultHarness(t)
	exp := time.Now().Add(365 * 24 * time.Hour).UTC().Truncate(time.Second)
	// Add a subscription, the way a machine delivers it.
	if code, out := h.post(t, "/v1/fleet/credentials", FleetCredentialRequest{Action: "put", PrincipalID: store.PoolPrincipal,
		Provider: credvault.Claude, Account: "icloud", Secret: credvault.Secret{SetupToken: "sk-ant-oat01-X", ExpiresAt: &exp}}); code != http.StatusOK {
		t.Fatalf("put pool: %d %v", code, out)
	}
	// Pause it, put a machine into maintenance, turn SPOT on, change a setting.
	for _, kv := range [][2]string{
		{PoolPausedPrefix + "icloud", "on"},
		{NodeMaintenancePrefix + "m4", "upgrade"},
		{SpotKey, "on"},
		{PoolSkipPctKey, "90"},
	} {
		if code, out := h.post(t, "/v1/fleet/settings", map[string]string{"key": kv[0], "value": kv[1]}); code != http.StatusOK {
			t.Fatalf("set %s: %d %v", kv[0], code, out)
		}
	}
	// A page polls the fleet: a read, audited by the fleet, not shown.
	if err := h.srv.Store.FleetAudit("operator", "fleet_sessions", "", "OK", "", time.Now()); err != nil {
		t.Fatal(err)
	}
	if err := h.srv.Store.FleetAudit("operator", "worker_start", "f1", "OK", "op1", time.Now()); err != nil {
		t.Fatal(err)
	}
	// Add a machine: the minted code is a row, the code itself is not.
	code, jc := h.post(t, "/v1/fleet/join-codes", map[string]string{"label": "web-1"})
	if code != http.StatusOK {
		t.Fatalf("join code: %d %v", code, jc)
	}
	// Leased, flagged: a session on it finishes, a node starts no new one.
	_, got, _ := lease(t, h, tok)
	var pooled *NodeCredential
	for i, c := range got.Credentials {
		if c.Account == "icloud" {
			pooled = &got.Credentials[i]
		}
	}
	if pooled == nil || !pooled.Paused || pooled.Access == nil {
		t.Fatalf("paused pool credential = %+v; want leased and flagged paused", pooled)
	}
	var creds struct {
		Paused []string `json:"paused"`
	}
	h.getJSON(t, "/v1/fleet/credentials", &creds)
	if len(creds.Paused) != 1 || creds.Paused[0] != "icloud" {
		t.Fatalf("credentials paused = %v; want [icloud]", creds.Paused)
	}
	if p := h.srv.poolSettings()["FLEET_ACCOUNT_PAUSED"]; p != "icloud" {
		t.Fatalf("client pool settings FLEET_ACCOUNT_PAUSED = %q", p)
	}
	// Resume, then remove it.
	if code, _ := h.post(t, "/v1/fleet/settings", map[string]string{"key": PoolPausedPrefix + "icloud", "value": ""}); code != http.StatusOK {
		t.Fatal("resume")
	}
	if code, out := h.post(t, "/v1/fleet/credentials", FleetCredentialRequest{Action: "delete", PrincipalID: store.PoolPrincipal,
		Provider: credvault.Claude, Account: "icloud"}); code != http.StatusOK {
		t.Fatalf("delete pool: %d %v", code, out)
	}

	evs := auditOf(t, h, "")
	for _, want := range []struct{ kind, action, target string }{
		{auditSubs, store.CredPut, "icloud"},
		{auditSubs, "setting", PoolPausedPrefix + "icloud"},
		{auditMachines, "node_maintenance", "m4"},
		{auditMachines, "setting", SpotKey},
		{auditSubs, "setting", PoolSkipPctKey},
		{auditSubs, store.CredDelete, "icloud"},
		{auditMachines, "node_join_code", "join:web-1"},
		{auditSessions, "worker_start", "f1"},
	} {
		e := findEvent(evs, want.kind, want.action, want.target)
		if e == nil {
			t.Errorf("no %s/%s %s row in %+v", want.kind, want.action, want.target, evs)
			continue
		}
		if e.Actor == "" {
			t.Errorf("%s %s has no actor", want.action, want.target)
		}
	}
	// Both pause rows (on, then resume) are there, newest first.
	n := 0
	for _, e := range evs {
		if e.Target == PoolPausedPrefix+"icloud" {
			n++
		}
	}
	if n != 2 {
		t.Errorf("%d pause rows; want 2 (pause, resume)", n)
	}
	for i := 1; i < len(evs); i++ {
		if evs[i].At.After(evs[i-1].At) {
			t.Fatalf("not newest first at %d", i)
		}
	}
	for _, e := range evs {
		if s, _ := jc["code"].(string); s != "" && strings.Contains(e.Target+e.Outcome+e.Detail, s) {
			t.Fatalf("the join code itself is in the audit: %+v", e)
		}
	}
	// A Fleet read is traffic too.
	if findEvent(evs, auditSessions, "fleet_sessions", "") != nil {
		t.Error("a fleet_sessions read is in the admin audit")
	}
	// A lease is traffic, not a change: not in the page's audit.
	if findEvent(evs, auditSubs, store.CredIssue, "") != nil {
		t.Error("a lease row is in the admin audit")
	}

	// One filter.
	for _, e := range auditOf(t, h, "?kind=mach") {
		if e.Kind != auditMachines {
			t.Fatalf("kind=mach answered %+v", e)
		}
	}
	if code := h.getCode(t, AuditPath+"?kind=nope"); code != http.StatusBadRequest {
		t.Errorf("kind=nope = %d; want 400", code)
	}
}

func TestAdminAudit_CSV(t *testing.T) {
	h, _, _ := newVaultHarness(t)
	if code, _ := h.post(t, "/v1/fleet/settings", map[string]string{"key": NodeMaintenancePrefix + "m4", "value": "upgrade"}); code != http.StatusOK {
		t.Fatal("maintenance")
	}
	resp, body := h.get(t, AuditPath+"?format=csv")
	if resp.StatusCode != http.StatusOK || !strings.HasPrefix(resp.Header.Get("Content-Type"), "text/csv") {
		t.Fatalf("csv: %d %s", resp.StatusCode, resp.Header.Get("Content-Type"))
	}
	if !strings.Contains(resp.Header.Get("Content-Disposition"), "audit-") {
		t.Errorf("no file name: %q", resp.Header.Get("Content-Disposition"))
	}
	lines := strings.Split(strings.TrimSpace(string(body)), "\n")
	if lines[0] != "at,kind,source,actor,action,target,outcome,detail" || len(lines) < 2 {
		t.Fatalf("csv = %q", body)
	}
	if !strings.Contains(string(body), ",node_maintenance,machine:m4,") {
		t.Errorf("no maintenance row in %s", body)
	}
	// A cell an actor typed never starts a formula.
	for in, want := range map[string]string{"=1+1": "'=1+1", "@x": "'@x", "-2": "'-2", "ok": "ok", "": ""} {
		if got := csvSafe(in); got != want {
			t.Errorf("csvSafe(%q) = %q; want %q", in, got, want)
		}
	}
}

func TestPoolPaused_Checked(t *testing.T) {
	h, _, _ := newVaultHarness(t)
	for _, kv := range [][2]string{
		{PoolPausedPrefix + "icloud", "maybe"},
		{PoolPausedPrefix + "has space", "on"},
		{PoolPausedPrefix, "on"},
	} {
		if code, _ := h.post(t, "/v1/fleet/settings", map[string]string{"key": kv[0], "value": kv[1]}); code != http.StatusBadRequest {
			t.Errorf("set %q=%q = %d; want 400", kv[0], kv[1], code)
		}
	}
}

func TestAuditKinds(t *testing.T) {
	for action, want := range map[string]string{
		"spawn": auditSessions, "role_denied": auditUsers, "node_maintenance": auditMachines,
		"spot_start": auditMachines, "team_bundle_put": auditSettings, "session_bind": auditSubs,
		"client_revoke": auditDevices, "relay_cred": auditMachines,
	} {
		if got := fleetAuditKind(action); got != want {
			t.Errorf("fleet %s = %s; want %s", action, got, want)
		}
	}
	for _, c := range []struct{ action, target, want string }{
		{"user.add", "octocat", auditUsers}, {"signin", "", auditUsers},
		{"setting", "pool.paused.x", auditSubs}, {"setting", SpotKey, auditMachines},
		{"setting", MeterKey, auditSettings}, {"setting", "user.7.machine_login", auditUsers},
	} {
		if got := hubAuditKind(c.action, c.target); got != c.want {
			t.Errorf("hub %s %s = %s; want %s", c.action, c.target, got, c.want)
		}
	}
	if a := credActor("left · by verkyyi (gh:100)"); a != "verkyyi (gh:100)" {
		t.Errorf("credActor = %q", a)
	}
}

// A user asking for an admin page gets 403 with the page itself — its shell
// draws 「不在你的菜单里」 — and one role_denied row; an admin gets the page.
func TestAdminPages_UserGets403Page(t *testing.T) {
	h, admin, user := rolesHarness(t)
	h.srv.UI = fstest.MapFS{}
	for _, p := range append(adminPageRoutes, struct{ path, id, file string }{"/nodes", "machines", "nodes.html"}) {
		h.srv.UI.(fstest.MapFS)[p.file] = &fstest.MapFile{Data: []byte("<title>" + p.id + "</title>")}
	}
	for _, p := range []string{"/subscriptions", "/nodes", "/admin/users", "/admin/settings", "/admin/audit"} {
		code, body := rolesGet(t, h, user, p)
		if code != http.StatusForbidden || !strings.Contains(string(body), "<title>") {
			t.Errorf("user GET %s = %d %q; want 403 and the page", p, code, body)
		}
		if code, _ := rolesGet(t, h, admin, p); code != http.StatusOK {
			t.Errorf("admin GET %s = %d; want 200", p, code)
		}
	}
	if code, _ := rolesGet(t, h, user, AuditPath); code != http.StatusForbidden {
		t.Errorf("user GET %s = %d; want 403", AuditPath, code)
	}
	n := 0
	for _, e := range h.audit(t) {
		if e.Action == "role_denied" {
			n++
		}
	}
	if fa, err := h.srv.Store.FleetAuditLog(0); err == nil {
		for _, e := range fa {
			if e.Action == "role_denied" {
				n++
			}
		}
	}
	if n < 6 {
		t.Errorf("%d role_denied rows; want one per refusal (6)", n)
	}
}

func TestLoadHistory(t *testing.T) {
	var lh loadHistory
	now := time.Date(2026, 10, 7, 12, 0, 0, 0, time.UTC)
	if s := lh.series("m4", now); s == nil || len(s) != 0 {
		t.Fatalf("empty series = %v", s)
	}
	lh.add("m4.tail.ts.net", 4, 8, now.Add(-20*time.Minute))
	lh.add("m4", 2, 8, now.Add(-10*time.Minute))
	lh.add("m4", 8, 8, now)
	lh.add("m4", 1, 0, now.Add(-5*time.Hour)) // too old: dropped
	got := lh.series("m4.tail.ts.net", now)
	want := []float64{0.5, 0.5, 0.25, 0.25, 1}
	if len(got) != len(want) {
		t.Fatalf("series = %v; want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("series = %v; want %v", got, want)
		}
	}
	if len(lh.series("m4", now.Add(3*time.Hour))) != 0 {
		// Everything is older than two hours: the window is empty again.
		t.Fatal("stale series not empty")
	}
}
