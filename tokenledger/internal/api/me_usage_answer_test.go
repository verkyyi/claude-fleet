package api

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/model"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

type fakeIssueMeta map[string]IssueMeta

func (f fakeIssueMeta) IssueMeta(_ context.Context, repo string, issue int) (IssueMeta, error) {
	return f[repo+"#"+itoa(issue)], nil
}

func itoa(n int) string { b, _ := json.Marshal(n); return string(b) }

const (
	meFleet = "33333333-3333-4333-8333-333333333333"
	meWOrch = meFleet + "/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
	meWScr  = meFleet + "/bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
	meWIss  = meFleet + "/cccccccc-cccc-4ccc-8ccc-cccccccccccc"
)

// meUsageHarness: bob and carol, each with pool rows; bob's fleet holds the
// orchestrator's window (an ordinary row since #3119, coordinator flagged),
// a scratch and an issue worker. now is a fixed Wednesday noon.
func meUsageHarness(t *testing.T) (h *ghHarness, bob, carol, admin *http.Cookie, now time.Time) {
	t.Helper()
	h = newGitHubHarnessWith(t, fullServer, "verkyyi")
	now = time.Date(2026, 10, 14, 12, 0, 0, 0, time.UTC)
	h.srv.budgetNow = func() time.Time { return now }
	h.srv.IssueMeta = fakeIssueMeta{
		"o/app#12": {Title: "合并额度与用量页", Epic: "o/app#10", EpicTitle: "EPIC: 用量"},
		"o/app#13": {Title: "用量没记到人名下"},
	}
	st := h.srv.Store
	for _, u := range []fakeGHUser{ghBob, ghCarol} {
		h.addUser(t, u)
		if _, err := st.AdoptPrincipal(githubPrincipal(u.ID), u.Login, u.Login, now); err != nil {
			t.Fatal(err)
		}
	}
	w, _ := json.Marshal([]map[string]any{
		{"worker_id": meWOrch, "identity": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", "coordinator": true},
		{"worker_id": meWScr, "key": "scratch-7"},
		{"worker_id": meWIss, "key": "issue-12"},
	})
	if _, err := st.RecordFleetSnapshot("ep_bob", "macmini", "bob", "mach-macmini", []store.FleetReport{{FleetID: meFleet,
		Name: "fleet", Repo: "o/app", Checkout: "/c", WorkerCount: 3, WorkersJSON: string(w)}}, now); err != nil {
		t.Fatal(err)
	}
	// What the proxies reported: the budget's rows (pool_usage), and nothing
	// the page reads — the same requests are in the scan below, so the page
	// counting both would show each twice (claude-fleet#3406).
	pool := func(who fakeGHUser, wid, provider, mdl string, in, out int64, at time.Time, repo string, issue int) {
		t.Helper()
		if err := st.AddPoolUsage(store.PoolUsage{Principal: githubPrincipal(who.ID), WorkerID: wid, Account: "acct-pool",
			Provider: provider, Model: mdl, In: in, Out: out, CacheRead: 999, At: at, Repo: repo, Issue: issue}); err != nil {
			t.Fatal(err)
		}
	}
	pool(ghBob, meWIss, "claude", "claude-opus-5-5", 1000, 200, now.Add(-time.Hour), "o/app", 12)
	pool(ghBob, meWIss, "claude", "claude-haiku-5-5-20260101", 100, 0, now.Add(-2*time.Hour), "o/app", 12)
	pool(ghBob, "", "codex", "gpt-5.4-codex", 500, 0, now.Add(-26*time.Hour), "o/app", 13)
	pool(ghBob, meWOrch, "claude", "claude-opus-5-5", 300, 0, now.Add(-3*time.Hour), "", 0)
	pool(ghBob, meWScr, "claude", "claude-sonnet-5-5", 40, 0, now.Add(-4*time.Hour), "", 0)
	pool(ghBob, "", "claude", "claude-opus-5-5", 7000, 0, now.Add(-10*24*time.Hour), "o/app", 12)
	pool(ghCarol, "", "claude", "claude-opus-5-5", 9999, 0, now.Add(-time.Hour), "o/secret", 99)

	// What the page reads: the scan, filed under a person by endpoint → login.
	bobEP := meEndpoint(t, h, "ep_bob", "macmini")
	carolEP := meEndpoint(t, h, "ep_carol", "carolbox")
	bobEP("claude", "bob",
		meEvent("claude-opus-5-5", 1000, 200, now.Add(-time.Hour), "issue-12", "o/app"), // today, a batch member
		meEvent("claude-haiku-5-5-20260101", 100, 0, now.Add(-2*time.Hour), "issue-12", "o/app"),
		meEvent("claude-opus-5-5", 300, 0, now.Add(-3*time.Hour), "", ""),                   // the orchestrator's window: no task
		meEvent("claude-sonnet-5-5", 40, 0, now.Add(-4*time.Hour), "scratch-7", ""),         // a scratch: no task
		meEvent("claude-opus-5-5", 7000, 0, now.Add(-10*24*time.Hour), "issue-12", "o/app")) // last week only
	bobEP("codex", "bob", meEvent("gpt-5.4-codex", 500, 0, now.Add(-26*time.Hour), "issue-13", "o/app"))         // yesterday
	carolEP("claude", "carol", meEvent("claude-opus-5-5", 9999, 0, now.Add(-time.Hour), "issue-99", "o/secret")) // never bob's
	for who, l := range map[fakeGHUser][3]string{ghBob: {"macmini", "bob", "ep_bob"}, ghCarol: {"carolbox", "carol", "ep_carol"}} {
		p, err := st.Principal(githubPrincipal(who.ID))
		if err != nil {
			t.Fatal(err)
		}
		if _, err := st.RecordLoginAccount(p, l[0], l[1], l[2], "test", now); err != nil {
			t.Fatal(err)
		}
	}
	_, bob = h.signIn(t, ghBob)
	_, carol = h.signIn(t, ghCarol)
	_, admin = h.signIn(t, ghAdmin)
	return
}

var meEventSeq int

// meEvent is one scanned turn: cache reads are never counted, so 999 of them
// rides along to prove it.
func meEvent(mdl string, in, out int64, at time.Time, branch, repo string) model.UsageEvent {
	meEventSeq++
	return model.UsageEvent{MessageUUID: fmt.Sprintf("me-%d", meEventSeq), SessionID: "s-" + branch, TS: at, Model: mdl,
		InputTokens: in, OutputTokens: out, CacheRead: 999, GitBranch: branch, GitRepo: repo, CWD: "/c/" + branch}
}

// meEndpoint enrolls endpoint id on host and returns its push: one batch of
// one source's events, run as osUser, through /v1/ingest as an agent sends it.
func meEndpoint(t *testing.T, h *ghHarness, id, host string) func(source, osUser string, evs ...model.UsageEvent) {
	t.Helper()
	tok, err := MintToken()
	if err != nil {
		t.Fatal(err)
	}
	if err := h.srv.Store.Enroll(id, host, HashToken(tok)); err != nil {
		t.Fatal(err)
	}
	return func(source, osUser string, evs ...model.UsageEvent) {
		t.Helper()
		acct := "acct-" + source + "-" + id
		for i := range evs {
			evs[i].AccountUUID, evs[i].EndpointID, evs[i].OSUser, evs[i].Source = acct, id, osUser, source
		}
		body, _ := json.Marshal(model.Batch{Identity: model.Identity{AccountUUID: acct, Email: acct + "@example.com",
			Hostname: host, OS: "darwin", Arch: "arm64", SubscriptionType: "max", OSUser: osUser, Source: source},
			AccountOrigin: model.OriginLogin, Events: evs})
		req, _ := http.NewRequest(http.MethodPost, h.http.URL+"/v1/ingest", bytes.NewReader(body))
		req.Header.Set("Authorization", "Bearer "+tok)
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("push %s %s: HTTP %d", id, source, resp.StatusCode)
		}
	}
}

