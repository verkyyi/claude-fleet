package api

import (
	"encoding/json"
	"io"
	"net/http"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/pricing"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// claude-fleet#1986 (EPIC #1982 C4): the people list and the hub's settings
// change on the web or from `fleet users` / `fleet hub set`, at once, every
// change audited, no deploy file touched.

// call is one request to the harness: the viewer token (an admin's door)
// unless a cookie is given. Returns the status and the decoded JSON body.
func (h *ghHarness) call(t *testing.T, method, path, body string, sess *http.Cookie) (int, map[string]any) {
	t.Helper()
	var rd io.Reader
	if body != "" {
		rd = strings.NewReader(body)
	}
	req, _ := http.NewRequest(method, h.http.URL+path, rd)
	req.Header.Set("Accept", "application/json")
	if body != "" {
		req.Header.Set("Content-Type", "application/json")
	}
	if sess != nil {
		req.AddCookie(sess)
	} else {
		req.Header.Set("Authorization", "Bearer "+viewerToken)
	}
	resp, err := noFollow.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	out := map[string]any{}
	_ = json.NewDecoder(resp.Body).Decode(&out)
	return resp.StatusCode, out
}

func (h *ghHarness) auditHas(t *testing.T, action, outcome, part string) bool {
	t.Helper()
	for _, e := range h.audit(t) {
		if e.Action == action && e.Outcome == outcome && strings.Contains(e.Target+" "+e.Detail, part) {
			return true
		}
	}
	return false
}

func newUsersHarness(t *testing.T) *ghHarness {
	t.Helper()
	h := newGitHubHarnessWith(t, fullServer, ghAdmin.Login)
	h.gh.mu.Lock()
	for _, u := range []fakeGHUser{ghAdmin, ghAlice, ghMallory} {
		h.gh.public[strings.ToLower(u.Login)] = u
	}
	h.gh.mu.Unlock()
	return h
}

// Adding a name lets that account in at once; removing it refuses the very
// next request and revokes its devices. Both are audited.
func TestFleetUsers_AddThenSignInThenRemove(t *testing.T) {
	h := newUsersHarness(t)
	if resp, sess := h.signIn(t, ghAlice); sess != nil {
		t.Fatalf("alice signed in before being added: %d", resp.StatusCode)
	}
	code, body := h.call(t, http.MethodPost, "/v1/fleet/users", `{"login":"Alice"}`, nil)
	if code != http.StatusCreated || body["added"] != "alice" {
		t.Fatalf("add = %d %v", code, body)
	}
	if id, ok, _ := h.srv.Store.PinnedID("alice"); !ok || id != ghAlice.ID {
		t.Fatalf("alice pinned to %d (%v), want %d", id, ok, ghAlice.ID)
	}
	_, sess := h.signIn(t, ghAlice)
	if sess == nil {
		t.Fatal("alice could not sign in right after being added")
	}
	if code, me := h.me(t, sess); code != http.StatusOK || me.Role != roleUser {
		t.Fatalf("alice /v1/me = %d role %q", code, me.Role)
	}
	// A device of hers, to be revoked with her.
	if _, err := h.srv.Store.RegisterDevice(store.FleetDevice{Fingerprint: "SHA256:alicekey",
		PrincipalID: githubPrincipal(ghAlice.ID), PublicKey: "ssh-ed25519 AAAA", Name: "alice-mbp"}, time.Now()); err != nil {
		t.Fatal(err)
	}

	code, body = h.call(t, http.MethodDelete, "/v1/fleet/users?login=alice", "", nil)
	if code != http.StatusOK || body["devices_revoked"] != float64(1) {
		t.Fatalf("remove = %d %v", code, body)
	}
	if code, _ := h.me(t, sess); code == http.StatusOK {
		t.Fatal("alice's session still works after removal")
	}
	if revoked, err := h.srv.Store.DeviceRevoked("SHA256:alicekey"); err != nil || !revoked {
		t.Fatalf("alice's device revoked = %v, %v", revoked, err)
	}
	if !h.auditHas(t, "user.add", "ok", "alice") || !h.auditHas(t, "user.remove", "ok", "1 device(s) revoked") {
		t.Fatalf("audit = %+v", h.audit(t))
	}
}

// A name GitHub does not know is refused, never added.
func TestFleetUsers_UnknownNameRefused(t *testing.T) {
	h := newUsersHarness(t)
	code, body := h.call(t, http.MethodPost, "/v1/fleet/users", `{"login":"nobody-here"}`, nil)
	if code != http.StatusBadRequest {
		t.Fatalf("add unknown = %d %v", code, body)
	}
	if users, _ := h.srv.Store.HubUsers(); len(users) != 0 {
		t.Fatalf("list = %+v, want empty", users)
	}
	if _, ok, _ := h.srv.Store.PinnedID("nobody-here"); ok {
		t.Fatal("an unknown name was pinned")
	}
	if code, _ := h.call(t, http.MethodPost, "/v1/fleet/users", `{"login":"bad name!"}`, nil); code != http.StatusBadRequest {
		t.Fatalf("add malformed = %d", code)
	}
}

// The deploy's admin is read-only: it cannot be removed, nor added as a user.
func TestFleetUsers_DeployAdminReadOnly(t *testing.T) {
	h := newUsersHarness(t)
	if _, sess := h.signIn(t, ghAdmin); sess == nil {
		t.Fatal("admin could not sign in")
	}
	if code, body := h.call(t, http.MethodDelete, "/v1/fleet/users?login=verkyyi", "", nil); code != http.StatusForbidden {
		t.Fatalf("remove deploy admin = %d %v", code, body)
	}
	if code, body := h.call(t, http.MethodPost, "/v1/fleet/users", `{"login":"VerkyYi"}`, nil); code != http.StatusConflict {
		t.Fatalf("add deploy admin = %d %v", code, body)
	}
	if role, _ := h.srv.githubRole(ghAdmin.ID); role != roleAdmin {
		t.Fatalf("admin's role = %q after the attempts", role)
	}
	code, body := h.call(t, http.MethodGet, "/v1/fleet/users", "", nil)
	users, _ := body["users"].([]any)
	if code != http.StatusOK || len(users) != 1 || users[0].(map[string]any)["deploy"] != true {
		t.Fatalf("list = %d %v", code, body)
	}
	if !h.auditHas(t, "user.remove", "refused", "verkyyi") {
		t.Fatalf("audit = %+v", h.audit(t))
	}
}

// Who can and who cannot touch the list: an admin (GitHub or the viewer
// token) can; a user cannot, not even to read it.
func TestFleetUsers_WhoMay(t *testing.T) {
	h := newUsersHarness(t)
	h.addUser(t, ghAlice)
	_, admin := h.signIn(t, ghAdmin)
	_, alice := h.signIn(t, ghAlice)
	if admin == nil || alice == nil {
		t.Fatal("sign-ins failed")
	}
	cases := []struct {
		who    string
		sess   *http.Cookie
		method string
		body   string
		want   int
	}{
		{"viewer token GET", nil, http.MethodGet, "", http.StatusOK},
		{"admin GET", admin, http.MethodGet, "", http.StatusOK},
		{"admin POST", admin, http.MethodPost, `{"login":"mallory"}`, http.StatusCreated},
		{"user GET", alice, http.MethodGet, "", http.StatusForbidden},
		{"user POST", alice, http.MethodPost, `{"login":"mallory"}`, http.StatusForbidden},
		{"user DELETE", alice, http.MethodDelete, `{"login":"mallory"}`, http.StatusForbidden},
	}
	for _, c := range cases {
		if code, body := h.call(t, c.method, "/v1/fleet/users", c.body, c.sess); code != c.want {
			t.Errorf("%s = %d, want %d (%v)", c.who, code, c.want, body)
		}
	}
	// The admin's add is recorded under their name.
	if !h.auditHas(t, "user.add", "ok", "mallory") {
		t.Fatalf("audit = %+v", h.audit(t))
	}
	for _, e := range h.audit(t) {
		if e.Action == "user.add" && !strings.Contains(e.Actor, "gh:100") {
			t.Errorf("user.add actor = %q, want the admin", e.Actor)
		}
	}
}

// A machine login set with the add lands on the person's row; one already
// someone else's is refused.
func TestFleetUsers_MachineLogin(t *testing.T) {
	h := newUsersHarness(t)
	if code, body := h.call(t, http.MethodPost, "/v1/fleet/users", `{"login":"alice","machine_login":"alice2"}`, nil); code != http.StatusCreated {
		t.Fatalf("add = %d %v", code, body)
	}
	if u, _ := h.srv.Store.HubUserByID(ghAlice.ID); u == nil || u.MachineLogin != "alice2" {
		t.Fatalf("alice = %+v", u)
	}
	code, body := h.call(t, http.MethodPut, "/v1/fleet/settings", `{"key":"user.gh:300.machine_login","value":"alice2"}`, nil)
	if code != http.StatusNotFound {
		t.Fatalf("mallory not on the list = %d %v", code, body)
	}
	h.call(t, http.MethodPost, "/v1/fleet/users", `{"login":"mallory"}`, nil)
	if code, body := h.call(t, http.MethodPut, "/v1/fleet/settings", `{"key":"user.gh:300.machine_login","value":"alice2"}`, nil); code != http.StatusBadRequest {
		t.Fatalf("taken login = %d %v", code, body)
	}
	if !h.auditHas(t, "setting", "ok", "user.gh:200.machine_login") {
		t.Fatalf("audit = %+v", h.audit(t))
	}
}

// Every settings change is one audit row with the old and new value; a bad
// value is refused and changes nothing; the reader sees the new value on
// the next request.
func TestHubSettings_PutReadAudit(t *testing.T) {
	h := newUsersHarness(t)
	cases := []struct {
		key, value string
		want       int
		read       string
	}{
		{PoolSkipPctKey, "90", http.StatusOK, "90"},
		{PoolSkipPctKey, "0", http.StatusBadRequest, "90"},
		{PoolSkipPctKey, "101", http.StatusBadRequest, "90"},
		{PoolMoveFullKey, "on", http.StatusOK, "on"},
		{PoolMoveFullKey, "maybe", http.StatusBadRequest, "on"},
		{AutoAssignKey, "m4, macmini", http.StatusOK, "m4,macmini"},
		{AutoAssignKey, "bad host!", http.StatusBadRequest, "m4,macmini"},
		{SpotKey, "on", http.StatusOK, "on"},
		{PublicBadgesKey, "on", http.StatusOK, "on"},
		{MeterKey, "off", http.StatusOK, "off"},
		{RoutesExtraKey, `[{"hostname":"m9","routes":[{"name":"lan","host":"10.0.0.9"}]}]`, http.StatusOK, `[{"hostname":"m9","routes":[{"name":"lan","host":"10.0.0.9"}]}]`},
		{RoutesExtraKey, `[{"hostname":"bad host"}]`, http.StatusBadRequest, `[{"hostname":"m9","routes":[{"name":"lan","host":"10.0.0.9"}]}]`},
		{PoolSkipPctKey, "", http.StatusOK, "85"},
	}
	for _, c := range cases {
		b, _ := json.Marshal(map[string]string{"key": c.key, "value": c.value})
		code, body := h.call(t, http.MethodPut, "/v1/fleet/settings", string(b), nil)
		if code != c.want {
			t.Errorf("PUT %s=%q = %d, want %d (%v)", c.key, c.value, code, c.want, body)
		}
		if got := h.srv.setting(c.key); got != c.read {
			t.Errorf("after PUT %s=%q: setting = %q, want %q", c.key, c.value, got, c.read)
		}
	}
	if !h.auditHas(t, "setting", "ok", "(default) → 90") || !h.auditHas(t, "setting", "ok", "90 → (default)") {
		t.Fatalf("audit = %+v", h.audit(t))
	}
	n := 0
	for _, e := range h.audit(t) {
		if e.Action == "setting" {
			n++
		}
	}
	if n != 8 { // one per accepted change
		t.Errorf("setting audit rows = %d, want 8", n)
	}
	// The readers follow at once.
	if got := h.srv.autoAssign(); strings.Join(got, ",") != "m4,macmini" {
		t.Errorf("autoAssign = %v", got)
	}
	if !h.srv.publicBadges() {
		t.Error("publicBadges off after hub.public_badges on")
	}
	if h.srv.spot() != nil {
		t.Error("spot() without a SPOT image")
	}
	found := false
	for _, m := range h.srv.fleetMachines() {
		found = found || m.Hostname == "m9"
	}
	if !found {
		t.Error("fleet.routes_extra's machine is not in the routes")
	}
	if p := h.srv.poolSettings(); p["FLEET_ACCOUNT_CEILING"] != "85" || p["FLEET_FAILOVER"] != "1" {
		t.Errorf("pool = %v", p)
	}
	// Any other key a settings PUT stores is audited too.
	if code, _ := h.call(t, http.MethodPut, "/v1/fleet/settings", `{"key":"fleet.node_cap.m4","value":"3"}`, nil); code != http.StatusOK {
		t.Fatalf("node cap = %d", code)
	}
	if !h.auditHas(t, "setting", "ok", "fleet.node_cap.m4") {
		t.Errorf("node cap change not audited")
	}
}

// hub.public_badges is read per request: switching it opens /badge/ to a
// signed-out browser at once, and closes it again.
func TestHubSettings_PublicBadgesLive(t *testing.T) {
	h := newUsersHarness(t)
	get := func() int {
		resp, err := noFollow.Get(h.http.URL + "/badge/team/x.svg")
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		return resp.StatusCode
	}
	if code := get(); code != http.StatusUnauthorized && code != http.StatusFound && code != http.StatusForbidden {
		t.Fatalf("badge signed out, switch off = %d", code)
	}
	h.call(t, http.MethodPut, "/v1/fleet/settings", `{"key":"hub.public_badges","value":"on"}`, nil)
	if code := get(); code == http.StatusUnauthorized || code == http.StatusFound || code == http.StatusForbidden {
		t.Fatalf("badge signed out, switch on = %d", code)
	}
	h.call(t, http.MethodPut, "/v1/fleet/settings", `{"key":"hub.public_badges","value":"off"}`, nil)
	if code := get(); code != http.StatusUnauthorized && code != http.StatusFound && code != http.StatusForbidden {
		t.Fatalf("badge signed out, switch off again = %d", code)
	}
}

// The old variables are still read for one version, are copied into the
// database once at start (audited as the deploy's), and a value an admin
// clears afterwards is not brought back by the next start.
func TestMigrateLegacySettings(t *testing.T) {
	st, err := store.Open(filepath.Join(t.TempDir(), "test.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	if err := st.EnsureNodes(); err != nil {
		t.Fatal(err)
	}
	s := &Server{Store: st, Pricing: pricing.Default(), Fleet: true,
		PublicBadges:         true,
		FleetAutoAssign:      []string{"m4"},
		FleetPrincipalLogins: map[string]string{"yilianghui": "verkyyi"}}

	// Before the copy: the old values apply.
	if got := s.setting(AutoAssignKey); got != "m4" {
		t.Fatalf("legacy auto_assign = %q", got)
	}
	if !s.publicBadges() {
		t.Fatal("legacy --public-badges not read")
	}
	if login, ok := s.mappedLoginFor("YiLiangHui"); !ok || login != "verkyyi" {
		t.Fatalf("legacy map = %q %v", login, ok)
	}

	now := time.Now()
	if err := s.MigrateLegacySettings(now); err != nil {
		t.Fatal(err)
	}
	settings, _ := st.FleetSettings()
	if settings[AutoAssignKey] != "m4" || settings[PublicBadgesKey] != "on" ||
		settings["user.yilianghui.machine_login"] != "verkyyi" {
		t.Fatalf("after migrate: %v", settings)
	}
	if settings[SpotKey] != "" {
		t.Fatalf("fleet.spot copied with no SPOT image: %q", settings[SpotKey])
	}
	log, _ := st.HubAuditLog(50)
	deployRows := 0
	for _, e := range log {
		if e.Action == "setting" && e.Actor == "deploy" {
			deployRows++
		}
	}
	if deployRows != 3 {
		t.Fatalf("deploy audit rows = %d, want 3: %+v", deployRows, log)
	}

	// Without the old variables the database alone decides now.
	s.FleetAutoAssign, s.PublicBadges, s.FleetPrincipalLogins = nil, false, nil
	if got := s.setting(AutoAssignKey); got != "m4" {
		t.Fatalf("auto_assign from the database = %q", got)
	}
	if login, ok := s.mappedLoginFor("yilianghui"); !ok || login != "verkyyi" {
		t.Fatalf("map from the database = %q %v", login, ok)
	}

	// An admin clears auto_assign; the deploy still names m4; a restart
	// does not bring it back.
	s.FleetAutoAssign = []string{"m4"}
	if code, why := s.putHubSetting("gh:100", AutoAssignKey, "", now); code != http.StatusOK {
		t.Fatalf("clear = %d %s", code, why)
	}
	if err := s.MigrateLegacySettings(now); err != nil {
		t.Fatal(err)
	}
	if got := s.autoAssign(); len(got) != 0 {
		t.Fatalf("auto_assign after clear + restart = %v, want none", got)
	}
}

// A WeCom person's machine login set in the settings replaces the old map's
// entry, and "none" takes them out of it.
func TestMachineLoginSettingOverridesLegacy(t *testing.T) {
	st, err := store.Open(filepath.Join(t.TempDir(), "test.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	if err := st.EnsureNodes(); err != nil {
		t.Fatal(err)
	}
	s := &Server{Store: st, FleetPrincipalLogins: map[string]string{"caojian": "old24", "yilianghui": "verkyyi"}}
	now := time.Now()
	if code, why := s.putHubSetting("operator", "user.caojian.machine_login", "verkyyi", now); code != http.StatusBadRequest {
		t.Fatalf("another person's login = %d %s", code, why)
	}
	if code, why := s.putHubSetting("operator", "user.CaoJian.machine_login", "cao24", now); code != http.StatusOK {
		t.Fatalf("set = %d %s", code, why)
	}
	if login, _ := s.mappedLoginFor("caojian"); login != "cao24" {
		t.Fatalf("caojian = %q, want cao24", login)
	}
	if code, why := s.putHubSetting("operator", "user.yilianghui.machine_login", "none", now); code != http.StatusOK {
		t.Fatalf("none = %d %s", code, why)
	}
	if login, ok := s.mappedLoginFor("yilianghui"); ok {
		t.Fatalf("yilianghui still mapped to %q", login)
	}
	if s.mappedLogin("verkyyi") {
		t.Fatal("verkyyi still someone's")
	}
}

// C9's account language (claude-fleet#2033) is one of the hub settings:
// validated, audited, and the bare-ID spelling of a GitHub person works for
// the machine login too.
func TestHubSettings_LangAndBareID(t *testing.T) {
	h := newUsersHarness(t)
	h.call(t, http.MethodPost, "/v1/fleet/users", `{"login":"alice"}`, nil)
	if code, body := h.call(t, http.MethodPut, "/v1/fleet/settings", `{"key":"user.200.lang","value":"zh"}`, nil); code != http.StatusOK {
		t.Fatalf("lang = %d %v", code, body)
	}
	if set, _ := h.srv.Store.FleetSettings(); set[langSettingKey(200)] != "zh-CN" {
		t.Fatalf("stored lang = %q", set[langSettingKey(200)])
	}
	if code, _ := h.call(t, http.MethodPut, "/v1/fleet/settings", `{"key":"user.200.lang","value":"klingon"}`, nil); code != http.StatusBadRequest {
		t.Fatalf("bad lang = %d", code)
	}
	if !h.auditHas(t, "setting", "ok", "user.200.lang") {
		t.Fatalf("lang change not audited: %+v", h.audit(t))
	}
	if code, body := h.call(t, http.MethodPut, "/v1/fleet/settings", `{"key":"user.200.machine_login","value":"alice9"}`, nil); code != http.StatusOK {
		t.Fatalf("bare-id machine login = %d %v", code, body)
	}
	if u, _ := h.srv.Store.HubUserByID(200); u == nil || u.MachineLogin != "alice9" {
		t.Fatalf("alice = %+v", u)
	}
}
