package api

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/credvault"
)

func TestSvcPassTenantValidation(t *testing.T) {
	h := newCPRig(t).h
	_, key, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	h.srv.RelaySignKey = key
	tok := svcStandingSetup(t, h, "livepage", "pass:issue runs:read")
	for _, tenant := range []string{"", "App", "a_b", "a.b", "a b", strings.Repeat("a", 33)} {
		st, out := svcDo(t, h, http.MethodPost, SvcPassPath, tok, map[string]string{"tenant": tenant})
		if st != http.StatusBadRequest || out["error_code"] != "invalid_argument" {
			t.Fatalf("tenant %q: %d %v", tenant, st, out)
		}
	}
	if st, out := svcDo(t, h, http.MethodPost, SvcPassPath, tok, map[string]string{"tenant": "app-a"}); st != http.StatusForbidden || out["error_code"] != "tenant_not_allowed" {
		t.Fatalf("no allowlist: %d %v", st, out)
	}
	putSetting(t, h, svcTenantsKey("svc:livepage"), "app-a, app-b,-", http.StatusOK)
	for _, kind := range []string{"fcp-h1", SessionCredKindH2} {
		out := svcPassMint(t, h, tok, map[string]string{"tenant": "app-a", "kind": kind})
		c, why := h.srv.parseSessionPass(out["cred"].(string), time.Now())
		if c == nil || why != "" || c.Tenant != "app-a" || !strings.HasPrefix(out["cred"].(string), kind+".") {
			t.Fatalf("claims %+v %s", c, why)
		}
		row, err := h.srv.Store.SessionCredByID(c.ID)
		if err != nil || row.Tenant != "app-a" {
			t.Fatalf("row %+v %v", row, err)
		}
		st, renewed := svcDo(t, h, http.MethodPost, SvcPassRenewPath, tok, map[string]string{"cred": out["cred"].(string)})
		if st != http.StatusOK {
			t.Fatalf("renew: %d %v", st, renewed)
		}
		nc, why := h.srv.parseSessionPass(renewed["cred"].(string), time.Now())
		if nc == nil || why != "" || nc.Tenant != c.Tenant || nc.ID != c.ID {
			t.Fatalf("renew claims %+v %s", nc, why)
		}
	}
	// The specified grammar permits leading/trailing hyphens, unlike service names.
	svcPassMint(t, h, tok, map[string]string{"tenant": "-"})
	svcPassMint(t, h, tok, nil)
	if st, _ := svcDo(t, h, http.MethodPost, SvcPassPath, tok, map[string]any{"tenant": "app-a", "providers": []string{"claude"}}); st != http.StatusBadRequest {
		t.Fatal("tenant pass admitted Claude")
	}
	audits, err := h.srv.Store.FleetAuditLog(500)
	if err != nil {
		t.Fatal(err)
	}
	for _, action := range []string{"svc.pass.issue", "svc.pass.renew"} {
		found := false
		for _, a := range audits {
			if a.Action == action && a.Outcome == "ok" && strings.Contains(a.OperationID, `tenant="app-a"`) {
				found = true
			}
		}
		if !found {
			t.Errorf("no tenant in %s audit", action)
		}
	}
}

func TestSvcPassTenantSettings(t *testing.T) {
	h := newCPRig(t).h
	for _, value := range []string{"App", "a,,b", "a,", "a_b", strings.Repeat("a", 33)} {
		putSetting(t, h, "fleet.svc.livepage.tenants", value, http.StatusBadRequest)
	}
	for _, key := range []string{"fleet.svc.Bad.tenants", "fleet.svc_tenant_budget.livepage.App", "fleet.svc_tenant_budget.livepage.a.b", "fleet.svc_tenant_budget.livepage."} {
		putSetting(t, h, key, "day=100", http.StatusBadRequest)
	}
	putSetting(t, h, "fleet.svc_tenant_budget.livepage.app-a", "day=bad", http.StatusBadRequest)
	putSetting(t, h, "fleet.svc_tenant_budget.livepage.app-a", "day=1k,week=2k", http.StatusOK)
	putSetting(t, h, "fleet.svc.livepage.tenants", "app-a, app-b", http.StatusOK)
	settings, _ := h.srv.Store.FleetSettings()
	if settings["fleet.svc.livepage.tenants"] != "app-a,app-b" {
		t.Fatal(settings)
	}
	if b := svcTenantBudget(settings, "svc:livepage", "app-a"); b.Day != 1000 || b.Week != 2000 {
		t.Fatal(b)
	}
	putSetting(t, h, "fleet.svc_tenant_budget.livepage", "day=100", http.StatusOK)
	putSetting(t, h, "fleet.svc_tenant_budget.livepage.app-a", "day=0,week=0", http.StatusOK)
	settings, _ = h.srv.Store.FleetSettings()
	if svcTenantBudget(settings, "svc:livepage", "app-a").set() {
		t.Fatal("explicit zero failed to override default")
	}
	putSetting(t, h, "fleet.svc_tenant_budget.livepage.app-a", "", http.StatusOK)
	settings, _ = h.srv.Store.FleetSettings()
	if svcTenantBudget(settings, "svc:livepage", "app-a").Day != 100 {
		t.Fatal("removed override did not fall back")
	}
}

