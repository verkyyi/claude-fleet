package api

import (
	"bytes"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/credvault"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/model"
)

// 我的额度 (claude-fleet#2517): a person reads the subscriptions their own
// (machine, login) pairs report under — bob's two, never carol's third — with
// no account uuid or e-mail in the answer; an admin reads their own too, not
// the pool; someone with nothing gets [].
func TestMeQuota_OwnSubscriptionsOnly(t *testing.T) {
	h := newGitHubHarnessWith(t, fullServer, "verkyyi")
	now := time.Now()
	reset5, reset7 := now.Add(2*time.Hour).UTC().Truncate(time.Second), now.Add(50*time.Hour).UTC().Truncate(time.Second)
	ingest := func(ep, host, acct string) {
		tok, err := MintToken()
		if err != nil {
			t.Fatal(err)
		}
		if err := h.srv.Store.Enroll(ep, host, HashToken(tok)); err != nil {
			t.Fatal(err)
		}
		body, _ := json.Marshal(model.Batch{Identity: model.Identity{AccountUUID: acct, Email: acct + "@example.com",
			Hostname: host, OS: "linux", Arch: "arm64", SubscriptionType: "max", OSUser: "ubuntu"},
			AccountOrigin: model.OriginLogin, Events: []model.UsageEvent{{AccountUUID: acct, EndpointID: ep,
				SessionID: "s-" + ep, MessageUUID: "s-" + ep, TS: now.Add(-time.Hour), Model: "claude-opus-5", OutputTokens: 100,
				CWD: "/p", OSUser: "ubuntu"}}})
		req, _ := http.NewRequest(http.MethodPost, h.http.URL+"/v1/ingest", bytes.NewReader(body))
		req.Header.Set("Authorization", "Bearer "+tok)
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("ingest %s: %d", ep, resp.StatusCode)
		}
	}
	ingest("ep_m1", "m1", "acct-a")
	ingest("ep_m3", "m3", "acct-b")
	ingest("ep_m2", "m2", "acct-c")
	limits := func(acct, ep string, h5, h7 float64) {
		if err := h.srv.Store.InsertLimits(&model.LimitsSnapshot{AccountUUID: acct, EndpointID: ep, ObservedAt: now,
			FiveHour: model.Window{Utilization: h5, ResetsAt: &reset5}, SevenDay: model.Window{Utilization: h7, ResetsAt: &reset7}}); err != nil {
			t.Fatal(err)
		}
	}
	limits("acct-a", "ep_m1", 62, 31)
	limits("acct-b", "ep_m3", 40, 100)
	limits("acct-c", "ep_m2", 5, 5)
	// A hand label names acct-a; acct-b keeps its reported e-mail, which
	// must not leave.
	if err := h.srv.Store.SetAccountLabel("acct-a", "icloud"); err != nil {
		t.Fatal(err)
	}

	for _, u := range []fakeGHUser{ghBob, ghCarol} {
		h.addUser(t, u)
		if _, err := h.srv.Store.AdoptPrincipal(githubPrincipal(u.ID), u.Login, u.Login, now); err != nil {
			t.Fatal(err)
		}
	}
	own := func(u fakeGHUser, host, ep string) {
		p, err := h.srv.Store.Principal(githubPrincipal(u.ID))
		if err != nil {
			t.Fatal(err)
		}
		if _, err := h.srv.Store.RecordLoginAccount(p, host, "ubuntu", ep, "test", now); err != nil {
			t.Fatal(err)
		}
	}
	own(ghBob, "m1", "ep_m1")
	own(ghBob, "m3", "ep_m3")
	own(ghCarol, "m2", "ep_m2")
	// Since claude-fleet#3227 the route is an admin's (the pool's windows):
	// the cut to a person's own logins is myQuota's, read here directly.
	read := func(u fakeGHUser) ([]MyQuota, string) {
		t.Helper()
		rows, err := h.srv.myQuota(githubPrincipal(u.ID), now)
		if err != nil {
			t.Fatal(err)
		}
		b, _ := json.Marshal(rows)
		return rows, string(b)
	}

	rows, raw := read(ghBob)
	if len(rows) != 2 {
		t.Fatalf("bob /v1/me/quota = %s; want his two subscriptions", raw)
	}
	for _, leak := range []string{"acct-", "@example.com", "account_uuid", "endpoint"} {
		if strings.Contains(raw, leak) {
			t.Errorf("bob's answer carries %q: %s", leak, raw)
		}
	}
	got := map[string]MyQuota{}
	for _, r := range rows {
		got[r.Subscription] = r
	}
	a, ok := got["icloud"]
	if !ok || a.State != QuotaOK || a.Used5hPct == nil || *a.Used5hPct != 62 || *a.Used7dPct != 31 ||
		a.ResetsAt == nil || !a.ResetsAt.Equal(reset5) || a.Provider != "claude" {
		t.Errorf("icloud = %+v; want ok 62/31, resets with the 5-hour window", a)
	}
	b, ok := got["Claude max"]
	if !ok || b.State != QuotaLimited || b.ResetsAt == nil || !b.ResetsAt.Equal(reset7) {
		t.Errorf("the weekly-full one = %+v (all: %s); want limited, resets with the 7-day window", b, raw)
	}

	if rows, raw := read(ghCarol); len(rows) != 1 || rows[0].Used5hPct == nil || *rows[0].Used5hPct != 5 {
		t.Errorf("carol /v1/me/quota = %s; want her one subscription", raw)
	}

	// An admin's "mine" is theirs too, not the pool: owning nothing, [].
	_, admin := h.signIn(t, ghAdmin)
	code, ab := rolesGet(t, h, admin, "/v1/me/quota")
	if raw := strings.TrimSpace(string(ab)); code != http.StatusOK || raw != "[]" {
		t.Errorf("an admin with no login /v1/me/quota = %d %q; want []", code, raw)
	}

	// The page is an admin's menu only (claude-fleet#3227).
	var me Me
	_, mb := rolesGet(t, h, admin, "/v1/me")
	_ = json.Unmarshal(mb, &me)
	if !containsString(me.Pages, "quota") {
		t.Errorf("/v1/me pages = %v; want quota", me.Pages)
	}
}

