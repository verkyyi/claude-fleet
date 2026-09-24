package api

import (
	"encoding/json"
	"fmt"
	"path/filepath"
	"testing"
	"time"

	"github.com/verkyyi/ccquota/internal/model"
	"github.com/verkyyi/ccquota/internal/pricing"
	"github.com/verkyyi/ccquota/internal/store"
)

// perRowAccountUsageView is what AccountUsageView did before issue #49: one
// whole-ledger Summary per observation row, 1970 → 2200 every time.
//
// It stays here as the oracle. The grouped query that replaced it is only
// allowed to be faster if it is byte-identical, and the cheapest way to keep
// that claim honest is to keep the slow version around and diff the JSON.
func (s *Server) perRowAccountUsageView(account, source string) (map[string]any, error) {
	rows, err := s.Store.AccountUsage(account, source)
	if err != nil {
		return nil, err
	}
	type observation struct {
		model.AccountUsage
		LocalTokens   int64 `json:"local_attributed_tokens"`
		LocalRequests int64 `json:"local_attributed_requests"`
	}
	out := []observation{}
	for _, u := range rows {
		sum, err := s.Store.Summary(store.Filter{Account: u.AccountUUID, Source: u.Source,
			Start: time.Unix(0, 0).UTC(), End: time.Date(2200, 1, 1, 0, 0, 0, 0, time.UTC)})
		if err != nil {
			return nil, err
		}
		out = append(out, observation{AccountUsage: u, LocalTokens: sum.Tokens, LocalRequests: sum.Events})
	}
	return map[string]any{"observations": out, "comparable": false, "note": accountUsageNoteEN}, nil
}

// seedAccountUsageLedger builds a ledger with several (account, source) pairs
// — the grain an observation row lands on, and therefore the grain that used
// to cost one full scan each — plus one account-wide observation per pair and
// one pair that reports to the vendor without any local attribution at all.
func seedAccountUsageLedger(t testing.TB, st *store.Store, accounts int, hoursPerPair int) {
	t.Helper()
	base := time.Date(2026, 8, 31, 12, 0, 0, 0, time.UTC)
	sources := []string{model.SourceClaude, model.SourceCodex}
	var evs []model.UsageEvent
	for a := 0; a < accounts; a++ {
		acct := fmt.Sprintf("acct-%02d", a)
		ep := "ep-" + acct
		id := model.Identity{AccountUUID: acct, Email: acct + "@example.com",
			Hostname: ep, OS: "linux", Arch: "amd64", MachineID: "m-" + acct}
		if err := st.UpsertAccount(id, "max", "default_claude_max_20x"); err != nil {
			t.Fatal(err)
		}
		if err := st.Enroll(ep, ep, "hash-"+ep); err != nil {
			t.Fatal(err)
		}
		if _, _, err := st.TouchEndpoint(ep, id, "test", true, nil); err != nil {
			t.Fatal(err)
		}
		for si, src := range sources {
			for h := 0; h < hoursPerPair; h++ {
				cost := 1.5
				evs = append(evs, model.UsageEvent{
					AccountUUID: acct, EndpointID: ep, Source: src,
					MessageUUID: fmt.Sprintf("%s-%s-%d", acct, src, h),
					SessionID:   fmt.Sprintf("s-%s-%s", acct, src),
					TS:          base.Add(time.Duration(h) * time.Hour),
					Model:       "claude-sonnet-5", CWD: "/w", GitBranch: "main",
					InputTokens: int64(10 + si), OutputTokens: int64(100 + h), CacheRead: 900,
					CostUSD: &cost,
				})
			}
			lifetime := int64(1_000_000 + a*1000 + si)
			peak := int64(50_000 + a)
			if err := st.InsertAccountUsage(model.AccountUsage{
				Source: src, AccountUUID: acct, EndpointID: ep,
				ObservedAt:      base.Add(time.Duration(a) * time.Minute),
				LifetimeTokens:  &lifetime,
				PeakDailyTokens: &peak,
				Daily:           []model.DailyUsage{{Date: "2026-08-31", Tokens: int64(4242 + a)}},
			}); err != nil {
				t.Fatal(err)
			}
		}
	}
	if _, _, err := st.InsertEvents(evs); err != nil {
		t.Fatal(err)
	}
	// A vendor observation with nothing local behind it: the grouped query
	// returns no row for this pair, and the view must still print 0/0 rather
	// than drop the observation or borrow a neighbour's total.
	zero := int64(7)
	if err := st.InsertAccountUsage(model.AccountUsage{
		Source: model.SourceClaude, AccountUUID: "acct-unattributed", EndpointID: "ep-acct-00",
		ObservedAt: base, LifetimeTokens: &zero,
	}); err != nil {
		t.Fatal(err)
	}
}

