package pricing

import (
	"math"
	"os"
	"path/filepath"
	"testing"

	"github.com/verkyyi/ccquota/internal/model"
)

func approx(t *testing.T, got *float64, want float64) {
	t.Helper()
	if got == nil {
		t.Fatalf("cost = nil, want %v", want)
	}
	if math.Abs(*got-want) > 1e-9 {
		t.Fatalf("cost = %v, want %v", *got, want)
	}
}

func TestCost_InputAndOutput(t *testing.T) {
	tbl := Default()
	// Sonnet 5: $2.00 / $10.00 per MTok.
	ev := &model.UsageEvent{Model: "claude-sonnet-5", InputTokens: 1_000_000, OutputTokens: 1_000_000}
	approx(t, tbl.Cost(ev), 12.0)
}

// The whole reason CacheCreate5m and CacheCreate1h are separate columns: a 1h
// cache write costs 2x base input, a 5m write 1.25x. Collapsing them would
// misprice long-lived caches by 60%.
func TestCost_CacheWriteTTLsDiffer(t *testing.T) {
	tbl := Default()
	base := 2.0 // Sonnet 5 input, $/MTok

	five := &model.UsageEvent{Model: "claude-sonnet-5", CacheCreate5m: 1_000_000}
	approx(t, tbl.Cost(five), base*1.25)

	hour := &model.UsageEvent{Model: "claude-sonnet-5", CacheCreate1h: 1_000_000}
	approx(t, tbl.Cost(hour), base*2.0)

	if *tbl.Cost(five) == *tbl.Cost(hour) {
		t.Fatal("5m and 1h cache writes priced identically")
	}
}

func TestCost_CacheReadIsCheap(t *testing.T) {
	tbl := Default()
	ev := &model.UsageEvent{Model: "claude-sonnet-5", CacheRead: 1_000_000}
	approx(t, tbl.Cost(ev), 2.0*0.1)
}

// An unpriced model must be admitted, not guessed. Returning 0 would show a
// busy endpoint as free.
func TestCost_UnknownModelIsNilNotZero(t *testing.T) {
	tbl := Default()
	ev := &model.UsageEvent{Model: "claude-something-unreleased", InputTokens: 5_000_000}
	if got := tbl.Cost(ev); got != nil {
		t.Fatalf("cost = %v, want nil for an unknown model", *got)
	}
}

// Transcripts carry date-suffixed ids for older models; the table is keyed by
// the base id.
func TestNormalize_StripsDateSuffix(t *testing.T) {
	cases := map[string]string{
		"claude-haiku-4-5-20251001": "claude-haiku-4-5",
		"claude-opus-4-5-20251101":  "claude-opus-4-5",
		"claude-opus-5":             "claude-opus-5",
		"claude-sonnet-5":           "claude-sonnet-5",
		"":                          "",
	}
	for in, want := range cases {
		if got := Normalize(in); got != want {
			t.Errorf("Normalize(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestCost_DateSuffixedModelIsPriced(t *testing.T) {
	tbl := Default()
	ev := &model.UsageEvent{Model: "claude-haiku-4-5-20251001", InputTokens: 1_000_000}
	approx(t, tbl.Cost(ev), 1.0)
}

// Rates move. An operator must be able to correct them without waiting for a
// release, and an override must not wipe the models it does not mention.
func TestLoadOverrides_MergesNotReplaces(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "pricing.json")
	err := os.WriteFile(p, []byte(`{
	  "models": {
	    "claude-sonnet-5": {"input": 9.0, "output": 9.0, "cache_write_5m": 9.0, "cache_write_1h": 9.0, "cache_read": 9.0},
	    "some-new-model":  {"input": 1.0, "output": 2.0, "cache_write_5m": 1.25, "cache_write_1h": 2.0, "cache_read": 0.1}
	  }
	}`), 0o644)
	if err != nil {
		t.Fatal(err)
	}

	tbl := Default()
	if err := tbl.LoadOverrides(p); err != nil {
		t.Fatal(err)
	}

	approx(t, tbl.Cost(&model.UsageEvent{Model: "claude-sonnet-5", InputTokens: 1_000_000}), 9.0)
	approx(t, tbl.Cost(&model.UsageEvent{Model: "some-new-model", OutputTokens: 1_000_000}), 2.0)
	// Untouched by the override file.
	approx(t, tbl.Cost(&model.UsageEvent{Model: "claude-opus-5", InputTokens: 1_000_000}), 5.0)
}

func TestLoadOverrides_MissingFileIsNotAnError(t *testing.T) {
	tbl := Default()
	if err := tbl.LoadOverrides(filepath.Join(t.TempDir(), "absent.json")); err != nil {
		t.Fatalf("a missing override file should be ignored, got %v", err)
	}
}

func TestCost_ZeroTokensIsZeroNotNil(t *testing.T) {
	tbl := Default()
	ev := &model.UsageEvent{Model: "claude-opus-5"}
	got := tbl.Cost(ev)
	if got == nil || *got != 0 {
		t.Fatalf("cost = %v, want 0 for a priced model with no tokens", got)
	}
}

// Guards against a rate table entry being added with a zero output rate by
// mistake — a plausible-looking typo that would silently halve every bill.
func TestDefault_NoZeroRates(t *testing.T) {
	for id, r := range Default().rates {
		if r.Input <= 0 || r.Output <= 0 || r.CacheWrite5m <= 0 || r.CacheWrite1h <= 0 || r.CacheRead <= 0 {
			t.Errorf("%s has a non-positive rate: %+v", id, r)
		}
		if r.CacheWrite1h <= r.CacheWrite5m {
			t.Errorf("%s: 1h cache write (%v) must cost more than 5m (%v)", id, r.CacheWrite1h, r.CacheWrite5m)
		}
		if r.CacheRead >= r.Input {
			t.Errorf("%s: cache read (%v) must be cheaper than input (%v)", id, r.CacheRead, r.Input)
		}
	}
}
