package api

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/credvault"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// Service usage by tenant, with a ceiling (claude-fleet#4006): two tenants'
// usage is kept apart, one tenant at its ceiling stops only that tenant, the
// whole service at its ceiling stops every service run and no person, and
// GET /v1/svc/usage agrees with what the callbacks carried.

// svcUse files tokens (all input) of metered usage for tenant at at.
func svcUse(t *testing.T, h *harness, tenant string, tokens int64, at time.Time) {
	t.Helper()
	if err := h.srv.Store.AddPoolUsage(store.PoolUsage{Principal: "svc:livepage", WorkerID: "svc/R1/a1", Tenant: tenant,
		Provider: credvault.Claude, In: tokens, Requests: 1, At: at}); err != nil {
		t.Fatal(err)
	}
}

func svcSubmitCode(t *testing.T, h *harness, tok string, req SvcRunRequest) (int, string) {
	t.Helper()
	st, out := svcDo(t, h, http.MethodPost, SvcRunsPath, tok, req)
	code, _ := out["error_code"].(string)
	return st, code
}

// One tenant at its ceiling: refused tenant_limit at submit, nothing queued;
// another tenant runs; a replay of a key already used still answers its run.
func TestSvcTenantLimitStopsOnlyThatTenant(t *testing.T) {
	h, fr, tok := svcRunsHarness(t)
	before := svcSubmit(t, h, tok, svcReq("space:ws:1", "early"))
	putSetting(t, h, SvcTenantBudgetPrefix+"livepage", "day=lots", http.StatusBadRequest)
	out := putSetting(t, h, SvcTenantBudgetPrefix+"livepage", "day=1k", http.StatusOK)
	if got := out["settings"].(map[string]any)[SvcTenantBudgetPrefix+"livepage"]; got != "day=1000" {
		t.Fatalf("stored tenant budget = %v", got)
	}
	svcUse(t, h, "space:ws:1", 1200, time.Now())
	svcUse(t, h, "space:ws:2", 300, time.Now())

	if st, code := svcSubmitCode(t, h, tok, svcReq("space:ws:1", "late")); st != http.StatusTooManyRequests || code != SvcErrTenantLimit {
		t.Fatalf("ws:1 over its ceiling → %d %q; want 429 tenant_limit", st, code)
	}
	if runs, _ := h.srv.Store.SvcRuns(store.SvcRunFilter{Principal: "svc:livepage", Tenant: "space:ws:1"}); len(runs) != 1 {
		t.Fatalf("a refused run was queued: %d runs for ws:1", len(runs))
	}
	if got := svcSubmit(t, h, tok, svcReq("space:ws:2", "other")); got["state"] != store.SvcRunRunning {
		t.Fatalf("ws:2 under its ceiling: %v", got)
	}
	if again := svcSubmit(t, h, tok, svcReq("space:ws:1", "early")); again["run_id"] != before["run_id"] || again["replayed"] != true {
		t.Fatalf("a replay of a used key: %v", again)
	}
	if !svcAudited(t, h, "svc.run.submit", "REFUSED") {
		t.Error("no REFUSED svc.run.submit audit row")
	}
	if n := len(fr.started); n != 2 {
		t.Errorf("runner started %d runs, want 2 (ws:1's first, ws:2's)", n)
	}
}

// The whole service at its ceiling: every service run refused quota_exceeded —
// at submit, and a queued one at dispatch — and no person held to it.
func TestSvcWholeBudgetStopsServiceNotPeople(t *testing.T) {
	h, fr, tok := svcRunsHarness(t)
	h.srv.SvcRunner = nil // queue only, so one waits for the dispatch
	queued := svcSubmit(t, h, tok, svcReq("space:ws:3", "waiting"))
	putSetting(t, h, SvcBudgetPrefix+"livepage", "day=1000,week=5000", http.StatusOK)
	svcUse(t, h, "space:ws:1", 600, time.Now())
	svcUse(t, h, "space:ws:2", 600, time.Now())

	for _, tenant := range []string{"space:ws:1", "space:ws:2", "space:ws:9"} {
		if st, code := svcSubmitCode(t, h, tok, svcReq(tenant, "k-"+tenant)); st != http.StatusTooManyRequests || code != SvcErrQuotaExceeded {
			t.Fatalf("%s with the service over → %d %q; want 429 quota_exceeded", tenant, st, code)
		}
	}
	h.srv.SvcRunner = fr
	h.srv.SvcRunsTick(t.Context(), time.Now())
	got := svcState(t, h, tok, queued["run_id"].(string))
	if got["state"] != store.SvcRunFailed || got["error_code"] != SvcErrQuotaExceeded {
		t.Fatalf("a queued run at dispatch, service over: %v", got)
	}
	if len(fr.started) != 0 {
		t.Fatalf("the runner was asked for %v", fr.started)
	}
	// a person: never held to the service's ceiling
	if st, over := h.srv.svcBudgetRefusal("gh:1005", "", time.Now()); over {
		t.Fatalf("a person refused by the service's ceiling: %+v", st)
	}
	// the day passes: back in
	h.srv.budgetNow = func() time.Time { return time.Now().Add(25 * time.Hour) }
	if st, over := h.srv.svcBudgetRefusal("svc:livepage", "space:ws:1", time.Now().Add(25*time.Hour)); over {
		t.Fatalf("a day later still refused: %+v", st)
	}
}