// A pool subscription is named by the label it was imported under, and one
// an admin paused reads paused — whatever its windows say.
func TestMeQuota_PoolLabelAndPaused(t *testing.T) {
	h, _, _ := newVaultHarness(t)
	now := time.Now()
	exp := now.Add(300 * 24 * time.Hour)
	putPool(t, h, credvault.Claude, "icloud", credvault.Secret{SetupToken: "sk-ant-oat01-ICLOUD", ExpiresAt: &exp, AccountUUID: icloudUUID})
	putPool(t, h, credvault.Claude, "gmail", credvault.Secret{SetupToken: "sk-ant-oat01-GMAIL", ExpiresAt: &exp})
	if err := h.srv.Store.SetFleetSetting(PoolPausedPrefix+"gmail", "on", now); err != nil {
		t.Fatal(err)
	}
	for _, id := range []model.Identity{{AccountUUID: icloudUUID, Email: "someone@icloud.com"}, {AccountUUID: gmailUUID, Email: "gmail@example.com"}} {
		if err := h.srv.Store.UpsertAccount(id, "max", ""); err != nil {
			t.Fatal(err)
		}
		if err := h.srv.Store.InsertLimits(&model.LimitsSnapshot{AccountUUID: id.AccountUUID, EndpointID: "ep_node", ObservedAt: now,
			FiveHour: model.Window{Utilization: 10}, SevenDay: model.Window{Utilization: 20}}); err != nil {
			t.Fatal(err)
		}
	}
	rows, err := h.srv.myQuota("", now) // the operator's door: every subscription
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]string{"icloud": QuotaOK, "gmail": QuotaPaused}
	for _, r := range rows {
		if w, ok := want[r.Subscription]; ok {
			if r.State != w {
				t.Errorf("%s = %s; want %s", r.Subscription, r.State, w)
			}
			delete(want, r.Subscription)
		}
	}
	if len(want) != 0 {
		t.Errorf("rows = %+v; missing %v", rows, want)
	}
}

func containsString(xs []string, s string) bool {
	for _, x := range xs {
		if x == s {
			return true
		}
	}
	return false
}