// The endpoint's contract is that its JSON does not move. One grouped query
// has to answer exactly what N per-row Summary calls answered, across every
// scope the endpoint is asked for.
func TestAccountUsageView_GroupedMatchesPerRowSummary(t *testing.T) {
	h := newHarness(t)
	seedAccountUsageLedger(t, h.srv.Store, 3, 4)

	for _, sc := range []struct{ account, source string }{
		{"", ""},
		{"all", ""},
		{store.AllAccounts, ""},
		{"acct-01", ""},
		{"", model.SourceCodex},
		{"all", model.SourceClaude},
		{"acct-02", model.SourceCodex},
		{"acct-nope", ""},
	} {
		name := fmt.Sprintf("account=%q source=%q", sc.account, sc.source)
		got, err := h.srv.AccountUsageView(sc.account, sc.source)
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		want, err := h.srv.perRowAccountUsageView(sc.account, sc.source)
		if err != nil {
			t.Fatalf("%s (oracle): %v", name, err)
		}
		gotJSON, err := json.Marshal(got)
		if err != nil {
			t.Fatal(err)
		}
		wantJSON, err := json.Marshal(want)
		if err != nil {
			t.Fatal(err)
		}
		if string(gotJSON) != string(wantJSON) {
			t.Fatalf("%s: JSON moved\n got: %s\nwant: %s", name, gotJSON, wantJSON)
		}
	}
}

// The two numbers on a row must come from that row's own (account, source)
// pair. A map lookup is easy to key wrongly and the equivalence test above
// would still pass if BOTH sides were wrong, so pin the values literally.
func TestAccountUsageView_AttributesEachPairToItself(t *testing.T) {
	h := newHarness(t)
	seedAccountUsageLedger(t, h.srv.Store, 2, 3)

	v, err := h.srv.AccountUsageView("all", "")
	if err != nil {
		t.Fatal(err)
	}
	b, err := json.Marshal(v["observations"])
	if err != nil {
		t.Fatal(err)
	}
	var rows []struct {
		Source        string `json:"source"`
		AccountUUID   string `json:"account_uuid"`
		LocalTokens   int64  `json:"local_attributed_tokens"`
		LocalRequests int64  `json:"local_attributed_requests"`
	}
	if err := json.Unmarshal(b, &rows); err != nil {
		t.Fatal(err)
	}
	// 2 accounts x 2 sources, plus the vendor-only pair.
	if len(rows) != 5 {
		t.Fatalf("rows: %d, want 5: %s", len(rows), b)
	}
	for _, r := range rows {
		// Three hours seeded per pair; input differs by source (10 vs 11) and
		// output by hour (100, 101, 102), cache read is 900 each.
		want := int64(3*900 + 100 + 101 + 102)
		switch r.Source {
		case model.SourceClaude:
			want += 3 * 10
		case model.SourceCodex:
			want += 3 * 11
		}
		requests := int64(3)
		if r.AccountUUID == "acct-unattributed" {
			want, requests = 0, 0
		}
		if r.LocalTokens != want || r.LocalRequests != requests {
			t.Errorf("%s/%s: tokens=%d requests=%d, want %d/%d",
				r.AccountUUID, r.Source, r.LocalTokens, r.LocalRequests, want, requests)
		}
	}
}