func TestSvcPassTenantRevokedMidLife(t *testing.T) {
	r := newCPRig(t)
	h := r.h
	tok := svcStandingSetup(t, h, "livepage", "pass:issue")
	putSetting(t, h, svcTenantsKey("svc:livepage"), "app-a,app-b", http.StatusOK)
	a := svcPassMint(t, h, tok, map[string]string{"tenant": "app-a"})["cred"].(string)
	b := svcPassMint(t, h, tok, map[string]string{"tenant": "app-b"})["cred"].(string)
	legacy := svcPassMint(t, h, tok, nil)["cred"].(string)
	for _, pass := range []string{a, b, legacy} {
		if v, _ := h.srv.verifySessionCred(pass, "", credvault.Codex, false, time.Now()); !v.Valid {
			t.Fatal(v)
		}
	}
	// Warm row caches must not let a removed tenant through.
	putSetting(t, h, svcTenantsKey("svc:livepage"), "app-b", http.StatusOK)
	if v, _ := h.srv.verifySessionCred(a, "", credvault.Codex, false, time.Now()); v.Valid || !v.Revoked || !strings.Contains(v.Reason, "tenant_not_allowed") {
		t.Fatal(v)
	}
	if st, out := svcDo(t, h, http.MethodPost, SvcPassPath, tok, map[string]string{"tenant": "app-a"}); st != 403 || out["error_code"] != "tenant_not_allowed" {
		t.Fatalf("mint revoked: %d %v", st, out)
	}
	if st, out := svcDo(t, h, http.MethodPost, SvcPassRenewPath, tok, map[string]string{"cred": a}); st != 403 {
		t.Fatalf("renew revoked: %d %v", st, out)
	}
	if st, body := r.call(t, credvault.Codex, a); st != 403 {
		t.Fatalf("resolve revoked: %d %s", st, body)
	}
	for _, pass := range []string{b, legacy} {
		if st, body := r.call(t, credvault.Codex, pass); st != 200 {
			t.Fatalf("unaffected pass: %d %s", st, body)
		}
	}
	putSetting(t, h, svcTenantsKey("svc:livepage"), "", http.StatusOK)
	if v, _ := h.srv.verifySessionCred(b, "", credvault.Codex, false, time.Now()); v.Valid {
		t.Fatal("clearing allowlist kept app-b")
	}
	svcPassMint(t, h, tok, nil) // no tenant stays independent of the allowlist
	putSetting(t, h, svcTenantsKey("svc:livepage"), "app-a", http.StatusOK)
	if v, _ := h.srv.verifySessionCred(a, "", credvault.Codex, false, time.Now()); !v.Valid {
		t.Fatal(v)
	}
}

