package pricing

import "github.com/verkyyi/ccquota/internal/model"

// VoicePriceNote says what every surface showing a voice figure has to say.
//
// It is the third kind of claim this column carries. Claude and Codex are
// notional; gateway and vendor bill are money that was actually charged. Voice
// rows are money too — but by default nobody here has priced them, and the
// honest reading of a zero is "not priced", not "free".
const VoicePriceNote = "Voice: usage an application reported about its own model calls — realtime speech " +
	"recognition and streaming synthesis, which travel as WebSocket frames past anything this deployment can meter. " +
	"These rows exist to make that usage visible and attributable (tenant, session, seconds heard, characters spoken); " +
	"the vendor's invoice cannot supply any of that — measured on this deployment it reported 0 seconds of speech " +
	"recognition while the agent was running. Money is the invoice's job: a row here is unpriced unless a collector " +
	"supplied a charge, and any billing item priced here must be excluded from the bill collector's include list so " +
	"the same spend is never counted twice. Safe to add to a gateway or vendor-bill total (all three are charges); " +
	"never add any of them to a Claude or Codex figure."

// voiceCost returns the supplied charge unchanged, or nil.
//
// Like vendorBillCost this computes nothing, but for the opposite reason: the
// vendor bill already had the number, whereas here nobody has one yet. The
// deliberate consequence is that the usage shows up in the ledger with a cost
// of *unknown* rather than 0 — a speech session that cost something real must
// never read as free just because this hub has no rate for it.
//
// Pricing these rows is a collector-side decision, not a table here: the rate
// depends on which engine served the session (the app reports it per session),
// and whichever side prices a billing item, the other must stop — see
// model.SourceVoice.
func voiceCost(ev *model.UsageEvent) *float64 {
	if d := ev.Details; d != nil {
		d.PriceSource = VoicePriceNote
		if ev.CostUSD == nil {
			d.PriceBasis = "unpriced: usage reported by the application, no charge supplied — " +
				"the money for this engine comes from the vendor invoice"
		} else {
			d.PriceBasis = "charge supplied by the reporting collector, taken as supplied"
		}
	}
	return ev.CostUSD
}
