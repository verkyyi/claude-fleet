package findings

import (
	"fmt"
	"strings"
	"testing"
	"time"
)

func sessions(tokens ...int64) []SessionStat {
	var out []SessionStat
	for i, t := range tokens {
		out = append(out, SessionStat{SessionID: "s" + string(rune('a'+i)), CWD: "/p/x", Model: "claude-opus-5",
			Tokens: t, Turns: 3, Duration: 90 * time.Minute})
	}
	return out
}

func kinds(fs []Finding) string {
	var k []string
	for _, f := range fs {
		k = append(k, f.Kind)
	}
	return strings.Join(k, ",")
}

func TestRunawaySession(t *testing.T) {
	// median of 10,10,10,10 = 10 -> threshold max(200, 100M) = 100M
	in := Inputs{Sessions: append(sessions(10, 10, 10, 10), SessionStat{SessionID: "big", CWD: "/p/y", Model: "m",
		Tokens: 150_000_000, Turns: 400, Duration: 6 * time.Hour})}
	fs := Review(in)
	if kinds(fs) != "runaway_session" || fs[0].Severity != "critical" || fs[0].Scope["session"] != "big" {
		t.Fatalf("%+v", fs)
	}
	if !strings.Contains(fs[0].Title, "150.0M") || !strings.Contains(fs[0].Detail, "6h 0m") {
		t.Fatalf("wording: %+v", fs[0])
	}
	// mutation: the big session shrunk below the absolute floor -> nothing fires
	in.Sessions[4].Tokens = 99_000_000
	if fs := Review(in); len(fs) != 0 {
		t.Fatalf("control: %+v", fs)
	}
	// relative rule: 25x median but under the floor still does not fire
	in.Sessions = append(sessions(1_000_000, 1_000_000, 1_000_000), SessionStat{SessionID: "x", Tokens: 25_000_000})
	if fs := Review(in); len(fs) != 0 {
		t.Fatalf("floor: %+v", fs)
	}
}

// Sessions is allowed to be a bounded, tokens-descending SAMPLE rather than
// the full population -- SessionTokenMedian is how a caller supplies the
// population's real median instead. This is the production bug this field
// exists to fix: a caller handing runaway() only its biggest N sessions used
// to derive a threshold from THEIR median, which is nowhere near the true
// population median and swallowed genuine outliers.
func TestRunaway_PopulationMedianOverridesSampleMedian(t *testing.T) {
	// Every session in this slice is already large -- as if a caller had
	// pulled only the top-N by tokens and none of the (hypothetical) many
	// small sessions that dominate the real population survived into it.
	in := Inputs{
		Sessions: []SessionStat{
			{SessionID: "s1", Tokens: 50_000_000, Turns: 3},
			{SessionID: "s2", Tokens: 50_000_000, Turns: 3},
			{SessionID: "s3", Tokens: 50_000_000, Turns: 3},
			{SessionID: "outlier", Tokens: 200_000_000, Turns: 10},
		},
		// The true population median, dominated by tiny sessions never
		// included in Sessions above -> threshold = max(20M, 100M) = 100M.
		SessionTokenMedian: 1_000,
	}
	fs := Review(in)
	if kinds(fs) != "runaway_session" || fs[0].Scope["session"] != "outlier" {
		t.Fatalf("%+v", fs)
	}

	// Control: zero the field. runaway() now falls back to the SAMPLE's own
	// median (50,000,000) -> threshold = max(20*50M, 100M) = 1B, which
	// swallows the 200M outlier entirely. This reproduces the bug exactly.
	in.SessionTokenMedian = 0
	if fs := Review(in); len(fs) != 0 {
		t.Fatalf("control (sample-median fallback should have swallowed the outlier): %+v", fs)
	}
}

