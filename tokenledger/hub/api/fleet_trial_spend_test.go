package api

import (
	"encoding/json"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

// trialSpendHarness is meUsageHarness with bob on trial terms (his limits
// carry an end — trialIdentity) since 04:00 Beijing on 10-14, carol a full
// member, and every push the hub makes caught.
func trialSpendHarness(t *testing.T) (h *ghHarness, bob, admin *http.Cookie, now time.Time, pushes func() []string) {
	t.Helper()
	h, bob, _, admin, now = meUsageHarness(t)
	st := h.srv.Store
	if err := st.SetFleetSetting(MemberLimitsPrefix+githubPrincipal(ghBob.ID),
		"until=2026-10-20T00:00:00Z,tokens=3000000,since=2026-10-13T20:00:00Z", now); err != nil {
		t.Fatal(err)
	}
	var mu sync.Mutex
	var got []string
	h.srv.Notify = func(msg string) {
		mu.Lock()
		defer mu.Unlock()
		got = append(got, msg)
	}
	h.srv.FleetPublicURL = "https://hub.example"
	old := trialSpendAsync
	trialSpendAsync = false
	t.Cleanup(func() { trialSpendAsync = old })
	return h, bob, admin, now, func() []string {
		mu.Lock()
		defer mu.Unlock()
		return append([]string(nil), got...)
	}
}

func readTrialSpend(t *testing.T, h *ghHarness, sess *http.Cookie, q string) TrialSpend {
	t.Helper()
	code, b := rolesGet(t, h, sess, TrialSpendPath+q)
	if code != http.StatusOK {
		t.Fatalf("%s%s = %d %s", TrialSpendPath, q, code, b)
	}
	var out TrialSpend
	if err := json.Unmarshal(b, &out); err != nil {
		t.Fatalf("%v: %s", err, b)
	}
	return out
}

// WACK C6 完成判据 ①: the day's numbers are /v1/admin/usage's — the same
// rows, the same count — over the trial identities only; split by source off
// the proxies' rows (C1's classes), the split summing to the whole.
func TestTrialSpend_SameAsAdminUsage(t *testing.T) {
	h, bob, admin, now, _ := trialSpendHarness(t)
	st := h.srv.Store
	bobP := githubPrincipal(ghBob.ID)
	// bob connected his own subscription and spent as much on it as on the pool
	if err := st.PutCredential(bobP, "claude", "acct-own", []byte("x"), "oauth", nil, now); err != nil {
		t.Fatal(err)
	}
	if err := st.AddPoolUsage(store.PoolUsage{Principal: bobP, Account: "acct-own", Provider: "claude",
		Model: "claude-opus-5-5", In: 1640, At: now.Add(-time.Hour)}); err != nil {
		t.Fatal(err)
	}
	code, b := rolesGet(t, h, admin, AdminUsagePath)
	if code != http.StatusOK {
		t.Fatalf("%s = %d %s", AdminUsagePath, code, b)
	}
	var all AdminUsage
	if err := json.Unmarshal(b, &all); err != nil {
		t.Fatal(err)
	}
	var bobToday int64 = -1
	for _, p := range all.People {
		if p.Principal == bobP {
			bobToday = p.Today
		}
	}
	// now is 20:00 Beijing: today's Beijing day and the UTC day hold the same rows
	got := readTrialSpend(t, h, admin, "?day=2026-10-14")
	if bobToday <= 0 || got.Tokens != bobToday {
		t.Fatalf("trial tokens %d; /v1/admin/usage says bob's today is %d", got.Tokens, bobToday)
	}
	if len(got.People) != 1 || got.People[0].Principal != bobP || got.People[0].Tokens != bobToday {
		t.Fatalf("people = %+v; want bob alone (carol is a member)", got.People)
	}
	p := got.People[0]
	if !p.New || !p.Active || p.TrialDay != 1 || got.New != 1 || got.Active != 1 {
		t.Errorf("bob = %+v, new %d active %d; want new, active, his first day", p, got.New, got.Active)
	}
	if p.BYO != bobToday/2 || p.Pool+p.BYO != p.Tokens || got.Pool+got.BYO != got.Tokens {
		t.Errorf("split pool %d · byo %d of %d; want half on his own", p.Pool, p.BYO, p.Tokens)
	}
	var bySrc int64
	for _, n := range got.BySource {
		bySrc += n
	}
	if bySrc != got.Tokens || got.BySource[store.SourceBYO] != p.BYO {
		t.Errorf("by_source %v; want it to sum to %d", got.BySource, got.Tokens)
	}
	if got.Over != 0 || got.AllOver || got.Line.PersonDay != 1000000 || got.Line.AllDay != 30000000 {
		t.Errorf("over %d all %t line %+v; want the default line, nobody over", got.Over, got.AllOver, got.Line)
	}
	// the day before had only bob's codex turn (18:00 Beijing on 10-13)
	if y := readTrialSpend(t, h, admin, "?day=2026-10-13"); y.Tokens != 500 || y.New != 0 {
		t.Errorf("10-13 = %d tokens, %d new; want 500, 0", y.Tokens, y.New)
	}
	if code, _ := rolesGet(t, h, admin, TrialSpendPath+"?day=yesterday-ish"); code != http.StatusBadRequest {
		t.Errorf("bad day = %d; want 400", code)
	}
	if code, b := rolesGet(t, h, bob, TrialSpendPath); code == http.StatusOK {
		t.Errorf("a member reads %s: %s", TrialSpendPath, b)
	}
}

// WACK C6 完成判据 ②: a line is pushed once — per person per day, everyone
// once per day — and a second raise inside the quiet window waits for it.
func TestTrialSpend_LinePushedOnce(t *testing.T) {
	h, _, _, now, all := trialSpendHarness(t)
	// now is 20:00 Beijing: the morning report goes out too — count the lines
	pushes := func() []string {
		var out []string
		for _, m := range all() {
			if strings.HasPrefix(m, "⚠️") {
				out = append(out, m)
			}
		}
		return out
	}
	st := h.srv.Store
	bobP := githubPrincipal(ghBob.ID)
	if err := st.SetFleetSetting(TrialAlertKey, "person_day=1000,all_day=1500", now); err != nil {
		t.Fatal(err)
	}
	// carol is no trial: her writes never count
	h.srv.trialSpendWrote(githubPrincipal(ghCarol.ID), now)
	if len(pushes()) != 0 {
		t.Fatalf("a member's usage pushed %q", pushes())
	}
	h.srv.trialSpendWrote(bobP, now)
	got := pushes()
	if len(got) != 1 || !strings.Contains(got[0], "⚠️ 试用用量超线") || !strings.Contains(got[0], "超过单人单日 1,000") ||
		!strings.Contains(got[0], "（试用第 1 天）") || !strings.Contains(got[0], "https://hub.example/admin/usage?") {
		t.Fatalf("pushes = %q; want bob's line, once", got)
	}
	for _, sub := range []string{bobP + "@2026-10-14", "all@2026-10-14"} {
		if _, _, open, _ := st.OpenFleetAlert(store.AlertTrialSpend, sub); !open {
			t.Errorf("trial_spend %s not raised", sub)
		}
	}
	// everyone's line went over in the same write: held, not a second push now
	more := now.Add(time.Minute)
	if err := st.AddPoolUsage(store.PoolUsage{Principal: bobP, Account: "acct-pool", Provider: "claude", In: 5000, At: more}); err != nil {
		t.Fatal(err)
	}
	h.srv.trialSpendWrote(bobP, more)
	h.srv.TrialSpendTick(more)
	if n := len(pushes()); n != 1 {
		t.Fatalf("%d pushes inside the quiet window; want 1: %q", n, pushes())
	}
	h.srv.TrialSpendTick(now.Add(trialSpendQuiet + time.Second))
	got = pushes()
	if len(got) != 2 || !strings.Contains(got[1], "全体试用（1 人）") || !strings.Contains(got[1], "超过全体单日 1,500") {
		t.Fatalf("pushes = %q; want everyone's line after the window", got)
	}
	// the rest of the day: nothing more, whatever is written
	later := now.Add(2 * time.Hour)
	h.srv.trialSpendWrote(bobP, later)
	h.srv.TrialSpendTick(later)
	if n := len(pushes()); n != 2 {
		t.Fatalf("%d pushes; want no more today: %q", n, pushes())
	}
	// the next day closes yesterday's, and its own line is its own
	tomorrow := time.Date(2026, 10, 15, 2, 0, 0, 0, time.UTC) // 10:00 Beijing
	h.srv.TrialSpendTick(tomorrow)
	if _, _, open, _ := st.OpenFleetAlert(store.AlertTrialSpend, bobP+"@2026-10-14"); open {
		t.Error("yesterday's trial_spend still open")
	}
}

// The morning report goes out once, at 09:00 Beijing, about the day before;
// a day nobody tried still says so.
func TestTrialSpend_DailyOnceAtNine(t *testing.T) {
	h, _, _, _, pushes := trialSpendHarness(t)
	daily := func() []string {
		var out []string
		for _, m := range pushes() {
			if strings.HasPrefix(m, "ClaudeFleet 试用日报") {
				out = append(out, m)
			}
		}
		return out
	}
	h.srv.TrialSpendTick(time.Date(2026, 10, 15, 0, 59, 0, 0, time.UTC)) // 08:59 Beijing
	if len(daily()) != 0 {
		t.Fatalf("a report before nine: %q", daily())
	}
	at := time.Date(2026, 10, 15, 1, 1, 0, 0, time.UTC)
	h.srv.TrialSpendTick(at)
	h.srv.TrialSpendTick(at.Add(time.Hour))
	got := daily()
	if len(got) != 1 {
		t.Fatalf("reports = %q; want one", got)
	}
	for _, want := range []string{"ClaudeFleet 试用日报 · 10 月 15 日", "新开通 1 人", "在试用 1 人",
		"试用用量 1,640 tokens（池子 1,640 · 自带订阅 0）", "需要看 没有人超线",
		"查看详情 https://hub.example/admin/usage?day=2026-10-14&tab=trial"} {
		if !strings.Contains(got[0], want) {
			t.Errorf("report lacks %q:\n%s", want, got[0])
		}
	}
	h.srv.TrialSpendTick(time.Date(2026, 10, 16, 1, 30, 0, 0, time.UTC))
	got = daily()
	if len(got) != 2 || !strings.Contains(got[1], "10 月 16 日\n昨天没有人试用，也没有新开通。") {
		t.Fatalf("empty day = %q; want the one line", got)
	}
	// daily=off keeps it in
	if err := h.srv.Store.SetFleetSetting(TrialAlertKey, "daily=off", at); err != nil {
		t.Fatal(err)
	}
	h.srv.TrialSpendTick(time.Date(2026, 10, 17, 1, 30, 0, 0, time.UTC))
	if n := len(daily()); n != 2 {
		t.Errorf("daily=off still sent: %q", daily())
	}
}

func TestTrialAlertSetting(t *testing.T) {
	for v, want := range map[string]trialAlertLine{
		"":                          {PersonDay: 1000000, AllDay: 30000000, Daily: true},
		"off":                       {},
		"person_day=2M":             {PersonDay: 2000000, AllDay: 30000000, Daily: true},
		"all_day=0,daily=off":       {PersonDay: 1000000},
		"person_day=1k all_day=50k": {PersonDay: 1000, AllDay: 50000, Daily: true},
	} {
		got, err := parseTrialAlert(v)
		if err != nil || got != want {
			t.Errorf("%q = %+v, %v; want %+v", v, got, err, want)
		}
	}
	for _, bad := range []string{"person_day=lots", "hourly=1", "daily=maybe", "person_day"} {
		if _, why := checkTrialAlert(nil, bad); why == "" {
			t.Errorf("%q accepted", bad)
		}
	}
	for n, want := range map[int64][2]string{0: {"0", "0"}, 9999: {"9,999", "10k"}, 1420000: {"142 万", "1.4M"},
		18200000: {"1,820 万", "18.2M"}, 1000000: {"100 万", "1M"}, 30000000: {"3,000 万", "30M"}} {
		if zh, en := spendTokens(n, false), spendTokens(n, true); zh != want[0] || en != want[1] {
			t.Errorf("%d = %q / %q; want %q", n, zh, en, want)
		}
	}
}

// The English words, for admins who all read English.
func TestTrialSpend_English(t *testing.T) {
	sum := TrialSpend{New: 6, Active: 14, Tokens: 18200000, BYO: 18200000, Over: 1,
		Line:     trialAlertLine{PersonDay: 1000000, AllDay: 30000000, Daily: true},
		Machines: []TrialSpendMachine{{Node: "mac-a", LoadPct: 52}}}
	sent := time.Date(2026, 10, 21, 1, 0, 0, 0, time.UTC)
	got := trialDailyMsg(sum, sent, true, "https://h/x")
	for _, want := range []string{"ClaudeFleet trial daily · Oct 21", "New 6 people", "Active 14 people",
		"Trial usage 18.2M tokens (pool 0 · own subscriptions 18.2M)", "Machines mac-a load 52%",
		"Watch 1 person over 1M tokens in a day", "View details https://h/x"} {
		if !strings.Contains(got, want) {
			t.Errorf("lacks %q:\n%s", want, got)
		}
	}
	zh := trialDailyMsg(sum, sent, false, "")
	if !strings.Contains(zh, "试用用量 1,820 万 tokens（池子 0 · 自带订阅 1,820 万）") || !strings.Contains(zh, "机器 mac-a 负载 52%") ||
		!strings.Contains(zh, "需要看 1 人单日超 100 万 tokens") {
		t.Errorf("zh:\n%s", zh)
	}
	p := TrialSpendPerson{Name: "小林", Kind: store.IdentityWeChat, TrialDay: 2}
	if m := trialSpendPersonMsg(p, 1420000, 1000000, false, ""); !strings.Contains(m, "谁 微信用户「小林」（试用第 2 天）") ||
		!strings.Contains(m, "今天 142 万 tokens，超过单人单日 100 万") {
		t.Errorf("person zh:\n%s", m)
	}
	if m := trialSpendPersonMsg(p, 1420000, 1000000, true, ""); !strings.Contains(m, "Who WeChat user “小林” (trial day 2)") {
		t.Errorf("person en:\n%s", m)
	}
}
