package model

import "testing"

// The axis exists because "no window" and "no reading" are different facts, and
// the card that asks "am I about to hit the wall?" may only list accounts that
// can HAVE a wall.
func TestHasQuotaWindow_OnlySubscriptionsHaveACeiling(t *testing.T) {
	for _, src := range []string{SourceClaude, SourceCodex} {
		if !HasQuotaWindow(src) {
			t.Errorf("%s is a subscription with a real quota pool; it must have a window", src)
		}
	}
}

// A stored row written before the source column existed is Claude, here as
// everywhere else — it must not silently lose its gauges.
func TestHasQuotaWindow_EmptySourceIsClaude(t *testing.T) {
	if !HasQuotaWindow("") {
		t.Error("an empty source reads as Claude and keeps its quota window")
	}
}

// The allow-list defaults to false on purpose: a source added to the constants
// and forgotten here goes MISSING from a quota card, which somebody notices,
// rather than sitting on one forever reporting a collector gap that cannot be
// fixed because there was never anything to collect.
func TestHasQuotaWindow_UnknownSourceHasNone(t *testing.T) {
	if HasQuotaWindow("some_future_source") {
		t.Error("an unclassified source must not be assumed to have a quota window")
	}
}

// Every source this build knows must be a deliberate answer on this axis. The
// list itself cannot enforce that (false is also an answer), so this pins the
// split and fails loudly when a source is added to model.Sources without one.
func TestHasQuotaWindow_CoversEverySource(t *testing.T) {
	want := map[string]bool{
		SourceClaude: true, SourceCodex: true,
	}
	for _, src := range Sources {
		w, ok := want[src]
		if !ok {
			t.Fatalf("%s is in model.Sources but this test does not say whether it has a "+
				"quota window — decide, then add it here", src)
		}
		if got := HasQuotaWindow(src); got != w {
			t.Errorf("HasQuotaWindow(%s) = %v, want %v", src, got, w)
		}
	}
}