func readMeUsage(t *testing.T, h *ghHarness, c *http.Cookie, q string) (MeUsage, string) {
	t.Helper()
	code, b := rolesGet(t, h, c, "/v1/me/usage"+q)
	if code != http.StatusOK {
		t.Fatalf("/v1/me/usage%s: HTTP %d %s", q, code, b)
	}
	var u MeUsage
	if err := json.Unmarshal(b, &u); err != nil {
		t.Fatalf("%v: %s", err, b)
	}
	return u, string(b)
}

func TestMeUsage_Totals_Days_Models(t *testing.T) {
	h, bob, _, _, _ := meUsageHarness(t)
	u, raw := readMeUsage(t, h, bob, "?range=7d")
	if u.Today != 1200+100+300+40 || u.TodayPrev != 500 {
		t.Errorf("today = %d / prev %d; want 1640 / 500", u.Today, u.TodayPrev)
	}
	if u.Week != 2140 || u.WeekPrev != 7000 {
		t.Errorf("week = %d / prev %d; want 2140 / 7000", u.Week, u.WeekPrev)
	}
	if u.Total != 2140 || len(u.Days) != 7 {
		t.Fatalf("total %d, %d days; want 2140 over 7: %s", u.Total, len(u.Days), raw)
	}
	if d := u.Days[6]; d.Day != "2026-10-14" || d.Claude != 1640 || d.Codex != 0 {
		t.Errorf("today's day = %+v", d)
	}
	if d := u.Days[5]; d.Codex != 500 || d.Claude != 0 {
		t.Errorf("yesterday's day = %+v; want codex 500", d)
	}
	names := map[string]int64{}
	for _, m := range u.Models {
		names[m.Name] = m.Tokens
	}
	want := map[string]int64{"Opus 5.5": 1500, "Haiku 5.5": 100, "GPT-5.4 Codex": 500, "Sonnet 5.5": 40}
	for n, v := range want {
		if names[n] != v {
			t.Errorf("model %s = %d; want %d (all %+v)", n, names[n], v, u.Models)
		}
	}
	if u.Models[0].Name != "Opus 5.5" {
		t.Errorf("models not largest first: %+v", u.Models)
	}
	// the pool is never named to a person
	for _, leak := range []string{"acct-pool", "account", "5h_pct", "o/secret"} {
		if strings.Contains(raw, leak) {
			t.Errorf("bob's answer carries %q: %s", leak, raw)
		}
	}
	if u, _ := readMeUsage(t, h, bob, "?range=today"); u.Total != 1640 || len(u.Days) != 7 {
		t.Errorf("range=today: total %d, %d days; want 1640 over a week of bars", u.Total, len(u.Days))
	}
	if u, _ := readMeUsage(t, h, bob, "?range=30d"); u.Total != 9140 || len(u.Days) != 30 {
		t.Errorf("range=30d: total %d, %d days; want 9140 over 30", u.Total, len(u.Days))
	}
	if code, _ := rolesGet(t, h, bob, "/v1/me/usage?range=1y"); code != http.StatusBadRequest {
		t.Errorf("range=1y: HTTP %d; want 400", code)
	}
}

