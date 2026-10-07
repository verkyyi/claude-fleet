package api

import (
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/model"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/pricing"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

const costScope = "account=all&since=2026-08-31T12:00:00Z&until=2026-08-31T15:00:00Z"

// seedCodex puts one Codex event beside the Claude fixture, so the review
// surface holds both sources at once. Its cost is stamped directly: the
// store takes it as given, which keeps the figure exact.
func seedCodex(t *testing.T, h *harness) {
	t.Helper()
	c := 100.0
	if _, _, err := h.srv.Store.InsertEvents([]model.UsageEvent{{
		Source: model.SourceCodex, AccountUUID: "acct-a", EndpointID: "ep_mac",
		SessionID: "s-cx", MessageUUID: "cx1",
		TS:    time.Date(2026, 8, 31, 12, 30, 0, 0, time.UTC),
		Model: "gpt-5", OutputTokens: 50, CostUSD: &c, CWD: "/p/alpha", OSUser: "verkyyi",
	}}); err != nil {
		t.Fatal(err)
	}
}

// Every source this build knows is addressable on every query surface, and an
// unknown one is a 400 that names the valid ones (issue #4).
func TestQuerySourceAcceptsEveryKnownSource(t *testing.T) {
	h := newHarness(t)
	seedReviewHarness(t, h)
	seedCodex(t, h)

	for _, src := range model.Sources {
		for _, path := range []string{"/v1/summary?", "/v1/usage?by=source&", "/v1/sessions?", "/v1/history?"} {
			res, body := h.get(t, path+costScope+"&source="+src)
			res.Body.Close()
			if res.StatusCode != http.StatusOK {
				t.Errorf("GET %s source=%s: %d %s", path, src, res.StatusCode, body)
			}
		}
	}
	for _, gone := range []string{"not-a-source", "gateway", "vendor_bill", "voice"} {
		res, body := h.get(t, "/v1/summary?"+costScope+"&source="+gone)
		res.Body.Close()
		if res.StatusCode != http.StatusBadRequest {
			t.Fatalf("source=%s was accepted: %d %s", gone, res.StatusCode, body)
		}
		for _, src := range model.Sources {
			if !strings.Contains(string(body), src) {
				t.Errorf("the 400 does not name %q, so a caller cannot tell what IS valid: %s", src, body)
			}
		}
	}
}

// Only Claude and Codex usage is taken (claude-fleet#1987): a batch from a
// gateway, vendor-bill or voice shipper is refused and nothing is stored.
func TestIngestRefusesRemovedSources(t *testing.T) {
	h := newHarness(t)
	tok := h.enroll(t, "shipper")
	for _, src := range []string{"gateway", "vendor_bill", "voice"} {
		res := h.push(t, tok, model.Batch{
			Identity: model.Identity{Source: src, AccountUUID: "app-" + src, Hostname: "box", OSUser: "svc"},
			Events: []model.UsageEvent{{MessageUUID: "m-" + src, SessionID: "s", Model: "m",
				TS: time.Date(2026, 8, 31, 12, 0, 0, 0, time.UTC), OutputTokens: 5}},
		})
		res.Body.Close()
		if res.StatusCode != http.StatusBadRequest {
			t.Errorf("source=%s batch: HTTP %d, want 400", src, res.StatusCode)
		}
	}
	var n int
	if err := h.srv.Store.DB().QueryRow(`SELECT COUNT(*) FROM usage_events`).Scan(&n); err != nil || n != 0 {
		t.Fatalf("usage_events holds %d rows after refused batches (%v)", n, err)
	}
}

// The summary's pricing note names the basis of the scope's figures: one
// source's own note when filtered to it, the mixed-source note when not
// (issue #4).
func TestSummaryPricingNoteFollowsTheSource(t *testing.T) {
	h := newHarness(t)
	seedReviewHarness(t, h)
	seedCodex(t, h)

	type prov struct {
		Source, Kind, RatesAsOf, Note string
	}
	get := func(source string) (note string, provs []prov) {
		var got struct {
			PricingNote string `json:"pricing_note"`
			Pricing     []struct {
				Source    string `json:"source"`
				Kind      string `json:"kind"`
				RatesAsOf string `json:"rates_as_of"`
				Note      string `json:"note"`
			} `json:"pricing"`
		}
		q := costScope
		if source != "" {
			q += "&source=" + source
		}
		h.getJSON(t, "/v1/summary?"+q, &got)
		for _, p := range got.Pricing {
			provs = append(provs, prov{p.Source, p.Kind, p.RatesAsOf, p.Note})
		}
		return got.PricingNote, provs
	}

	for _, tc := range []struct {
		source, wantNote, wantKind, wantAsOf string
	}{
		{model.SourceClaude, pricing.ClaudePriceNote, model.CostNotional, pricing.RatesAsOf},
		{model.SourceCodex, pricing.OpenAIPriceNote, model.CostNotional, pricing.OpenAIRatesAsOf},
	} {
		note, provs := get(tc.source)
		if note != tc.wantNote {
			t.Errorf("source=%s note = %q, want the %s note", tc.source, note, tc.source)
		}
		if len(provs) != 1 || provs[0].Source != tc.source {
			t.Fatalf("source=%s provenance = %+v, want exactly its own", tc.source, provs)
		}
		if provs[0].Kind != tc.wantKind || provs[0].RatesAsOf != tc.wantAsOf {
			t.Errorf("source=%s provenance = %+v, want kind=%s rates_as_of=%s", tc.source, provs[0], tc.wantKind, tc.wantAsOf)
		}
	}

	// Unfiltered: no single basis, so the note says what the columns mean and
	// every source is described.
	note, provs := get("")
	if note != pricing.MixedSourceNote {
		t.Errorf("unfiltered note = %q, want the mixed-source note", note)
	}
	if len(provs) != len(model.Sources) {
		t.Fatalf("unfiltered provenance = %+v, want one entry per source", provs)
	}
	if strings.Contains(note, "API equivalent at") {
		t.Error("an unfiltered summary still claims one source's basis")
	}
}

// The summary's money: split by source, one legitimate fold, and a real spend
// figure the notional number cannot enter.
func TestSummarySplitsCostAndReportsRealSpend(t *testing.T) {
	h := newHarness(t)
	seedReviewHarness(t, h)
	seedCodex(t, h)
	if err := h.srv.Store.SetPlanPrice(model.SubscriptionPlan{
		Plan: "max", Source: model.SourceClaude, MonthlyCost: 200, Currency: "USD",
		EffectiveFrom: time.Date(2020, 1, 1, 0, 0, 0, 0, time.UTC),
	}); err != nil {
		t.Fatal(err)
	}

	type summaryCost struct {
		Cost         store.CostBySource `json:"cost"`
		CostNotional float64            `json:"cost_notional"`
		RealSpend    RealSpend          `json:"real_spend"`
		Subscription []struct {
			Plan   string  `json:"plan"`
			Amount float64 `json:"amount"`
			Priced bool    `json:"priced"`
		} `json:"subscription_spend"`
	}
	var got summaryCost
	h.getJSON(t, "/v1/summary?"+costScope, &got)

	cx, ok := got.Cost.Of(model.SourceCodex)
	if !ok || cx.CostUSD != 100 || cx.Kind != model.CostNotional {
		t.Fatalf("codex cost = %+v, want $100 notional", cx)
	}
	cl, _ := got.Cost.Of(model.SourceClaude)
	if cl.CostUSD == 0 || cl.Kind != model.CostNotional {
		t.Fatalf("claude cost = %+v, want a notional figure", cl)
	}
	if got.CostNotional != cl.CostUSD+cx.CostUSD {
		t.Errorf("cost_notional = %v, want claude %v + codex %v", got.CostNotional, cl.CostUSD, cx.CostUSD)
	}

	// Real spend is the subscriptions, and NOT the notional figure.
	if got.RealSpend.Total != got.RealSpend.Subscription {
		t.Errorf("real_spend.total = %v, want the subscription term %v", got.RealSpend.Total, got.RealSpend.Subscription)
	}

	// The subscription term itself, over a window the account was actually
	// seen in -- a plan is billed for the months it exists, not for the
	// window some stored turns happen to fall in (see SubscriptionSpendOver).
	var live summaryCost
	h.getJSON(t, "/v1/summary?account=all&since=72h", &live)
	if len(live.Subscription) == 0 {
		t.Fatalf("the summary reports no subscription spend at all: %+v", live.RealSpend)
	}
	if live.RealSpend.Subscription <= 0 || live.RealSpend.Total != live.RealSpend.Subscription {
		t.Fatalf("real_spend = %+v (rows %+v), want exactly its subscription term", live.RealSpend, live.Subscription)
	}
}

// An unpriced plan must make real spend say so rather than quietly report a
// total that is too low.
func TestRealSpendReportsWhatItCouldNotAdd(t *testing.T) {
	plans := []store.SubscriptionSpend{
		{Plan: "max", Source: model.SourceClaude, Currency: "USD", Amount: 200, Priced: true, Seats: 1},
		{Plan: "team", Source: model.SourceClaude, Priced: false, Seats: 4},
		{Plan: "pro", Source: model.SourceCodex, Currency: "CNY", Amount: 999, Priced: true, Seats: 1},
	}
	rs := RealSpendOver(plans)
	if rs.Subscription != 200 || rs.Total != 200 {
		t.Fatalf("real spend = %+v, want 200", rs)
	}
	if rs.Complete {
		t.Error("real spend claims to be complete with an unpriced plan and a foreign currency in it")
	}
	if len(rs.Missing) != 2 {
		t.Errorf("missing = %v, want both the unpriced plan and the CNY one", rs.Missing)
	}
}

// A live session from a source this build has no cost kind for is counted in
// no total; it stays visible on its own row.
func TestLiveSnapshotCountsOnlyKnownMoney(t *testing.T) {
	now := time.Now().UTC()
	l := NewLive()
	l.Report("ep1", "web-01", []LiveSession{
		{SessionID: "s1", Source: model.SourceClaude, ObservedAt: now, CostUSD: 1, USDPerHour: 2},
		{SessionID: "s2", Source: "some-future-thing", ObservedAt: now, CostUSD: 100, USDPerHour: 50},
	})
	snap := l.Snapshot()
	if snap.SessionCost != 1 || snap.USDPerHour != 2 {
		t.Errorf("live money = %v / %v per hour, want 1 / 2", snap.SessionCost, snap.USDPerHour)
	}
}

// A source-scoped page must not show another source's plan: a Codex-scoped
// summary carries no Claude invoice.
func TestSubscriptionSpendHonoursTheSourceChip(t *testing.T) {
	h := newHarness(t)
	seedReviewHarness(t, h)
	seedCodex(t, h)
	if err := h.srv.Store.SetPlanPrice(model.SubscriptionPlan{
		Plan: "max", Source: model.SourceClaude, MonthlyCost: 200, Currency: "USD",
		EffectiveFrom: time.Date(2020, 1, 1, 0, 0, 0, 0, time.UTC),
	}); err != nil {
		t.Fatal(err)
	}
	var got struct {
		Subscription []struct {
			Source string `json:"source"`
		} `json:"subscription_spend"`
		RealSpend RealSpend `json:"real_spend"`
	}
	h.getJSON(t, "/v1/summary?account=all&since=72h&source=codex", &got)
	if len(got.Subscription) != 0 {
		t.Errorf("a codex-scoped summary carries claude subscription rows: %+v", got.Subscription)
	}
	if got.RealSpend.Subscription != 0 {
		t.Errorf("real_spend for source=codex includes %v of claude subscription money", got.RealSpend.Subscription)
	}

	h.getJSON(t, "/v1/summary?account=all&since=72h&source=claude", &got)
	if len(got.Subscription) != 1 || got.Subscription[0].Source != model.SourceClaude {
		t.Fatalf("claude-scoped subscription rows = %+v", got.Subscription)
	}
}
