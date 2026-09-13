package store

import (
	"fmt"
	"math"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/ccquota/internal/model"
)

// THE GUARD (issue #2). Sibling to plans_test.go's guard, which keeps real
// subscription spend out of the notional token figure; this one keeps the
// three kinds of money inside cost_usd apart from each other.
//
// It needs to be a test rather than a convention because the failure is
// silent. A blended cost aggregate returns a plausible number: nothing errors,
// nothing looks empty, and the first sign of trouble is somebody acting on a
// figure that was an API-equivalent estimate and a real invoice added
// together. Every aggregate below is checked against per-source arithmetic
// chosen so that a blend is unmistakable.

// The fixture's per-source costs are order-of-magnitude apart so that any
// accidental sum is a number that cannot be produced any other way:
//
//	claude   3 events x $1    = $3     notional
//	codex    2 events x $10   = $20    notional
//	gateway  1 event  x $100  = $100   BILLED
//
// notional = 23, billed = 100, and the forbidden blend = 123.
const (
	guardClaudeCost   = 3.0
	guardCodexCost    = 20.0
	guardGatewayCost  = 100.0
	guardNotionalCost = guardClaudeCost + guardCodexCost
	guardBlended      = guardNotionalCost + guardGatewayCost
)

var guardBase = time.Date(2026, 9, 1, 12, 0, 0, 0, time.UTC)

// seedThreeSources puts all three kinds of money in one account, one endpoint,
// one project, one user and one hour, so that EVERY breakdown axis produces a
// bucket that spans sources. A fixture that separated them by project would
// let a blending aggregate pass by accident.
func seedThreeSources(t *testing.T, s *Store) {
	t.Helper()
	seedAccount(t, s, "acct-a", "ep-a1")
	mk := func(source, uuid string, cost float64, session string) model.UsageEvent {
		c := cost
		return model.UsageEvent{
			Source: source, AccountUUID: "acct-a", EndpointID: "ep-a1",
			MessageUUID: uuid, SessionID: session, TS: guardBase,
			Model: "m-" + source, OutputTokens: 100, CostUSD: &c,
			CWD: "/w", GitBranch: "main", OSUser: "verkyyi", Effort: "high", Entrypoint: "cli",
		}
	}
	evs := []model.UsageEvent{
		mk(model.SourceClaude, "c1", 1, "s-claude"),
		mk(model.SourceClaude, "c2", 1, "s-claude"),
		mk(model.SourceClaude, "c3", 1, "s-claude"),
		mk(model.SourceCodex, "x1", 10, "s-codex"),
		mk(model.SourceCodex, "x2", 10, "s-codex"),
		mk(model.SourceGateway, "g1", 100, "s-gateway"),
	}
	if _, _, err := s.InsertEvents(evs); err != nil {
		t.Fatal(err)
	}
}

func guardFilter() Filter {
	return Filter{Account: "acct-a", Start: guardBase.Add(-time.Hour), End: guardBase.Add(time.Hour)}
}

// checkSplit asserts one aggregate kept the three kinds apart.
func checkSplit(t *testing.T, what string, c CostBySource) {
	t.Helper()
	for _, want := range []struct {
		source string
		cost   float64
		kind   string
	}{
		{model.SourceClaude, guardClaudeCost, model.CostNotional},
		{model.SourceCodex, guardCodexCost, model.CostNotional},
		{model.SourceGateway, guardGatewayCost, model.CostBilled},
	} {
		got, ok := c.Of(want.source)
		if !ok {
			t.Errorf("%s: no %s entry in %+v", what, want.source, c)
			continue
		}
		if !near(got.CostUSD, want.cost) {
			t.Errorf("%s: %s cost = %v, want %v (full split %+v)", what, want.source, got.CostUSD, want.cost, c)
		}
		if got.Kind != want.kind {
			t.Errorf("%s: %s kind = %q, want %q", what, want.source, got.Kind, want.kind)
		}
	}
	if !near(c.Notional(), guardNotionalCost) {
		t.Errorf("%s: Notional() = %v, want %v", what, c.Notional(), guardNotionalCost)
	}
	if !near(c.Billed(), guardGatewayCost) {
		t.Errorf("%s: Billed() = %v, want %v", what, c.Billed(), guardGatewayCost)
	}
	// The whole point: no figure anywhere in the aggregate is the blend.
	for _, sc := range c {
		if near(sc.CostUSD, guardBlended) {
			t.Errorf("%s: %s carries the BLENDED total %v — costs were summed across sources", what, sc.Source, sc.CostUSD)
		}
	}
	if near(c.Notional()+c.Billed(), guardBlended) && len(c) == 1 {
		t.Errorf("%s: the split collapsed to one entry: %+v", what, c)
	}
}