// A run whose proxy refused it mid-run ends with the budget's code, not a
// retry.
func TestSvcOverBudgetFailureIsNotRetried(t *testing.T) {
	h, _, tok := svcRunsHarness(t)
	ref := svcSubmit(t, h, tok, svcReq("space:ws:1", "mid"))["run_id"].(string)
	putSetting(t, h, SvcTenantBudgetPrefix+"livepage", "day=1000", http.StatusOK)
	svcUse(t, h, "space:ws:1", 1500, time.Now())
	if _, err := h.srv.SvcRunFinish(svcRunID(t, ref), store.SvcRunFailed, SvcErrInfra, nil, nil); err != nil {
		t.Fatal(err)
	}
	got := svcState(t, h, tok, ref)
	if got["state"] != store.SvcRunFailed || got["error_code"] != SvcErrTenantLimit || got["attempt"].(float64) != 1 {
		t.Fatalf("over budget mid-run: %v; want failed tenant_limit, no retry", got)
	}
}

// GET /v1/svc/usage: one line per tenant, its runs' usage the sum of what
// their callbacks carried, the metered usage apart, budgets where they stand.
func TestSvcUsageMatchesCallbacks(t *testing.T) {
	h, _, tok := svcRunsHarness(t)
	putSetting(t, h, SvcTenantBudgetPrefix+"livepage", "day=10k", http.StatusOK)
	usage := map[string][]string{
		"space:ws:1": {`{"model":"m","input_tokens":100,"output_tokens":40,"wall_s":30}`, `{"model":"m","input_tokens":7,"output_tokens":3,"wall_s":1.5}`},
		"space:ws:2": {`{"model":"m","input_tokens":1000,"output_tokens":500,"wall_s":60}`},
	}
	want := map[string][2]float64{}
	for tenant, us := range usage {
		for i, u := range us {
			ref := svcSubmit(t, h, tok, svcReq(tenant, tenant+"-"+string(rune('a'+i))))["run_id"].(string)
			if _, err := h.srv.SvcRunFinish(svcRunID(t, ref), store.SvcRunSucceeded, "", svcGoodResult, json.RawMessage(u)); err != nil {
				t.Fatal(err)
			}
			cb := svcState(t, h, tok, ref)["usage"].(map[string]any) // the callback's body
			w := want[tenant]
			w[0] += cb["input_tokens"].(float64)
			w[1] += cb["output_tokens"].(float64)
			want[tenant] = w
		}
	}
	svcUse(t, h, "space:ws:1", 2000, time.Now())
	svcUse(t, h, "space:ws:2", 300, time.Now())
	svcUse(t, h, "space:ws:2", 999, time.Now().Add(-3*24*time.Hour)) // before today
	// a person's row is never a tenant's
	if err := h.srv.Store.AddPoolUsage(store.PoolUsage{Principal: "gh:1005", Provider: credvault.Claude, In: 5000, At: time.Now()}); err != nil {
		t.Fatal(err)
	}

	st, out := svcDo(t, h, http.MethodGet, SvcUsagePath+"?since=today", tok, nil)
	if st != http.StatusOK {
		t.Fatalf("usage: %d %v", st, out)
	}
	t.Logf("GET %s?since=today → %v", SvcUsagePath, out)
	lines := out["tenants"].([]any)
	if len(lines) != 2 {
		t.Fatalf("tenants %v; want ws:1 and ws:2", lines)
	}
	metered := map[string]float64{"space:ws:1": 2000, "space:ws:2": 300}
	for _, l := range lines {
		m := l.(map[string]any)
		tenant := m["tenant"].(string)
		u := m["usage"].(map[string]any)
		if u["input_tokens"] != want[tenant][0] || u["output_tokens"] != want[tenant][1] {
			t.Errorf("%s usage %v; the callbacks carried in=%v out=%v", tenant, u, want[tenant][0], want[tenant][1])
		}
		if got := m["metered"].(map[string]any)["tokens"]; got != metered[tenant] {
			t.Errorf("%s metered %v; want %v", tenant, got, metered[tenant])
		}
		if b, _ := m["budget"].(map[string]any); b == nil || b["limit_day"] != float64(10000) {
			t.Errorf("%s budget %v", tenant, m["budget"])
		}
	}
	total := out["total"].(map[string]any)
	if total["runs"] != float64(3) || total["metered"].(map[string]any)["tokens"] != float64(2300) {
		t.Errorf("total %v", total)
	}
	st, one := svcDo(t, h, http.MethodGet, SvcUsagePath+"?tenant=space:ws:2&since="+time.Now().AddDate(0, 0, -6).Format("2006-01-02"), tok, nil)
	if st != http.StatusOK || len(one["tenants"].([]any)) != 1 {
		t.Fatalf("one tenant, a week: %d %v", st, one)
	}
	if got := one["tenants"].([]any)[0].(map[string]any)["metered"].(map[string]any)["tokens"]; got != float64(1299) {
		t.Errorf("ws:2 over the week metered %v; want 1299", got)
	}
	if st, _ := svcDo(t, h, http.MethodGet, SvcUsagePath+"?since=yesterday", tok, nil); st != http.StatusBadRequest {
		t.Errorf("a bad since: %d", st)
	}
	// another principal reads only its own
	other := svcSetup(t, h, "other", "runs:read")
	if _, o := svcDo(t, h, http.MethodGet, SvcUsagePath, other, nil); len(o["tenants"].([]any)) != 0 {
		t.Errorf("another service sees %v", o["tenants"])
	}
}

