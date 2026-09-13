// internal/store/rollup_equiv_test.go
package store

import (
	"fmt"
	"math/rand"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/ccquota/internal/model"
)

// The rollup must agree with the raw events for every filter and every
// hour-aligned range. If this ever fails, the rollup is lying to the dashboard.
func TestRollupEquivalence(t *testing.T) {
	s := newStore(t)
	seedAccount(t, s, "acct-a", "ep-a1")
	seedAccount(t, s, "acct-b", "ep-b1")
	// One endpoint carries a team so ByTeam's hand-rebound join (usage_hourly
	// vs. usage_events) actually discriminates rather than comparing two
	// all-unassigned rows.
	if err := s.SetEndpointTeam("ep-a1", "red"); err != nil {
		t.Fatal(err)
	}
	rng := rand.New(rand.NewSource(42))
	base := time.Date(2026, 8, 20, 0, 0, 0, 0, time.UTC)
	accounts := []string{"acct-a", "acct-b"}
	eps := map[string]string{"acct-a": "ep-a1", "acct-b": "ep-b1"}
	models := []string{"claude-opus-5", "claude-haiku-4-5", "claude-fable-5-1"}
	cwds := []string{"/p/one", "/p/two", "/p/three"}
	entrypoints := []string{"cli", "ide", ""}
	var evs []model.UsageEvent
	for i := 0; i < 600; i++ {
		acct := accounts[rng.Intn(2)]
		e := ev(acct, eps[acct], fmt.Sprintf("u-%d", i), int64(rng.Intn(500)))
		e.TS = base.Add(time.Duration(rng.Intn(10*24*60)) * time.Minute)
		e.SessionID = fmt.Sprintf("s-%d", rng.Intn(25))
		e.Model, e.CWD = models[rng.Intn(3)], cwds[rng.Intn(3)]
		e.GitBranch = []string{"main", "feat"}[rng.Intn(2)]
		e.OSUser = []string{"u1", "u2"}[rng.Intn(2)]
		e.Effort = []string{"xhigh", "high", ""}[rng.Intn(3)]
		e.Entrypoint = entrypoints[rng.Intn(3)]
		e.InputTokens, e.CacheRead = int64(rng.Intn(50)), int64(rng.Intn(5000))
		e.IsSidechain = rng.Intn(6) == 0
		if e.Model == "claude-fable-5-1" {
			e.CostUSD = nil
		}
		evs = append(evs, e)
	}
	if _, _, err := s.InsertEvents(evs); err != nil {
		t.Fatal(err)
	}
	dims := []Dimension{ByEndpoint, ByProject, BySession, ByModel, ByBranch, ByUser, ByAccount, ByTeam, ByEffort, ByEntrypoint}
	for trial := 0; trial < 40; trial++ {
		f := Filter{Account: []string{"acct-a", "acct-b", AllAccounts}[rng.Intn(3)]}
		h1, h2 := rng.Intn(240), rng.Intn(240)
		if h1 > h2 {
			h1, h2 = h2, h1
		}
		f.Start, f.End = base.Add(time.Duration(h1)*time.Hour), base.Add(time.Duration(h2+1)*time.Hour)
		switch rng.Intn(5) {
		case 0:
			f.Model = models[rng.Intn(3)]
		case 1:
			f.CWD = cwds[rng.Intn(3)]
		case 2:
			f.OSUser = "u1"
		case 3:
			f.Session = fmt.Sprintf("s-%d", rng.Intn(25))
		}
		d := dims[rng.Intn(len(dims))]
		got, err := s.UsageByFiltered(f, d, 100)
		if err != nil {
			t.Fatal(err)
		}
		want, err := s.usageByEventsFiltered(f, d)
		if err != nil {
			t.Fatal(err)
		}
		if len(got) != len(want) {
			t.Fatalf("trial %d %+v by %s: rollup %d rows, events %d rows", trial, f, d, len(got), len(want))
		}
		for i := range got {
			g, w := got[i], want[i]
			if g.Key != w.Key || g.Events != w.Events || g.Tokens != w.Tokens || g.Unpriced != w.Unpriced ||
				g.Sidechain != w.Sidechain || costKey(g.Cost) != costKey(w.Cost) {
				t.Fatalf("trial %d %+v by %s row %d: rollup %+v vs events %+v", trial, f, d, i, g, w)
			}
		}
	}
}

// usageByEventsFiltered is the oracle: the same aggregate straight off usage_events.
func (s *Store) usageByEventsFiltered(f Filter, d Dimension) ([]Bucket, error) {
	col, err := d.column()
	if err != nil {
		return nil, err
	}
	where, args, err := f.where("ts")
	if err != nil {
		return nil, err
	}
	q := fmt.Sprintf(`SELECT %s AS k, COUNT(*), %s,
		COALESCE(SUM(CASE WHEN is_sidechain = 1 THEN input_tokens + output_tokens + cache_create_5m_tokens
		  + cache_create_1h_tokens + cache_read_tokens ELSE 0 END),0),
		%s
		FROM usage_events %s GROUP BY k ORDER BY 3 DESC, k LIMIT 100`, col, tokenSumExpr, eventCostSplit.sel, where)
	rows, err := s.db.Query(q, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Bucket
	for rows.Next() {
		var b Bucket
		cs := eventCostSplit.scan()
		if err := rows.Scan(append([]any{&b.Key, &b.Events, &b.Tokens, &b.Sidechain}, cs.dest()...)...); err != nil {
			return nil, err
		}
		b.Cost = cs.costs()
		b.Unpriced = b.Cost.Unpriced()
		out = append(out, b)
	}
	return out, rows.Err()
}

// costKey renders a split so two of them can be compared as one string,
// per source, without a float64 == float64.
func costKey(c CostBySource) string {
	var b strings.Builder
	for _, sc := range c {
		fmt.Fprintf(&b, "%s=%.6f/%d/%d;", sc.Source, sc.CostUSD, sc.Events, sc.Unpriced)
	}
	return b.String()
}

// Raw and rollup agree on every figure. They may disagree on provider for
// hours whose rollup row predates the dimension — that gap is documented by
// ProviderNote, and this pins it to provider alone: no total may move.
func TestRollupEquiv_ProviderGapDoesNotMoveTotals(t *testing.T) {
	s := newStore(t)
	seedAccount(t, s, "acct", "ep1")

	e := ev("acct", "ep1", "gp1", 100)
	e.Source = model.SourceGateway
	e.Model = "qwen-plus"
	e.Details = &model.UsageDetails{Provider: "dashscope.aliyuncs.com"}
	if _, _, err := s.InsertEvents([]model.UsageEvent{e}); err != nil {
		t.Fatal(err)
	}
	// Simulate a rollup row written before the dimension existed.
	if _, err := s.DB().Exec(`UPDATE usage_hourly SET provider = ''`); err != nil {
		t.Fatal(err)
	}

	var rawTok, rollTok int64
	if err := s.DB().QueryRow(`SELECT COALESCE(SUM(output_tokens),0) FROM usage_events`).Scan(&rawTok); err != nil {
		t.Fatal(err)
	}
	if err := s.DB().QueryRow(`SELECT COALESCE(SUM(output_tokens),0) FROM usage_hourly`).Scan(&rollTok); err != nil {
		t.Fatal(err)
	}
	if rawTok != rollTok {
		t.Errorf("totals moved: raw %d, rollup %d", rawTok, rollTok)
	}
}
