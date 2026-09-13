package pricing

import "github.com/verkyyi/ccquota/internal/model"

// ClaudePriceNote is the caveat the built-in Anthropic table carries.
//
// It exists as a named constant for the same reason OpenAIPriceNote and
// GatewayPriceNote do: every surface showing this source's figure has to say
// what the figure is, and a note written inline on one surface is a note the
// next surface forgets.
const ClaudePriceNote = "Claude: API equivalent at " + RatesAsOf + " published rates. " +
	"A Pro or Max subscription is not billed per token, so this is what the work would have cost " +
	"at API rates — useful for ranking endpoints and projects, misleading if read as an invoice. " +
	"The subscription itself is real money and is reported separately; never add the two."

// MixedSourceNote is what a surface says when its scope spans sources.
//
// Not a disclaimer bolted onto a blended total — there is no blended total.
// It says why the cost column has more than one number in it.
const MixedSourceNote = "This scope spans more than one source, and cost_usd means a different thing " +
	"in each: Claude and Codex figures are API-equivalent estimates for work billed by subscription, " +
	"gateway figures are actual per-call charges. They are reported apart and never added. " +
	"Real spend is subscription + gateway; the notional figure is not part of it."

// SourceProvenance is everything a surface must show beside ONE source's cost
// figure: which source it is, which kind of money, when the rates behind it
// were last reviewed, and the note saying so in words.
//
// Carried per source rather than per response because a response that spans
// sources has no single answer to any of these fields — which is the whole
// point of keeping the figures apart.
type SourceProvenance struct {
	Source    string `json:"source"`
	Kind      string `json:"kind"`
	RatesAsOf string `json:"rates_as_of"`
	Note      string `json:"note"`
}

// ProvenanceFor describes one source. An unknown source is described as
// unknown rather than guessed at: an unreviewed rate date is a reporting bug,
// and inventing one hides it.
func ProvenanceFor(source string) SourceProvenance {
	p := SourceProvenance{Source: model.UsageSource(source), Kind: model.CostKind(source)}
	switch p.Source {
	case model.SourceClaude:
		p.RatesAsOf, p.Note = RatesAsOf, ClaudePriceNote
	case model.SourceCodex:
		p.RatesAsOf, p.Note = OpenAIRatesAsOf, OpenAIPriceNote
	case model.SourceGateway:
		p.RatesAsOf, p.Note = GatewayRatesAsOf, GatewayPriceNote
	case model.SourceVendorBill:
		// RatesAsOf stays empty on purpose: there is no rate table behind these
		// rows, so there is no review date to state. Putting today's date here
		// would claim a review that never happened; borrowing the gateway's
		// would attribute these figures to rates that did not produce them.
		// Each row's own billing period travels with it (TS + Model).
		p.Note = VendorBillPriceNote
	default:
		p.Note = "Unrecognised source: this build has no rate table for it, so its cost figure " +
			"has no stated basis and belongs in no total."
	}
	return p
}

// Provenance describes every source a surface is about to show.
//
// Pass one source to describe a scope filtered to it, or none to describe
// every source this build knows — which is what an unfiltered scope shows,
// since an unfiltered cost aggregate is a set of figures, not one.
func Provenance(sources ...string) []SourceProvenance {
	if len(sources) == 1 && sources[0] != "" {
		return []SourceProvenance{ProvenanceFor(sources[0])}
	}
	if len(sources) == 0 || (len(sources) == 1 && sources[0] == "") {
		sources = model.Sources
	}
	out := make([]SourceProvenance, 0, len(sources))
	for _, s := range sources {
		out = append(out, ProvenanceFor(s))
	}
	return out
}

// Note is the single sentence a surface prints when it has room for one: the
// source's own note when the scope is one source, and the mixed-source rule
// when it is not.
//
// This replaces the older "anything that is not Claude gets the Codex note"
// test, which attached OpenAI's wording to gateway figures (the opposite of
// true for a source that is billed) and to unfiltered ones (which have no
// single basis at all).
func Note(source string) string {
	if source == "" {
		return MixedSourceNote
	}
	return ProvenanceFor(source).Note
}
