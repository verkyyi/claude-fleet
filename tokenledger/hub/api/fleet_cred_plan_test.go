package api

import (
	"context"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/credvault"
	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/model"
)

// plan records an existing credential's subscription (claude-fleet EEJD): a
// setup token cannot say, so an admin does; the pool list then names the plan,
// its tier and what it costs a month — the token untouched, nothing sealed in
// the audit.
func TestCredentialSetPlan(t *testing.T) {
	h, _, _ := newVaultHarness(t)
	exp := time.Now().Add(300 * 24 * time.Hour)
	putPool(t, h, credvault.Claude, "Charlie_20X", credvault.Secret{SetupToken: "sk-ant-oat01-KEEPME", ExpiresAt: &exp})
	before, _ := h.srv.Store.Credential(store.PoolPrincipal, credvault.Claude, "Charlie_20X")

	set := func(provider, account, plan, tier string) int {
		code, _ := h.post(t, "/v1/fleet/credentials", FleetCredentialRequest{Action: "plan", PrincipalID: store.PoolPrincipal,
			Provider: provider, Account: account, Plan: plan, RateLimitTier: tier})
		return code
	}
	for _, bad := range [][2]string{{"Max 20x", ""}, {"max", "20×"}, {"", "default_claude_max_20x"}} {
		if code := set(credvault.Claude, "Charlie_20X", bad[0], bad[1]); code != http.StatusBadRequest {
			t.Fatalf("plan %q/%q: %d, want 400", bad[0], bad[1], code)
		}
	}
	if code := set(credvault.Claude, "nosuch", "max", ""); code != http.StatusNotFound {
		t.Fatalf("plan of a missing credential: %d", code)
	}
	if code := set(credvault.GitHub, "Charlie_20X", "max", ""); code != http.StatusBadRequest {
		t.Fatalf("plan on github: %d", code)
	}
	if err := h.srv.Store.SetPlanPrice(model.SubscriptionPlan{Plan: "max", Source: "claude", MonthlyCost: 200,
		EffectiveFrom: time.Now().Add(-time.Hour)}); err != nil {
		t.Fatal(err)
	}
	if code := set(credvault.Claude, "Charlie_20X", "max", "default_claude_max_20x"); code != http.StatusOK {
		t.Fatalf("plan: %d", code)
	}
	after, _ := h.srv.Store.Credential(store.PoolPrincipal, credvault.Claude, "Charlie_20X")
	if plan, src := h.srv.Vault.PlanMetadata(*after); plan != "max" || src != "admin" {
		t.Fatalf("plan after set = %q/%q", plan, src)
	}
	if after.Version != before.Version {
		t.Fatalf("plan bumped the version %d → %d", before.Version, after.Version)
	}
	acc, err := h.srv.Vault.Lease(context.Background(), store.PoolPrincipal, credvault.Claude, "Charlie_20X")
	if err != nil || acc.AccessToken != "sk-ant-oat01-KEEPME" {
		t.Fatalf("token after plan: %v", err)
	}

	var list struct {
		Credentials []struct {
			Account     string   `json:"account"`
			Plan        string   `json:"plan"`
			PlanSource  string   `json:"plan_source"`
			PlanTier    string   `json:"plan_tier"`
			MonthlyCost *float64 `json:"monthly_cost"`
			Currency    string   `json:"currency"`
		} `json:"credentials"`
	}
	h.getJSON(t, "/v1/fleet/credentials?principal_id=pool", &list)
	found := false
	for _, c := range list.Credentials {
		if c.Account != "Charlie_20X" {
			continue
		}
		found = true
		if c.Plan != "max" || c.PlanSource != "admin" || c.PlanTier != "default_claude_max_20x" ||
			c.MonthlyCost == nil || *c.MonthlyCost != 200 || c.Currency != "USD" {
			t.Fatalf("listed: %+v", c)
		}
	}
	if !found {
		t.Fatal("Charlie_20X not listed")
	}

	audit, _ := h.srv.Store.CredAuditLog(store.PoolPrincipal, 10)
	ok := false
	for _, a := range audit {
		if strings.Contains(a.Detail, "KEEPME") {
			t.Fatalf("a secret in the audit: %+v", a)
		}
		if a.Action == store.CredPlan && strings.Contains(a.Detail, "plan=max tier=default_claude_max_20x") && strings.Contains(a.Detail, "by ") {
			ok = true
		}
	}
	if !ok {
		t.Fatalf("no plan audit row: %+v", audit)
	}

	// An empty plan clears it: unpriced again, nothing left to name.
	if code := set(credvault.Claude, "Charlie_20X", "", ""); code != http.StatusOK {
		t.Fatalf("clear: %d", code)
	}
	after, _ = h.srv.Store.Credential(store.PoolPrincipal, credvault.Claude, "Charlie_20X")
	if plan, _ := h.srv.Vault.PlanMetadata(*after); plan != "" || h.srv.Vault.PlanTier(*after) != "" {
		t.Fatalf("plan after clear = %q", plan)
	}
}
