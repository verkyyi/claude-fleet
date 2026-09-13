package pricing

import (
	"fmt"
	"time"

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
//
// This flat map means "this price holds whoever serves it". Per-contract rates
// live in the `providers` block: a gateway that fans out to several upstreams
// reaches one model id at several prices, and failover decides which contract
// served any given call.
var gatewayRates = map[string]Rates{}

// providerOverride is one upstream's contract: the rates it charges, and an
// optional human label for display. Label never affects a rate.
type providerOverride struct {
	Label  string           `json:"label"`
	Models map[string]Rates `json:"models"`
}

// gatewayPricing is the deployment's gateway rate data, carried per-Table so
// --pricing can correct it.
//
// Provenance travels with the rates. A corrected number stamped with the
// built-in's review date would put a lie in the price basis, which is the one
// thing a source that reports real spend cannot afford.
type gatewayPricing struct {
	rates map[string]Rates // flat: "this price holds whoever serves it"
	// byProvider is provider -> normalized model -> rates. A provider block is
	// authoritative for the models it names; the flat table answers only what
	// the provider left unsaid.
	byProvider map[string]map[string]Rates
	labels     map[string]string
	ratesAsOf  string
	cnyPerUSD  float64
	fxAsOf     string
	source     string
}

func defaultGateway() gatewayPricing {
	r := make(map[string]Rates, len(gatewayRates))
	for id, v := range gatewayRates {
		r[id] = v
	}
	return gatewayPricing{
		rates:      r,
		byProvider: map[string]map[string]Rates{},
		labels:     map[string]string{},
		ratesAsOf:  GatewayRatesAsOf,
		cnyPerUSD:  GatewayCNYPerUSD,
		fxAsOf:     GatewayFXAsOf,
		source:     GatewayPriceSource,
	}
}

// gatewayOverride is the "gateway" block of a --pricing overrides file.
//
//	{"gateway": {
//	  "rates_as_of": "2026-09-12",
//	  "cny_per_usd": 7.09, "cny_per_usd_as_of": "2026-09-12",
//	  "price_source": "https://internal/gateway/pricing",
//	  "models": {"some-vendor-model": {"input": 4.0, "output": 16.0}},
//	  "providers": {"dashscope.aliyuncs.com": {"label": "阿里云百炼",
//	    "models": {"qwen-plus": {"input": 0.8, "output": 2.0}}}}
//	}}
type gatewayOverride struct {
	Models      map[string]Rates            `json:"models"`
	Providers   map[string]providerOverride `json:"providers"`
	RatesAsOf   string                      `json:"rates_as_of"`
	CNYPerUSD   *float64                    `json:"cny_per_usd"`
	CNYAsOf     string                      `json:"cny_per_usd_as_of"`
	PriceSource string                      `json:"price_source"`
}

// validate rejects a block before any of the file is applied, so a typo in the
// gateway half cannot leave the model half half-loaded.
func (o *gatewayOverride) validate(path string) error {
	anyRate := len(o.Models) > 0
	for _, p := range o.Providers {
		if len(p.Models) > 0 {
			anyRate = true
		}
	}
	if anyRate && o.RatesAsOf == "" {
		return fmt.Errorf(`pricing overrides %s: gateway rates need "rates_as_of" -- an undated rate cannot be disclosed in a price basis`, path)
	}
	if err := validateGatewayRates(path, "", o.Models); err != nil {
		return err
	}
	for name, p := range o.Providers {
		if name == "" {
			return fmt.Errorf(`pricing overrides %s: gateway.providers has an empty key -- the empty provider means "not declared" and cannot carry a contract`, path)
		}
		if err := validateGatewayRates(path, name, p.Models); err != nil {
			return err
		}
	}
	if o.CNYPerUSD != nil {
		if *o.CNYPerUSD <= 0 {
			return fmt.Errorf("pricing overrides %s: gateway.cny_per_usd must be positive", path)
		}
		if o.CNYAsOf == "" {
			return fmt.Errorf(`pricing overrides %s: gateway.cny_per_usd needs "cny_per_usd_as_of" -- a conversion is only honest with the date it was set`, path)
		}
	}
	return nil
}

func validateGatewayRates(path, provider string, models map[string]Rates) error {
	where := "gateway model %q"
	if provider != "" {
		where = "gateway provider " + provider + " model %q"
	}
	for id, r := range models {
		// A rate carries exactly one shape. Both at once would price the same
		// event twice, and there is no reading of that result that is correct.
		if r.PricedByUnit() && (r.Input != 0 || r.Output != 0) {
			return fmt.Errorf("pricing overrides %s: "+where+" sets both a per-unit price and per-token rates — a rate carries one shape or the other", path, id)
		}
		if r.PricedByUnit() {
			if !GatewayUnits[r.Unit] {
				return fmt.Errorf("pricing overrides %s: "+where+" has unknown billing unit %q (want one of image, second, char, call)", path, id, r.Unit)
			}
			// Zero is not a discount — same rule as the token shape below.
			// Rejecting it at startup beats an event that prices to 0.00 and
			// reads as "this vendor gave it away".
			if r.Price <= 0 {
				return fmt.Errorf("pricing overrides %s: "+where+" needs a positive price per %s in CNY", path, id, r.Unit)
			}
		} else if r.Input <= 0 || r.Output <= 0 {
			// Zero is not a discount. A gateway call is never free, and a rate
			// left at zero would understate a real bill in silence.
			return fmt.Errorf("pricing overrides %s: "+where+" needs positive input and output rates in CNY per million tokens, or a unit+price pair", path, id)
		}
		if r.CacheWrite5m != 0 || r.CacheWrite1h != 0 || r.CacheRead != 0 {
			return fmt.Errorf("pricing overrides %s: "+where+" sets a cache rate, but this source reports no cache tokens", path, id)
		}
		if err := validatePeak(path, where, id, r.Peak); err != nil {
			return err
		}
	}
	return nil
}

// validatePeak rejects a surcharge block that would apply the wrong number, or
// none at all, while looking configured.
//
// Every check here is a case where a running hub would otherwise report money
// that is quietly wrong: an unparseable window is skipped (so peak calls bill at
// off-peak), an empty list surcharges nothing, and a multiplier at or below 1
// means somebody inverted the window and every peak hour under-reports.
func validatePeak(path, where, id string, w *PeakWindow) error {
	if w == nil {
		return nil
	}
	if w.Multiplier <= 1 {
		return fmt.Errorf("pricing overrides %s: "+where+" has a peak multiplier of %g -- a peak tier costs MORE than off-peak, "+
			"and the base rate is the off-peak one; a value at or below 1 means the window is inverted", path, id, w.Multiplier)
	}
	if len(w.UTCHours) == 0 {
		return fmt.Errorf("pricing overrides %s: "+where+" has a peak block with no utc_hours -- it would surcharge nothing while looking configured", path, id)
	}
	for _, spec := range w.UTCHours {
		from, to, ok := parseWindow(spec)
		if !ok {
			return fmt.Errorf("pricing overrides %s: "+where+" has an unreadable peak window %q (want \"HH:MM-HH:MM\" in UTC)", path, id, spec)
		}
		if from == to {
			return fmt.Errorf("pricing overrides %s: "+where+" has a zero-width peak window %q", path, id, spec)
		}
	}
	return nil
}

// atPeak returns the rate as charged at ts, and a note for the price basis.
//
// The event's OWN timestamp decides, never the clock: repricing last month's
// events (store.Reprice) has to land them in the tier they actually happened
// in, and a rate that asked "is it peak now" would restate history by whatever
// time of day the operator ran the command.
func atPeak(r Rates, ts time.Time) (Rates, string) {
	if !r.Peak.AppliesAt(ts) {
		if r.Peak != nil {
			return r, ", off-peak"
		}
		return r, ""
	}
	m := r.Peak.Multiplier
	r.Input *= m
	r.Output *= m
	r.Price *= m
	return r, fmt.Sprintf(", peak x%g", m)
}

// gatewayRate copies exactly the fields this source can price on.
//
// The field list is explicit, not a struct copy: the cache columns must never
// survive into a gateway rate (this source reports no cache tokens, and
// validateGatewayRates rejects a file that sets them — silently carrying one
// through would make that rejection a lie). ★ The cost of an explicit list is
// that a NEW field is dropped in silence unless someone adds it here; that
// already happened once, to Unit/Price (#6130), and the symptom was a
// per-image rate quietly pricing as "CNY 0 in / 0 out per MTok".
func gatewayRate(r Rates) Rates {
	return Rates{Input: r.Input, Output: r.Output, Unit: r.Unit, Price: r.Price, Peak: r.Peak}
}

func (g *gatewayPricing) merge(o *gatewayOverride) {
	for id, r := range o.Models {
		g.rates[Normalize(id)] = gatewayRate(r)
	}
	for name, p := range o.Providers {
		if p.Label != "" {
			g.labels[name] = p.Label
		}
		if len(p.Models) == 0 {
			continue
		}
		at := g.byProvider[name]
		if at == nil {
			at = map[string]Rates{}
			g.byProvider[name] = at
		}
		for id, r := range p.Models {
			at[Normalize(id)] = gatewayRate(r)
		}
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

// rateFor finds the contract that served this call.
//
// A provider block is authoritative for the models it names, so the flat table
// is consulted only when the provider stated no rate for this model. Returning
// the provider that supplied the rate ("" for the flat table) is what lets the
// price basis disclose which contract produced the figure.
func (g *gatewayPricing) rateFor(provider, modelID string) (Rates, string, bool) {
	id := Normalize(modelID)
	if m, ok := g.byProvider[provider]; ok {
		if r, ok := m[id]; ok {
			return r, provider, true
		}
	}
	if r, ok := g.rates[id]; ok {
		return r, "", true
	}
	return Rates{}, "", false
}

// GatewayProviderLabel is the operator-supplied display name for an upstream,
// or "" when none was stated. The hub never invents one: a hostname it cannot
// name is shown as the hostname.
func (t *Table) GatewayProviderLabel(provider string) string { return t.gw.labels[provider] }

// gatewayCost prices one pay-per-call gateway event on the contract that
// actually served it, converting the vendor's CNY rate to USD at the pinned
// constant and disclosing both the conversion and the contract.
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

	provider := e.Provider
	if provider == "" {
		provider = d.Provider
	}

	r, pricedBy, ok := g.rateFor(provider, e.Model)
	if !ok {
		// Name the provider, not just the model: with failover across
		// upstreams "which contract is missing a rate" is the actionable half.
		if provider == "" {
			d.PriceBasis = "unpriced: no gateway rate configured for this model, and the call declared no provider"
		} else {
			d.PriceBasis = fmt.Sprintf("unpriced: no gateway rate configured for provider %s, model %s", provider, e.Model)
		}
		return nil
	}
	if g.cnyPerUSD <= 0 {
		d.PriceBasis = "unpriced: no usable CNY/USD rate"
		return nil
	}

	// Which tier this call fell in, by its own timestamp. tier is "" for a
	// contract with one price around the clock, so those price bases read
	// exactly as they did before peak windows existed.
	r, tier := atPeak(r, e.TS)

	// ── the per-unit shape ───────────────────────────────────────────────
	// Images by the picture, audio by the second: a growing share of what the
	// gateway fronts is not billed per token at all. These rows price off the
	// event's own declared usage and NEVER fall back to the token columns —
	// an image call carries no tokens, so a fallback would price every one of
	// them at 0.00 and report a real bill as free.
	if r.PricedByUnit() {
		if d.Usage == nil {
			d.PriceBasis = fmt.Sprintf("unpriced: %s is priced per %s, but this event declared no usage", e.Model, r.Unit)
			return nil
		}
		// A mismatched unit is a wiring bug between the shipper and the rate
		// table, and multiplying anyway would put a confidently wrong number
		// in a column that means real money.
		if d.UsageUnit != r.Unit {
			d.PriceBasis = fmt.Sprintf("unpriced: %s is priced per %s, but this event reports usage in %q", e.Model, r.Unit, d.UsageUnit)
			return nil
		}
		if *d.Usage < 0 {
			d.PriceBasis = "unpriced: implausible usage"
			return nil
		}
		cny := *d.Usage * r.Price
		usd := cny / g.cnyPerUSD
		contract := "any provider"
		if pricedBy != "" {
			contract = "provider " + pricedBy
		}
		d.PriceBasis = fmt.Sprintf("billed: %s%s, CNY %g per %s × %g %s as of %s, converted at %.4f CNY/USD pinned %s",
			contract, tier, r.Price, r.Unit, *d.Usage, r.Unit, g.ratesAsOf, g.cnyPerUSD, g.fxAsOf)
		return &usd
	}

	// ── the per-token shape ──────────────────────────────────────────────
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
	const perMillion = 1_000_000.0
	cny := float64(e.InputTokens)/perMillion*r.Input + float64(e.OutputTokens)/perMillion*r.Output
	usd := cny / g.cnyPerUSD
	contract := "any provider"
	if pricedBy != "" {
		contract = "provider " + pricedBy
	}
	d.PriceBasis = fmt.Sprintf("billed: %s%s, CNY %g in / %g out per MTok as of %s, converted at %.4f CNY/USD pinned %s",
		contract, tier, r.Input, r.Output, g.ratesAsOf, g.cnyPerUSD, g.fxAsOf)
	return &usd
}