func near(a, b float64) bool { return math.Abs(a-b) < 1e-9 }

func TestNoCostAggregateCrossesSources(t *testing.T) {
	s := newStore(t)
	seedThreeSources(t, s)
	f := guardFilter()

	// Every dimension whose buckets can span sources. BySource is left out
	// on purpose: its rows are one source each by construction, and it is
	// checked separately below.
	crossing := []Dimension{ByEndpoint, ByProject, ByModel, ByUser, ByBranch, ByAccount, ByEffort, ByEntrypoint}

	for _, d := range crossing {
		if d == ByModel {
			// The fixture gives each source its own model id, so a by-model
			// bucket cannot span sources; skip it here and let the total
			// across its rows be checked instead.
			var all CostBySource
			rows, err := s.UsageBy("acct-a", d, f.Start, f.End, 50)
			if err != nil {
				t.Fatal(err)
			}
			for _, r := range rows {
				all.Add(r.Cost)
			}
			checkSplit(t, "UsageBy(model) summed over rows", all)
			continue
		}
		rows, err := s.UsageBy("acct-a", d, f.Start, f.End, 50)
		if err != nil {
			t.Fatalf("UsageBy %s: %v", d, err)
		}
		if len(rows) != 1 {
			t.Fatalf("UsageBy %s: want one bucket spanning all sources, got %d: %+v", d, len(rows), rows)
		}
		checkSplit(t, "UsageBy("+string(d)+")", rows[0].Cost)

		frows, err := s.UsageByFiltered(f, d, 50)
		if err != nil {
			t.Fatalf("UsageByFiltered %s: %v", d, err)
		}
		if len(frows) != 1 {
			t.Fatalf("UsageByFiltered %s: got %d buckets: %+v", d, len(frows), frows)
		}
		checkSplit(t, "UsageByFiltered("+string(d)+")", frows[0].Cost)
	}

	// History: one time bucket holding all three.
	hist, err := s.History("acct-a", Hourly, f.Start, f.End)
	if err != nil {
		t.Fatal(err)
	}
	if len(hist) != 1 {
		t.Fatalf("History: got %d buckets: %+v", len(hist), hist)
	}
	checkSplit(t, "History", hist[0].Cost)

	// Summary: the KPI strip's own totals.
	sum, err := s.Summary(f)
	if err != nil {
		t.Fatal(err)
	}
	checkSplit(t, "Summary", sum.Cost)

	// SummaryWithPricing reads through a transaction; same rule.
	psum, _, err := s.SummaryWithPricing(f)
	if err != nil {
		t.Fatal(err)
	}
	checkSplit(t, "SummaryWithPricing", psum.Cost)

	// HourlyByModel, folded across its rows.
	hours, err := s.HourlyByModel(f)
	if err != nil {
		t.Fatal(err)
	}
	var hourly CostBySource
	for _, h := range hours {
		hourly.Add(h.Cost)
	}
	checkSplit(t, "HourlyByModel", hourly)

	// The per-user page.
	us, err := s.UserSummary("verkyyi", f.Start, f.End)
	if err != nil {
		t.Fatal(err)
	}
	checkSplit(t, "UserSummary", us.Cost)

	ub, err := s.UsageByUser("verkyyi", ByProject, f.Start, f.End, 50)
	if err != nil {
		t.Fatal(err)
	}
	if len(ub) != 1 {
		t.Fatalf("UsageByUser: got %d buckets: %+v", len(ub), ub)
	}
	checkSplit(t, "UsageByUser", ub[0].Cost)
}

