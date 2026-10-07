package api

import (
	"encoding/json"
	"errors"
	"html"
	"net/http"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// claude-fleet#2094: the enterprise-WeChat era left 24haowan@macmini active
// under the old principal CaoJian. Mapping the GitHub person to it hands the
// old row over — record-only — and the person can sign a certificate; a login
// that is another GitHub person's is still refused.

// legacyPerson records an old-era principal holding login, active on host,
// with a device, a certificate row, a budget and some usage beside it.
func legacyPerson(t *testing.T, h *harness, pid, login, host string) {
	t.Helper()
	now := time.Now()
	p, err := h.srv.Store.AdoptPrincipal(pid, login, "曹健", now)
	if err != nil {
		t.Fatal(err)
	}
	if err := h.srv.Store.AdoptAccount(p, host, now); err != nil {
		t.Fatal(err)
	}
	if _, err := h.srv.Store.RegisterDevice(store.FleetDevice{Fingerprint: "SHA256:cao-old",
		PrincipalID: pid, PublicKey: "ssh-ed25519 AAAA", Name: "cao-mbp"}, now); err != nil {
		t.Fatal(err)
	}
	db := h.srv.Store.DB()
	for _, q := range []string{
		`INSERT INTO fleet_certs (serial, principal_id, key_id, principals, key_fingerprint, via, issued_at, valid_after, valid_before)
		 VALUES ('s-old', '` + pid + `', 'k', '` + login + `', 'fp', 'test', 't', 't', 't')`,
		`INSERT INTO fleet_person_usage (principal, provider, bucket, tokens, requests) VALUES ('` + pid + `', 'claude', 1, 100, 2)`,
		`INSERT INTO fleet_settings (key, value, updated) VALUES ('fleet.person_budget.` + pid + `', '5h=1000', 't')`,
	} {
		if _, err := db.Exec(q); err != nil {
			t.Fatalf("%s: %v", q, err)
		}
	}
}

func countRows(t *testing.T, h *harness, q string, args ...any) int {
	t.Helper()
	var n int
	if err := h.srv.Store.DB().QueryRow(q, args...).Scan(&n); err != nil {
		t.Fatalf("%s: %v", q, err)
	}
	return n
}

func TestFleetMappedGitHubPersonTakesOverALegacyLogin(t *testing.T) {
	h, _ := certHarness(t)
	h.srv.FleetAdmins = []string{"verkyyi"}
	admin := connectNode(t, h, "m5-op", "macmini", "verkyyi", true)
	connectNode(t, h, "m5-24h", "macmini", "24haowan", false)
	waitFor(t, 3*time.Second, "two nodes", func() bool { return len(roster(t, h).Nodes) == 2 })
	legacyPerson(t, h, "CaoJian", "24haowan", "macmini")

	// Before the map: an unmapped person is told the old reason.
	listPerson(t, h, pCao, "cjilyy")
	if _, _, _, err := h.srv.fleetLoginsOf(pCao); !errors.Is(err, errNoAccount) || err.Error() != errNoAccount.Error() {
		t.Fatalf("unmapped: %v", err)
	}

	// The operator maps cjilyy → 24haowan (fleet hub users add … --machine-login).
	settings, _ := h.srv.Store.FleetSettings()
	code, why, moved := h.srv.putMachineLoginMoved("operator", pCao, "24haowan", settings, time.Now())
	if code != http.StatusOK || moved == nil || moved.From != "CaoJian" || moved.Login != "24haowan" ||
		strings.Join(moved.Hosts, ",") != "macmini" {
		t.Fatalf("map = %d %q %+v", code, why, moved)
	}
	p, logins, _, err := h.srv.fleetLoginsOf(pCao)
	if err != nil || p.ID != pCao || strings.Join(logins, ",") != "24haowan" {
		t.Fatalf("fleetLoginsOf(cjilyy) = %+v %v %v", p, logins, err)
	}
	if _, err := h.srv.Store.Principal("CaoJian"); !errors.Is(err, store.ErrNoPrincipal) {
		t.Fatalf("the old row is still there: %v", err)
	}
	for _, c := range []struct {
		q    string
		want int
	}{
		{`SELECT count(*) FROM fleet_accounts WHERE principal_id = 'gh:3001' AND state = 'active'`, 1},
		{`SELECT count(*) FROM fleet_devices WHERE principal_id = 'gh:3001'`, 1},
		{`SELECT count(*) FROM fleet_certs WHERE principal_id = 'gh:3001'`, 1},
		{`SELECT count(*) FROM fleet_person_usage WHERE principal = 'gh:3001' AND tokens = 100`, 1},
		{`SELECT count(*) FROM fleet_settings WHERE key = 'fleet.person_budget.gh:3001'`, 1},
		{`SELECT count(*) FROM fleet_accounts WHERE lower(principal_id) = 'caojian'`, 0},
		{`SELECT count(*) FROM fleet_devices WHERE principal_id = 'CaoJian'`, 0},
		{`SELECT count(*) FROM fleet_settings WHERE key LIKE '%CaoJian%'`, 0},
		{`SELECT count(*) FROM hub_audit WHERE action = 'principal.rekey' AND target = '24haowan' AND detail LIKE 'CaoJian → gh:3001%'`, 1},
	} {
		if n := countRows(t, h, c.q); n != c.want {
			t.Fatalf("%s = %d, want %d", c.q, n, c.want)
		}
	}
	if got, ok := readMsg(admin.tnode, 300*time.Millisecond); ok && got.Type == control.TypeAccountOp {
		t.Fatalf("the admin node was sent an op: %+v", got)
	}

	// Idempotent: the sign-in runs it again and moves nothing.
	if m := h.srv.placePrincipal(pCao, "cjilyy", pCao); m != nil {
		t.Fatalf("second placement moved %+v", m)
	}

	// The QR's page offers the confirm button, and the certificate carries 24haowan.
	_, body := postJSON(t, h, "/v1/fleet/login/start", map[string]string{"public_key": newUserKey(t)})
	var st DeviceStart
	json.Unmarshal(body, &st)
	pc, raw := asUID(t, h, http.MethodGet, "/fleet/login?code="+st.UserCode, pCao, "cjilyy", nil)
	page := html.UnescapeString(string(raw))
	if pc != 200 || strings.Contains(page, "issue yet") || !strings.Contains(page, ">Confirm</button>") {
		t.Fatalf("confirm page %d:\n%s", pc, page)
	}
	pc, done := cookieForm(t, h, personCookie(pCao, "cjilyy"), h.http.URL, url.Values{"code": {st.UserCode}, "action": {"approve"}})
	if pc != 200 || !strings.Contains(done, "valid until") {
		t.Fatalf("approve %d:\n%s", pc, done)
	}
	code, body = postJSON(t, h, "/v1/fleet/login/poll", map[string]string{"device_code": st.DeviceCode})
	var cr CertResponse
	json.Unmarshal(body, &cr)
	if code != 200 || strings.Join(cr.Principals, ",") != "24haowan" {
		t.Fatalf("poll: %d %s", code, body)
	}
}

// A login another GitHub person holds is never taken over: the map is
// refused and names them; a sign-in whose map predates the conflict is told
// why on the confirm page.
func TestFleetLegacyTakeOverRefusesAnotherGitHubPerson(t *testing.T) {
	h, _ := certHarness(t)
	listPerson(t, h, pCao, "cjilyy")
	listPerson(t, h, pHuang, "vincentgh")
	if _, err := h.srv.Store.AdoptPrincipal(pHuang, "24haowan", "", time.Now()); err != nil {
		t.Fatal(err)
	}
	settings, _ := h.srv.Store.FleetSettings()
	code, why, moved := h.srv.putMachineLoginMoved("operator", pCao, "24haowan", settings, time.Now())
	if code != http.StatusBadRequest || moved != nil || !strings.Contains(why, "vincentgh") {
		t.Fatalf("map onto another GitHub person's login = %d %q %+v", code, why, moved)
	}
	// The map written straight into the table (as an older hub let it be):
	// placement refuses, and the page says whose it is.
	u, _ := h.srv.Store.HubUserByID(3001)
	u.MachineLogin = "24haowan"
	if err := h.srv.Store.UpsertHubUser(*u); err != nil {
		t.Fatal(err)
	}
	if m := h.srv.placePrincipal(pCao, "cjilyy", "test"); m != nil {
		t.Fatalf("took it over: %+v", m)
	}
	if p, err := h.srv.Store.PrincipalByLogin("24haowan"); err != nil || p.ID != pHuang {
		t.Fatalf("24haowan is now %+v %v", p, err)
	}
	_, _, _, err := h.srv.fleetLoginsOf(pCao)
	if !errors.Is(err, errNoAccount) || !strings.Contains(err.Error(), "another GitHub person") || !strings.Contains(err.Error(), "vincentgh") {
		t.Fatalf("reason = %v", err)
	}
}

// The operator's hand: POST /v1/fleet/accounts {action: rekey}.
func TestFleetAccountsRekeyAction(t *testing.T) {
	h := newFleetHarness(t)
	legacyPerson(t, h, "zx", "zx", "macmini")
	post := func(req FleetAccountRequest) (int, string) {
		b, _ := json.Marshal(req)
		r, _ := http.NewRequest(http.MethodPost, h.http.URL+"/v1/fleet/accounts", strings.NewReader(string(b)))
		r.Header.Set("Authorization", "Bearer "+viewerToken)
		res, err := http.DefaultClient.Do(r)
		if err != nil {
			t.Fatal(err)
		}
		defer res.Body.Close()
		var out map[string]any
		json.NewDecoder(res.Body).Decode(&out)
		raw, _ := json.Marshal(out)
		return res.StatusCode, string(raw)
	}
	if code, body := post(FleetAccountRequest{Action: "rekey", PrincipalID: "nobody", ToPrincipalID: "4001"}); code != http.StatusNotFound {
		t.Fatalf("unknown from = %d %s", code, body)
	}
	if code, body := post(FleetAccountRequest{Action: "rekey", PrincipalID: "zx", ToPrincipalID: "4001"}); code != 200 ||
		!strings.Contains(body, `"to":"gh:4001"`) || !strings.Contains(body, `"login":"zx"`) {
		t.Fatalf("rekey = %d %s", code, body)
	}
	if a := accountState(t, h, "gh:4001", "macmini"); a.State != store.AccountActive {
		t.Fatalf("zx on macmini = %+v", a)
	}
	// A second person on the new id: refused, nothing moved.
	legacyPerson2 := func() {
		if _, err := h.srv.Store.AdoptPrincipal("olduser", "olduser", "", time.Now()); err != nil {
			t.Fatal(err)
		}
	}
	legacyPerson2()
	if code, body := post(FleetAccountRequest{Action: "rekey", PrincipalID: "olduser", ToPrincipalID: "gh:4001"}); code != http.StatusConflict {
		t.Fatalf("onto a held id = %d %s", code, body)
	}
	if p, err := h.srv.Store.Principal("olduser"); err != nil || p.Login != "olduser" {
		t.Fatalf("olduser = %+v %v", p, err)
	}
}
