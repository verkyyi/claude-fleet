package pricing

import (
	"fmt"

	"github.com/verkyyi/ccquota/internal/model"
)

// GatewayPriceNote says what every surface showing a gateway figure has to
// say: this one is not notional.
//
// Claude and Codex costs answer "what would this have cost at API rates" for
// work nobody is billed per token for. The gateway fronts non-Anthropic
// vendors on a pay-per-call contract, so its cost_usd IS the invoice. Same
// column, two kinds of money — which is why a gateway total must never be
// added to a Claude or Codex one.
const GatewayPriceNote = "Gateway: billed per call — this figure is an actual charge, not the API-equivalent estimate the other sources carry. Rates are the deployment's own, stated in CNY in the --pricing overrides file and converted to USD at a pinned, human-reviewed rate; each event's price basis carries the rate and the date it was set. Never add a gateway total to a Claude or Codex one: they are different kinds of money."

// GatewayRatesAsOf documents when the built-in gateway table was last
// reviewed. A deployment that states its own rates states its own date with
// them; see gatewayOverride.
const GatewayRatesAsOf = "2026-09-12"

// The vendors behind the gateway publish in CNY, and Rates is dollars per
// million tokens. Converting at a pinned constant is the cheaper half of a
// real trade-off: a live FX feed would silently restate every historical
// figure each morning, and a currency dimension would touch every read path
// and every MCP output for the sake of one source. Stale and disclosed beats
// moving and invisible — the conversion is named in every price basis.
//
// Review this before trusting a figure built on it, and correct it in
// --pricing rather than waiting for a release.
const (
	GatewayCNYPerUSD = 7.09
	GatewayFXAsOf    = "2026-09-12"
)

// GatewayPriceSource is the default provenance string. A deployment pointing
// at its own contract overrides it.
const GatewayPriceSource = "operator-supplied gateway price list (--pricing)"

// gatewayRates is deliberately empty.
//
// Gateway prices are per-deployment contract terms, not published rates that
// belong in a binary: two sites fronting the same vendor pay different
// numbers, and a wrong rate baked into an image is a wrong invoice nobody can
// correct without a release. Deployments state their own in the --pricing
// overrides file, which merges rather than replaces, so correcting one model
// never drops the rest. An unconfigured model stays unpriced with a basis
// saying exactly that — the same nil-not-zero rule the rest of the package
// keeps, and the honest answer for real money.
//
// Keys are normalized model ids; values are CNY per million tokens, input and
// output only. This source carries no cache breakdown at all.
var gatewayRates = map[string]Rates{}

// gatewayPricing is the deployment's gateway rate data, carried per-Table so
// --pricing can correct it.
//
// Provenance travels with the rates. A corrected number stamped with the
// built-in's review date would put a lie in the price basis, which is the one
// thing a source that reports real spend cannot afford.
type gatewayPricing struct {
	rates     map[string]Rates // CNY per million tokens, input/output only
	ratesAsOf string
	cnyPerUSD float64
	fxAsOf    string
	source    string
}

func defaultGateway() gatewayPricing {
	r := make(map[string]Rates, len(gatewayRates))
	for id, v := range gatewayRates {
		r[id] = v
	}
	return gatewayPricing{
		rates:     r,
		ratesAsOf: GatewayRatesAsOf,
		cnyPerUSD: GatewayCNYPerUSD,
		fxAsOf:    GatewayFXAsOf,
		source:    GatewayPriceSource,
	}
}

// gatewayOverride is the "gateway" block of a --pricing overrides file.
//
//	{"gateway": {
//	  "rates_as_of": "2026-09-12",
//	  "cny_per_usd": 7.09, "cny_per_usd_as_of": "2026-09-12",
//	  "price_source": "https://internal/gateway/pricing",
//	  "models": {"some-vendor-model": {"input": 4.0, "output": 16.0}}
//	}}
type gatewayOverride struct {
	Models      map[string]Rates `json:"models"`
	RatesAsOf   string           `json:"rates_as_of"`
	CNYPerUSD   *float64         `json:"cny_per_usd"`
	CNYAsOf     string           `json:"cny_per_usd_as_of"`
	PriceSource string           `json:"price_source"`
}

