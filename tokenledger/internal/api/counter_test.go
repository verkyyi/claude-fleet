package api

import (
	"encoding/json"
	"errors"
	"testing"
	"time"
)

// The safeguard the whole feature turns on: extrapolation must have a deadline.
// Without one, a fleet that has died still shows a number climbing confidently
// — asserting work that is not happening, which is the only way a projected
// counter genuinely misleads.
func TestCounterView_ProjectionExpiresAfterTheLastReport(t *testing.T) {
	measured := time.Date(2026, 9, 1, 12, 0, 0, 0, time.UTC)
	v := counterView(100, 5000, measured, 1200)
	if v.ProjectUntil == nil {
		t.Fatal("no projection deadline: the page would count forever")
	}
	if got := v.ProjectUntil.Sub(measured); got != projectionWindow {
		t.Errorf("deadline is %s after the measurement, want %s", got, projectionWindow)
	}
	if !v.ProjectUntil.After(measured) {
		t.Error("deadline must be after the measurement it extends")
	}
}

// No live sessions means no measured rate. There is then nothing to project
// FROM, and inventing one would be fabrication rather than estimation.
func TestCounterView_NoRateMeansNoProjection(t *testing.T) {
	measured := time.Date(2026, 9, 1, 12, 0, 0, 0, time.UTC)

	for _, tc := range []struct {
		name     string
		rate     float64
		measured time.Time
	}{
		{"zero rate", 0, measured},
		{"negative rate", -50, measured},
		{"never measured", 1200, time.Time{}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			v := counterView(100, 5000, tc.measured, tc.rate)
			if v.ProjectUntil != nil {
				t.Errorf("ProjectUntil = %v, want absent", *v.ProjectUntil)
			}
			if v.TokensPerMin != 0 {
				t.Errorf("TokensPerMin = %v, want 0", v.TokensPerMin)
			}
			// The measured figure itself is still served — it is a fact.
			if v.Tokens != 5000 {
				t.Errorf("Tokens = %d; the measurement is still true", v.Tokens)
			}
		})
	}
}

// Control: a live rate DOES produce a projection. Without this, "expires" and
// "never projects at all" are the same test, and a counter that never moves
// would pass everything above.
func TestCounterView_ALiveRateDoesProject(t *testing.T) {
	measured := time.Now().UTC()
	v := counterView(100, 5000, measured, 1200)
	if v.ProjectUntil == nil || v.TokensPerMin != 1200 {
		t.Fatalf("a live rate produced no projection: %+v", v)
	}
}

func TestCounter_CachesWithinTTL(t *testing.T) {
	var c Counter
	calls := 0
	load := func() (int64, int64, error) {
		calls++
		return int64(calls), int64(calls * 1000), nil
	}

	for i := 0; i < 5; i++ {
		if _, _, _, err := c.Total(load); err != nil {
			t.Fatal(err)
		}
	}
	if calls != 1 {
		t.Errorf("full table scan ran %d times for 5 snapshots; the SSE stream "+
			"pushes several times a second", calls)
	}
}

// The counter's whole promise is that it never goes backwards. A read that
// comes back smaller — a merge mid-flight, a partial scan — must not shrink it.
func TestCounter_NeverShrinks(t *testing.T) {
	var c Counter
	if _, _, _, err := c.Total(func() (int64, int64, error) { return 10, 9000, nil }); err != nil {
		t.Fatal(err)
	}
	c.measuredAt = time.Now().Add(-2 * counterTTL) // force a refresh

	_, tokens, _, err := c.Total(func() (int64, int64, error) { return 3, 10, nil })
	if err != nil {
		t.Fatal(err)
	}
	if tokens != 9000 {
		t.Errorf("total fell to %d from 9000", tokens)
	}
}

// A momentarily unreadable database must not blank the headline figure.
func TestCounter_ServesTheLastReadingOnError(t *testing.T) {
	var c Counter
	if _, _, _, err := c.Total(func() (int64, int64, error) { return 10, 9000, nil }); err != nil {
		t.Fatal(err)
	}
	c.measuredAt = time.Now().Add(-2 * counterTTL)

	_, tokens, _, err := c.Total(func() (int64, int64, error) { return 0, 0, errors.New("db locked") })
	if err != nil {
		t.Fatalf("an error blanked the counter: %v", err)
	}
	if tokens != 9000 {
		t.Errorf("tokens = %d, want the last good reading", tokens)
	}
}

// Unknown must render as absent, not as zero: zero claims this hub has never
// seen a token.
func TestCounter_UnknownIsOmittedNotZeroed(t *testing.T) {
	var c Counter
	if _, _, _, err := c.Total(func() (int64, int64, error) { return 0, 0, errors.New("no db") }); err == nil {
		t.Fatal("a first-read failure should report an error, not a zero total")
	}
	snap := Snapshot{}
	b, err := json.Marshal(snap)
	if err != nil {
		t.Fatal(err)
	}
	if got := string(b); contains(got, `"counter"`) {
		t.Errorf("a snapshot with no counter still serialises one: %s", got)
	}
}

