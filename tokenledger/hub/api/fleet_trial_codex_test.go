package api

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/model"
)

func TestTrialProviderPinAndDefaults(t *testing.T) {
	h := newFleetHarness(t)
	for _, tc := range []struct {
		setting, body, want string
		status              int
	}{
		{"codex", `{"text":"task","images":[{"data":"unchanged"}],"unknown":1}`, "codex", 200},
		{"codex", `{"agent":"claude","text":"task"}`, "claude", 200},
		{"claude", `{"agent":"codex","text":"task"}`, "codex", 200},
		{"", `{"text":"task"}`, "claude", 200},
		{"broken", `{"text":"task"}`, "", 503},
		{"broken", `{"agent":"codex","text":"task"}`, "codex", 200},
		{"codex", `{"agent":7}`, "", 400},
		{"codex", `{"agent":"unknown"}`, "", 400},
		{"codex", `null`, "", 400},
	} {
		t.Run(tc.setting+tc.body, func(t *testing.T) {
			setHubSetting(t, h.srv, ClientDefaultsPrefix+"FLEET_AGENT", tc.setting)
			r := httptest.NewRequest(http.MethodPost, ChatPathPrefix+"open", strings.NewReader(tc.body))
			w := httptest.NewRecorder()
			ok := h.srv.trialOpenProvider(w, r, "trial-test")
			if ok != (tc.status == 200) || w.Code != tc.status {
				t.Fatalf("open = %v %d %s", ok, w.Code, w.Body)
			}
			if !ok {
				return
			}
			raw, _ := io.ReadAll(r.Body)
			var body, original map[string]any
			_ = json.Unmarshal(raw, &body)
			_ = json.Unmarshal([]byte(tc.body), &original)
			if body["agent"] != tc.want || r.ContentLength != int64(len(raw)) {
				t.Fatalf("unpinned body: %s", raw)
			}
			delete(body, "agent")
			delete(original, "agent")
			got, _ := json.Marshal(body)
			want, _ := json.Marshal(original)
			if string(got) != string(want) {
				t.Fatalf("changed user intent: %s != %s", got, want)
			}
			// A relay replica receiving the pinned body must retain the decision
			// even if the team/local default has changed in the meantime.
			setHubSetting(t, h.srv, ClientDefaultsPrefix+"FLEET_AGENT", "claude")
			r.Body = io.NopCloser(strings.NewReader(string(raw)))
			if !h.srv.trialOpenProvider(w, r, "trial-test") {
				t.Fatal("replica rejected pinned choice")
			}
			raw, _ = io.ReadAll(r.Body)
			_ = json.Unmarshal(raw, &body)
			if body["agent"] != tc.want {
				t.Fatalf("replica changed provider: %s", raw)
			}
		})
	}
	setHubSetting(t, h.srv, ClientDefaultsPrefix+"FLEET_AGENT", "broken")
	if why := h.srv.trialHold("", time.Now()); why != trialWaitBusy+":provider" {
		t.Fatalf("invalid default admitted: %q", why)
	}
	if why := h.srv.qrHold(time.Now()); why != trialWaitBusy+":provider" {
		t.Fatalf("invalid default admitted through scanned trial: %q", why)
	}
}

func TestTrialOpenCodexExhaustionAndProviderOverride(t *testing.T) {
	h := newFleetHarness(t)
	now := time.Now()
	for _, id := range []model.Identity{{AccountUUID: "full-cx", Source: model.SourceCodex}, {AccountUUID: "free-cl", Source: model.SourceClaude}} {
		if err := h.srv.Store.UpsertAccount(id, "pro", ""); err != nil {
			t.Fatal(err)
		}
	}
	if err := h.srv.Store.InsertQuota(model.QuotaSnapshot{Source: model.SourceCodex, AccountUUID: "full-cx", EndpointID: "test-node", ObservedAt: now,
		Windows: []model.QuotaWindow{{ID: "primary", Minutes: 300, UsedPercent: 100}}, Observation: "app_server"}); err != nil {
		t.Fatal(err)
	}
	if err := h.srv.Store.InsertLimits(&model.LimitsSnapshot{AccountUUID: "free-cl", EndpointID: "test-node", ObservedAt: now,
		FiveHour: model.Window{Utilization: 5}}); err != nil {
		t.Fatal(err)
	}
	for _, agent := range []string{"codex", "claude"} {
		r := httptest.NewRequest(http.MethodPost, ChatPathPrefix+"open", strings.NewReader(`{"agent":"`+agent+`","text":"task"}`))
		w := httptest.NewRecorder()
		if ok := h.srv.trialOpenProvider(w, r, "trial-test"); ok != (agent == "claude") {
			t.Fatalf("%s open: %v %s", agent, ok, w.Body)
		}
		if agent == "codex" && w.Code != http.StatusTooManyRequests {
			t.Fatalf("exhausted Codex = %d", w.Code)
		}
	}
}