// by_session is the viewer's sessions, today and this week, by worker_id
// (claude-fleet#3377): each column sums to today / week with the "none" item
// for the rows on no session, a session is named off its fleet's heartbeat,
// and another person's session is never in it.
func TestMeUsage_BySession(t *testing.T) {
	h, bob, carol, _, _ := meUsageHarness(t)
	u, raw := readMeUsage(t, h, bob, "")
	var today, week int64
	got := map[string]MeUsageSession{}
	for _, it := range u.BySession {
		today += it.Today
		week += it.Week
		k := it.Key
		if it.Kind == workNone {
			k = workNone
		}
		got[k] = it
	}
	if today != u.Today || week != u.Week {
		t.Errorf("by_session sums to %d / %d; want today %d / week %d: %s", today, week, u.Today, u.Week, raw)
	}
	// A transcript names no worker: its session is the key its branch names.
	if it := got["issue-12"]; it.Today != 1300 || it.Week != 1300 || it.Repo != "o/app" || it.Issue != 12 {
		t.Errorf("the issue worker = %+v; want issue-12, 1300 / 1300 on o/app#12", it)
	}
	if it := got["issue-13"]; it.Today != 0 || it.Week != 500 {
		t.Errorf("yesterday's codex = %+v; want issue-13 at 500 this week", it)
	}
	if it := got["scratch-7"]; it.Today != 40 {
		t.Errorf("the scratch = %+v; want scratch-7 at 40", it)
	}
	if it := got[workNone]; it.Today != 300 || it.Week != 300 {
		t.Errorf("no session = %+v; want the branchless 300", it)
	}
	if len(u.BySession) != 4 || u.BySession[len(u.BySession)-1].Kind != workNone || u.BySession[0].Key != "issue-12" {
		t.Errorf("by_session order = %+v; want largest first, none last", u.BySession)
	}
	c, raw := readMeUsage(t, h, carol, "")
	if len(c.BySession) != 2 || c.BySession[0].Key != "issue-99" || c.BySession[0].Today != 9999 || c.BySession[1].Kind != workNone {
		t.Errorf("carol's by_session = %+v; want her issue-99 at 9999, then none", c.BySession)
	}
	if strings.Contains(raw, "issue-12") || strings.Contains(raw, "scratch-7") {
		t.Errorf("carol's answer names bob's sessions: %s", raw)
	}
}