func TestUnpricedModel(t *testing.T) {
	in := Inputs{Models: []ModelStat{{Model: "claude-fable-5-1", Tokens: 3_300_000_000, Unpriced: 9104}, {Model: "claude-opus-5", Tokens: 1}}}
	fs := Review(in)
	if kinds(fs) != "unpriced_model" || fs[0].Severity != "warning" || fs[0].Scope["model"] != "claude-fable-5-1" {
		t.Fatalf("%+v", fs)
	}
	in.Models[0].Unpriced = 0
	if fs := Review(in); len(fs) != 0 {
		t.Fatalf("control: %+v", fs)
	}
}

func TestTimeInCritical(t *testing.T) {
	in := Inputs{SelectionSeconds: 7 * 86400, Critical: []AccountCritical{{Label: "a@x", Seconds: 3600, PrevSeconds: 0, Episodes: 2}}}
	fs := Review(in)
	if kinds(fs) != "time_in_critical" || fs[0].Severity != "warning" || !strings.Contains(fs[0].Title, "1h 0m") {
		t.Fatalf("%+v", fs)
	}
	in.Critical[0].Seconds = 7 * 86400 / 5 // 20% of the selection
	if fs := Review(in); fs[0].Severity != "critical" {
		t.Fatalf("20%% of the period must be critical: %+v", fs)
	}
	in.Critical[0].Seconds = 0
	if fs := Review(in); len(fs) != 0 {
		t.Fatalf("control: %+v", fs)
	}
}

func TestCacheHitDrop(t *testing.T) {
	in := Inputs{
		Projects:     []ProjectStat{{CWD: "/p/a", Turns: 500, CacheHit: 0.88}, {CWD: "/p/b", Turns: 50, CacheHit: 0.10}},
		PrevProjects: []ProjectStat{{CWD: "/p/a", Turns: 400, CacheHit: 0.97}, {CWD: "/p/b", Turns: 500, CacheHit: 0.95}},
	}
	fs := Review(in)
	// /p/b has too few turns in the current period; only /p/a fires
	if kinds(fs) != "cache_hit_drop" || fs[0].Scope["project"] != "/p/a" || fs[0].Severity != "info" {
		t.Fatalf("%+v", fs)
	}
	in.Projects[0].CacheHit = 0.93 // 4-point drop: under the 5-point threshold
	if fs := Review(in); len(fs) != 0 {
		t.Fatalf("control: %+v", fs)
	}
}

func TestSpendSpike(t *testing.T) {
	in := Inputs{Tokens: 3_000_000_000, PrevTokens: 1_000_000_000,
		Projects:     []ProjectStat{{CWD: "/p/a", Turns: 10, Tokens: 2_500_000_000, PrevTokens: 500_000_000}},
		PrevProjects: []ProjectStat{{CWD: "/p/a", Turns: 10, Tokens: 500_000_000}}}
	fs := Review(in)
	if kinds(fs) != "spend_spike,spend_spike" || fs[1].Scope["project"] != "/p/a" {
		t.Fatalf("%+v", fs)
	}
	in.Tokens = 1_400_000_000 // 1.4x: under 1.5x
	in.Projects[0].Tokens = 700_000_000
	if fs := Review(in); len(fs) != 0 {
		t.Fatalf("control: %+v", fs)
	}
	in.Tokens, in.PrevTokens = 900_000_000, 100_000_000 // 9x but under the 1B floor
	in.Projects = nil
	if fs := Review(in); len(fs) != 0 {
		t.Fatalf("floor: %+v", fs)
	}
}