func TestParseSvcBudget(t *testing.T) {
	for in, want := range map[string]string{"day=2M": "day=2000000", "week=10m, day=1k": "day=1000,week=10000000",
		"24h=5,7d=6": "day=5,week=6"} {
		b, err := ParseSvcBudget(in)
		if err != nil || b.String() != want {
			t.Errorf("%q → %q %v; want %q", in, b.String(), err, want)
		}
	}
	for _, bad := range []string{"", "5h=1", "day", "day=x"} {
		if _, err := ParseSvcBudget(bad); err == nil {
			t.Errorf("%q parsed", bad)
		}
	}
}

// svcPassFor mints a run's pass as svcRunSpec does: svc:livepage, its tenant
// and run signed in.
func svcPassFor(t *testing.T, h *harness, tenant, run string) string {
	t.Helper()
	var rnd [16]byte
	_, _ = rand.Read(rnd[:])
	now := time.Now().Truncate(time.Second)
	worker := "svc/" + run + "/a1"
	// a service uses only what is listed for it (claude-fleet#4085): these
	// tests are about budgets and yield, so list the whole pool once
	if set, _ := h.srv.Store.FleetSettings(); set[credUserKey("svc:livepage")] == "" {
		if err := h.srv.Store.SetFleetSetting(credUserKey("svc:livepage"), `"*"`, now); err != nil {
			t.Fatal(err)
		}
	}
	c := sessionCredClaims{V: 1, ID: "sc_" + hex.EncodeToString(rnd[:]), Principal: "svc:livepage", WorkerID: worker,
		Machine: "svc-run", Providers: []string{credvault.Claude}, Iat: now.Unix(), Exp: now.Add(time.Hour).Unix(),
		Svc: "livepage", Tenant: tenant, Run: run}
	if err := h.srv.Store.AddSessionCred(store.SessionCred{ID: c.ID, PrincipalID: c.Principal, WorkerID: worker,
		WorkerKey: worker, Machine: "svc-run", Providers: c.Providers, IssuedAt: now, ExpiresAt: time.Unix(c.Exp, 0)}); err != nil {
		t.Fatal(err)
	}
	return h.srv.signSessionPass(c)
}

func svcMetered(t *testing.T, h *harness, tenant string) int64 {
	t.Helper()
	rows, err := h.srv.Store.SvcUsageSince("svc:livepage", tenant, time.Now().Add(-time.Hour), time.Time{})
	if err != nil {
		t.Fatal(err)
	}
	var n int64
	for _, r := range rows {
		n += r.Tokens()
	}
	return n
}