// since_first is the hour of the scan's oldest row, anyone's — a previous
// window that starts before it was not fully recorded and the page shows no
// percent off it (claude-fleet#3230, #3406). Nothing recorded = absent.
func TestMeUsage_SinceFirst(t *testing.T) {
	h, bob, carol, _, now := meUsageHarness(t)
	want := now.Add(-10 * 24 * time.Hour).Truncate(time.Hour)
	for _, c := range []*http.Cookie{bob, carol} {
		if u, raw := readMeUsage(t, h, c, ""); u.SinceFirst == nil || !u.SinceFirst.Equal(want) {
			t.Errorf("since_first = %v; want %v (the oldest row, anyone's): %s", u.SinceFirst, want, raw)
		}
	}
	h2 := newGitHubHarnessWith(t, fullServer, "verkyyi")
	h2.addUser(t, ghBob)
	_, c := h2.signIn(t, ghBob)
	if _, raw := readMeUsage(t, h2, c, ""); strings.Contains(raw, "since_first") {
		t.Errorf("nothing recorded yet, but since_first is set: %s", raw)
	}
}

// Only the viewer's own, whatever is asked; an admin reads theirs, not the hub.
func TestMeUsage_OwnOnly(t *testing.T) {
	h, _, carol, admin, _ := meUsageHarness(t)
	u, raw := readMeUsage(t, h, carol, "?principal="+githubPrincipal(ghBob.ID))
	if u.Today != 9999 || u.Total != 9999 || strings.Contains(raw, "scratch-7") || strings.Contains(raw, "o/app") {
		t.Errorf("carol reads %s; want her own 9999 and nothing of bob's", raw)
	}
	if u, raw := readMeUsage(t, h, admin, ""); u.Total != 0 || u.Week != 0 {
		t.Errorf("an admin with no login of theirs reads %s; want 0", raw)
	}
}

