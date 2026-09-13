package api

import (
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/ccquota/internal/model"
	"github.com/verkyyi/ccquota/internal/pricing"
	"github.com/verkyyi/ccquota/internal/store"
)

const costScope = "account=all&since=2026-08-31T12:00:00Z&until=2026-08-31T15:00:00Z"

// seedGateway pushes one gateway event alongside the Claude fixture, so the
// review surface holds two kinds of money at once. Its cost is stamped
// directly rather than derived: gateway rates are per-deployment and this
// repo ships none (see pricing/gateway.go), so a fixture that relied on the
// built-in table would price at nil.
func seedGateway(t *testing.T, h *harness) {
	t.Helper()
	c := 100.0
	if _, _, err := h.srv.Store.InsertEvents([]model.UsageEvent{{
		Source: model.SourceGateway, AccountUUID: "acct-a", EndpointID: "ep_mac",
		SessionID: "s-gw", MessageUUID: "gw1",
		TS:    time.Date(2026, 8, 31, 12, 30, 0, 0, time.UTC),
		Model: "qwen3-max", OutputTokens: 50, CostUSD: &c, CWD: "/p/alpha", OSUser: "verkyyi",
	}}); err != nil {
		t.Fatal(err)
	}
}

// A gateway-scoped request used to be a 400: querySource listed claude and
// codex literally, so the one scope in which a billed figure can be read
// alone was unreachable from the dashboard and from MCP (issue #4).
func TestQuerySourceAcceptsEveryKnownSource(t *testing.T) {
	h := newHarness(t)
	seedReviewHarness(t, h)
	seedGateway(t, h)

	for _, src := range model.Sources {
		for _, path := range []string{"/v1/summary?", "/v1/usage?by=source&", "/v1/sessions?", "/v1/history?"} {
			res, body := h.get(t, path+costScope+"&source="+src)
			res.Body.Close()
			if res.StatusCode != http.StatusOK {
				t.Errorf("GET %s source=%s: %d %s", path, src, res.StatusCode, body)
			}
		}
	}
	res, body := h.get(t, "/v1/summary?"+costScope+"&source=not-a-source")
	res.Body.Close()
	if res.StatusCode != http.StatusBadRequest {
		t.Fatalf("an unknown source was accepted: %d %s", res.StatusCode, body)
	}
	for _, src := range model.Sources {
		if !strings.Contains(string(body), src) {
			t.Errorf("the 400 does not name %q, so a caller cannot tell what IS valid: %s", src, body)
		}
	}
}