// Through the cluster credential proxy: each call filed under its pass's
// tenant; a tenant over its ceiling refused mid-run, the other tenant and a
// person not; the service over its ceiling refused whole, the person not.
func TestSvcProxyFilesByTenantAndStops(t *testing.T) {
	r := newCPRig(t)
	for _, acct := range []string{"pool1", "pool2"} {
		if err := r.h.srv.Vault.Put(store.PoolPrincipal, credvault.Claude, acct, credvault.Secret{RefreshToken: "rt-" + acct}); err != nil {
			t.Fatal(err)
		}
	}
	ws1, ws2 := svcPassFor(t, r.h, "space:ws:1", "R11"), svcPassFor(t, r.h, "space:ws:2", "R12")
	frank, _ := r.issue(t, fidA)
	for _, c := range []string{ws1, ws1, ws2} {
		if st, body := r.call(t, credvault.Claude, c); st != 200 {
			t.Fatalf("a service call → %d %s", st, body)
		}
	}
	waitFor(t, 3*time.Second, "usage filed by tenant", func() bool {
		return svcMetered(t, r.h, "space:ws:1") == 300 && svcMetered(t, r.h, "space:ws:2") == 150
	})
	if n := svcMetered(t, r.h, ""); n != 450 {
		t.Fatalf("the service's metered usage %d, want 450 (no person's in it)", n)
	}

	putSetting(t, r.h, SvcTenantBudgetPrefix+"livepage", "day=300", http.StatusOK)
	r.pastCache()
	if st, body := r.call(t, credvault.Claude, ws1); st != http.StatusForbidden || !strings.Contains(body, PersonBudgetExceeded) {
		t.Fatalf("ws:1 at its ceiling → %d %s; want 403", st, body)
	}
	if st, body := r.call(t, credvault.Claude, ws2); st != 200 {
		t.Fatalf("ws:2 under its ceiling → %d %s", st, body)
	}
	if st, body := r.call(t, credvault.Claude, frank); st != 200 {
		t.Fatalf("a person, a tenant at its ceiling → %d %s", st, body)
	}
	waitFor(t, 3*time.Second, "ws:2's second call filed", func() bool { return svcMetered(t, r.h, "space:ws:2") == 300 })

	putSetting(t, r.h, SvcTenantBudgetPrefix+"livepage", "", http.StatusOK)
	putSetting(t, r.h, SvcBudgetPrefix+"livepage", "day=600", http.StatusOK)
	r.pastCache()
	for _, c := range []string{ws1, ws2} {
		if st, body := r.call(t, credvault.Claude, c); st != http.StatusForbidden || !strings.Contains(body, PersonBudgetExceeded) {
			t.Fatalf("the service at its ceiling → %d %s; want 403", st, body)
		}
	}
	if st, body := r.call(t, credvault.Claude, frank); st != 200 {
		t.Fatalf("a person, the service at its ceiling → %d %s", st, body)
	}
}

// A tight pool: a service run is never first bound to an account at or past
// the yield threshold; every pool account tight ⇒ it waits, a person does not.
func TestSvcYieldsTightPool(t *testing.T) {
	r := newCPRig(t)
	for _, acct := range []string{"pool1", "pool2"} {
		if err := r.h.srv.Vault.Put(store.PoolPrincipal, credvault.Claude, acct, credvault.Secret{RefreshToken: "rt-" + acct}); err != nil {
			t.Fatal(err)
		}
	}
	soon := time.Now().Add(48 * time.Hour)
	atLimit(t, r, "pool1", 85, soon)
	ws1 := svcPassFor(t, r.h, "space:ws:1", "R21")
	if st, body := r.call(t, credvault.Claude, ws1); st != 200 {
		t.Fatalf("a service call with pool2 free → %d %s", st, body)
	}
	if acct, _ := r.boundTo(t, "svc/R21/a1"); acct != "pool2" {
		t.Fatalf("pool1 is at 85%%; the service bound to %s, want pool2", acct)
	}
	atLimit(t, r, "pool2", 90, soon)
	ws2 := svcPassFor(t, r.h, "space:ws:2", "R22")
	if st, body := r.call(t, credvault.Claude, ws2); st == 200 {
		t.Fatalf("every pool account tight, the service still got one: %s", body)
	}
	frank, _ := r.issue(t, fidA)
	if st, body := r.call(t, credvault.Claude, frank); st != 200 {
		t.Fatalf("a person in a tight pool → %d %s", st, body)
	}
	putSetting(t, r.h, SvcYieldKey("svc:livepage"), "95", http.StatusOK)
	r.pastCache()
	if st, body := r.call(t, credvault.Claude, ws2); st != 200 {
		t.Fatalf("the threshold raised to 95%% → %d %s", st, body)
	}
}