func TestMeUsage_Limit(t *testing.T) {
	h, bob, carol, _, now := meUsageHarness(t)
	// 不限额: no limit, no remaining, no reset.
	_, raw := readMeUsage(t, h, bob, "")
	var probe map[string]map[string]any
	_ = json.Unmarshal([]byte(raw), &probe)
	lim := probe["limit"]
	if lim["set"] != false {
		t.Errorf("no budget: limit = %v; want set false", lim)
	}
	for _, k := range []string{"limit_week", "remaining_week", "reset_week", "limit_5h", "remaining_5h", "reset_5h"} {
		if _, ok := lim[k]; ok {
			t.Errorf("no budget: limit carries %s: %v", k, lim)
		}
	}
	if lim["used_week"].(float64) != 2140 {
		t.Errorf("used_week = %v; want 2140", lim["used_week"])
	}

	// A weekly limit: remaining = limit − used; the 5-hour window unset stays out.
	if err := h.srv.Store.SetFleetSetting(PersonBudgetPrefix+githubPrincipal(ghBob.ID), "week=10k", now); err != nil {
		t.Fatal(err)
	}
	u, raw := readMeUsage(t, h, bob, "")
	l := u.Limit
	if !l.Set || l.LimitWeek == nil || *l.LimitWeek != 10000 || l.RemainingWeek == nil || *l.RemainingWeek != 10000-l.UsedWeek ||
		l.UsedWeek != 2140 || l.ResetWeek == nil || l.Limit5h != nil || l.Remaining5h != nil {
		t.Errorf("week=10k: limit = %s", raw)
	}
	if l.ResetWeek != nil && (!l.ResetWeek.After(now) || l.ResetWeek.After(now.Add(budgetWindowWeek))) {
		t.Errorf("reset_week %v not within the coming week", l.ResetWeek)
	}

	// A 5-hour window too, already over: remaining is 0, never below.
	if err := h.srv.Store.SetFleetSetting(PersonBudgetPrefix+githubPrincipal(ghBob.ID), "5h=1k,week=10k", now); err != nil {
		t.Fatal(err)
	}
	u, raw = readMeUsage(t, h, bob, "")
	l = u.Limit
	if l.Limit5h == nil || *l.Limit5h != 1000 || l.Used5h != 1640 || l.Remaining5h == nil || *l.Remaining5h != 0 ||
		!l.Over || l.Window != "5h" || l.Reset5h == nil {
		t.Errorf("5h=1k: limit = %s", raw)
	}
	// carol's limit is not bob's business, nor bob's hers
	if u, _ := readMeUsage(t, h, carol, ""); u.Limit.Set {
		t.Errorf("carol has no budget but reads %+v", u.Limit)
	}
}

func TestMeUsage_WhereItWent(t *testing.T) {
	h, bob, carol, _, _ := meUsageHarness(t)
	u, raw := readMeUsage(t, h, bob, "?range=7d")
	sum := func(xs []MeUsageItem) (n int64) {
		for _, x := range xs {
			n += x.Tokens
		}
		return
	}
	for name, xs := range map[string][]MeUsageItem{"issue": u.Work.Issue, "repo": u.Work.Repo, "epic": u.Work.Epic} {
		if sum(xs) != u.Total {
			t.Errorf("work.%s sums to %d; want the total %d: %s", name, sum(xs), u.Total, raw)
		}
		if last := xs[len(xs)-1]; last.Kind != workNone {
			t.Errorf("work.%s ends with %+v; want the none row last", name, last)
		}
	}
	by := map[string]MeUsageItem{}
	for _, it := range u.Work.Issue {
		by[it.Kind+":"+it.Repo+"#"+itoa(it.Issue)] = it
	}
	if it := by["issue:o/app#12"]; it.Tokens != 1300 || it.Title != "合并额度与用量页" || it.Epic != "o/app#10" ||
		it.EpicTitle != "EPIC: 用量" || len(it.Sessions) != 1 || it.Sessions[0] != "issue-12" || it.Node != "macmini" ||
		len(it.Models) != 2 || it.Models[0][0] != "Opus 5.5" {
		t.Errorf("task #12 = %+v", it)
	}
	if it := by["issue:o/app#13"]; it.Tokens != 500 || it.Epic != "" || it.Sessions[0] != "issue-13" {
		t.Errorf("task #13 = %+v", it)
	}
	// A transcript names no worker, so the orchestrator's window is just a
	// row on no task: the none row, beside the scratch.
	if _, ok := by["orch:#0"]; ok {
		t.Errorf("an orch row off the scan, which names no worker: %s", raw)
	}
	if it := by["none:#0"]; it.Tokens != 340 || len(it.Sessions) != 1 || it.Sessions[0] != "scratch-7" || it.Node != "macmini" {
		t.Errorf("the none row = %+v; want 340 with the scratch named, on macmini", it)
	}
	if u.Work.Issue[0].Issue != 12 || u.Work.Issue[len(u.Work.Issue)-1].Kind != workNone {
		t.Errorf("order: tasks largest first, then none: %+v", u.Work.Issue)
	}
	repo := map[string]int64{}
	for _, it := range u.Work.Repo {
		repo[it.Kind+":"+it.Repo] = it.Tokens
	}
	if repo["repo:o/app"] != 1800 || repo["none:"] != 340 {
		t.Errorf("work.repo = %+v", u.Work.Repo)
	}
	epic := map[string]int64{}
	for _, it := range u.Work.Epic {
		epic[it.Kind+":"+it.Epic] = it.Tokens
	}
	if epic["epic:o/app#10"] != 1300 || epic["none:"] != 840 {
		t.Errorf("work.epic = %+v", u.Work.Epic)
	}

	// Nothing at all: each breakdown is still its one none row, at 0.
	if err := h.srv.Store.AddPoolUsage(store.PoolUsage{}); err == nil {
		t.Fatal("a row with no principal was written")
	}
	_, admin := h.signIn(t, ghAdmin)
	u, raw = readMeUsage(t, h, admin, "")
	for _, xs := range [][]MeUsageItem{u.Work.Issue, u.Work.Repo, u.Work.Epic} {
		if len(xs) != 1 || xs[0].Kind != workNone || xs[0].Tokens != 0 {
			t.Errorf("empty: %s", raw)
		}
	}
	_ = carol
}

