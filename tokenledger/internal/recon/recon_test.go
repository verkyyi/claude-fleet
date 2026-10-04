package recon

import (
	"math"
	"testing"
	"time"

	"github.com/verkyyi/ccquota/internal/model"
	"github.com/verkyyi/ccquota/internal/pricing"
)

var reset = time.Date(2026, 9, 1, 10, 0, 0, 0, time.UTC)

func snapshot(fiveHourPct float64) *model.LimitsSnapshot {
	r := reset
	return &model.LimitsSnapshot{
		AccountUUID: "acct",
		ObservedAt:  reset.Add(-time.Hour),
		FiveHour:    model.Window{Utilization: fiveHourPct, ResetsAt: &r},
	}
}

// event at a given offset before the reset.
func at(endpoint string, before time.Duration, out int64) model.UsageEvent {
	return model.UsageEvent{
		EndpointID: endpoint, TS: reset.Add(-before),
		Model: "claude-sonnet-5", OutputTokens: out,
	}
}

func find(shares []Share, id string) *Share {
	for i := range shares {
		if shares[i].EndpointID == id {
			return &shares[i]
		}
	}
	return nil
}

// The headline behavior: an exact account total, split proportionally.
func TestEndpointShares_ProportionalSplit(t *testing.T) {
	snap := snapshot(40) // 40% of the 5h window used, account-wide
	evs := []model.UsageEvent{
		at("ep-a", 1*time.Hour, 750),
		at("ep-b", 2*time.Hour, 250),
	}

	shares, win := EndpointShares(snap, evs, pricing.Default(), map[string]string{"ep-a": "web-01"})

	if !win.Start.Equal(reset.Add(-FiveHourWindow)) || !win.End.Equal(reset) {
		t.Fatalf("window = %v..%v", win.Start, win.End)
	}
	if len(shares) != 2 {
		t.Fatalf("shares = %d, want 2", len(shares))
	}

	a := find(shares, "ep-a")
	if math.Abs(a.FractionOfWindow-0.75) > 1e-9 {
		t.Errorf("ep-a fraction = %v, want 0.75", a.FractionOfWindow)
	}
	// 75% of the endpoints' spend, applied to the exact 40% account figure.
	if math.Abs(a.EstimatedUtilization-30) > 1e-9 {
		t.Errorf("ep-a estimated utilization = %v, want 30", a.EstimatedUtilization)
	}
	if a.Label != "web-01" {
		t.Errorf("label = %q, want web-01", a.Label)
	}

	b := find(shares, "ep-b")
	if math.Abs(b.EstimatedUtilization-10) > 1e-9 {
		t.Errorf("ep-b estimated utilization = %v, want 10", b.EstimatedUtilization)
	}

	// The parts must sum to the exact whole.
	if sum := a.EstimatedUtilization + b.EstimatedUtilization; math.Abs(sum-40) > 1e-9 {
		t.Errorf("shares sum to %v, want the account total 40", sum)
	}
}

// Weighting by cost is what stops a cache-heavy machine from looking like the
// biggest spender. Equal token counts on very different models must NOT split
// evenly.
func TestEndpointShares_WeightsByCostNotRawTokens(t *testing.T) {
	snap := snapshot(100)
	opus := model.UsageEvent{EndpointID: "expensive", TS: reset.Add(-time.Hour),
		Model: "claude-opus-5", OutputTokens: 1_000_000}
	haiku := model.UsageEvent{EndpointID: "cheap", TS: reset.Add(-time.Hour),
		Model: "claude-haiku-4-5", OutputTokens: 1_000_000}

	shares, _ := EndpointShares(snap, []model.UsageEvent{opus, haiku}, pricing.Default(), nil)

	exp := find(shares, "expensive")
	cheap := find(shares, "cheap")
	if exp.Tokens != cheap.Tokens {
		t.Fatalf("precondition: token counts should be equal, got %d vs %d", exp.Tokens, cheap.Tokens)
	}
	// Opus output $25/MTok vs Haiku $5/MTok -> 25/30 and 5/30.
	if math.Abs(exp.FractionOfWindow-25.0/30.0) > 1e-9 {
		t.Errorf("expensive fraction = %v, want %v", exp.FractionOfWindow, 25.0/30.0)
	}
	if exp.FractionOfWindow <= cheap.FractionOfWindow {
		t.Error("equal raw tokens on Opus and Haiku split evenly; weighting is not applied")
	}
}

