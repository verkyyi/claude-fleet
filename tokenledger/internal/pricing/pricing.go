// Package pricing turns token counts into a notional US-dollar figure.
//
// "Notional" matters. On a Pro or Max subscription nobody is billed per token;
// the number here answers "what would this have cost at API rates", which is
// useful for ranking endpoints and projects against each other and misleading
// if read as an invoice. Every surface that displays it says so.
//
// Two sources break that rule and have to say so louder: gateway usage is
// pay-per-call, so its figure IS the invoice (see gateway.go), and vendor-bill
// rows are read straight off the provider's invoice (see vendorbill.go) —
// that one is the only branch here that computes nothing at all. cost_usd
// therefore means two different KINDS of thing depending on source, which is
// worse than mixing token counts because it looks like money. Costs of
// different kinds must never be summed; the two billed ones may be.
package pricing

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/verkyyi/ccquota/internal/model"
)

// RatesAsOf documents when the built-in table was last checked against
// Anthropic's published pricing. Stale rates are a reporting bug, so the
// dashboard shows this date next to any cost figure.
const RatesAsOf = "2026-09-01"

// Rates are US dollars per million tokens.
type Rates struct {
	Input        float64 `json:"input"`
	Output       float64 `json:"output"`
	CacheWrite5m float64 `json:"cache_write_5m"`
	CacheWrite1h float64 `json:"cache_write_1h"`
	CacheRead    float64 `json:"cache_read"`

	// Unit and Price are the OTHER shape a rate can take: a price per
	// non-token billing unit — per image, per second of audio, per call.
	// They exist because a growing share of what the gateway fronts is not
	// billed per token at all, and the alternative (invent a token count and
	// reuse Input/Output) is the one thing this package refuses: a made-up
	// number would be summed into every token total in this hub and read as
	// real. Same rule as Details.Usage, one layer up.
	//
	// A rate carries EXACTLY ONE shape. validateGatewayRates enforces that,
	// because a rate carrying both would price the same event twice and there
	// is no reading of the result that is correct.
	//
	// Price is in the same currency as Input/Output (CNY for the gateway
	// table), but per Unit rather than per million tokens.
	Unit  string  `json:"unit,omitempty"`
	Price float64 `json:"price,omitempty"`

	// FreeMonthlyTokens is a vendor's free monthly allowance for this model.
	//
	// It exists because "no rate configured" and "free" are different facts that
	// this table could not previously tell apart. doubao ships a free monthly
	// tier; leaving it unpriced happens to produce the right total today, but it
	// produces it for the wrong reason — the model reads as a pricing GAP, and
	// the day the allowance is exceeded nothing changes on its own.
	//
	// Declaring it flips both: an event inside the allowance prices to 0 with a
	// basis that says WHY it is 0, and crossing the allowance raises a finding
	// rather than passing silently.
	//
	// It is deliberately NOT applied per event by counting tokens as they
	// arrive. Table.Cost is a pure function of one event and is shared by ingest
	// and --reprice precisely so the two cannot disagree; a running monthly
	// counter would make a price depend on the ORDER events were seen in, and a
	// repriced month would no longer reproduce the month it replaced. The
	// allowance is therefore priced as 0 while it holds, and the crossing is
	// reported by internal/findings from the month's own totals — a fact the
	// store can establish exactly, which a per-event function cannot.
	FreeMonthlyTokens int64 `json:"free_monthly_tokens,omitempty"`

	// Peak is a time-of-day surcharge on whichever shape above this rate
	// carries. Nil means the contract charges one price around the clock.
	//
	// It exists because some contracts are priced by WHEN the call happened, and
	// a table that can only say one number per model cannot express them at all.
	// DeepSeek is the case that forced it: peak hours cost a multiple of
	// off-peak, on a published schedule. Before this, the honest options were to
	// leave the model unpriced (what this deployment did) or to pick one of the
	// two numbers and be wrong for most of the day — LiteLLM's table fills in
	// the peak price and therefore overstates roughly 79% of the hours.
	//
	// The base Input/Output/Price are the OFF-PEAK rate and Multiplier scales
	// them inside the window. That direction is deliberate: the cheaper number
	// is the one a contract quotes as its headline, so a reader who ignores the
	// peak block entirely under-reads rather than over-reads the bill, and an
	// unnoticed omission errs toward "look again" rather than a confident
	// overcharge.
	Peak *PeakWindow `json:"peak,omitempty"`
}