func TestOrderingAndCap(t *testing.T) {
	in := Inputs{SelectionSeconds: 86400,
		Models:   []ModelStat{{Model: "m", Unpriced: 1, Tokens: 1}},
		Critical: []AccountCritical{{Label: "a", Seconds: 50000, Episodes: 1}},
		Tokens:   5_000_000_000, PrevTokens: 1_000_000_000}
	fs := Review(in)
	if kinds(fs) != "time_in_critical,unpriced_model,spend_spike" {
		t.Fatalf("severity order: %s", kinds(fs))
	}
	var many []ModelStat
	for i := 0; i < 12; i++ {
		many = append(many, ModelStat{Model: "m" + string(rune('a'+i)), Unpriced: 1, Tokens: int64(i)})
	}
	capped := Review(Inputs{Models: many})
	if len(capped) != 8 {
		t.Fatalf("cap at 8, got %d", len(capped))
	}
	// The cap must keep the 8 LARGEST findings, not the first 8 appended: on a
	// real fleet with more than 8 same-kind, same-severity findings (e.g. 12
	// unpriced models), dropping the small ones and keeping the big ones is
	// the whole point of a findings list.
	for _, f := range capped {
		switch f.Scope["model"] {
		case "ma", "mb", "mc", "md":
			t.Fatalf("cap kept a small finding instead of a large one: %+v", capped)
		}
	}
	if capped[0].Scope["model"] != "ml" || capped[7].Scope["model"] != "me" {
		t.Fatalf("cap survivors not sorted by descending magnitude: %+v", capped)
	}
}

func TestNowFindings(t *testing.T) {
	now := time.Date(2026, 9, 2, 12, 0, 0, 0, time.UTC)
	old := now.Add(-2 * time.Hour)
	in := NowInputs{Now: now,
		Windows:   []WindowStat{{Label: "a@x", FiveHourPct: 82}, {Label: "b@x", FiveHourPct: 95}, {Label: "c@x", FiveHourPct: 10}},
		Endpoints: []EndpointSeen{{Label: "macmini-zx", LastSeen: &old}, {Label: "fresh", LastSeen: &now}, {Label: "never"}},
		Live:      []LiveStat{{SessionID: "s1", CWD: "/p", Tokens: 250_000_000}, {SessionID: "s2", Tokens: 1000}}}
	fs := Now(in)
	if kinds(fs) != "window_high,window_high,stale_agent,stale_agent,live_runaway" {
		t.Fatalf("%s", kinds(fs))
	}
	if fs[0].Severity != "critical" || fs[1].Severity != "warning" || !strings.Contains(fs[0].Title, "b@x") {
		t.Fatalf("%+v", fs[:2])
	}
	in.Windows, in.Live = nil, nil
	in.Endpoints = []EndpointSeen{{Label: "fresh", LastSeen: &now}}
	if fs := Now(in); len(fs) != 0 {
		t.Fatalf("control: %+v", fs)
	}
}

// The free-allowance rule is the other half of pricing.Rates.FreeMonthlyTokens.
// An event inside the allowance prices to 0 because that is what the vendor
// charges; nothing in the pricing path can see the MONTH's total, so this rule
// is the only thing standing between "the allowance was exceeded" and every
// subsequent call still reporting 0.00.
func TestFreeAllowance(t *testing.T) {
	fs := freeAllowance([]FreeAllowanceStat{
		{Model: "over", Tokens: 1_400_000, Allowance: 1_000_000},
		{Model: "near", Tokens: 850_000, Allowance: 1_000_000},
		{Model: "fine", Tokens: 2_014, Allowance: 1_000_000},
		{Model: "exact", Tokens: 1_000_000, Allowance: 1_000_000},
		// No allowance declared: nothing to say.
		{Model: "none", Tokens: 9_000_000, Allowance: 0},
	})
	got := map[string]string{}
	for _, f := range fs {
		got[f.Scope["model"]] = f.Severity
	}
	if got["over"] != "critical" {
		t.Errorf("an exceeded allowance is %q; it is money starting to be charged and reported as free", got["over"])
	}
	// Exactly at the allowance is spent, not nearly spent: the next call costs.
	if got["exact"] != "critical" {
		t.Errorf("an allowance used to the last token is %q; want critical", got["exact"])
	}
	if got["near"] != "warning" {
		t.Errorf("85%% of an allowance is %q; want a warning", got["near"])
	}
	if _, ok := got["fine"]; ok {
		t.Error("0.2% of an allowance raised a finding; this rule must not fire on ordinary usage")
	}
	if _, ok := got["none"]; ok {
		t.Error("a model with no declared allowance raised a finding")
	}
}

