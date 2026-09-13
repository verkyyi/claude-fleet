package pricing

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"time"

	"github.com/verkyyi/ccquota/internal/model"
)

// PlanPrice is one subscription price as declared in an overrides file.
//
// No amounts ship in this repo. A subscription price is a contract between an
// operator and a vendor — it varies by region, seat count and negotiation —
// so a built-in table would be wrong for most hubs while looking authoritative
// on all of them. The per-token rates in this package can have defaults
// because they are published; these cannot.
type PlanPrice struct {
	Plan          string  `json:"plan"`   // matches an account's subscription_type
	Source        string  `json:"source"` // 'claude' | 'codex' | ...; defaults to claude
	MonthlyCost   float64 `json:"monthly_cost"`
	Currency      string  `json:"currency"`       // defaults to USD downstream
	EffectiveFrom string  `json:"effective_from"` // RFC3339; when this price started
}

// LoadPlanPrices reads the subscription prices declared in an overrides file.
//
// Deliberately NOT a method on Table, and deliberately a separate type from
// Rates. Table holds per-token rates, which are NOTIONAL — "what this would
// have cost at API rates", explicitly not an invoice. A subscription price is
// real money that is billed whether or not a token is spent. Keeping the two
// apart in the type system is the cheapest available guard against the one
// mistake that matters here: adding them together.
//
// A missing file is not an error, matching LoadOverrides: overrides are
// optional, and a hub that has not priced its plans reports them as unpriced
// rather than refusing to start.
func LoadPlanPrices(path string) ([]model.SubscriptionPlan, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return nil, nil
		}
		return nil, fmt.Errorf("read pricing overrides: %w", err)
	}
	var doc struct {
		Plans []PlanPrice `json:"plans"`
	}
	if err := json.Unmarshal(b, &doc); err != nil {
		return nil, fmt.Errorf("parse pricing overrides %s: %w", path, err)
	}

	out := make([]model.SubscriptionPlan, 0, len(doc.Plans))
	for i, p := range doc.Plans {
		if p.Plan == "" {
			return nil, fmt.Errorf("%s: plans[%d] has no plan name", path, i)
		}
		if p.EffectiveFrom == "" {
			return nil, fmt.Errorf("%s: plans[%d] (%s) has no effective_from; "+
				"an undated price cannot be applied to a reporting period", path, i, p.Plan)
		}
		from, err := time.Parse(time.RFC3339, p.EffectiveFrom)
		if err != nil {
			return nil, fmt.Errorf("%s: plans[%d] (%s) effective_from %q is not RFC3339: %w",
				path, i, p.Plan, p.EffectiveFrom, err)
		}
		out = append(out, model.SubscriptionPlan{
			Plan:          p.Plan,
			Source:        model.UsageSource(p.Source),
			MonthlyCost:   p.MonthlyCost,
			Currency:      p.Currency,
			EffectiveFrom: from.UTC(),
		})
	}
	return out, nil
}
