package pricing

import (
	"math"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/verkyyi/ccquota/internal/model"
)

// A deployment's own contract, stated the way the vendors publish it: CNY per
// million tokens, input and output only.
const gatewayOverrideFile = `{
  "gateway": {
    "rates_as_of": "2026-09-10",
    "cny_per_usd": 7.0,
    "cny_per_usd_as_of": "2026-09-11",
    "price_source": "https://internal.example/gateway/pricing",
    "models": {"vendor-large": {"input": 7.0, "output": 70.0}}
  }
}`

func gatewayTable(t *testing.T, doc string) *Table {
	t.Helper()
	p := filepath.Join(t.TempDir(), "pricing.json")
	if err := os.WriteFile(p, []byte(doc), 0o644); err != nil {
		t.Fatal(err)
	}
	tbl := Default()
	if err := tbl.LoadOverrides(p); err != nil {
		t.Fatal(err)
	}
	return tbl
}

func gatewayEvent() *model.UsageEvent {
	return &model.UsageEvent{
		Source: model.SourceGateway, Model: "vendor-large",
		InputTokens: 1_000_000, OutputTokens: 1_000_000,
		Details: &model.UsageDetails{},
	}
}

// The conversion is the whole design question, so it is the first thing
// pinned: CNY 7 + CNY 70 at 7.0 CNY/USD is $11, not ¥77.
func TestGatewayCost_ConvertsCNYToUSDAndDisclosesIt(t *testing.T) {
	ev := gatewayEvent()
	got := gatewayTable(t, gatewayOverrideFile).Cost(ev)
	if got == nil || math.Abs(*got-11.0) > 1e-9 {
		t.Fatalf("cost = %v, want 11.0 (basis %q)", got, ev.Details.PriceBasis)
	}
	d := ev.Details
	// A figure that is a real charge may never appear without its conversion.
	for _, want := range []string{"billed:", "CNY 7 in / 70 out", "2026-09-10", "7.0000 CNY/USD", "2026-09-11"} {
		if !strings.Contains(d.PriceBasis, want) {
			t.Errorf("basis %q is missing %q", d.PriceBasis, want)
		}
	}
	if d.PriceVersion != "gateway-2026-09-10" {
		t.Errorf("price version = %q", d.PriceVersion)
	}
	if d.PriceSource != "https://internal.example/gateway/pricing" {
		t.Errorf("price source = %q", d.PriceSource)
	}
}

// Built-in defaults stay minimal on purpose: a rate baked into the image is a
// contract term this build cannot know. Unconfigured must say so, not guess.
func TestGatewayCost_UnconfiguredModelIsNilWithAReason(t *testing.T) {
	ev := gatewayEvent()
	if got := Default().Cost(ev); got != nil {
		t.Fatalf("cost = %v, want nil for a model with no configured rate", *got)
	}
	if ev.Details.PriceBasis != "unpriced: no gateway rate configured" {
		t.Errorf("basis = %q", ev.Details.PriceBasis)
	}
}

// The source carries no cache breakdown and the rates price input and output
// only, so a cache count means the rates no longer cover the event.
func TestGatewayCost_CacheTokensAreUnpricedNotIgnored(t *testing.T) {
	tbl := gatewayTable(t, gatewayOverrideFile)
	for _, ev := range []*model.UsageEvent{
		{Source: model.SourceGateway, Model: "vendor-large", InputTokens: 10, CacheRead: 1, Details: &model.UsageDetails{}},
		{Source: model.SourceGateway, Model: "vendor-large", InputTokens: 10, CacheCreate5m: 1, Details: &model.UsageDetails{}},
		{Source: model.SourceGateway, Model: "vendor-large", InputTokens: 10, CacheCreate1h: 1, Details: &model.UsageDetails{}},
	} {
		if got := tbl.Cost(ev); got != nil {
			t.Fatalf("cost = %v, want nil when cache tokens are present", *got)
		}
		if ev.Details.PriceBasis != "unpriced: gateway rates cover input and output only" {
			t.Errorf("basis = %q", ev.Details.PriceBasis)
		}
	}
	// The three cache columns being legitimately 0 is the normal case.
	ev := gatewayEvent()
	if got := tbl.Cost(ev); got == nil {
		t.Fatalf("zero cache columns should price, basis %q", ev.Details.PriceBasis)
	}
}

// Nowhere to stamp the basis means nowhere to disclose the conversion, and an
// undisclosed converted charge is the one output this source cannot emit.
func TestGatewayCost_NoDetailsIsUnpriced(t *testing.T) {
	ev := gatewayEvent()
	ev.Details = nil
	if got := gatewayTable(t, gatewayOverrideFile).Cost(ev); got != nil {
		t.Fatalf("cost = %v, want nil without a Details to carry the basis", *got)
	}
}

