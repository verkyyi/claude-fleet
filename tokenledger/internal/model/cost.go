package model

// What cost_usd means.
//
// Claude and Codex are the only sources (claude-fleet#1987), and both carry a
// NOTIONAL figure: "what this would have cost at API rates". Nobody is billed
// it — useful for ranking, misleading as an invoice. Real money is the
// subscription, billed monthly whether or not a token is spent; it lives in
// subscription_plans, never in cost_usd (see store.SubscriptionSpend), and the
// two are never added.
const (
	CostNotional = "notional"

	// CostUnknown is a source this build has not classified. Unknown money is
	// reported on its own and folded into nothing.
	CostUnknown = "unknown"
)

// Sources is every collector source this build knows, in display order.
//
// This is the closed set the cost split is built from: a source added to the
// constants above and forgotten here is caught by the guard in cost_test.go,
// because an unclassified source silently becomes CostUnknown everywhere.
var Sources = []string{SourceClaude, SourceCodex}

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
	}
	return CostUnknown
}

// HasQuotaWindow reports whether a source's account can have a QUOTA WINDOW at
// all — a pool with a ceiling and a reset that "am I about to hit the wall?"
// is a question about. Both sources' subscriptions do.
//
// The default is deliberately false: a source added to the constants and
// forgotten here goes missing from a quota card, which is visible and
// harmless, rather than appearing there forever saying "no reading available".
// web/dist/lib/providers.js mirrors this set for the dashboard's own filter;
// the guard in cost_quota_test.go keeps both honest.
func HasQuotaWindow(source string) bool {
	switch UsageSource(source) {
	case SourceClaude, SourceCodex:
		return true
	}
	return false
}
