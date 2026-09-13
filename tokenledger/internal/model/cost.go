package model

// The three kinds of money in this hub.
//
// cost_usd is one column carrying two different claims, and a third kind of
// money never enters that column at all:
//
//   - CostNotional — Claude and Codex. "What this would have cost at API
//     rates." Nobody is billed it. Useful for ranking, misleading as an
//     invoice.
//   - CostBilled — the gateway (metered per call) and vendor bills (read off
//     the invoice). Either way the figure IS money that was charged.
//   - subscription spend — real money, billed monthly whether or not a token
//     is spent. It lives in subscription_plans, never in cost_usd; see
//     store.SubscriptionSpend.
//
// Real spend is subscription + billed. A notional figure must never enter that
// sum, and two figures of different kinds must never be added at all. This is
// the same discipline get_account_usage and get_live already apply to
// overlapping TOKEN counters, extended to the column that looks like money.
const (
	CostNotional = "notional"
	CostBilled   = "billed"

	// CostUnknown is a source this build has not classified. It is deliberately
	// neither kind: a new source defaulting into "notional" would silently add
	// a real charge to an estimate, and defaulting into "billed" would do the
	// reverse. Unknown money is reported on its own and folded into nothing.
	CostUnknown = "unknown"
)

// Sources is every collector source this build knows, in display order.
//
// This is the closed set the cost split is built from: a source added to the
// constants above and forgotten here is caught by the guard in cost_test.go,
// because an unclassified source silently becomes CostUnknown everywhere.
var Sources = []string{SourceClaude, SourceCodex, SourceGateway, SourceVendorBill, SourceVoice}

// KnownSource reports whether source names a collector this build understands.
// The empty string is not a source — it is "no constraint" to a filter and
// "Claude" to a stored row; callers that mean either say so themselves.
func KnownSource(source string) bool {
	for _, s := range Sources {
		if s == source {
			return true
		}
	}
	return false
}

// CostKind says which kind of money a source's cost_usd is.
//
// Every fold of a cost aggregate goes through this rather than testing source
// names inline: one place decides, so adding a source is one edit and a failing
// test rather than a blended total nobody notices.
func CostKind(source string) string {
	switch UsageSource(source) {
	case SourceClaude, SourceCodex:
		return CostNotional
	case SourceGateway, SourceVendorBill, SourceVoice:
		// Both are real charges, and they are deliberately the same kind even
		// though they are measured differently (metered per call vs. read off
		// the invoice). Real spend is one question — "what did this cost" —
		// and the two answers are commensurable; a notional figure is not.
		// ⚠️ They can still DOUBLE-COUNT if a collector ever bills the same
		// spend both ways. Keep the division at the source: the bill collector
		// must only carry what no gateway route can see.
		return CostBilled
	}
	return CostUnknown
}
