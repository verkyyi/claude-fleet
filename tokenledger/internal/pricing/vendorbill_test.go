package pricing

import (
	"testing"

	"github.com/verkyyi/ccquota/internal/model"
)

func f(v float64) *float64 { return &v }

// The whole point of the source: the supplied amount survives. Apply() stamps
// CostUSD unconditionally, so a branch that recomputed (or returned nil) would
// silently erase an invoice figure — and nothing downstream could tell.
func TestVendorBillCostIsTakenAsSupplied(t *testing.T) {
	evs := []model.UsageEvent{{
		Source:  model.SourceVendorBill,
		Model:   "doubao-seedance-2-5",
		CostUSD: f(38.75),
		Details: &model.UsageDetails{},
	}}
	Default().Apply(evs)
	if evs[0].CostUSD == nil || *evs[0].CostUSD != 38.75 {
		t.Fatalf("cost = %v, want 38.75 unchanged", evs[0].CostUSD)
	}
	if evs[0].Details.PriceSource != VendorBillPriceNote {
		t.Errorf("price source not stamped: %q", evs[0].Details.PriceSource)
	}
}

// Zero tokens must not turn into zero money, and a model nobody has rates for
// must not turn the invoice figure into nil. Both would happen if this source
// fell through to the token-rate path.
func TestVendorBillIgnoresTokensAndRateTable(t *testing.T) {
	evs := []model.UsageEvent{{
		Source:  model.SourceVendorBill,
		Model:   "no-such-model-in-any-table",
		CostUSD: f(1.5),
	}}
	Default().Apply(evs)
	if evs[0].CostUSD == nil || *evs[0].CostUSD != 1.5 {
		t.Fatalf("cost = %v, want 1.5", evs[0].CostUSD)
	}
}

// A collector that failed to read an amount has not discovered that something
// was free. nil stays nil.
func TestVendorBillWithoutAmountStaysUnpriced(t *testing.T) {
	evs := []model.UsageEvent{{
		Source:  model.SourceVendorBill,
		Model:   "doubao-seedance-2-5",
		Details: &model.UsageDetails{},
	}}
	Default().Apply(evs)
	if evs[0].CostUSD != nil {
		t.Fatalf("cost = %v, want nil (unpriced, not free)", *evs[0].CostUSD)
	}
	if evs[0].Details.PriceBasis == "" {
		t.Error("unpriced row must say why in its price basis")
	}
}

// It is real money, so it belongs in the billed fold — and must never land in
// the notional one.
func TestVendorBillIsBilledMoney(t *testing.T) {
	if got := model.CostKind(model.SourceVendorBill); got != model.CostBilled {
		t.Fatalf("kind = %q, want %q", got, model.CostBilled)
	}
}
