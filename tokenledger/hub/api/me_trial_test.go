package api

import (
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

// claude-fleet T796: a trial member reads their own limits on /v1/me/usage —
// days left, tokens used against the ceiling, the session count, one state —
// asks to 转正 once, and the admin's person-usage shows the ask. Tokens are
// counted as every limit counts them: a cache read is not one.
func TestMeUsageTrial(t *testing.T) {
	h := newGitHubHarnessWith(t, fullServer, "ivan")
	now := time.Now()
	h.srv.budgetNow = func() time.Time { return now }
	for _, u := range []fakeGHUser{ghBob, ghCarol} {
		h.addUser(t, u)
		if _, err := h.srv.Store.AdoptPrincipal(githubPrincipal(u.ID), u.Login, u.Login, now); err != nil {
			t.Fatal(err)
		}
	}
	bobID := githubPrincipal(ghBob.ID)
	setHubSetting(t, h.srv, MemberLimitsPrefix+bobID,
		MemberLimits{Until: now.Add(6*24*time.Hour + time.Hour), Tokens: 1_000_000, Sessions: 1, Since: now.Add(-time.Hour)}.String())
	if err := h.srv.Store.AddPoolUsage(store.PoolUsage{Principal: bobID, Provider: "claude", Model: "claude-opus-5",
		In: 100_000, CacheWrite: 50_000, Out: 50_000, CacheRead: 9_000_000, At: now.Add(-time.Minute)}); err != nil {
		t.Fatal(err)
	}
	_, bob := h.signIn(t, ghBob)
	_, carol := h.signIn(t, ghCarol)
	_, admin := h.signIn(t, fakeGHUser{ID: 100, Login: "ivan"})

	trial := func(c *http.Cookie) *MeUsageTrial {
		t.Helper()
		code, b := rolesGet(t, h, c, "/v1/me/usage?range=today")
		if code != http.StatusOK {
			t.Fatalf("HTTP %d %s", code, b)
		}
		var a MeUsage
		if err := json.Unmarshal(b, &a); err != nil {
			t.Fatalf("%v: %s", err, b)
		}
		return a.Trial
	}
	tr := trial(bob)
	if tr == nil || tr.State != trialOK || tr.Tokens != 1_000_000 || tr.UsedTokens != 200_000 || tr.Sessions != 1 ||
		tr.DaysLeft == nil || *tr.DaysLeft != 7 || tr.Until == nil || tr.UpgradeAsked != nil {
		t.Fatalf("bob's trial = %+v", tr)
	}
	if tr := trial(carol); tr != nil {
		t.Fatalf("carol is on no trial: %+v", tr)
	}
	if code, _ := requestsDo(t, h, carol, http.MethodPost, MeTrialUpgradePath, map[string]any{}); code != http.StatusConflict {
		t.Fatalf("carol's 转正 = %d; want 409", code)
	}
	code, b := requestsDo(t, h, bob, http.MethodPost, MeTrialUpgradePath, map[string]any{})
	if code != http.StatusOK || !strings.Contains(string(b), "upgrade_asked") {
		t.Fatalf("bob's 转正 = %d %s", code, b)
	}
	first := trial(bob).UpgradeAsked
	if first == nil {
		t.Fatal("no upgrade_asked after asking")
	}
	requestsDo(t, h, bob, http.MethodPost, MeTrialUpgradePath, map[string]any{})
	if again := trial(bob).UpgradeAsked; again == nil || !again.Equal(*first) {
		t.Fatalf("asking again moved the time: %v → %v", first, again)
	}
	// T805: the admin is told once, however often bob asks
	if ns, _ := h.srv.Store.NoticesOf(githubPrincipal(100), store.NotifyKindUpgrade); len(ns) != 1 || ns[0].Refs[0] != bobID {
		t.Fatalf("the admin's 转正 notices = %+v", ns)
	}
	code, b = rolesGet(t, h, admin, "/v1/fleet/person-usage")
	var people struct {
		People []PersonBudgetState `json:"people"`
	}
	if code != http.StatusOK || json.Unmarshal(b, &people) != nil {
		t.Fatalf("person-usage = %d %s", code, b)
	}
	found := false
	for _, p := range people.People {
		if p.Principal == bobID {
			found = p.TrialTokens == 1_000_000 && p.TrialUsedTokens == 200_000 && p.TrialSessions == 1 && p.UpgradeAsked != nil
		}
	}
	if !found {
		t.Fatalf("admin's row for bob lacks the trial: %s", b)
	}

	// 80 % used: soon; all of it: spent, and the proxies refuse.
	if err := h.srv.Store.AddPoolUsage(store.PoolUsage{Principal: bobID, Provider: "claude", Model: "claude-opus-5",
		Out: 650_000, At: now.Add(-time.Minute)}); err != nil {
		t.Fatal(err)
	}
	if tr := trial(bob); tr.State != trialSoon {
		t.Fatalf("85%% used = %+v", tr)
	}
	if err := h.srv.Store.AddPoolUsage(store.PoolUsage{Principal: bobID, Provider: "claude", Model: "claude-opus-5",
		Out: 200_000, At: now.Add(-time.Minute)}); err != nil {
		t.Fatal(err)
	}
	if tr := trial(bob); tr.State != trialSpent {
		t.Fatalf("all used = %+v", tr)
	}
	st, _ := h.srv.personBudgetState(bobID, now)
	if !st.Over || st.Window != "trial_tokens" || !strings.Contains(st.Message, "试用额度已用完") || !strings.Contains(st.Message, "100 万") {
		t.Fatalf("spent state = %+v", st)
	}
}

func TestTrialStateOf(t *testing.T) {
	now := time.Date(2026, 10, 21, 8, 0, 0, 0, time.UTC)
	at := func(d time.Duration) *time.Time { u := now.Add(d); return &u }
	for _, c := range []struct {
		t    MeUsageTrial
		want string
	}{
		{MeUsageTrial{Until: at(48 * time.Hour)}, trialOK},
		{MeUsageTrial{Until: at(23 * time.Hour)}, trialSoon},
		{MeUsageTrial{Until: at(-time.Second)}, trialExpired},
		{MeUsageTrial{Tokens: 100, UsedTokens: 79}, trialOK},
		{MeUsageTrial{Tokens: 100, UsedTokens: 80}, trialSoon},
		{MeUsageTrial{Tokens: 100, UsedTokens: 100}, trialSpent},
		{MeUsageTrial{USD: 20, SpentUSD: 20}, trialSpent},
		{MeUsageTrial{Until: at(-time.Second), Tokens: 100, UsedTokens: 100}, trialExpired},
	} {
		if got := trialStateOf(&c.t, now); got != c.want {
			t.Errorf("%+v = %s; want %s", c.t, got, c.want)
		}
	}
}