func TestSvcPassTenantUsageAndDistinctBudgets(t *testing.T) {
	r := newCPRig(t)
	h := r.h
	tok := svcStandingSetup(t, h, "livepage", "pass:issue runs:read")
	putSetting(t, h, svcTenantsKey("svc:livepage"), "app-a,app-b,app-c", 200)
	putSetting(t, h, SvcTenantBudgetPrefix+"livepage", "day=150", 200)
	putSetting(t, h, SvcTenantBudgetPrefix+"livepage.app-b", "day=450,week=900", 200)
	passes := map[string]string{}
	for _, tenant := range []string{"app-a", "app-b", "app-c"} {
		passes[tenant] = svcPassMint(t, h, tok, map[string]string{"tenant": tenant})["cred"].(string)
	}
	for _, tenant := range []string{"app-a", "app-b"} {
		if st, body := r.call(t, credvault.Codex, passes[tenant]); st != 200 {
			t.Fatalf("call %s: %d %s", tenant, st, body)
		}
	}
	waitFor(t, 3*time.Second, "separate app metering", func() bool { return svcMetered(t, h, "app-a") == 150 && svcMetered(t, h, "app-b") == 150 })
	r.pastCache()
	if st, body := r.call(t, credvault.Codex, passes["app-a"]); st != 403 || !strings.Contains(body, PersonBudgetExceeded) {
		t.Fatalf("app-a ceiling: %d %s", st, body)
	}
	if st, out := svcDo(t, h, http.MethodPost, SvcPassPath, tok, map[string]string{"tenant": "app-a"}); st != 429 || out["error_code"] != SvcErrTenantLimit {
		t.Fatalf("mint ceiling: %d %v", st, out)
	}
	if st, body := r.call(t, credvault.Codex, passes["app-b"]); st != 200 {
		t.Fatalf("distinct ceiling: %d %s", st, body)
	}
	waitFor(t, 3*time.Second, "app-b second call", func() bool { return svcMetered(t, h, "app-b") == 300 })
	// Week overrides are enforced independently of the day ceiling.
	putSetting(t, h, SvcTenantBudgetPrefix+"livepage.app-b", "day=450,week=300", 200)
	r.pastCache()
	if st, body := r.call(t, credvault.Codex, passes["app-b"]); st != 403 {
		t.Fatalf("week ceiling: %d %s", st, body)
	}
	st, out := svcDo(t, h, http.MethodGet, SvcUsagePath+"?since="+time.Now().Add(-time.Hour).UTC().Format(time.RFC3339), tok, nil)
	if st != 200 {
		t.Fatalf("usage: %d %v", st, out)
	}
	lines := out["tenants"].([]any)
	if len(lines) != 2 {
		t.Fatal(lines)
	}
	for _, x := range lines {
		line := x.(map[string]any)
		tenant := line["tenant"].(string)
		want := map[string]float64{"app-a": 150, "app-b": 300}[tenant]
		if line["metered"].(map[string]any)["tokens"] != want {
			t.Fatal(line)
		}
		if tenant == "app-b" && line["budget"].(map[string]any)["limit_day"] != float64(450) {
			t.Fatal(line)
		}
	}
	req, _ := http.NewRequest(http.MethodGet, h.http.URL+AdminUsagePath, nil)
	req.Header.Set("Authorization", "Bearer "+viewerToken)
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	var admin AdminUsage
	if err := json.NewDecoder(res.Body).Decode(&admin); err != nil || res.StatusCode != 200 {
		t.Fatalf("admin: %d %v", res.StatusCode, err)
	}
	if len(admin.Services) != 3 {
		t.Fatalf("admin services %+v", admin.Services)
	}
	for _, s := range admin.Services {
		if s.Principal != "svc:livepage" || !s.Enabled || s.Budget.UsedDay != map[string]int64{"app-a": 150, "app-b": 300, "app-c": 0}[s.Tenant] {
			t.Fatal(s)
		}
		if s.Tenant == "app-b" && (s.Budget.LimitDay != 450 || s.Budget.LimitWeek != 300) {
			t.Fatal(s)
		}
	}
	putSetting(t, h, svcTenantsKey("svc:livepage"), "app-b,app-c", 200)
	adminRows, err := h.srv.adminSvcUsage(time.Now())
	if err != nil {
		t.Fatal(err)
	}
	for _, row := range adminRows {
		if row.Tenant == "app-a" && (row.Enabled || row.Budget.UsedDay != 150) {
			t.Fatalf("revoked app's usage lost: %+v", row)
		}
	}
	// Whole-service cap still includes all apps, including an unused app.
	putSetting(t, h, SvcBudgetPrefix+"livepage", "day=450", 200)
	r.pastCache()
	if st, body := r.call(t, credvault.Codex, passes["app-c"]); st != 403 {
		t.Fatalf("whole: %d %s", st, body)
	}
	if st, out := svcDo(t, h, http.MethodPost, SvcPassPath, tok, map[string]string{"tenant": "app-c"}); st != 429 || out["error_code"] != SvcErrQuotaExceeded {
		t.Fatalf("whole mint: %d %v", st, out)
	}
}
