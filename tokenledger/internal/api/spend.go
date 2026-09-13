// internal/api/spend.go
package api

import (
	"fmt"

	"github.com/verkyyi/ccquota/internal/store"
)

// RealSpend is the only figure on the Review page that is money somebody was
// actually charged.
//
// It has exactly two terms — subscription invoices and metered gateway calls —
// and the notional token figure is not one of them, cannot be added into one,
// and is not reachable from this type. Everything the hub knows about cost is
// in the summary beside it; this is the subset that would appear on a bill.
type RealSpend struct {
	Currency     string  `json:"currency"`
	Subscription float64 `json:"subscription"`
	Gateway      float64 `json:"gateway"`
	Total        float64 `json:"total"`

	// Complete is false when something real is missing from Total: a plan
	// nobody has priced, or a plan priced in a currency this hub cannot
	// convert. Missing is reported rather than silently omitted, because the
	// error is always in the one direction nobody double-checks — too low.
	Complete bool     `json:"complete"`
	Missing  []string `json:"missing,omitempty"`
}

// RealSpendOver adds the two real terms and says what it could not add.
//
// It takes the whole CostBySource rather than a gateway figure so that the
// caller cannot hand it the wrong number: the only cost this can reach is
// Billed(), and the notional figure is unreachable from here by construction.
//
// No FX, matching store.DefaultCurrency's rule: a plan quoted in another
// currency is listed as missing rather than converted at an invented rate.
func RealSpendOver(cost store.CostBySource, plans []store.SubscriptionSpend) RealSpend {
	out := RealSpend{Currency: store.DefaultCurrency, Gateway: cost.Billed(), Complete: true}
	for _, p := range plans {
		switch {
		case !p.Priced:
			out.Complete = false
			out.Missing = append(out.Missing, fmt.Sprintf(
				"%s/%s (%d seat(s)) has no recorded price for this period", p.Source, p.Plan, p.Seats))
		case p.Currency != out.Currency:
			out.Complete = false
			out.Missing = append(out.Missing, fmt.Sprintf(
				"%s/%s is priced in %s and this hub does no currency conversion", p.Source, p.Plan, p.Currency))
		default:
			out.Subscription += p.Amount
		}
	}
	out.Total = out.Subscription + out.Gateway
	return out
}

// RealSpendNote is what the figure above has to say for itself wherever it is
// shown.
const RealSpendNote = "Real spend is subscription invoices plus metered gateway charges. " +
	"The notional token cost is NOT part of it: nobody is billed per token on a subscription, " +
	"so adding that figure here would invent spending that never happened."