// The pool's windows are an admin's: a person gets 403 and no 我的额度 page.
func TestMeQuota_AdminOnly(t *testing.T) {
	h, bob, _, admin, _ := meUsageHarness(t)
	if code, b := rolesGet(t, h, bob, "/v1/me/quota"); code != http.StatusForbidden {
		t.Errorf("a user's /v1/me/quota: HTTP %d %s; want 403", code, b)
	}
	if code, b := rolesGet(t, h, admin, "/v1/me/quota"); code != http.StatusOK {
		t.Errorf("an admin's /v1/me/quota: HTTP %d %s; want 200", code, b)
	}
	if _, me := h.me(t, bob); containsString(me.Pages, "quota") || !containsString(me.Pages, "usage") {
		t.Errorf("a user's pages = %v; want usage, not quota", me.Pages)
	}
	if _, me := h.me(t, admin); !containsString(me.Pages, "quota") {
		t.Errorf("an admin's pages = %v; want quota", me.Pages)
	}
}

func TestModelHumanName(t *testing.T) {
	for in, want := range map[string]string{
		"claude-opus-5-5":            "Opus 5.5",
		"claude-sonnet-5-5-20260101": "Sonnet 5.5",
		"claude-haiku-4-5":           "Haiku 4.5",
		"claude-fable-5-1":           "Fable 5.1",
		"claude-opus-4-1-20250805":   "Opus 4.1",
		"claude-opus-5":              "Opus 5",
		"claude-opus-5-5[1m]":        "Opus 5.5",
		"claude-3-5-sonnet-20241022": "Sonnet 3.5",
		"gpt-5.4-codex":              "GPT-5.4 Codex",
		"gpt-5-codex-mini":           "GPT-5 Codex Mini",
		"o3":                         "o3",
		"":                           "",
	} {
		if got := modelHumanName(in); got != want {
			t.Errorf("modelHumanName(%q) = %q; want %q", in, got, want)
		}
	}
}

