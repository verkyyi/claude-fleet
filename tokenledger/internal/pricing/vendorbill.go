package pricing

import "github.com/verkyyi/ccquota/internal/model"

// VendorBillPriceNote says what every surface showing a vendor-bill figure has
// to say. It is the counterpart of GatewayPriceNote: both are real money, but
// this one was not measured here at all.
const VendorBillPriceNote = "Vendor bill: read off the provider's invoice, not metered from a request. " +
	"The figure is what was actually charged for spend that never passes through this deployment's gateway " +
	"(asynchronous task APIs — video generation, file transcription — hand back a vendor-signed result URL and " +
	"require publicly fetchable input, so nothing sits in that data path). Because an invoice line has no caller, " +
	"these rows carry no per-app attribution and no token counters; the billing unit is seconds, images or calls. " +
	"Safe to add to a gateway total (both are charges); never add either to a Claude or Codex figure."

// vendorBillCost returns the supplied charge unchanged.
//
// This is the one place in the package that does not compute a cost, and the
// reason is the whole point of the source: there is no rate to apply, because
// the number already came from the invoice. Running it through a rate table
// would replace a known charge with a guess — exactly backwards from every
// other branch here, where nil means "unknown" and a number means "derived".
//
// A row arriving without a cost stays unpriced rather than becoming 0: a bill
// collector that failed to read an amount has not discovered that something
// was free.
func vendorBillCost(ev *model.UsageEvent) *float64 {
	if d := ev.Details; d != nil {
		d.PriceSource = VendorBillPriceNote
		if ev.CostUSD == nil {
			d.PriceBasis = "unpriced: vendor bill row carried no amount"
		} else {
			// The billing period and the line item live in Model/TS, which the
			// collector fills from the invoice row; stating them again here
			// would be a second place to keep in sync.
			d.PriceBasis = "vendor invoice amount, taken as supplied"
		}
	}
	return ev.CostUSD
}
