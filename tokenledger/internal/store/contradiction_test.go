package store

import (
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/ccquota/internal/model"
)

func at(s string) *time.Time {
	t, err := time.Parse(time.RFC3339, s)
	if err != nil {
		panic(err)
	}
	return &t
}

func snap(fivePct float64, fiveReset string, sevenPct float64, sevenReset string) *model.LimitsSnapshot {
	s := &model.LimitsSnapshot{}
	s.FiveHour = model.Window{Utilization: fivePct}
	s.SevenDay = model.Window{Utilization: sevenPct}
	if fiveReset != "" {
		s.FiveHour.ResetsAt = at(fiveReset)
	}
	if sevenReset != "" {
		s.SevenDay.ResetsAt = at(sevenReset)
	}
	return s
}

func TestContradictsPrevious(t *testing.T) {
	const w5 = "2026-09-01T18:40:00Z"
	const w7 = "2026-09-04T14:00:00Z"

	cases := []struct {
		name       string
		prev, next *model.LimitsSnapshot
		want       bool
		inWhy      string
	}{
		{
			// The measured failure: 41% -> 0% in three minutes, same reset.
			name: "seven-day collapses without resetting",
			prev: snap(32, w5, 41, w7),
			next: snap(0, "2026-09-01T22:50:00Z", 0, w7),
			want: true, inWhy: "seven-day",
		},
		{
			name: "five-hour collapses without resetting",
			prev: snap(80, w5, 10, w7),
			next: snap(3, w5, 10, w7),
			want: true, inWhy: "five-hour",
		},
		{
			// Ordinary progress.
			name: "utilization climbing is normal",
			prev: snap(30, w5, 41, w7),
			next: snap(32, w5, 41, w7),
			want: false,
		},
		{
			// A rollover: the window turned over, so a drop to near-zero is
			// exactly what should happen. Flagging this would make the guard
			// fire every five hours and disable limits permanently.
			name: "a drop AFTER the reset time moved is a rollover, not a contradiction",
			prev: snap(96, w5, 41, w7),
			next: snap(2, "2026-09-01T23:40:00Z", 41, w7),
			want: false,
		},
		{
			name: "rounding noise is not a contradiction",
			prev: snap(28.000000000000004, w5, 41, w7),
			next: snap(28, w5, 40.5, w7),
			want: false,
		},
		{
			// Sub-second skew between sources already made one subscription
			// fingerprint as two; it must not make every reading a new window.
			name: "sub-second skew in the reset time is still the same window",
			prev: snap(80, "2026-09-01T18:40:00.278Z", 41, w7),
			next: snap(3, "2026-09-01T18:40:00.357Z", 41, w7),
			want: true, inWhy: "five-hour",
		},
		{
			name: "no previous reading cannot contradict",
			prev: nil,
			next: snap(0, w5, 0, w7),
			want: false,
		},
		{
			name: "a missing reset time is not comparable",
			prev: snap(80, "", 41, ""),
			next: snap(0, "", 0, ""),
			want: false,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, why := ContradictsPrevious(tc.prev, tc.next)
			if got != tc.want {
				t.Fatalf("got %v (%s), want %v", got, why, tc.want)
			}
			if tc.inWhy != "" && !strings.Contains(why, tc.inWhy) {
				t.Errorf("reason %q does not name the window (%q)", why, tc.inWhy)
			}
			if got && why == "" {
				t.Error("a refusal with no reason leaves the operator nothing to act on")
			}
		})
	}
}

// A refused reading is never stored, so the baseline it is compared against
// stops moving. If the guard trusted that baseline forever, a persistent
// condition would leave the account's limits unavailable until the window rolled
// over — days, for the seven-day one. Stale evidence must stop convicting.
func TestContradictsPrevious_SelfHealsRatherThanWedging(t *testing.T) {
	const w5 = "2026-09-01T18:40:00Z"
	const w7 = "2026-09-04T14:00:00Z"
	base := time.Date(2026, 9, 1, 17, 57, 0, 0, time.UTC)

	prev := snap(32, w5, 41, w7)
	prev.ObservedAt = base

	fresh := snap(0, w5, 0, w7)
	fresh.ObservedAt = base.Add(3 * time.Minute)
	if bad, _ := ContradictsPrevious(prev, fresh); !bad {
		t.Error("a contradiction three minutes later must still be refused")
	}

	later := snap(0, w5, 0, w7)
	later.ObservedAt = base.Add(30 * time.Minute)
	if bad, why := ContradictsPrevious(prev, later); bad {
		t.Errorf("still refusing against a 30-minute-old baseline: %s — the account's "+
			"limits would stay unavailable until the window rolled over", why)
	}
}
