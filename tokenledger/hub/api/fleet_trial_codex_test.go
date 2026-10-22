package api

import (
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/model"
)

// Admission follows the same default as the session, while every trial gate
// continues to apply. In particular a full Claude pool cannot hold Codex.
func TestTrialCodexDefaultAdmission(t *testing.T) {
	h := newFleetHarness(t)
	now := time.Now()
	for _, id := range []model.Identity{{AccountUUID: "trial-cl", Source: model.SourceClaude}, {AccountUUID: "trial-cx", Source: model.SourceCodex}} {
		if err := h.srv.Store.UpsertAccount(id, "pro", ""); err != nil {
			t.Fatal(err)
		}
	}
	if err := h.srv.Store.InsertLimits(&model.LimitsSnapshot{AccountUUID: "trial-cl", EndpointID: "test-node", ObservedAt: now,
		FiveHour: model.Window{Utilization: 100}, SevenDay: model.Window{Utilization: 99}}); err != nil {
		t.Fatal(err)
	}
	if err := h.srv.Store.InsertQuota(model.QuotaSnapshot{Source: model.SourceCodex, AccountUUID: "trial-cx", EndpointID: "test-node",
		ObservedAt: now, Observation: "app_server", Windows: []model.QuotaWindow{{ID: "primary", Minutes: 300, UsedPercent: 10}}}); err != nil {
		t.Fatal(err)
	}
	setHubSetting(t, h.srv, ClientDefaultsPrefix+"FLEET_AGENT", "codex")
	if left, ok := h.srv.poolLeft(); !ok || left != 90 {
		t.Fatalf("Codex default headroom = %v, %v; want 90 despite Claude full", left, ok)
	}
	if why := h.srv.trialHold("", now); why == trialWaitQuota {
		t.Fatalf("Codex held by Claude quota: %s", why)
	}
	setHubSetting(t, h.srv, TrialSlotsKey, "0")
	if why := h.srv.trialHold("", now); why != trialWaitFull {
		t.Fatalf("Codex bypassed slots: %s", why)
	}
	setHubSetting(t, h.srv, TrialSlotsKey, "8")
	setHubSetting(t, h.srv, TrialCredAllowKey, "[]")
	if why := h.srv.trialHold("", now); why != trialWaitNoSub {
		t.Fatalf("Codex bypassed subscription isolation: %s", why)
	}
	setHubSetting(t, h.srv, TrialCredAllowKey, `"*"`)
	setHubSetting(t, h.srv, ClientDefaultsPrefix+"FLEET_AGENT", "claude")
	if left, ok := h.srv.poolLeft(); !ok || left != 0 {
		t.Fatalf("Claude default headroom = %v, %v; want 0", left, ok)
	}
	if why := h.srv.trialHold("", now); why != trialWaitQuota {
		t.Fatalf("Claude pool full was not held: %s", why)
	}
	setHubSetting(t, h.srv, ClientDefaultsPrefix+"FLEET_AGENT", "codex")
	if err := h.srv.Store.InsertQuota(model.QuotaSnapshot{Source: model.SourceCodex, AccountUUID: "trial-cx", EndpointID: "test-node",
		ObservedAt: now.Add(time.Second), Observation: "app_server", Windows: []model.QuotaWindow{{ID: "primary", Minutes: 300, UsedPercent: 100}}}); err != nil {
		t.Fatal(err)
	}
	if why := h.srv.trialHold("", now); why != trialWaitQuota {
		t.Fatalf("Codex pool full was not held: %s", why)
	}
}

// Continuing with another agent spends the SAME person's budget: neither a
// fresh native session nor another provider buys another allowance.
func TestTrialCodexContinuationBudgetIsolation(t *testing.T) {
	h := newFleetHarness(t)
	now := time.Now()
	const alice = "p:11111111-2222-4333-8444-555555555555"
	const bob = "p:66666666-2222-4333-8444-555555555555"
	for _, p := range []string{alice, bob} {
		setHubSetting(t, h.srv, MemberLimitsPrefix+p, MemberLimits{Tokens: 100, Since: now.Add(-time.Hour), Until: now.Add(time.Hour), Sessions: 1}.String())
	}
	for _, u := range []store.PoolUsage{
		{Principal: alice, Provider: "claude", Model: "claude-opus-5", In: 60, At: now},
		{Principal: alice, Provider: "codex", Model: "gpt-5", In: 40, At: now},
		{Principal: bob, Provider: "codex", Model: "gpt-5", In: 10, At: now},
	} {
		if err := h.srv.Store.AddPoolUsage(u); err != nil {
			t.Fatal(err)
		}
	}
	a, err := h.srv.personBudgetState(alice, now)
	if err != nil || !a.Over || a.Error != PersonBudgetExceeded || a.TrialUsedTokens != 100 || a.TrialSessions != 1 {
		t.Fatalf("continued trial budget = %+v, %v", a, err)
	}
	b, err := h.srv.personBudgetState(bob, now)
	if err != nil || b.Over || b.TrialUsedTokens != 10 {
		t.Fatalf("another person's Codex trial = %+v, %v", b, err)
	}
}