// The session route must check the provider it actually starts, even after a
// seat was admitted against the team default's other pool.
func TestTrialOpenExplicitClaudeCannotSpendCodexHeadroom(t *testing.T) {
	h := newFleetHarness(t)
	enablePeople(t, h)
	setHubSetting(t, h.srv, TrialKey, "on")
	setHubSetting(t, h.srv, ClientDefaultsPrefix+"FLEET_AGENT", "codex")
	now := time.Now()
	const pid = "p:10000000-0000-4000-8000-000000004060"
	cookie := trialSession(t, h, pid)
	if err := h.srv.Store.PlaceTrial(pid, "mac-d", now); err != nil {
		t.Fatal(err)
	}
	if _, err := h.srv.Store.ReadyTrial(pid, now); err != nil {
		t.Fatal(err)
	}
	setChatHome(t, h, pid, "mac-d", "trial-test")
	if err := h.srv.Store.UpsertAccount(model.Identity{AccountUUID: "explicit-cl", Source: model.SourceClaude}, "pro", ""); err != nil {
		t.Fatal(err)
	}
	if err := h.srv.Store.InsertLimits(&model.LimitsSnapshot{AccountUUID: "explicit-cl", EndpointID: "test-node", ObservedAt: now,
		FiveHour: model.Window{Utilization: 100}}); err != nil {
		t.Fatal(err)
	}
	resp := chatDo(t, h, http.MethodPost, ChatPathPrefix+"open", cookie, map[string]string{"X-Fleet-Webchat": "1"}, `{"agent":"claude","text":"continue my task"}`)
	if got := chatCode(t, resp); resp.StatusCode != http.StatusTooManyRequests || got != "trial_quota" {
		t.Fatalf("explicit exhausted Claude = %d %s; must refuse before starting a writer", resp.StatusCode, got)
	}
	tr, err := h.srv.Store.Trial(pid)
	if err != nil || tr.Msgs != 0 {
		t.Fatalf("refused open spent trial line: %+v %v", tr, err)
	}
}

// Scanned trial codes grant limited membership rather than a role=trial row.
// Both identities must use the same effective-provider check, even with the
// legacy fleet.trial switch off (the site's D grayscale remains independent).
func TestTrialOpenLimitedMemberUsesSameProviderGate(t *testing.T) {
	h := newFleetHarness(t)
	enablePeople(t, h)
	const pid = "gh:9435294"
	listPerson(t, h, pid, "trial-limited")
	now := time.Now()
	setHubSetting(t, h.srv, MemberLimitsPrefix+pid, MemberLimits{Tokens: 100, Since: now.Add(-time.Minute), Until: now.Add(time.Hour), Sessions: 1}.String())
	setHubSetting(t, h.srv, ClientDefaultsPrefix+"FLEET_AGENT", "codex")
	setChatHome(t, h, pid, "mac-d", "trial-limited")
	if err := h.srv.Store.UpsertAccount(model.Identity{AccountUUID: "limited-cl", Source: model.SourceClaude}, "pro", ""); err != nil {
		t.Fatal(err)
	}
	if err := h.srv.Store.InsertLimits(&model.LimitsSnapshot{AccountUUID: "limited-cl", EndpointID: "test-node", ObservedAt: now, FiveHour: model.Window{Utilization: 100}}); err != nil {
		t.Fatal(err)
	}
	resp := chatDo(t, h, http.MethodPost, ChatPathPrefix+"open", personCookie(pid, "trial-limited"), map[string]string{"X-Fleet-Webchat": "1"}, `{"agent":"claude","text":"preserve this trial task"}`)
	if code := chatCode(t, resp); resp.StatusCode != http.StatusTooManyRequests || code != "trial_quota" {
		t.Fatalf("limited member open = %d %s", resp.StatusCode, code)
	}
	if h.srv.trialOn() {
		t.Fatal("test enabled the legacy trial switch")
	}
}

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
	setHubSetting(t, h.srv, ClientDefaultsPrefix+"FLEET_AGENT", "")
	if left, ok := h.srv.poolLeft(); !ok || left != 0 {
		t.Fatalf("missing default must use dispatch's Claude compatibility pool: %v %v", left, ok)
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
