package store

import (
	"fmt"
	"time"

	"github.com/verkyyi/ccquota/internal/model"
)

// utilizationDropTolerance is how far a window's utilization may fall inside one
// window before the reading is treated as belonging to a different account.
//
// Not zero: Anthropic reports a rounded percentage and occasional float noise
// (28.000000000000004 appears in real payloads), and rounding can move a figure
// by a point. Ten points is far outside that and far inside the failure this
// catches — the observed case fell 41 points.
const utilizationDropTolerance = 10.0

// maxComparisonAge is how old the previous reading may be and still be used as
// evidence against a new one.
//
// Without this the guard wedges. A refused reading is not stored, so the
// baseline it was compared against never moves: if the condition persists —
// whatever caused it — every subsequent reading is refused against the same
// increasingly ancient number, and the account's limits stay unavailable until
// the window rolls over, which for the seven-day window is days.
//
// So the rule self-heals. A contradiction is refused loudly while the evidence
// is fresh; if it is still being reported fifteen minutes later, the world has
// changed and the new reading is believed. A one-off glitch does not survive
// that long; a real change does.
const maxComparisonAge = 15 * time.Minute

// ContradictsPrevious reports whether snap cannot belong to the same account as
// the reading before it.
//
// The limits payload carries NO account identity, and neither does the stored
// credential: ccquota files a reading under whichever account ~/.claude.json
// names, using whichever token was freshest. Nothing checks the two agree, so a
// divergence records one subscription's utilization as another's — and a
// scheduler reading it sees headroom that does not exist.
//
// One case is provable without any identity at all. Within a single window —
// same resets_at — utilization only ever climbs: it is the fraction of that
// window's allowance already spent, and spending cannot be undone before the
// window turns over. A large drop with the reset time UNCHANGED is therefore not
// this account's number.
//
// Measured here: seven-day utilization went 41% -> 0% in three minutes with an
// identical resets_at of 2026-09-04T14:00:00, and ccquota stored it as truth.
//
// A reset time that MOVED is an ordinary rollover and says nothing, so it is not
// flagged. That asymmetry is the whole rule: this reports a contradiction, never
// a suspicion.
func ContradictsPrevious(prev, snap *model.LimitsSnapshot) (bool, string) {
	if prev == nil || snap == nil {
		return false, ""
	}
	// Stale evidence convicts nobody — see maxComparisonAge.
	if !prev.ObservedAt.IsZero() && !snap.ObservedAt.IsZero() &&
		snap.ObservedAt.Sub(prev.ObservedAt) > maxComparisonAge {
		return false, ""
	}
	if why, bad := windowContradicts("seven-day", prev.SevenDay, snap.SevenDay); bad {
		return true, why
	}
	if why, bad := windowContradicts("five-hour", prev.FiveHour, snap.FiveHour); bad {
		return true, why
	}
	return false, ""
}

func windowContradicts(name string, prev, cur model.Window) (string, bool) {
	// Both readings must sit in the SAME window. No reset time on either side
	// means there is nothing to compare against.
	if prev.ResetsAt == nil || cur.ResetsAt == nil {
		return "", false
	}
	if !sameWindow(*prev.ResetsAt, *cur.ResetsAt) {
		return "", false
	}
	drop := prev.Utilization - cur.Utilization
	if drop <= utilizationDropTolerance {
		return "", false
	}
	return fmt.Sprintf(
		"the %s window fell from %.0f%% to %.0f%% without resetting (still resets %s); "+
			"utilization cannot go backwards inside one window, so this reading is not "+
			"this subscription's",
		name, prev.Utilization, cur.Utilization,
		cur.ResetsAt.UTC().Format(time.RFC3339)), true
}

// sameWindow compares reset instants to the minute. The same window's reset is
// reported with slightly different sub-second precision by different sources —
// 0.722s of skew already made one subscription fingerprint as two — so an exact
// comparison would call every reading a new window and the rule would never fire.
func sameWindow(a, b time.Time) bool {
	return a.UTC().Truncate(time.Minute).Equal(b.UTC().Truncate(time.Minute))
}
