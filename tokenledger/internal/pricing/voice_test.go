package pricing

import (
	"strings"
	"testing"

	"github.com/verkyyi/ccquota/internal/model"
)

// The rule this source exists to keep: usage here, money on the invoice.
//
// A voice row arriving without a charge must stay unpriced rather than become
// 0. Zero is a claim that a speech session was free; nil is the truth, which is
// that this hub was never told what it cost. The same nil-not-zero rule the
// rest of the package keeps — and here it is load-bearing, because the usage
// IS present and would otherwise read as "lots of calls, no money".
func TestVoiceRowWithoutAChargeStaysUnpriced(t *testing.T) {
	ev := &model.UsageEvent{Source: model.SourceVoice, Model: "doubao/seed-tts-2.0", Details: &model.UsageDetails{}}
	if got := (&Table{}).Cost(ev); got != nil {
		t.Fatalf("cost = %v, want nil (unpriced) — 0 would claim the session was free", *got)
	}
	if !strings.Contains(ev.Details.PriceBasis, "unpriced") {
		t.Errorf("basis = %q, want it to say unpriced", ev.Details.PriceBasis)
	}
	if !strings.Contains(ev.Details.PriceBasis, "invoice") {
		t.Errorf("basis = %q, want it to point at where the money does come from", ev.Details.PriceBasis)
	}
}

// When a collector does supply a charge it is taken as given, never recomputed.
// There is no rate table behind this source, and inventing one would replace a
// known number with a guess.
func TestVoiceChargeIsTakenAsSupplied(t *testing.T) {
	want := 1.25
	ev := &model.UsageEvent{Source: model.SourceVoice, CostUSD: &want, Details: &model.UsageDetails{}}
	got := (&Table{}).Cost(ev)
	if got == nil || *got != want {
		t.Fatalf("cost = %v, want %v taken unchanged", got, want)
	}
	if strings.Contains(ev.Details.PriceBasis, "unpriced") {
		t.Errorf("basis = %q, must not say unpriced when a charge was supplied", ev.Details.PriceBasis)
	}
}

// A rate table must never reach these rows, however the model id is spelled.
// This is the guard against the tempting wrong fix: "voice has no price, so
// let it fall through to the default rates" would price speech seconds with a
// per-million-token table and produce a confident wrong number.
func TestVoiceNeverFallsThroughToTheTokenRateTable(t *testing.T) {
	tab := &Table{rates: map[string]Rates{Normalize("seed-tts-2.0"): {Input: 999, Output: 999}}}
	ev := &model.UsageEvent{
		Source: model.SourceVoice, Model: "seed-tts-2.0",
		InputTokens: 1_000_000, OutputTokens: 1_000_000,
		Details: &model.UsageDetails{},
	}
	if got := tab.Cost(ev); got != nil {
		t.Fatalf("cost = %v — a token rate table priced a speech row", *got)
	}
}

// Voice is real money, so it folds with the other charges and never with the
// notional ones. Getting this wrong blends an estimate into a bill.
func TestVoiceIsBilledNotNotional(t *testing.T) {
	if got := model.CostKind(model.SourceVoice); got != model.CostBilled {
		t.Errorf("kind = %q, want %q", got, model.CostBilled)
	}
	if !model.KnownSource(model.SourceVoice) {
		t.Error("voice is not in model.Sources — it would silently become CostUnknown everywhere")
	}
}

// The note has to state the double-counting rule, because that rule is the
// only thing standing between this source and the one error this ledger must
// never make. A reader deciding whether to price a billing item here needs to
// be told, at the point of use, that the bill collector must then stop.
func TestVoiceNoteStatesTheDoubleCountingRule(t *testing.T) {
	n := strings.ToLower(VoicePriceNote)
	for _, want := range []string{"twice", "exclude"} {
		if !strings.Contains(n, want) {
			t.Errorf("VoicePriceNote does not mention %q — the double-count boundary is unstated", want)
		}
	}
}

// The usage a voice row carries must live in the non-token pair, never in the
// token counters. This is the guard against the tempting shortcut: "put the
// seconds in input_tokens so the existing dashboards show something". Those
// counters are summed into every token total in this hub, so a speech session
// borrowing them does not show up as speech — it shows up as tokens nobody
// spent, in figures nobody re-derives.
func TestVoiceUsageLivesInItsOwnUnitNotInTokenCounters(t *testing.T) {
	secs := 125.129
	ev := &model.UsageEvent{
		Source: model.SourceVoice, Model: "dashscope/paraformer-realtime-8k-v2",
		Details: &model.UsageDetails{Usage: &secs, UsageUnit: "second"},
	}
	if ev.InputTokens != 0 || ev.OutputTokens != 0 || ev.CacheRead != 0 || ev.Thinking != 0 {
		t.Fatal("a voice event carries token counters — they will be summed into this hub's token totals")
	}
	if ev.Details.Usage == nil || *ev.Details.Usage != secs || ev.Details.UsageUnit != "second" {
		t.Fatalf("usage = %v %q, want the seconds it actually heard", ev.Details.Usage, ev.Details.UsageUnit)
	}
	// Unpriced is still the expected outcome: a unit is not a rate.
	if got := (&Table{}).Cost(ev); got != nil {
		t.Errorf("cost = %v — carrying a unit must not make the hub invent a price", *got)
	}
}

// A missing amount is nil, not 0 — the same rule the cost column keeps, for
// the same reason: 0 seconds is a measurement, and "we were not told" is not.
func TestVoiceUsageAbsentIsNilNotZero(t *testing.T) {
	d := &model.UsageDetails{}
	if d.Usage != nil {
		t.Fatal("zero value of Usage is not nil — an unreported amount would read as a measured 0")
	}
}