// handleSummary used to attach the Codex note to everything that was not
// Claude — which meant a gateway summary carried "API equivalent estimate",
// the exact opposite of true for a source billed per call, and an unfiltered
// summary carried it too despite having no single basis at all (issue #4).
func TestSummaryPricingNoteFollowsTheSource(t *testing.T) {
	h := newHarness(t)
	seedReviewHarness(t, h)
	seedGateway(t, h)

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
		{model.SourceGateway, pricing.GatewayPriceNote, model.CostBilled, pricing.GatewayRatesAsOf},
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

// The summary's money: split by source, folded only two ways, and with a real
// spend figure the notional number cannot enter.
func TestSummarySplitsCostAndReportsRealSpend(t *testing.T) {
	h := newHarness(t)
	seedReviewHarness(t, h)
	seedGateway(t, h)
	if err := h.srv.Store.SetPlanPrice(model.SubscriptionPlan{
		Plan: "max", Source: model.SourceClaude, MonthlyCost: 200, Currency: "USD",
		EffectiveFrom: time.Date(2020, 1, 1, 0, 0, 0, 0, time.UTC),
	}); err != nil {
		t.Fatal(err)
	}

	type summaryCost struct {
		Cost         store.CostBySource `json:"cost"`
		CostNotional float64            `json:"cost_notional"`
		CostBilled   float64            `json:"cost_billed"`
		RealSpend    RealSpend          `json:"real_spend"`
		Subscription []struct {
			Plan   string  `json:"plan"`
			Amount float64 `json:"amount"`
			Priced bool    `json:"priced"`
		} `json:"subscription_spend"`
	}
	var got summaryCost
	h.getJSON(t, "/v1/summary?"+costScope, &got)

	gw, ok := got.Cost.Of(model.SourceGateway)
	if !ok || gw.CostUSD != 100 || gw.Kind != model.CostBilled {
		t.Fatalf("gateway cost = %+v, want $100 billed", gw)
	}
	cl, _ := got.Cost.Of(model.SourceClaude)
	if cl.CostUSD == 0 || cl.Kind != model.CostNotional {
		t.Fatalf("claude cost = %+v, want a notional figure", cl)
	}
	if got.CostBilled != 100 {
		t.Errorf("cost_billed = %v, want 100", got.CostBilled)
	}
	if got.CostNotional != cl.CostUSD {
		t.Errorf("cost_notional = %v, want the claude figure %v", got.CostNotional, cl.CostUSD)
	}
	if got.CostNotional == 0 {
		t.Fatal("fixture produced no notional cost; the checks below would pass vacuously")
	}

	// Real spend is subscription + gateway, and NOT the notional figure.
	if got.RealSpend.Gateway != 100 {
		t.Errorf("real_spend.gateway = %v, want 100", got.RealSpend.Gateway)
	}
	if got.RealSpend.Total != got.RealSpend.Subscription+got.RealSpend.Gateway {
		t.Errorf("real_spend.total = %v, want subscription + gateway", got.RealSpend.Total)
	}
	if got.RealSpend.Total >= got.CostNotional && got.CostNotional > got.RealSpend.Gateway {
		t.Errorf("real_spend %v looks like it absorbed the notional figure %v", got.RealSpend.Total, got.CostNotional)
	}

	// The subscription term itself, over a window the account was actually
	// seen in -- a plan is billed for the months it exists, not for the
	// window some stored turns happen to fall in (see SubscriptionSpendOver).
	var live summaryCost
	h.getJSON(t, "/v1/summary?account=all&since=72h", &live)
	if len(live.Subscription) == 0 {
		t.Fatalf("the summary reports no subscription spend at all: %+v", live.RealSpend)
	}
	if live.RealSpend.Subscription <= 0 {
		t.Fatalf("real_spend carries no subscription term: %+v (rows %+v)", live.RealSpend, live.Subscription)
	}
	if live.RealSpend.Total != live.RealSpend.Subscription+live.RealSpend.Gateway {
		t.Errorf("real_spend.total = %+v is not its two terms", live.RealSpend)
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
	cost := store.CostBySource{
		{Source: model.SourceClaude, Kind: model.CostNotional, CostUSD: 5000},
		{Source: model.SourceGateway, Kind: model.CostBilled, CostUSD: 10},
	}
	rs := RealSpendOver(cost, plans)
	if rs.Subscription != 200 || rs.Gateway != 10 || rs.Total != 210 {
		t.Fatalf("real spend = %+v, want 200 + 10", rs)
	}
	if rs.Complete {
		t.Error("real spend claims to be complete with an unpriced plan and a foreign currency in it")
	}
	if len(rs.Missing) != 2 {
		t.Errorf("missing = %v, want both the unpriced plan and the CNY one", rs.Missing)
	}
	if rs.Total >= 5000 {
		t.Error("the notional figure reached real spend")
	}
}

// Live sessions are an overlapping counter with its own never-add rule; the
// same rule applies one level down, between the kinds of money in it.
func TestLiveSnapshotKeepsBilledCostApart(t *testing.T) {
	now := time.Now().UTC()
	l := NewLive()
	// Only Claude heartbeats get an ObservedAt filled in for them; every
	// other source states its own or is dropped as stale.
	l.Report("ep1", "web-01", []LiveSession{
		{SessionID: "s1", Source: model.SourceClaude, ObservedAt: now, CostUSD: 1, USDPerHour: 2},
		{SessionID: "s2", Source: model.SourceGateway, ObservedAt: now, CostUSD: 100, USDPerHour: 50},
	})
	snap := l.Snapshot()
	if snap.SessionCost != 1 {
		t.Errorf("notional live cost = %v, want 1", snap.SessionCost)
	}
	if snap.SessionCostBilled != 100 {
		t.Errorf("billed live cost = %v, want 100", snap.SessionCostBilled)
	}
	if snap.USDPerHour != 2 || snap.USDPerHourBilled != 50 {
		t.Errorf("burn rates blended: %v / %v", snap.USDPerHour, snap.USDPerHourBilled)
	}
	if snap.SessionCost == 101 {
		t.Error("live costs were summed across sources")
	}
}

// A gateway-scoped page must not show a Claude plan's invoice next to its own
// charges: that source has no subscription, and the honest answer to "what
// does this source cost" is its metered bill alone.
func TestSubscriptionSpendHonoursTheSourceChip(t *testing.T) {
	h := newHarness(t)
	seedReviewHarness(t, h)
	seedGateway(t, h)
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
	h.getJSON(t, "/v1/summary?account=all&since=72h&source=gateway", &got)
	if len(got.Subscription) != 0 {
		t.Errorf("a gateway-scoped summary carries subscription rows: %+v", got.Subscription)
	}
	if got.RealSpend.Subscription != 0 {
		t.Errorf("real_spend for source=gateway includes %v of subscription money", got.RealSpend.Subscription)
	}

	h.getJSON(t, "/v1/summary?account=all&since=72h&source=claude", &got)
	if len(got.Subscription) != 1 || got.Subscription[0].Source != model.SourceClaude {
		t.Fatalf("claude-scoped subscription rows = %+v", got.Subscription)
	}
	if got.RealSpend.Gateway != 0 {
		t.Errorf("real_spend for source=claude includes %v of gateway money", got.RealSpend.Gateway)
	}
}
