package pricing

import (
	"github.com/verkyyi/ccquota/internal/model"
	"strings"
)

const OpenAIRatesAsOf = "2026-09-07"
const OpenAIPriceSource = "https://developers.openai.com/api/docs/pricing"
const OpenAIPriceNote = "Codex: API equivalent at 2026-09-07 published rates, including historical revaluation. Missing service tier uses Standard. Subscription bills and credits are separate; unknown provider/model/cache-write breakdown remains unpriced."

var openAIRates = map[string]Rates{
	"gpt-6-astra":   {Input: 10, CacheRead: 1, CacheWrite5m: 12.5, Output: 50},
	"gpt-5.6-sol":   {Input: 4, CacheRead: .4, CacheWrite5m: 5, Output: 20},
	"gpt-5.6-terra": {Input: 2, CacheRead: .2, CacheWrite5m: 2.5, Output: 12},
	"gpt-5.6-luna":  {Input: .2, CacheRead: .02, CacheWrite5m: .25, Output: 1.2},
	"gpt-5.2-codex": {Input: 1.75, CacheRead: .175, Output: 14},
	"gpt-5.4":       {Input: 2.5, CacheRead: .25, Output: 15},
	"gpt-5.5":       {Input: 5, CacheRead: .5, Output: 30},
	"gpt-5.3-codex": {Input: 1.75, CacheRead: .175, Output: 14},
}

func codexCost(e *model.UsageEvent) *float64 {
	d := e.Details
	if d == nil {
		return nil
	}
	d.PriceVersion = "openai-" + OpenAIRatesAsOf
	d.PriceSource = OpenAIPriceSource
	d.PriceBasis = "unpriced: unknown provider or model"
	name := Normalize(e.Model)
	r, ok := openAIRates[name]
	if !ok || d.Provider != "openai" {
		return nil
	}
	var write int64
	if r.CacheWrite5m > 0 && d.CacheWrite == nil {
		d.PriceBasis = "unpriced: cache-write breakdown unavailable"
		return nil
	}
	if d.CacheWrite != nil {
		write = *d.CacheWrite
	}
	if write < 0 || write > e.InputTokens || (write > 0 && r.CacheWrite5m == 0) {
		d.PriceBasis = "unpriced: unsupported cache-write breakdown"
		return nil
	}
	tier := strings.ToLower(d.ServiceTier)
	factor := 1.0
	switch tier {
	case "", "default", "standard":
	case "priority", "fast":
		if name == "gpt-5.4" || name == "gpt-5.5" || name == "gpt-5.2-codex" {
			d.PriceBasis = "unpriced: legacy Fast rate not verified"
			return nil
		}
		factor = 2
	case "flex", "batch":
		if r.CacheWrite5m == 0 {
			d.PriceBasis = "unpriced: unsupported service tier"
			return nil
		}
		factor = .5
	default:
		d.PriceBasis = "unpriced: unknown service tier"
		return nil
	}
	d.PriceBasis = "API equivalent at " + OpenAIRatesAsOf + " rates; "
	if tier == "" {
		d.PriceBasis += "Standard assumed (tier absent)"
	} else {
		d.PriceBasis += tier
	}
	// The threshold uses the complete prompt, including cached input.
	if (r.CacheWrite5m > 0 || name == "gpt-5.4" || name == "gpt-5.5") && e.InputTokens+e.CacheRead > 272000 {
		r.Input *= 2
		r.CacheRead *= 2
		r.CacheWrite5m *= 2
		r.Output *= 1.5
		d.PriceBasis += "; >272K input tier"
	}
	if name == "gpt-5.4" || name == "gpt-5.5" {
		d.PriceBasis += "; per-request equivalent (session-wide adjustments unavailable)"
	}
	c := (float64(e.InputTokens-write)*r.Input + float64(write)*r.CacheWrite5m + float64(e.CacheRead)*r.CacheRead + float64(e.OutputTokens)*r.Output) / 1e6 * factor
	return &c
}
