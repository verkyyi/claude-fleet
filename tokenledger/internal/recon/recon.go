// Package recon joins the two numbers ccquota holds.
//
// Anthropic reports EXACT, account-wide utilization: "you have used 4% of your
// 5-hour window". It does not say which machine spent it. The transcript
// scanner knows exactly which machine spent which tokens, but has no idea what
// share of a quota that represents.
//
// Neither answers "which of my six servers ate my week". Together they do:
//
//	endpoint_share ≈ (endpoint_weighted_tokens / total_weighted_tokens) × utilization
//
// The total is exact. The split is PROPORTIONAL, and therefore an estimate: it
// assumes utilization tracks weighted spend. Every caller is expected to label
// split figures as estimates and the total as exact — see spec §7.
package recon

import (
	"sort"
	"time"

	"github.com/verkyyi/ccquota/internal/model"
	"github.com/verkyyi/ccquota/internal/pricing"
)

// FiveHourWindow is the length of the session rate-limit bucket.
const FiveHourWindow = 5 * time.Hour

// SevenDayWindow is the length of the weekly bucket.
const SevenDayWindow = 7 * 24 * time.Hour

// Share is one endpoint's estimated slice of a rate-limit window.
type Share struct {
	EndpointID string `json:"endpoint_id"`
	Label      string `json:"label"`

	Events int   `json:"events"`
	Tokens int64 `json:"tokens"`

	// WeightedTokens is spend expressed in a common unit so an Opus output
	// token is not treated as equal to a Haiku cache read. Without weighting, a
	// machine doing cheap cache-heavy work would look like the biggest burner.
	WeightedTokens float64 `json:"weighted_tokens"`

	// FractionOfWindow is this endpoint's share of all weighted spend in the
	// window, 0-1.
	FractionOfWindow float64 `json:"fraction_of_window"`

	// EstimatedUtilization is FractionOfWindow × the exact account-wide
	// utilization. An ESTIMATE. Never present it with the authority of the
	// account total.
	EstimatedUtilization float64 `json:"estimated_utilization"`
}

// Window bounds a rate-limit period.
type Window struct {
	Start time.Time `json:"start"`
	End   time.Time `json:"end"`
}

// WindowFor derives the period a snapshot's reset time implies.
//
// Anthropic reports when the window resets, not when it opened, so the start is
// the reset minus the window length. When the reset time is absent the window
// is anchored on the observation instead, which keeps the split usable and
// slightly wrong rather than empty.
func WindowFor(resetsAt *time.Time, observedAt time.Time, length time.Duration) Window {
	if resetsAt != nil {
		return Window{Start: resetsAt.Add(-length), End: *resetsAt}
	}
	return Window{Start: observedAt.Add(-length), End: observedAt}
}

// Contains reports whether t falls in [Start, End).
func (w Window) Contains(t time.Time) bool {
	return !t.Before(w.Start) && t.Before(w.End)
}

// Weigher converts an event into comparable spend.
type Weigher interface {
	Cost(*model.UsageEvent) *float64
}

// Weight returns an event's weighted spend.
//
// Notional cost is the best available proxy for what Anthropic meters, since
// its rates already encode the relative expense of each model and token class.
// Events on an unpriced model contribute 0 weight — they cannot be placed on
// the same scale, and guessing would silently shift the split. Callers surface
// that as an "unpriced" count rather than pretending the machine was idle.
func Weight(w Weigher, e *model.UsageEvent) float64 {
	if c := w.Cost(e); c != nil {
		return *c
	}
	return 0
}

// EndpointShares apportions a snapshot's exact five-hour utilization across the
// endpoints that spent inside that window.
//
// labels maps endpoint id to a human name; missing entries fall back to the id.
func EndpointShares(snap *model.LimitsSnapshot, evs []model.UsageEvent, w Weigher, labels map[string]string) ([]Share, Window) {
	win := WindowFor(snap.FiveHour.ResetsAt, snap.ObservedAt, FiveHourWindow)
	return sharesIn(win, snap.FiveHour.Utilization, evs, w, labels), win
}

// SevenDayShares does the same for the weekly window.
func SevenDayShares(snap *model.LimitsSnapshot, evs []model.UsageEvent, w Weigher, labels map[string]string) ([]Share, Window) {
	win := WindowFor(snap.SevenDay.ResetsAt, snap.ObservedAt, SevenDayWindow)
	return sharesIn(win, snap.SevenDay.Utilization, evs, w, labels), win
}

func sharesIn(win Window, utilization float64, evs []model.UsageEvent, w Weigher, labels map[string]string) []Share {
	byEndpoint := map[string]*Share{}
	var total float64

	for i := range evs {
		e := &evs[i]
		if !win.Contains(e.TS) {
			continue
		}
		s := byEndpoint[e.EndpointID]
		if s == nil {
			label := labels[e.EndpointID]
			if label == "" {
				label = e.EndpointID
			}
			s = &Share{EndpointID: e.EndpointID, Label: label}
			byEndpoint[e.EndpointID] = s
		}
		s.Events++
		s.Tokens += e.TotalTokens()
		weight := Weight(w, e)
		s.WeightedTokens += weight
		total += weight
	}

	out := make([]Share, 0, len(byEndpoint))
	for _, s := range byEndpoint {
		// A window with no priced spend cannot be apportioned. Leaving the
		// fractions at zero is the honest result; dividing would panic and
		// splitting evenly would invent data.
		if total > 0 {
			s.FractionOfWindow = s.WeightedTokens / total
			s.EstimatedUtilization = s.FractionOfWindow * utilization
		}
		out = append(out, *s)
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].WeightedTokens != out[j].WeightedTokens {
			return out[i].WeightedTokens > out[j].WeightedTokens
		}
		return out[i].EndpointID < out[j].EndpointID
	})
	return out
}

// BurnRate describes how fast a window is being consumed.
type BurnRate struct {
	// PercentPerHour is measured over the elapsed part of the window.
	PercentPerHour float64 `json:"percent_per_hour"`

	// ExhaustedAt is when the window would hit 100% at the current rate, or
	// nil if it resets first or nothing is being spent. nil is common and not
	// an error — most of the time you are not on track to hit the wall.
	ExhaustedAt *time.Time `json:"exhausted_at"`

	// ResetsFirst is true when the window resets before it would be exhausted.
	ResetsFirst bool `json:"resets_first"`
}

// Burn projects a window forward from its current utilization.
func Burn(win Window, utilization float64, now time.Time) BurnRate {
	elapsed := now.Sub(win.Start).Hours()
	if elapsed <= 0 || utilization <= 0 {
		return BurnRate{ResetsFirst: true}
	}
	rate := utilization / elapsed
	if rate <= 0 {
		return BurnRate{ResetsFirst: true}
	}
	remaining := 100 - utilization
	if remaining <= 0 {
		t := now
		return BurnRate{PercentPerHour: rate, ExhaustedAt: &t}
	}
	hoursLeft := remaining / rate
	at := now.Add(time.Duration(hoursLeft * float64(time.Hour)))
	if at.After(win.End) {
		return BurnRate{PercentPerHour: rate, ResetsFirst: true}
	}
	return BurnRate{PercentPerHour: rate, ExhaustedAt: &at}
}

// DefaultWeigher is the pricing table.
func DefaultWeigher() Weigher { return pricing.Default() }