// The exceeded case must outrank the approaching one however they arrive: one
// is money already being mischarged, the other is a heads-up.
func TestFreeAllowance_ExceededOutranksApproaching(t *testing.T) {
	fs := finish(freeAllowance([]FreeAllowanceStat{
		{Model: "near", Tokens: 999_999, Allowance: 1_000_000},
		{Model: "over", Tokens: 1_000_001, Allowance: 1_000_000},
	}), nil, false)
	if len(fs) < 2 {
		t.Fatalf("got %d findings; want both", len(fs))
	}
	if fs[0].Scope["model"] != "over" {
		t.Errorf("first finding is %q; the exceeded allowance must lead", fs[0].Scope["model"])
	}
}

// Owner is the answer to "who do I go to about this", and it has exactly two
// correct shapes: named exactly, or absent. This covers both, because both are
// load-bearing -- an owner GUESSED onto a fleet-wide finding sends somebody
// after a machine that is not theirs, and is believed precisely because the
// page printed it.
func TestOwnerFilledWhenKnownAbsentWhenNot(t *testing.T) {
	now := time.Date(2026, 9, 2, 12, 0, 0, 0, time.UTC)
	old := now.Add(-2 * time.Hour)

	fs := Now(NowInputs{Now: now,
		// A window belongs to a SUBSCRIPTION, which many logins draw on: no owner.
		Windows: []WindowStat{{Label: "a@x", FiveHourPct: 95}},
		Endpoints: []EndpointSeen{
			// Both halves known: the stale-agent alert can finally say whose
			// machine it is and which team owns the spend.
			{Label: "macmini-zx", LastSeen: &old, OSUser: "verky", Team: "infra"},
			// Enrolled but never allocated to a team. Half-known is still worth
			// carrying -- "go find verky" beats "go find somebody".
			{Label: "never-allocated", OSUser: "ci"},
			// An endpoint the hub holds no attribution for at all. It must still
			// produce its finding, with no owner rather than no alert.
			{Label: "anonymous"},
		},
		Live: []LiveStat{{SessionID: "s1", CWD: "/p", Tokens: 250_000_000, OSUser: "verky", Team: "infra"}},
	})

	byKind := map[string][]Finding{}
	for _, f := range fs {
		byKind[f.Kind] = append(byKind[f.Kind], f)
	}
	if n := len(byKind["stale_agent"]); n != 3 {
		t.Fatalf("stale_agent count = %d, want 3 -- a missing owner must not drop the finding: %s", n, kinds(fs))
	}
	stale := byKind["stale_agent"]
	// Ordered by weight: "never reported" outranks any elapsed time, so the two
	// never-reported endpoints lead and macmini-zx (2h) comes last.
	var named, halfNamed, unnamed *Finding
	for i := range stale {
		switch stale[i].Args["label"] {
		case "macmini-zx":
			named = &stale[i]
		case "never-allocated":
			halfNamed = &stale[i]
		case "anonymous":
			unnamed = &stale[i]
		}
	}
	if named == nil || halfNamed == nil || unnamed == nil {
		t.Fatalf("missing one of the three stale findings: %+v", stale)
	}
	if named.Owner == nil || named.Owner.User != "verky" || named.Owner.Team != "infra" {
		t.Errorf("stale agent with a known login and team: Owner = %+v, want verky/infra", named.Owner)
	}
	if halfNamed.Owner == nil || halfNamed.Owner.User != "ci" || halfNamed.Owner.Team != "" {
		t.Errorf("unallocated endpoint: Owner = %+v, want user ci and an empty team", halfNamed.Owner)
	}
	// nil, not &Owner{}: "nobody named" must be ONE shape, so a consumer's
	// presence check cannot be true for a finding that names no one.
	if unnamed.Owner != nil {
		t.Errorf("endpoint with no attribution: Owner = %+v, want nil", unnamed.Owner)
	}
	if w := byKind["window_high"]; len(w) != 1 || w[0].Owner != nil {
		t.Errorf("a rate-limit window is a subscription's, not a person's: %+v", w)
	}
	if l := byKind["live_runaway"]; len(l) != 1 || l[0].Owner == nil || l[0].Owner.User != "verky" {
		t.Errorf("live runaway: %+v", l)
	}

	// The period rules: a session has one login on one endpoint; a model and a
	// project are shared, so neither may name anyone.
	review := Review(Inputs{
		SessionTokenMedian: 1_000,
		Sessions: []SessionStat{
			{SessionID: "abcdef123456", CWD: "/srv/api", Model: "claude-opus-5",
				Tokens: 400_000_000, Turns: 9, Duration: time.Hour, OSUser: "verky", Team: "infra"},
			{SessionID: "beefbeefbeef", CWD: "/srv/api", Model: "claude-opus-5",
				Tokens: 300_000_000, Turns: 9, Duration: time.Hour},
		},
		Models: []ModelStat{{Model: "qwen-plus", Tokens: 900, Unpriced: 19}},
	})
	var runaways, unpriced []Finding
	for _, f := range review {
		switch f.Kind {
		case "runaway_session":
			runaways = append(runaways, f)
		case "unpriced_model":
			unpriced = append(unpriced, f)
		}
	}
	if len(runaways) != 2 {
		t.Fatalf("want 2 runaway sessions, got %d: %s", len(runaways), kinds(review))
	}
	if runaways[0].Owner == nil || runaways[0].Owner.User != "verky" || runaways[0].Owner.Team != "infra" {
		t.Errorf("runaway session with a known login: Owner = %+v", runaways[0].Owner)
	}
	if runaways[1].Owner != nil {
		t.Errorf("runaway session the caller could not attribute: Owner = %+v, want nil", runaways[1].Owner)
	}
	if len(unpriced) != 1 || unpriced[0].Owner != nil {
		t.Errorf("a model is used fleet-wide and has no owner: %+v", unpriced)
	}
}