// claude-fleet#3406: 我的用量 and the overview read the scan, filed under a
// person by endpoint → login → principal. bob has two logins on two machines
// and nothing in pool_usage: his week is both machines' sum. A login on his
// machine that is no one's, and his login NAME on a machine that is not his,
// are nobody's — counted as unattributed on the overview, in no person's row.
func TestMeUsage_FromScan_TwoLogins(t *testing.T) {
	h := newGitHubHarnessWith(t, fullServer, "verkyyi")
	now := time.Date(2026, 10, 14, 12, 0, 0, 0, time.UTC)
	h.srv.budgetNow = func() time.Time { return now }
	st := h.srv.Store
	for _, u := range []fakeGHUser{ghBob, ghCarol} {
		h.addUser(t, u)
		if _, err := st.AdoptPrincipal(githubPrincipal(u.ID), u.Login, u.Login, now); err != nil {
			t.Fatal(err)
		}
	}
	mini, box := meEndpoint(t, h, "ep_mini", "mini"), meEndpoint(t, h, "ep_box", "box")
	stray, cbox := meEndpoint(t, h, "ep_stray", "stray"), meEndpoint(t, h, "ep_cbox", "cbox")
	mini("claude", "bob", meEvent("claude-opus-5-5", 100, 10, now.Add(-2*time.Hour), "issue-1", "o/app"),
		meEvent("claude-opus-5-5", 5, 0, now.Add(-3*24*time.Hour), "", ""))
	box("codex", "bobby", meEvent("gpt-5.4-codex", 1000, 0, now.Add(-24*time.Hour), "", ""))
	box("claude", "nobody", meEvent("claude-opus-5-5", 50000, 0, now.Add(-time.Hour), "", ""))
	stray("claude", "bob", meEvent("claude-opus-5-5", 70000, 0, now.Add(-time.Hour), "", ""))
	cbox("claude", "carol", meEvent("claude-opus-5-5", 9000, 0, now.Add(-time.Hour), "", ""))
	for _, a := range []struct {
		who               fakeGHUser
		host, login, epID string
	}{{ghBob, "mini", "bob", "ep_mini"}, {ghBob, "box", "bobby", "ep_box"}, {ghCarol, "cbox", "carol", "ep_cbox"}} {
		p, err := st.Principal(githubPrincipal(a.who.ID))
		if err != nil {
			t.Fatal(err)
		}
		if _, err := st.RecordLoginAccount(p, a.host, a.login, a.epID, "test", now); err != nil {
			t.Fatal(err)
		}
	}
	if rows, err := st.PoolUsageFor("", time.Time{}, time.Time{}); err != nil || len(rows) != 0 {
		t.Fatalf("pool_usage = %v, %v; want empty", rows, err)
	}

	_, bob := h.signIn(t, ghBob)
	u, raw := readMeUsage(t, h, bob, "?range=7d")
	if u.Total != 110+5+1000 || u.Week != 1115 || u.Today != 110 || u.TodayPrev != 1000 {
		t.Errorf("bob's 7d = total %d week %d today %d / prev %d; want 1115 / 1115 / 110 / 1000: %s",
			u.Total, u.Week, u.Today, u.TodayPrev, raw)
	}
	if d := u.Days[5]; d.Codex != 1000 || d.Claude != 0 {
		t.Errorf("yesterday = %+v; want box's codex 1000", d)
	}
	if u.SinceFirst == nil || !u.SinceFirst.Equal(now.Add(-3*24*time.Hour)) {
		t.Errorf("since_first = %v; want the scan's oldest hour", u.SinceFirst)
	}
	_, carol := h.signIn(t, ghCarol)
	if c, raw := readMeUsage(t, h, carol, "?range=7d"); c.Total != 9000 {
		t.Errorf("carol's 7d = %d; want her own 9000: %s", c.Total, raw)
	}

	_, admin := h.signIn(t, ghAdmin)
	var ov AdminOverview
	if code := getJSON(t, h, admin, AdminOverviewPath+"?since=2026-10-01T00:00:00Z", &ov); code != http.StatusOK {
		t.Fatalf("admin %s = %d", AdminOverviewPath, code)
	}
	week := map[string]int64{}
	for _, p := range ov.People {
		week[p.Principal] = p.Week
	}
	if week[githubPrincipal(ghBob.ID)] != 1115 || week[githubPrincipal(ghCarol.ID)] != 9000 || len(week) != 2 {
		t.Errorf("overview people = %+v; want bob 1115, carol 9000, no one else", ov.People)
	}
	if ov.Totals.Tokens != 1115+9000+50000+70000 || ov.Totals.TokensUnattributed != 120000 {
		t.Errorf("overview totals = %+v; want 130115 with 120000 unattributed", ov.Totals)
	}
}
