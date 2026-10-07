package api

import (
	"errors"
	"net/http"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// claude-fleet#2108: C4 copied the enterprise-WeChat map into the settings
// as user.<old id>.machine_login. That key stood in front of #2094's hand-over:
// `fleet hub users add VincentPat --machine-login vincent` was refused with
// "machine login vincent is already huangyongsheng's".

// oldIdentity records the old principal pid holding login, active on host,
// and the settings key the C4 migration left naming it.
func oldIdentity(t *testing.T, st *store.Store, pid, login, host string, mapped bool) {
	t.Helper()
	now := time.Now()
	p, err := st.AdoptPrincipal(pid, login, "", now)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.AdoptAccount(p, host, now); err != nil {
		t.Fatal(err)
	}
	if mapped {
		if err := st.SetFleetSetting(machineLoginSettingKey(pid), login, now); err != nil {
			t.Fatal(err)
		}
	}
}

func settingCount(t *testing.T, st *store.Store, key string) int {
	t.Helper()
	var n int
	if err := st.DB().QueryRow(`SELECT count(*) FROM fleet_settings WHERE lower(key) = lower(?)`, key).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n
}

// The issue's repro: the old key and the old row both name vincent; adding
// the GitHub person with that login succeeds, the login moves to them, the
// key is gone and the drop is audited. Another GitHub person still refuses.
func TestFleetUsers_MachineLoginTakesOverAnOldIdentitysKey(t *testing.T) {
	h := newUsersHarness(t)
	st := h.srv.Store
	oldIdentity(t, st, "huangyongsheng", "vincent", "m4", true)
	// An old key with no principal row behind it (yilianghui's, cleared by
	// hand on prod — here still there).
	if err := st.SetFleetSetting("user.yilianghui.machine_login", "yl", time.Now()); err != nil {
		t.Fatal(err)
	}

	code, body := h.call(t, http.MethodPost, "/v1/fleet/users", `{"login":"alice","machine_login":"vincent"}`, nil)
	if code != http.StatusCreated {
		t.Fatalf("add alice --machine-login vincent = %d %v", code, body)
	}
	if m, _ := body["moved_login"].(map[string]any); m == nil || m["from"] != "huangyongsheng" || m["login"] != "vincent" {
		t.Fatalf("moved_login = %v", body["moved_login"])
	}
	alice := githubPrincipal(ghAlice.ID)
	if p, err := st.PrincipalByLogin("vincent"); err != nil || p.ID != alice {
		t.Fatalf("vincent is %+v %v, want %s", p, err, alice)
	}
	if _, err := st.Principal("huangyongsheng"); !errors.Is(err, store.ErrNoPrincipal) {
		t.Fatalf("the old row is still there: %v", err)
	}
	if n := settingCount(t, st, "user.huangyongsheng.machine_login"); n != 0 {
		t.Fatalf("the old key is still there (%d)", n)
	}
	if !h.auditHas(t, "setting", "ok", "user.huangyongsheng.machine_login vincent → (default): login vincent handed from the old identity huangyongsheng to "+alice) {
		t.Fatalf("no audit of the dropped key: %+v", h.audit(t))
	}
	if !h.auditHas(t, "principal.rekey", "ok", "huangyongsheng → "+alice) {
		t.Fatalf("no rekey audit: %+v", h.audit(t))
	}

	// A key with no row behind it is handed over too: just deleted.
	code, body = h.call(t, http.MethodPost, "/v1/fleet/users", `{"login":"mallory","machine_login":"yl"}`, nil)
	if code != http.StatusCreated || body["moved_login"] != nil {
		t.Fatalf("add mallory --machine-login yl = %d %v", code, body)
	}
	if n := settingCount(t, st, "user.yilianghui.machine_login"); n != 0 {
		t.Fatalf("yilianghui's key is still there (%d)", n)
	}
	if !h.auditHas(t, "setting", "ok", "login yl handed from the old identity yilianghui") {
		t.Fatalf("no audit of yilianghui's key: %+v", h.audit(t))
	}

	// A GitHub person's login is never taken: mallory → vincent is refused.
	code, body = h.call(t, http.MethodPut, "/v1/fleet/settings", `{"key":"user.gh:300.machine_login","value":"vincent"}`, nil)
	if code != http.StatusBadRequest {
		t.Fatalf("another GitHub person's login = %d %v", code, body)
	}
	if p, _ := st.PrincipalByLogin("vincent"); p == nil || p.ID != alice {
		t.Fatalf("vincent moved: %+v", p)
	}

	// A non-GitHub principal still cannot take an old identity's login.
	oldIdentity(t, st, "zx", "zx", "m4", true)
	if code, why := h.srv.putHubSetting("operator", "user.caojian.machine_login", "zx", time.Now()); code != http.StatusBadRequest {
		t.Fatalf("old → old = %d %s", code, why)
	}
}

// The start's sweep: an old key whose login a GitHub person holds, that
// names no login, or whose login is nobody's / someone else's is dropped and
// audited; one whose old row still holds it, with no GitHub person mapped,
// is kept. A second run does nothing.
func TestDropLegacyMachineLogins(t *testing.T) {
	h := newUsersHarness(t)
	st, now := h.srv.Store, time.Now()
	oldIdentity(t, st, "zx", "zx", "m4", true)            // kept
	oldIdentity(t, st, "caojian", "24haowan", "m4", true) // a GitHub person mapped to it
	if err := st.UpsertHubUser(store.HubUser{GitHubID: ghAlice.ID, Login: "alice", Role: store.RoleUser,
		MachineLogin: "24haowan", AddedBy: "test", AddedAt: now}); err != nil {
		t.Fatal(err)
	}
	if _, err := st.AdoptPrincipal(githubPrincipal(ghAdmin.ID), "malm", "", now); err != nil {
		t.Fatal(err)
	}
	for k, v := range map[string]string{
		"user.huangyongsheng.machine_login": "vincent", // no row holds vincent
		"user.yilianghui.machine_login":     "none",
		"user.oldadm.machine_login":         "malm", // a GitHub person's principal row
		"user.oldzx.machine_login":          "zx",   // zx's, not oldzx's
	} {
		if err := st.SetFleetSetting(k, v, now); err != nil {
			t.Fatal(err)
		}
	}
	if err := h.srv.DropLegacyMachineLogins(now); err != nil {
		t.Fatal(err)
	}
	for k, want := range map[string]int{
		"user.zx.machine_login":             1,
		"user.caojian.machine_login":        0,
		"user.huangyongsheng.machine_login": 0,
		"user.yilianghui.machine_login":     0,
		"user.oldadm.machine_login":         0,
		"user.oldzx.machine_login":          0,
	} {
		if n := settingCount(t, st, k); n != want {
			t.Errorf("%s = %d, want %d", k, n, want)
		}
	}
	for _, part := range []string{
		"user.caojian.machine_login 24haowan → (default): old identity, login 24haowan is gh:200's",
		"user.huangyongsheng.machine_login vincent → (default): old identity, no account holds login vincent",
		"user.oldzx.machine_login zx → (default): old identity, login zx is zx's, not oldzx's",
	} {
		if !h.auditHas(t, "setting", "ok", part) {
			t.Errorf("no audit %q: %+v", part, h.audit(t))
		}
	}
	before := len(h.audit(t))
	if err := h.srv.DropLegacyMachineLogins(now); err != nil {
		t.Fatal(err)
	}
	if after := len(h.audit(t)); after != before {
		t.Fatalf("the second run wrote %d audit rows", after-before)
	}

	// zx's GitHub account mapped to zx takes the kept key over.
	code, body := h.call(t, http.MethodPost, "/v1/fleet/users", `{"login":"mallory","machine_login":"zx"}`, nil)
	if code != http.StatusOK && code != http.StatusCreated {
		t.Fatalf("add mallory --machine-login zx = %d %v", code, body)
	}
}
