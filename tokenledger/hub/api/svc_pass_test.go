package api

import (
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/credvault"
	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

// A service's standing pass (svc_pass.go): svc:<name> with pass:issue mints a
// Codex-only session pass for itself, renews it, and loses it with its token
// or its principal; its usage is the service's, held to the service's budget
// and its yield.

// svcStandingSetup makes svc:<name> with scopes, lists every subscription for
// it (the allowlist a service needs, claude-fleet#4085), and issues a token.
func svcStandingSetup(t *testing.T, h *harness, name, scopes string) string {
	t.Helper()
	tok := svcSetup(t, h, name, scopes)
	if err := h.srv.Store.SetFleetSetting(credUserKey("svc:"+name), `"*"`, time.Now()); err != nil {
		t.Fatal(err)
	}
	return tok
}

func svcPassMint(t *testing.T, h *harness, tok string, body any) map[string]any {
	t.Helper()
	st, out := svcDo(t, h, http.MethodPost, SvcPassPath, tok, body)
	if st != http.StatusOK {
		t.Fatalf("mint: %d %v", st, out)
	}
	return out
}

func TestSvcPassScopeAndShape(t *testing.T) {
	h := newCPRig(t).h
	// the scopes a service held before: none of them mints a pass
	old := svcStandingSetup(t, h, "livepage", "runs:write runs:read templates:write runs:eval templates:qualify")
	if st, _ := svcDo(t, h, http.MethodPost, SvcPassPath, old, nil); st != http.StatusForbidden {
		t.Fatalf("a token without pass:issue minted: %d", st)
	}
	if st, _ := svcDo(t, h, http.MethodPost, SvcPassRenewPath, old, map[string]string{"cred": "fcp-h1.x.y"}); st != http.StatusForbidden {
		t.Fatalf("a token without pass:issue renewed: %d", st)
	}
	if st := svcCall(t, h, http.MethodPost, SvcPassPath, ""); st != http.StatusUnauthorized {
		t.Fatalf("no token: %d", st)
	}

	tok := svcStandingSetup(t, h, "xiaoerge", "pass:issue")
	out := svcPassMint(t, h, tok, nil)
	cred, _ := out["cred"].(string)
	if !strings.HasPrefix(cred, "fcp-h1.") && !strings.HasPrefix(cred, "fcp-h2.") {
		t.Fatalf("cred %q", cred)
	}
	if out["principal_id"] != "svc:xiaoerge" || out["worker_id"] != "svc-standing/xiaoerge" || out["machine"] != "svc-standing" {
		t.Fatalf("answer %v", out)
	}
	if ps := out["providers"].([]any); len(ps) != 1 || ps[0] != credvault.Codex {
		t.Fatalf("providers %v; a standing pass is codex only", ps)
	}
	exp, _ := time.Parse(time.RFC3339, out["expires_at"].(string))
	if d := time.Until(exp); d > SessionCredTTL || d < SessionCredTTL-time.Minute {
		t.Fatalf("default life %v; want %v", d, SessionCredTTL)
	}
	c, why := h.srv.parseSessionPass(cred, time.Now())
	if c == nil || why != "" || c.Svc != "xiaoerge" || c.Tenant != "" || c.Run != "" {
		t.Fatalf("claims %+v %q", c, why)
	}
	if h.srv.svcPassTenant(c) != "" {
		t.Fatalf("a standing pass files under tenant %q", h.srv.svcPassTenant(c))
	}
	// codex verifies, claude does not: Claude stays off the cluster
	if v, _ := h.srv.verifySessionCred(cred, "svc:xiaoerge", credvault.Codex, true, time.Now()); !v.Valid {
		t.Fatalf("codex: %+v", v)
	}
	if v, _ := h.srv.verifySessionCred(cred, "", credvault.Claude, true, time.Now()); v.Valid {
		t.Fatal("a standing pass covers claude")
	}
	for _, bad := range []any{
		map[string]any{"providers": []string{"claude"}},
		map[string]any{"providers": []string{"codex", "claude"}},
		map[string]any{"ttl_seconds": 60},
		map[string]any{"ttl_seconds": int(SessionCredTTL.Seconds()) + 1},
	} {
		if st, o := svcDo(t, h, http.MethodPost, SvcPassPath, tok, bad); st != http.StatusBadRequest {
			t.Errorf("%v → %d %v; want 400", bad, st, o)
		}
	}
	short := svcPassMint(t, h, tok, map[string]any{"providers": []string{"codex"}, "ttl_seconds": 600})
	exp, _ = time.Parse(time.RFC3339, short["expires_at"].(string))
	if d := time.Until(exp); d > 10*time.Minute {
		t.Fatalf("ttl_seconds 600 → %v", d)
	}
	if !svcAudited(t, h, "svc.pass.issue", "ok") {
		t.Error("no svc.pass.issue audit row")
	}

	// passes off: 503, nothing minted
	h.srv.SessionCredKey = nil
	if st, o := svcDo(t, h, http.MethodPost, SvcPassPath, tok, nil); st != http.StatusServiceUnavailable || o["error_code"] != SessionCredOff {
		t.Fatalf("passes off: %d %v", st, o)
	}
}

// No Codex subscription on the service's allowlist: refused, nothing minted.
func TestSvcPassNeedsAllowlist(t *testing.T) {
	h := newCPRig(t).h
	tok := svcSetup(t, h, "xiaoerge", "pass:issue")
	st, out := svcDo(t, h, http.MethodPost, SvcPassPath, tok, nil)
	if st != http.StatusForbidden || out["error_code"] != "no_credential" {
		t.Fatalf("no allowlist: %d %v", st, out)
	}
	if rows, _ := h.srv.Store.SessionCreds(false, time.Now(), 50); len(rows) != 0 {
		t.Fatalf("a refused mint left %d passes", len(rows))
	}
	if !svcAudited(t, h, "svc.pass.issue", "REFUSED") {
		t.Error("no REFUSED svc.pass.issue audit row")
	}
}

// Renewal: the same pass, a new expiry, by its own principal only; a lapsed
// pass inside the grace too.
func TestSvcPassRenew(t *testing.T) {
	h := newCPRig(t).h
	tok := svcStandingSetup(t, h, "xiaoerge", "pass:issue")
	other := svcStandingSetup(t, h, "other", "pass:issue")
	out := svcPassMint(t, h, tok, map[string]any{"ttl_seconds": 600})
	cred := out["cred"].(string)

	st, re := svcDo(t, h, http.MethodPost, SvcPassRenewPath, tok, map[string]string{"cred": cred})
	if st != http.StatusOK || re["id"] != out["id"] {
		t.Fatalf("renew: %d %v", st, re)
	}
	if st, o := svcDo(t, h, http.MethodPost, SvcPassRenewPath, other, map[string]string{"cred": cred}); st != http.StatusNotFound {
		t.Fatalf("another service renewed it: %d %v", st, o)
	}
	if !svcAudited(t, h, "svc.pass.renew", "ok") {
		t.Error("no svc.pass.renew audit row")
	}
	// a person's pass is not a standing pass
	sess := newCPRig(t)
	frank, _ := sess.issue(t, fidA)
	stok := svcStandingSetup(t, sess.h, "xiaoerge", "pass:issue")
	if st, o := svcDo(t, sess.h, http.MethodPost, SvcPassRenewPath, stok, map[string]string{"cred": frank}); st != http.StatusNotFound {
		t.Fatalf("a person's pass renewed by a service: %d %v", st, o)
	}

	// lapsed: the row ran out an hour ago — still renewable inside the grace
	id := out["id"].(string)
	if _, err := h.srv.Store.RenewSessionCred(id, time.Now().Add(-time.Hour), time.Now(), time.Now().Add(-48*time.Hour)); err != nil {
		t.Fatal(err)
	}
	h.srv.sessCred.drop("")
	if st, o := svcDo(t, h, http.MethodPost, SvcPassRenewPath, tok, map[string]string{"cred": re["cred"].(string)}); st != http.StatusOK {
		t.Fatalf("a lapsed pass inside the grace: %d %v", st, o)
	}
}

// Revoking the token that minted a pass, or disabling its principal, ends the
// pass at its next verify and stops new ones at once.
func TestSvcPassRevokedWithTokenOrPrincipal(t *testing.T) {
	h := newCPRig(t).h
	a := svcStandingSetup(t, h, "xiaoerge", "pass:issue")
	b := svcIssue(t, h, "xiaoerge")
	pa := svcPassMint(t, h, a, nil)["cred"].(string)
	pb := svcPassMint(t, h, b, nil)["cred"].(string)
	valid := func(cred string) bool {
		v, _ := h.srv.verifySessionCred(cred, "", credvault.Codex, false, time.Now())
		return v.Valid
	}
	if !valid(pa) || !valid(pb) {
		t.Fatal("fresh passes do not verify")
	}
	prefix, _ := svcTokenPrefix(a)
	if st, o := svcAdmin(t, h, SvcAdminRequest{Op: "revoke", Prefix: prefix, Reason: "rotated"}); st != http.StatusOK {
		t.Fatalf("revoke: %d %v", st, o)
	}
	if valid(pa) {
		t.Fatal("the revoked token's pass still verifies")
	}
	if !valid(pb) {
		t.Fatal("the other token's pass stopped with it")
	}
	if st, _ := svcDo(t, h, http.MethodPost, SvcPassPath, a, nil); st != http.StatusUnauthorized {
		t.Fatalf("a revoked token minted: %d", st)
	}
	if st, _ := svcDo(t, h, http.MethodPost, SvcPassRenewPath, b, map[string]string{"cred": pa}); st != http.StatusForbidden {
		t.Fatalf("the revoked token's pass renewed: %d", st)
	}

	if st, o := svcAdmin(t, h, SvcAdminRequest{Op: "disable", Principal: "svc:xiaoerge"}); st != http.StatusOK {
		t.Fatalf("disable: %d %v", st, o)
	}
	if valid(pb) {
		t.Fatal("a disabled service's pass still verifies")
	}
	if st, _ := svcDo(t, h, http.MethodPost, SvcPassPath, b, nil); st != http.StatusUnauthorized {
		t.Fatalf("a disabled service minted: %d", st)
	}
	if st, o := svcAdmin(t, h, SvcAdminRequest{Op: "enable", Principal: "svc:xiaoerge"}); st != http.StatusOK {
		t.Fatalf("enable: %d %v", st, o)
	}
	if !valid(pb) {
		t.Fatal("enabled again, the live token's pass does not verify")
	}
}

// Through the cluster credential proxy: a standing pass's Codex calls are
// metered under svc:<name> (tenant ""), the service's budget refuses it — at
// resolve and at mint — and no person.
func TestSvcPassMeteredAndBudgeted(t *testing.T) {
	r := newCPRig(t)
	tok := svcStandingSetup(t, r.h, "xiaoerge", "pass:issue")
	cred := svcPassMint(t, r.h, tok, nil)["cred"].(string)
	if st, body := r.call(t, credvault.Codex, cred); st != 200 {
		t.Fatalf("a standing pass's codex call → %d %s", st, body)
	}
	if st, _ := r.call(t, credvault.Claude, cred); st == 200 {
		t.Fatal("a standing pass reached claude through the proxy")
	}
	metered := func(tenant string) int64 {
		rows, err := r.h.srv.Store.SvcUsageSince("svc:xiaoerge", tenant, time.Now().Add(-time.Hour), time.Time{})
		if err != nil {
			t.Fatal(err)
		}
		var n int64
		for _, x := range rows {
			n += x.Tokens()
		}
		return n
	}
	waitFor(t, 3*time.Second, "the call metered under svc:xiaoerge", func() bool { return metered("") == 150 })
	rows, _ := r.h.srv.Store.SvcUsageSince("svc:xiaoerge", "", time.Now().Add(-time.Hour), time.Time{})
	for _, x := range rows {
		if x.Tenant != "" {
			t.Fatalf("filed under tenant %q", x.Tenant)
		}
	}

	putSetting(t, r.h, SvcBudgetPrefix+"xiaoerge", "day=150", http.StatusOK)
	r.pastCache()
	if st, body := r.call(t, credvault.Codex, cred); st != http.StatusForbidden || !strings.Contains(body, PersonBudgetExceeded) {
		t.Fatalf("over the service's budget → %d %s; want 403", st, body)
	}
	if st, o := svcDo(t, r.h, http.MethodPost, SvcPassPath, tok, nil); st != http.StatusTooManyRequests || o["error_code"] != SvcErrQuotaExceeded {
		t.Fatalf("mint over budget: %d %v", st, o)
	}
	frank, _ := r.issue(t, fidA)
	if st, body := r.call(t, credvault.Codex, frank); st != 200 {
		t.Fatalf("a person, the service over its budget → %d %s", st, body)
	}
}

// A tight pool: a standing pass yields at EVERY new request, not only its
// first — once its account crosses fleet.svc.<name>.yield_pct it moves; all
// tight ⇒ it waits, a person does not.
func TestSvcPassYieldsEveryRequest(t *testing.T) {
	r := newCPRig(t)
	if err := r.h.srv.Vault.Put(store.PoolPrincipal, credvault.Codex, "poolcx2",
		credvault.Secret{RefreshToken: "rt-cx2", AccountID: "aid-pool2"}); err != nil {
		t.Fatal(err)
	}
	tok := svcStandingSetup(t, r.h, "xiaoerge", "pass:issue")
	cred := svcPassMint(t, r.h, tok, nil)["cred"].(string)
	if st, body := r.call(t, credvault.Codex, cred); st != 200 {
		t.Fatalf("first call → %d %s", st, body)
	}
	first := codexBound(t, r, "svc-standing/xiaoerge")
	second := map[string]string{"poolcx": "poolcx2", "poolcx2": "poolcx"}[first]
	now := time.Now()
	codexSelectionQuota(t, r, first, now, 85, 10, time.Hour, 48*time.Hour)
	codexSelectionQuota(t, r, second, now, 10, 10, time.Hour, 48*time.Hour)
	r.pastCache()
	if st, body := r.call(t, credvault.Codex, cred); st != 200 {
		t.Fatalf("second call → %d %s", st, body)
	}
	if got := codexBound(t, r, "svc-standing/xiaoerge"); got != second {
		t.Fatalf("%s crossed 80%%; the standing pass stayed on %s, want %s", first, got, second)
	}
	codexSelectionQuota(t, r, second, now.Add(time.Second), 90, 10, time.Hour, 48*time.Hour)
	r.pastCache()
	if st, body := r.call(t, credvault.Codex, cred); st == 200 {
		t.Fatalf("every pool account tight, the standing pass still got one: %s", body)
	}
	frank, _ := r.issue(t, fidA)
	if st, body := r.call(t, credvault.Codex, frank); st != 200 {
		t.Fatalf("a person in a tight pool → %d %s", st, body)
	}
	putSetting(t, r.h, SvcYieldKey("svc:xiaoerge"), "95", http.StatusOK)
	r.pastCache()
	if st, body := r.call(t, credvault.Codex, cred); st != 200 {
		t.Fatalf("the threshold raised to 95%% → %d %s", st, body)
	}
}