// validate rejects a block before any of the file is applied, so a typo in the
// gateway half cannot leave the model half half-loaded.
func (o *gatewayOverride) validate(path string) error {
	if len(o.Models) > 0 && o.RatesAsOf == "" {
		return fmt.Errorf(`pricing overrides %s: gateway.models needs "rates_as_of" — an undated rate cannot be disclosed in a price basis`, path)
	}
	for id, r := range o.Models {
		// Zero is not a discount. A gateway call is never free, and a rate
		// left at zero would understate a real bill in silence.
		if r.Input <= 0 || r.Output <= 0 {
			return fmt.Errorf("pricing overrides %s: gateway model %q needs positive input and output rates in CNY per million tokens", path, id)
		}
		if r.CacheWrite5m != 0 || r.CacheWrite1h != 0 || r.CacheRead != 0 {
			return fmt.Errorf("pricing overrides %s: gateway model %q sets a cache rate, but this source reports no cache tokens", path, id)
		}
	}
	if o.CNYPerUSD != nil {
		if *o.CNYPerUSD <= 0 {
			return fmt.Errorf("pricing overrides %s: gateway.cny_per_usd must be positive", path)
		}
		if o.CNYAsOf == "" {
			return fmt.Errorf(`pricing overrides %s: gateway.cny_per_usd needs "cny_per_usd_as_of" — a conversion is only honest with the date it was set`, path)
		}
	}
	return nil
}

func (g *gatewayPricing) merge(o *gatewayOverride) {
	for id, r := range o.Models {
		g.rates[Normalize(id)] = Rates{Input: r.Input, Output: r.Output}
	}
	if o.RatesAsOf != "" {
		g.ratesAsOf = o.RatesAsOf
	}
	if o.CNYPerUSD != nil {
		g.cnyPerUSD = *o.CNYPerUSD
		g.fxAsOf = o.CNYAsOf
	}
	if o.PriceSource != "" {
		g.source = o.PriceSource
	}
}

// gatewayCost prices one pay-per-call gateway event, converting the vendor's
// CNY rate to USD at the pinned constant and disclosing the conversion.
func (t *Table) gatewayCost(e *model.UsageEvent) *float64 {
	d := e.Details
	if d == nil {
		// Nowhere to stamp the basis. A converted figure presented without
		// its conversion is exactly what this design refuses, so the event
		// stays unpriced rather than arriving as a bare number.
		return nil
	}
	g := &t.gw
	d.PriceVersion = "gateway-" + g.ratesAsOf
	d.PriceSource = g.source

	d.PriceBasis = "unpriced: no gateway rate configured"
	r, ok := g.rates[Normalize(e.Model)]
	if !ok {
		return nil
	}
	if e.InputTokens < 0 || e.OutputTokens < 0 {
		d.PriceBasis = "unpriced: implausible token counts"
		return nil
	}
	// The source reports no cache breakdown, so the three cache columns are
	// legitimately 0 and the configured rates cover input and output only. A
	// non-zero count here means the adapter grew a breakdown the rates do not
	// price: cheaper to admit than to undercount a real invoice.
	if e.CacheCreate5m != 0 || e.CacheCreate1h != 0 || e.CacheRead != 0 {
		d.PriceBasis = "unpriced: gateway rates cover input and output only"
		return nil
	}
	if g.cnyPerUSD <= 0 {
		d.PriceBasis = "unpriced: no usable CNY/USD rate"
		return nil
	}

	const perMillion = 1_000_000.0
	cny := float64(e.InputTokens)/perMillion*r.Input + float64(e.OutputTokens)/perMillion*r.Output
	usd := cny / g.cnyPerUSD
	d.PriceBasis = fmt.Sprintf("billed: CNY %g in / %g out per MTok as of %s, converted at %.4f CNY/USD pinned %s",
		r.Input, r.Output, g.ratesAsOf, g.cnyPerUSD, g.fxAsOf)
	return &usd
}