// Sessions takes the other half of the rule: rather than carrying a split, a
// session row is SCOPED to one source, and says which. A row whose cost_usd
// were a blend would show up here as a session with more money than any single
// source spent.
func TestSessionRowsAreScopedToOneSource(t *testing.T) {
	s := newStore(t)
	seedThreeSources(t, s)

	rows, err := s.Sessions(guardFilter(), "cost", 50, 0)
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]struct {
		cost float64
		kind string
	}{
		"s-claude":  {guardClaudeCost, model.CostNotional},
		"s-codex":   {guardCodexCost, model.CostNotional},
		"s-gateway": {guardGatewayCost, model.CostBilled},
	}
	if len(rows) != len(want) {
		t.Fatalf("got %d session rows, want %d: %+v", len(rows), len(want), rows)
	}
	for _, r := range rows {
		w, ok := want[r.SessionID]
		if !ok {
			t.Fatalf("unexpected session %q", r.SessionID)
		}
		if !near(r.CostUSD, w.cost) {
			t.Errorf("session %s cost = %v, want %v", r.SessionID, r.CostUSD, w.cost)
		}
		if r.CostKind != w.kind {
			t.Errorf("session %s kind = %q, want %q", r.SessionID, r.CostKind, w.kind)
		}
		if r.Source == "" {
			t.Errorf("session %s carries no source, so its cost has no stated kind of money", r.SessionID)
		}
		if near(r.CostUSD, guardBlended) {
			t.Errorf("session %s carries the blended total", r.SessionID)
		}
	}
	// Sorted by cost, descending: the ranking still works, it just never sums.
	if rows[0].SessionID != "s-gateway" {
		t.Errorf("sort=cost gave %q first, want s-gateway", rows[0].SessionID)
	}
}

// A source filter is the other sanctioned way to make a cost figure mean one
// thing. Asking for one source must return that source's money and nothing
// else's.
func TestSourceFilterScopesCost(t *testing.T) {
	s := newStore(t)
	seedThreeSources(t, s)
	for _, tc := range []struct {
		source string
		cost   float64
	}{
		{model.SourceClaude, guardClaudeCost},
		{model.SourceCodex, guardCodexCost},
		{model.SourceGateway, guardGatewayCost},
	} {
		f := guardFilter()
		f.Source = tc.source
		sum, err := s.Summary(f)
		if err != nil {
			t.Fatal(err)
		}
		got, _ := sum.Cost.Of(tc.source)
		if !near(got.CostUSD, tc.cost) {
			t.Errorf("source=%s: cost = %v, want %v", tc.source, got.CostUSD, tc.cost)
		}
		for _, sc := range sum.Cost {
			if sc.Source != tc.source && sc.CostUSD != 0 {
				t.Errorf("source=%s leaked %s money: %+v", tc.source, sc.Source, sc)
			}
		}
	}
}

// A source this build has no rate basis for must land in neither fold. The
// alternative — defaulting it into "notional" — is how a real charge would
// quietly become an estimate the day a fourth collector ships.
func TestUnknownSourceIsInNeitherFold(t *testing.T) {
	s := newStore(t)
	seedThreeSources(t, s)
	c := 7.0
	if _, _, err := s.InsertEvents([]model.UsageEvent{{
		Source: "some-future-thing", AccountUUID: "acct-a", EndpointID: "ep-a1",
		MessageUUID: "f1", SessionID: "s-future", TS: guardBase, Model: "m-future",
		OutputTokens: 10, CostUSD: &c, CWD: "/w", OSUser: "verkyyi",
	}}); err != nil {
		t.Fatal(err)
	}
	sum, err := s.Summary(guardFilter())
	if err != nil {
		t.Fatal(err)
	}
	if !near(sum.Cost.Notional(), guardNotionalCost) {
		t.Errorf("an unclassified source entered Notional(): %v", sum.Cost.Notional())
	}
	if !near(sum.Cost.Billed(), guardGatewayCost) {
		t.Errorf("an unclassified source entered Billed(): %v", sum.Cost.Billed())
	}
	un := sum.Cost.Unclassified()
	if len(un) != 1 || !near(un[0].CostUSD, 7) {
		t.Fatalf("unclassified money was dropped rather than surfaced: %+v", sum.Cost)
	}
}

// Whatever the split says, the underlying rows must still be there: a "split"
// that quietly lost a source would satisfy every assertion above.
func TestSplitAccountsForEveryEvent(t *testing.T) {
	s := newStore(t)
	seedThreeSources(t, s)
	sum, err := s.Summary(guardFilter())
	if err != nil {
		t.Fatal(err)
	}
	if sum.Cost.Events() != sum.Events {
		t.Errorf("split covers %d events, summary counted %d", sum.Cost.Events(), sum.Events)
	}
	if sum.Events != 6 {
		t.Errorf("fixture drift: %d events", sum.Events)
	}
}