// PeakWindow is when a contract charges its surcharge, and how much.
//
// Hours are UTC and stated as "HH:MM-HH:MM" so a window reads the way the
// contract writes it. A window may cross midnight ("22:30-02:00"). The event's
// own timestamp decides — never "now" — so repricing an old event lands in the
// same tier it did when it happened (see store.Reprice).
type PeakWindow struct {
	// Multiplier scales the off-peak rate inside the window. Greater than 1 by
	// definition, which validation enforces: a "peak" that charges less is
	// somebody's inverted window, and silently honouring it would underreport a
	// real bill for most of the day.
	Multiplier float64 `json:"multiplier"`
	// UTCHours are the windows, each "HH:MM-HH:MM". At least one is required —
	// a peak block naming no hours would apply the surcharge nowhere while
	// looking configured.
	UTCHours []string `json:"utc_hours"`
	// WeekdaysOnly limits the windows to Mon-Fri UTC, which is how the
	// contracts that have a peak tier tend to state it.
	WeekdaysOnly bool `json:"weekdays_only,omitempty"`
}

// AppliesAt reports whether ts falls inside the surcharge.
func (w *PeakWindow) AppliesAt(ts time.Time) bool {
	if w == nil {
		return false
	}
	t := ts.UTC()
	if w.WeekdaysOnly {
		switch t.Weekday() {
		case time.Saturday, time.Sunday:
			return false
		}
	}
	mins := t.Hour()*60 + t.Minute()
	for _, spec := range w.UTCHours {
		from, to, ok := parseWindow(spec)
		if !ok {
			continue
		}
		switch {
		case from == to:
			// A zero-width window matches nothing; validation rejects it, and
			// treating it as "all day" here would be the worst possible reading.
		case from < to:
			if mins >= from && mins < to {
				return true
			}
		default:
			// Crosses midnight: inside means after the start OR before the end.
			if mins >= from || mins < to {
				return true
			}
		}
	}
	return false
}

// parseWindow reads "HH:MM-HH:MM" into minutes-from-midnight. The bool says
// whether it parsed at all; validateGatewayRates rejects the ones that do not,
// so a running hub never silently skips a window it could not read.
func parseWindow(spec string) (from, to int, ok bool) {
	a, b, found := strings.Cut(spec, "-")
	if !found {
		return 0, 0, false
	}
	from, ok = parseHHMM(a)
	if !ok {
		return 0, 0, false
	}
	to, ok = parseHHMM(b)
	if !ok {
		return 0, 0, false
	}
	return from, to, true
}

func parseHHMM(s string) (int, bool) {
	h, m, found := strings.Cut(strings.TrimSpace(s), ":")
	if !found {
		return 0, false
	}
	hh, err := strconv.Atoi(h)
	if err != nil || hh < 0 || hh > 23 {
		return 0, false
	}
	mm, err := strconv.Atoi(m)
	if err != nil || mm < 0 || mm > 59 {
		return 0, false
	}
	return hh*60 + mm, true
}

// PricedByUnit says which of the two shapes this rate carries. It reads the
// unit, not the price: a rate naming a unit with a zero price is a
// misconfiguration to be reported, not a token rate to fall back to.
func (r Rates) PricedByUnit() bool { return r.Unit != "" }

// GatewayUnits are the billing units the gateway table accepts. The list is
// closed on purpose: a typo'd unit would never match an event's UsageUnit,
// and the event would stay silently unpriced instead of loudly rejected at
// startup.
//
// "call" is the flat-fee escape hatch (bill per request regardless of size);
// it pairs with an event whose Usage is the number of calls the row covers,
// which for a one-row-per-call source is 1.
var GatewayUnits = map[string]bool{"image": true, "second": true, "char": true, "call": true}

// Cache rates are published as multiples of the base input rate rather than as
// independent numbers, so deriving them keeps the table honest: a corrected
// input rate corrects its cache rates too, instead of leaving three stale
// figures behind.
const (
	cacheWrite5mMultiplier = 1.25
	cacheWrite1hMultiplier = 2.0
	cacheReadMultiplier    = 0.1
)