// A Claude setup token (claude-fleet#1463) cannot be refreshed: the reminder
// starts a month out, turns critical in the last week, and stays critical once
// it has ended — the day the lease starts being refused.
func TestSetupTokenReminder(t *testing.T) {
	now := time.Date(2026, 10, 4, 12, 0, 0, 0, time.UTC)
	day := 24 * time.Hour
	fs := Now(NowInputs{Now: now, SetupTokens: []SetupToken{
		{PrincipalID: "pool", Provider: "claude", Account: "far", ExpiresAt: now.Add(400 * day)},
		{PrincipalID: "pool", Provider: "claude", Account: "soon", ExpiresAt: now.Add(20*day + time.Hour)},
		{PrincipalID: "pool", Provider: "claude", Account: "week", ExpiresAt: now.Add(5 * day)},
		{PrincipalID: "wecom-bob", Provider: "claude", Account: "gone", ExpiresAt: now.Add(-2 * day)},
	}})
	if kinds(fs) != "cred_setup_token,cred_setup_token,cred_setup_token" {
		t.Fatalf("%s", kinds(fs))
	}
	by := map[string]Finding{}
	for _, f := range fs {
		by[f.Args["account"]] = f
	}
	if f := by["soon"]; f.Severity != "warning" || f.Template != TmplCredSetupExpiring || !strings.Contains(f.Title, "soon (pool · claude) expires in 20 days") {
		t.Fatalf("soon: %+v", f)
	}
	if f := by["week"]; f.Severity != "critical" || f.Template != TmplCredSetupExpiring || f.Args["left"] != "5 days" {
		t.Fatalf("week: %+v", f)
	}
	if f := by["gone"]; f.Severity != "critical" || f.Template != TmplCredSetupExpired || !strings.Contains(f.Title, "gone (wecom-bob · claude) expired 2 days ago") ||
		f.Detail != "expired 2026-10-02" {
		t.Fatalf("gone: %+v", f)
	}
	// Critical first: the ones with the least time lead the list.
	if fs[0].Severity != "critical" || fs[2].Severity != "warning" {
		t.Fatalf("order: %s %s %s", fs[0].Severity, fs[1].Severity, fs[2].Severity)
	}
	for _, f := range fs {
		if f.Link != "/credentials" || f.ID == "" {
			t.Fatalf("link/id: %+v", f)
		}
	}
	// Two rows, two identities: muting one does not silence the other.
	if by["soon"].ID == by["week"].ID {
		t.Fatal("two setup tokens share a finding id")
	}
}