func contains(s, sub string) bool {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return true
		}
	}
	return false
}

// End to end: the counter reaches the wire, counts every subscription, and is
// NOT the live session figure — a completed turn is in both, so adding them
// would count it twice.
func TestLiveSnapshot_CarriesTheLifetimeCounter(t *testing.T) {
	h := newHarness(t)
	tok := h.enroll(t, "laptop")
	h.push(t, tok, batchFor("acct-a", "laptop", []string{"a1", "a2"}, "/a"))
	h.push(t, tok, batchFor("acct-b", "laptop", []string{"b1"}, "/b"))

	_, body := h.get(t, "/v1/live")
	var snap Snapshot
	if err := json.Unmarshal(body, &snap); err != nil {
		t.Fatal(err)
	}
	if snap.Counter == nil {
		t.Fatal("no counter on the live snapshot")
	}
	if snap.Counter.Turns != 3 {
		t.Errorf("turns = %d, want 3 across both subscriptions", snap.Counter.Turns)
	}
	if snap.Counter.Tokens <= 0 {
		t.Errorf("tokens = %d", snap.Counter.Tokens)
	}
	if snap.Counter.MeasuredAt.IsZero() {
		t.Error("no measurement time; the page cannot project without one")
	}
}

// A hub with no live store must still answer /v1/live. Dereferencing nil there
// panicked and killed the connection — in the one handler a dashboard polls
// continuously.
func TestLiveSnapshot_SurvivesAHubWithNoLiveStore(t *testing.T) {
	h := newHarness(t)
	h.srv.LiveStore = nil

	code, body := getAs(t, h, "/v1/live", viewerToken)
	if code != 200 {
		t.Fatalf("HTTP %d: %s", code, first(body, 200))
	}
	var snap Snapshot
	if err := json.Unmarshal([]byte(body), &snap); err != nil {
		t.Fatal(err)
	}
	if snap.ActiveSessions != 0 {
		t.Errorf("active sessions = %d, want 0", snap.ActiveSessions)
	}
}

// `omitempty` does nothing for a time.Time — it is a struct, never "empty" — so
// a value field shipped 0001-01-01 to the page as if it were a deadline. The
// client tests this field for presence; a zero date is a claim about the past,
// not an admission that there is nothing to project from.
func TestCounterView_AbsentDeadlineIsOmittedFromJSON(t *testing.T) {
	measured := time.Date(2026, 9, 1, 12, 0, 0, 0, time.UTC)
	v := counterView(1, 2, measured, 0)

	b, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	if contains(string(b), "project_until") {
		t.Errorf("a counter with nothing to project from still ships a deadline: %s", b)
	}
	if contains(string(b), "0001-01-01") {
		t.Errorf("zero time serialised as a date: %s", b)
	}

	// Control: a real deadline IS serialised.
	live := counterView(1, 2, measured, 600)
	lb, err := json.Marshal(live)
	if err != nil {
		t.Fatal(err)
	}
	if !contains(string(lb), "project_until") {
		t.Errorf("a real deadline was dropped: %s", lb)
	}
}

// The rate must come from the stored total's own growth, not from the live
// per-session figure.
//
// The live rate is the delta between two consecutive statusLine reports, and
// between turns that delta is genuinely zero — measured on this hub, FIVE
// active sessions reported 0 tokens/min because no turn had completed in the
// last few seconds. A counter driven by it stutters: freeze, lurch, freeze.
func TestCounter_RateComesFromTheStoredTotalsGrowth(t *testing.T) {
	var c Counter
	tokens := int64(1000)
	load := func() (int64, int64, error) { return 1, tokens, nil }

	if _, _, _, err := c.Total(load); err != nil {
		t.Fatal(err)
	}
	if c.Rate() != 0 {
		t.Errorf("a single measurement cannot imply a rate, got %v", c.Rate())
	}

	// A whole window later, having grown by 6000 tokens.
	c.rateBaseAt = time.Now().Add(-2 * time.Minute)
	c.measuredAt = time.Time{} // force a refresh
	tokens = 7000
	if _, _, _, err := c.Total(load); err != nil {
		t.Fatal(err)
	}
	if got := c.Rate(); got < 2500 || got > 3500 {
		t.Errorf("rate = %v tokens/min, want ~3000 (6000 over 2 minutes)", got)
	}
}

// No growth over a whole window means nothing is running. Carrying the last
// busy rate forward would keep the counter climbing through an idle fleet.
func TestCounter_NoGrowthMeansNoRate(t *testing.T) {
	var c Counter
	load := func() (int64, int64, error) { return 1, 5000, nil }

	if _, _, _, err := c.Total(load); err != nil {
		t.Fatal(err)
	}
	c.perMin = 9999 // pretend it was busy
	c.rateBaseAt = time.Now().Add(-2 * time.Minute)
	c.measuredAt = time.Time{}

	if _, _, _, err := c.Total(load); err != nil {
		t.Fatal(err)
	}
	if c.Rate() != 0 {
		t.Errorf("rate = %v after a window with no growth, want 0", c.Rate())
	}
}