// The one input whose output DOES move, and deliberately: an observation
// ingested under the literal AllAccounts sentinel.
//
// The per-row version fed that string back into Filter, which reads "*" as
// "every subscription", so one malformed row was handed the blended total of
// the whole hub — the exact leak the sentinel exists to prevent. A grouped
// scan has no such reading: "*" is just an account_uuid that matches its own
// rows and nobody else's.
func TestAccountUsageView_SentinelAccountIsNotEveryAccount(t *testing.T) {
	h := newHarness(t)
	seedAccountUsageLedger(t, h.srv.Store, 2, 3)
	at := int64(1)
	if err := h.srv.Store.InsertAccountUsage(model.AccountUsage{
		Source: model.SourceClaude, AccountUUID: store.AllAccounts, EndpointID: "ep-acct-00",
		ObservedAt: time.Date(2026, 8, 31, 12, 0, 0, 0, time.UTC), LifetimeTokens: &at,
	}); err != nil {
		t.Fatal(err)
	}
	v, err := h.srv.AccountUsageView("", "")
	if err != nil {
		t.Fatal(err)
	}
	b, _ := json.Marshal(v["observations"])
	var rows []struct {
		AccountUUID string `json:"account_uuid"`
		LocalTokens int64  `json:"local_attributed_tokens"`
	}
	if err := json.Unmarshal(b, &rows); err != nil {
		t.Fatal(err)
	}
	for _, r := range rows {
		if r.AccountUUID == store.AllAccounts && r.LocalTokens != 0 {
			t.Fatalf("sentinel row borrowed %d tokens from other subscriptions", r.LocalTokens)
		}
	}
}

// AttributedTotals is the store-side half: one row per (account, source) pair
// in scope, each equal to what Summary reports for that pair alone.
func TestAttributedTotals_MatchesSummaryPerPair(t *testing.T) {
	h := newHarness(t)
	st := h.srv.Store
	seedAccountUsageLedger(t, st, 3, 2)

	all := store.Filter{Account: store.AllAccounts,
		Start: time.Unix(0, 0).UTC(), End: time.Date(2200, 1, 1, 0, 0, 0, 0, time.UTC)}
	totals, err := st.AttributedTotals(all)
	if err != nil {
		t.Fatal(err)
	}
	if len(totals) != 6 {
		t.Fatalf("pairs: %d, want 6: %+v", len(totals), totals)
	}
	for k, a := range totals {
		f := all
		f.Account, f.Source = k.Account, k.Source
		sum, err := st.Summary(f)
		if err != nil {
			t.Fatal(err)
		}
		if a.Tokens != sum.Tokens || a.Events != sum.Events {
			t.Errorf("%+v: %+v, want tokens=%d events=%d", k, a, sum.Tokens, sum.Events)
		}
	}
	// Scoping narrows the groups rather than blending them.
	one := all
	one.Account, one.Source = "acct-01", model.SourceCodex
	got, err := st.AttributedTotals(one)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 1 {
		t.Fatalf("scoped pairs: %+v", got)
	}
	if _, ok := got[store.AccountSource{Account: "acct-01", Source: model.SourceCodex}]; !ok {
		t.Fatalf("scoped key: %+v", got)
	}
	// The guard Filter puts on a blank account still applies here.
	if _, err := st.AttributedTotals(store.Filter{Start: all.Start, End: all.End}); err == nil {
		t.Fatal("blank account accepted")
	}
}

// BenchmarkAccountUsageView is the before/after the issue asks for: the same
// ledger, read once per observation row and then once in total.
func BenchmarkAccountUsageView(b *testing.B) {
	run := func(b *testing.B, accounts, hours int, view func(*Server) error) {
		st, err := store.Open(filepath.Join(b.TempDir(), "bench.db"))
		if err != nil {
			b.Fatal(err)
		}
		defer st.Close()
		seedAccountUsageLedger(b, st, accounts, hours)
		srv := &Server{Store: st, Pricing: pricing.Default(), ViewerToken: viewerToken}
		b.ResetTimer()
		for i := 0; i < b.N; i++ {
			if err := view(srv); err != nil {
				b.Fatal(err)
			}
		}
	}
	for _, size := range []struct {
		name            string
		accounts, hours int
	}{
		{"6pairs", 3, 2000},
		{"20pairs", 10, 2000},
	} {
		b.Run(size.name+"/per-row", func(b *testing.B) {
			run(b, size.accounts, size.hours, func(s *Server) error {
				_, err := s.perRowAccountUsageView("all", "")
				return err
			})
		})
		b.Run(size.name+"/grouped", func(b *testing.B) {
			run(b, size.accounts, size.hours, func(s *Server) error {
				_, err := s.AccountUsageView("all", "")
				return err
			})
		})
	}
}
