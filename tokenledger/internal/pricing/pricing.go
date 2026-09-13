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
}

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