// The structural half of the guard: a cost aggregate added to this package
// LATER must go through costSplit, or say in the SQL itself why it does not.
//
// The behavioural tests above can only check the aggregates that exist today.
// This one checks the shape of the code, so that the next SUM(cost_usd) — the
// one nobody thought to write a test for — cannot land silently. An
// aggregate whose GROUP BY already includes source is legitimate and declares
// itself with a /* cost-split-exempt: why */ comment in the query.
func TestEveryRawCostSumDeclaresItself(t *testing.T) {
	files, err := filepath.Glob("*.go")
	if err != nil {
		t.Fatal(err)
	}
	const marker = "cost-split-exempt"
	for _, name := range files {
		if strings.HasSuffix(name, "_test.go") {
			continue
		}
		b, err := os.ReadFile(name)
		if err != nil {
			t.Fatal(err)
		}
		for i, line := range strings.Split(string(b), "\n") {
			if !strings.Contains(line, "SUM(cost_usd") || strings.Contains(line, marker) {
				continue
			}
			t.Errorf("%s:%d sums cost_usd without going through costSplit and without a "+
				"/* %s: why */ note:\n\t%s\n\nA cost aggregate must either split by source "+
				"(see costSplit in cost.go) or be scoped to one source by its GROUP BY.",
				name, i+1, marker, strings.TrimSpace(line))
		}
	}
}

// costSplit's generated SQL must actually name every source this build knows.
// A source added to model.Sources and forgotten here would silently fall into
// the "(other)" bucket and out of both folds.
func TestCostSplitCoversEverySource(t *testing.T) {
	for _, split := range []costSplit{eventCostSplit, hourlyCostSplit} {
		for _, s := range model.Sources {
			if !strings.Contains(split.sel, "'"+s+"'") {
				t.Errorf("costSplit does not name source %q:\n%s", s, split.sel)
			}
		}
		if got, want := len(split.sources), len(model.Sources)+1; got != want {
			t.Errorf("costSplit has %d column groups, want %d (every source plus one for the rest)", got, want)
		}
	}
	// And every known source has a kind, so nothing real lands in
	// CostUnknown.
	for _, s := range model.Sources {
		if model.CostKind(s) == model.CostUnknown {
			t.Errorf("source %q has no cost kind: it would be reported in neither Notional() nor Billed()", s)
		}
	}
	if model.CostKind("not-a-source") != model.CostUnknown {
		t.Error("an unrecognised source was classified rather than flagged")
	}
}

// CostBySource must not grow a blended accessor. This is a design constraint,
// not a behaviour, so the test states it where the next person to add a
// convenience Total() will read it.
func TestCostBySourceHasNoBlendedTotal(t *testing.T) {
	var c CostBySource
	c.Add(CostBySource{
		{Source: model.SourceClaude, Kind: model.CostNotional, CostUSD: 1, Events: 1},
		{Source: model.SourceGateway, Kind: model.CostBilled, CostUSD: 100, Events: 1},
	})
	// If a Total() ever appears, this line stops compiling only if it is
	// removed again -- so assert the intent in words the reviewer will see.
	if fmt.Sprintf("%.2f/%.2f", c.Notional(), c.Billed()) != "1.00/100.00" {
		t.Fatalf("folds are wrong: %+v", c)
	}
	if near(c.Notional(), 101) || near(c.Billed(), 101) {
		t.Fatal("a fold produced the blended figure")
	}
}

// Real money must answer to the same scope as everything shown beside it. A
// hub-wide invoice figure printed next to one subscription's usage is correct
// about something the reader is not looking at, which is the same class of
// error as a blended cost column.
func TestSubscriptionSpendHonoursTheAccountScope(t *testing.T) {
	s := newStore(t)
	seedAccount(t, s, "acct-a", "ep-a1")
	seedAccount(t, s, "acct-b", "ep-b1")
	if err := s.SetPlanPrice(price("max", 200, day(2020, 1, 1))); err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC()
	from := now.Add(-averageMonth)

	all, err := s.SubscriptionSpendOver(AllAccounts, from, now)
	if err != nil {
		t.Fatal(err)
	}
	if len(all) != 1 || all[0].Seats != 2 {
		t.Fatalf("hub-wide spend = %+v, want one plan at 2 seats", all)
	}

	one, err := s.SubscriptionSpendOver("acct-a", from, now)
	if err != nil {
		t.Fatal(err)
	}
	if len(one) != 1 || one[0].Seats != 1 {
		t.Fatalf("account-scoped spend = %+v, want one plan at 1 seat", one)
	}
	if one[0].Amount >= all[0].Amount {
		t.Errorf("one account costs %v, the whole hub %v — the scope was ignored", one[0].Amount, all[0].Amount)
	}
	if _, err := s.SubscriptionSpendOver("", from, now); err == nil {
		t.Error(`an empty account was accepted; "which subscriptions is this the bill for" has no default`)
	}
}