// The branch is chosen by source, not by model id: a gateway event naming a
// Claude model must not collect Anthropic rates.
func TestGatewayCost_SourceDecidesTheBranch(t *testing.T) {
	ev := &model.UsageEvent{Source: model.SourceGateway, Model: "claude-sonnet-5", InputTokens: 1_000_000, Details: &model.UsageDetails{}}
	if got := gatewayTable(t, gatewayOverrideFile).Cost(ev); got != nil {
		t.Fatalf("cost = %v, want nil — a gateway event must not be priced at Anthropic rates", *got)
	}
	// And the other direction: a claude event is untouched by gateway config.
	claude := &model.UsageEvent{Model: "claude-sonnet-5", InputTokens: 1_000_000}
	approx(t, gatewayTable(t, gatewayOverrideFile).Cost(claude), 2.0)
}

func TestGatewayCost_ZeroTokensIsZeroNotNil(t *testing.T) {
	ev := &model.UsageEvent{Source: model.SourceGateway, Model: "vendor-large", Details: &model.UsageDetails{}}
	got := gatewayTable(t, gatewayOverrideFile).Cost(ev)
	if got == nil || *got != 0 {
		t.Fatalf("cost = %v, want 0 for a configured model with no tokens", got)
	}
}

func TestGatewayKnown_RecognisesConfiguredModels(t *testing.T) {
	tbl := gatewayTable(t, gatewayOverrideFile)
	if !tbl.Known("vendor-large") {
		t.Error("a configured gateway model must be Known")
	}
	if Default().Known("vendor-large") {
		t.Error("an unconfigured gateway model must not be Known")
	}
	// The other two tables still answer for themselves.
	if !tbl.Known("gpt-6-astra") || !tbl.Known("claude-opus-5") {
		t.Error("gateway rates displaced another source's table")
	}
}

func TestGatewayOverrides_RejectDishonestBlocks(t *testing.T) {
	cases := map[string]string{
		"undated rates":       `{"gateway":{"models":{"m":{"input":1,"output":2}}}}`,
		"zero output":         `{"gateway":{"rates_as_of":"2026-09-10","models":{"m":{"input":1,"output":0}}}}`,
		"negative input":      `{"gateway":{"rates_as_of":"2026-09-10","models":{"m":{"input":-1,"output":2}}}}`,
		"cache rate supplied": `{"gateway":{"rates_as_of":"2026-09-10","models":{"m":{"input":1,"output":2,"cache_read":0.1}}}}`,
		"undated fx":          `{"gateway":{"cny_per_usd":7.0}}`,
		"zero fx":             `{"gateway":{"cny_per_usd":0,"cny_per_usd_as_of":"2026-09-10"}}`,
	}
	for name, doc := range cases {
		p := filepath.Join(t.TempDir(), "pricing.json")
		if err := os.WriteFile(p, []byte(doc), 0o644); err != nil {
			t.Fatal(err)
		}
		if err := Default().LoadOverrides(p); err == nil {
			t.Errorf("%s: accepted, want an error", name)
		}
	}
}

// A rejected file must change nothing at all — a half-applied override is a
// table nobody can reason about.
func TestGatewayOverrides_RejectedFileAppliesNothing(t *testing.T) {
	doc := `{
	  "models": {"claude-sonnet-5": {"input": 9, "output": 9, "cache_write_5m": 9, "cache_write_1h": 9, "cache_read": 9}},
	  "gateway": {"models": {"m": {"input": 1, "output": 2}}}
	}`
	p := filepath.Join(t.TempDir(), "pricing.json")
	if err := os.WriteFile(p, []byte(doc), 0o644); err != nil {
		t.Fatal(err)
	}
	tbl := Default()
	if err := tbl.LoadOverrides(p); err == nil {
		t.Fatal("undated gateway rates accepted")
	}
	approx(t, tbl.Cost(&model.UsageEvent{Model: "claude-sonnet-5", InputTokens: 1_000_000}), 2.0)
}

// Gateway rates merge like every other rate: correcting one must not drop the
// rest, and the built-in FX survives a models-only correction.
func TestGatewayOverrides_Merge(t *testing.T) {
	dir := t.TempDir()
	first := filepath.Join(dir, "a.json")
	second := filepath.Join(dir, "b.json")
	if err := os.WriteFile(first, []byte(gatewayOverrideFile), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(second, []byte(`{"gateway":{"rates_as_of":"2026-09-12","models":{"vendor-small":{"input":0.7,"output":7}}}}`), 0o644); err != nil {
		t.Fatal(err)
	}
	tbl := Default()
	if err := tbl.LoadOverrides(first); err != nil {
		t.Fatal(err)
	}
	if err := tbl.LoadOverrides(second); err != nil {
		t.Fatal(err)
	}
	small := &model.UsageEvent{Source: model.SourceGateway, Model: "vendor-small", OutputTokens: 1_000_000, Details: &model.UsageDetails{}}
	approx(t, tbl.Cost(small), 1.0) // CNY 7 at the 7.0 rate carried over
	large := gatewayEvent()
	if got := tbl.Cost(large); got == nil {
		t.Fatalf("the earlier model was dropped, basis %q", large.Details.PriceBasis)
	}
}

// The note is the only place a reader is told this column changed meaning.
func TestGatewayPriceNote_SaysItIsBilled(t *testing.T) {
	for _, want := range []string{"billed", "never add", "cny"} {
		if !strings.Contains(strings.ToLower(GatewayPriceNote), want) {
			t.Errorf("note is missing %q: %s", want, GatewayPriceNote)
		}
	}
}