// Events outside the window belong to a previous, already-reset period.
func TestEndpointShares_ExcludesEventsOutsideWindow(t *testing.T) {
	snap := snapshot(50)
	evs := []model.UsageEvent{
		at("inside", 1*time.Hour, 100),
		at("outside", 6*time.Hour, 100_000), // before the window opened
	}
	shares, _ := EndpointShares(snap, evs, pricing.Default(), nil)

	if len(shares) != 1 || shares[0].EndpointID != "inside" {
		t.Fatalf("shares = %+v, want only the in-window endpoint", shares)
	}
}

// The boundary must not double-count: an event exactly at the reset instant
// belongs to the NEXT window.
func TestWindow_ContainsIsHalfOpen(t *testing.T) {
	win := WindowFor(&reset, reset, FiveHourWindow)
	if !win.Contains(win.Start) {
		t.Error("the window start must be included")
	}
	if win.Contains(win.End) {
		t.Error("the reset instant belongs to the next window, not this one")
	}
}

// A window where nothing priced was spent cannot be apportioned. It must
// return zeros, not panic and not invent an even split.
func TestEndpointShares_ZeroTotalDoesNotDivideByZero(t *testing.T) {
	snap := snapshot(15)
	unpriced := model.UsageEvent{EndpointID: "ep-a", TS: reset.Add(-time.Hour),
		Model: "some-unreleased-model", OutputTokens: 5_000_000}

	shares, _ := EndpointShares(snap, []model.UsageEvent{unpriced}, pricing.Default(), nil)

	if len(shares) != 1 {
		t.Fatalf("shares = %d, want 1", len(shares))
	}
	if shares[0].FractionOfWindow != 0 || shares[0].EstimatedUtilization != 0 {
		t.Errorf("unapportionable window produced %v; want zeros", shares[0])
	}
	// The raw activity is still reported, so the endpoint does not look idle.
	if shares[0].Tokens != 5_000_000 {
		t.Errorf("tokens = %d, want the raw count to survive", shares[0].Tokens)
	}
}

func TestEndpointShares_NoEvents(t *testing.T) {
	shares, _ := EndpointShares(snapshot(0), nil, pricing.Default(), nil)
	if len(shares) != 0 {
		t.Fatalf("shares = %+v, want none", shares)
	}
}

// With no reset time the window anchors on the observation instead of vanishing.
func TestWindowFor_FallsBackToObservation(t *testing.T) {
	obs := time.Date(2026, 9, 1, 12, 0, 0, 0, time.UTC)
	win := WindowFor(nil, obs, FiveHourWindow)
	if !win.End.Equal(obs) || !win.Start.Equal(obs.Add(-FiveHourWindow)) {
		t.Fatalf("window = %v..%v, want it anchored on the observation", win.Start, win.End)
	}
}

func TestBurn_ProjectsExhaustion(t *testing.T) {
	win := Window{Start: reset.Add(-FiveHourWindow), End: reset}
	// One hour in, 20% used -> 20%/h -> the remaining 80% takes 4h, which is
	// exactly the window's end, so it resets first (not strictly after).
	now := win.Start.Add(time.Hour)
	b := Burn(win, 20, now)
	if math.Abs(b.PercentPerHour-20) > 1e-9 {
		t.Errorf("rate = %v, want 20", b.PercentPerHour)
	}

	// Twice as fast: 40% in one hour -> exhausted 1.5h later, inside the window.
	b = Burn(win, 40, now)
	if b.ExhaustedAt == nil {
		t.Fatal("expected a projected exhaustion inside the window")
	}
	wantAt := now.Add(90 * time.Minute)
	if b.ExhaustedAt.Sub(wantAt).Abs() > time.Second {
		t.Errorf("exhausted at %v, want ~%v", b.ExhaustedAt, wantAt)
	}
}

// Idle is the common case and must not produce a projection.
func TestBurn_IdleWindowHasNoProjection(t *testing.T) {
	win := Window{Start: reset.Add(-FiveHourWindow), End: reset}
	b := Burn(win, 0, win.Start.Add(time.Hour))
	if b.ExhaustedAt != nil {
		t.Errorf("exhausted at %v, want nil for an idle window", b.ExhaustedAt)
	}
	if !b.ResetsFirst {
		t.Error("an idle window resets before it is exhausted")
	}
}

func TestBurn_SlowBurnResetsFirst(t *testing.T) {
	win := Window{Start: reset.Add(-FiveHourWindow), End: reset}
	b := Burn(win, 5, win.Start.Add(2*time.Hour)) // 2.5%/h -> 38h to fill
	if !b.ResetsFirst || b.ExhaustedAt != nil {
		t.Errorf("got %+v, want ResetsFirst with no projection", b)
	}
}