// tier builds a full rate set from the two published headline numbers.
func tier(input, output float64) Rates {
	return Rates{
		Input:        input,
		Output:       output,
		CacheWrite5m: input * cacheWrite5mMultiplier,
		CacheWrite1h: input * cacheWrite1hMultiplier,
		CacheRead:    input * cacheReadMultiplier,
	}
}

// Table maps a normalized model id to its rates.
type Table struct {
	rates map[string]Rates
	gw    gatewayPricing
}

// Default returns the built-in table.
//
// Keys are base model ids with no date suffix; see Normalize. Models absent
// here are reported as unpriced rather than free.
func Default() *Table {
	return &Table{rates: map[string]Rates{
		// Current generation.
		"claude-fable-5":  tier(10, 50),
		"claude-mythos-5": tier(10, 50),
		"claude-opus-5":   tier(5, 25),
		"claude-opus-4-8": tier(5, 25),
		"claude-opus-4-7": tier(5, 25),
		"claude-opus-4-6": tier(5, 25),
		"claude-sonnet-5": tier(2, 10),

		// Previous generation, still present in older transcripts.
		"claude-sonnet-4-6": tier(3, 15),
		"claude-opus-4-5":   tier(5, 25),
		"claude-sonnet-4-5": tier(3, 15),
		"claude-haiku-4-5":  tier(1, 5),
	}, gw: defaultGateway()}
}

// dateSuffix matches the trailing snapshot date on ids like
// claude-haiku-4-5-20251001.
var dateSuffix = regexp.MustCompile(`-(\d{8}|\d{4}-\d{2}-\d{2})$`)

// Normalize reduces a transcript's model id to the table's key.
func Normalize(id string) string {
	return dateSuffix.ReplaceAllString(id, "")
}

// Cost returns the notional cost of one event, or nil when the model is not in
// the table.
//
// nil rather than zero is deliberate: an unpriced model is an admission that
// the figure is unknown. Zero is a claim that the work was free, and a busy
// endpoint running an unrecognised model would silently rank as idle.
func (t *Table) Cost(ev *model.UsageEvent) *float64 {
	switch ev.Source {
	case model.SourceCodex:
		return codexCost(ev)
	case model.SourceGateway:
		return t.gatewayCost(ev)
	case model.SourceVendorBill:
		return vendorBillCost(ev)
	case model.SourceVoice:
		return voiceCost(ev)
	}
	r, ok := t.rates[Normalize(ev.Model)]
	if !ok {
		return nil
	}
	const perMillion = 1_000_000.0
	c := float64(ev.InputTokens)/perMillion*r.Input +
		float64(ev.OutputTokens)/perMillion*r.Output +
		float64(ev.CacheCreate5m)/perMillion*r.CacheWrite5m +
		float64(ev.CacheCreate1h)/perMillion*r.CacheWrite1h +
		float64(ev.CacheRead)/perMillion*r.CacheRead
	return &c
}

// Known reports whether a model has rates.
func (t *Table) Known(modelID string) bool {
	id := Normalize(modelID)
	if _, ok := openAIRates[id]; ok {
		return true
	}
	if _, ok := t.gw.rates[id]; ok {
		return true
	}
	_, ok := t.rates[id]
	return ok
}

// LoadOverrides merges rates from a JSON file over the built-in table.
//
// Merge, not replace: an operator correcting one model's rate must not lose
// every other model. A missing file is not an error — overrides are optional.
func (t *Table) LoadOverrides(path string) error {
	b, err := os.ReadFile(path)
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return nil
		}
		return fmt.Errorf("read pricing overrides: %w", err)
	}
	var doc struct {
		Models  map[string]Rates `json:"models"`
		Gateway *gatewayOverride `json:"gateway"`
	}
	if err := json.Unmarshal(b, &doc); err != nil {
		return fmt.Errorf("parse pricing overrides %s: %w", path, err)
	}
	// Validate the whole file before applying any of it: a typo in the gateway
	// block must not leave the table half-corrected.
	if doc.Gateway != nil {
		if err := doc.Gateway.validate(path); err != nil {
			return err
		}
	}
	for id, r := range doc.Models {
		t.rates[Normalize(id)] = r
	}
	if doc.Gateway != nil {
		t.gw.merge(doc.Gateway)
	}
	return nil
}

// Apply stamps CostUSD on each event in place.
func (t *Table) Apply(evs []model.UsageEvent) {
	for i := range evs {
		evs[i].CostUSD = t.Cost(&evs[i])
	}
}