// An account whose credential cannot be renewed is one critical finding per
// (provider, account) carrying the command that fixes it; any other login
// state is not a finding; a severity change keeps the Problem and moves the ID.
func TestAccountReauth(t *testing.T) {
	fs := Now(NowInputs{Now: time.Date(2026, 10, 5, 12, 0, 0, 0, time.UTC), Logins: []LoginState{
		{Provider: "codex", Account: "ops@example.com", Where: "m5:default, m4:work", State: "reauth_required",
			Reason: "Access token expired and no refresh credential is available", Command: "codex login --device-auth"},
		{Provider: "codex", Account: "fine@example.com", Where: "m5:fine", State: "valid"},
		{Provider: "codex", Account: "due@example.com", Where: "m5:due", State: "refresh_due"},
		{Provider: "claude", Account: "pool/icloud", State: "reauth_required"},
	}})
	if kinds(fs) != "account_login,account_login" {
		t.Fatalf("%s", kinds(fs))
	}
	by := map[string]Finding{}
	for _, f := range fs {
		by[f.Args["account"]] = f
	}
	f := by["ops@example.com"]
	if f.Severity != "critical" || f.Template != TmplAccountReauth || f.Link != "/credentials" ||
		f.Title != "account ops@example.com (codex · m5:default, m4:work) needs re-login — run `codex login --device-auth`" ||
		f.Detail != "Access token expired and no refresh credential is available" {
		t.Fatalf("ops: %+v", f)
	}
	// No machine, no command, no reason: the sentence still stands.
	if g := by["pool/icloud"]; g.Args["where"] != "-" || g.Args["command"] != "sign in again" || g.Detail == "" || g.ID == f.ID || g.Problem == f.Problem {
		t.Fatalf("pool: %+v", g)
	}
	// Problem is the identity minus severity/template: the setup token that
	// turns critical is the same problem with a new id.
	now := time.Date(2026, 10, 4, 12, 0, 0, 0, time.UTC)
	tok := func(days int) Finding {
		return Now(NowInputs{Now: now, SetupTokens: []SetupToken{{PrincipalID: "pool", Provider: "claude", Account: "a", ExpiresAt: now.Add(time.Duration(days) * 24 * time.Hour)}}})[0]
	}
	warn, crit := tok(20), tok(3)
	if warn.ID == crit.ID || warn.Problem != crit.Problem || warn.Problem == "" {
		t.Fatalf("warn %s/%s crit %s/%s", warn.ID, warn.Problem, crit.ID, crit.Problem)
	}
	if other := tok(20); other.Problem != warn.Problem {
		t.Fatal("Problem is not stable across evaluations")
	}
}

// Uncapped keeps every finding; the default keeps a page's eight.
func TestUncapped(t *testing.T) {
	var ws []WindowStat
	for i := 0; i < 12; i++ {
		ws = append(ws, WindowStat{AccountUUID: fmt.Sprintf("acct-%d", i), Label: fmt.Sprintf("a%d@x", i), FiveHourPct: 95})
	}
	if n := len(Now(NowInputs{Windows: ws})); n != maxFindings {
		t.Fatalf("capped: %d findings, want %d", n, maxFindings)
	}
	if n := len(Now(NowInputs{Windows: ws, Uncapped: true})); n != 12 {
		t.Fatalf("uncapped: %d findings, want 12", n)
	}
}
