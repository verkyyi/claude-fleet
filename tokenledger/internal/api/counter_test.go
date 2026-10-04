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

// A TTL alone made the counter up to 30s staler than the data it reports, for
// no reason: the total changes only when something is ingested, and the hub
// knows exactly when that happens.
func TestCounter_IngestInvalidatesTheCache(t *testing.T) {
	h := newHarness(t)
	tok := h.enroll(t, "laptop")
	h.push(t, tok, batchFor("acct-a", "laptop", []string{"a1"}, "/a"))

	_, body := h.get(t, "/v1/live")
	var first Snapshot
	if err := json.Unmarshal(body, &first); err != nil {
		t.Fatal(err)
	}
	if first.Counter == nil {
		t.Fatal("no counter")
	}

	// A second push, well inside the TTL.
	h.push(t, tok, batchFor("acct-a", "laptop", []string{"a2", "a3"}, "/a"))

	_, body = h.get(t, "/v1/live")
	var second Snapshot
	if err := json.Unmarshal(body, &second); err != nil {
		t.Fatal(err)
	}
	if second.Counter.Turns <= first.Counter.Turns {
		t.Fatalf("turns stayed at %d after ingesting more; the counter is serving "+
			"a cached total the hub already knows is out of date", second.Counter.Turns)
	}
	if second.Counter.Turns != 3 {
		t.Errorf("turns = %d, want 3", second.Counter.Turns)
	}
}

// Control: a read that ingests nothing must NOT invalidate, or the cache is
// pointless and every SSE push costs a full table scan.
func TestCounter_ReadsDoNotInvalidateTheCache(t *testing.T) {
	h := newHarness(t)
	tok := h.enroll(t, "laptop")
	h.push(t, tok, batchFor("acct-a", "laptop", []string{"a1"}, "/a"))

	scans := 0
	h.srv.counter.Invalidate()
	if _, _, _, err := h.srv.counter.Total(func() (int64, int64, error) {
		scans++
		return 1, 100, nil
	}); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 5; i++ {
		h.get(t, "/v1/live")
	}
	if _, _, _, err := h.srv.counter.Total(func() (int64, int64, error) {
		scans++
		return 1, 100, nil
	}); err != nil {
		t.Fatal(err)
	}
	if scans != 1 {
		t.Errorf("the total was recomputed %d times across 5 reads with no ingest", scans)
	}
}

// The raw live rate is unusable: it is the delta between two consecutive
// statusLine reports, so it reads zero between turns and spikes on the report
// that lands one. Smoothing is what makes it drivable.
func TestCounter_SmoothsTheSpikyLiveRate(t *testing.T) {
	var c Counter
	// The measured shape on this hub: mostly nothing, occasionally a burst.
	for _, sample := range []float64{0, 0, 0, 60000, 0, 0, 0, 60000, 0, 0, 0, 60000} {
		c.ObserveLiveRate(sample)
	}
	got := c.Rate()
	if got <= 0 {
		t.Fatalf("rate = %v; the counter would freeze between turns", got)
	}
	if got > 40000 {
		t.Errorf("rate = %v; a spike is being followed rather than smoothed", got)
	}
}

// Idleness is information. Ignoring zero samples would make the average decay
// only while work was happening, and hold its last busy value forever once a
// fleet went quiet.
func TestCounter_LiveRateDecaysWhenWorkStops(t *testing.T) {
	var c Counter
	for i := 0; i < 20; i++ {
		c.ObserveLiveRate(60000)
	}
	busy := c.Rate()
	if busy < 50000 {
		t.Fatalf("rate never reached the sustained value: %v", busy)
	}
	for i := 0; i < 40; i++ {
		c.ObserveLiveRate(0)
	}
	if idle := c.Rate(); idle > busy/20 {
		t.Errorf("rate is %v after 40 idle samples (was %v); it is not decaying", idle, busy)
	}
}

// The live rate is preferred because it is fresh in seconds rather than
// minutes — but the stored-growth rate must remain for a hub whose endpoints
// report usage without statusLine heartbeats.
func TestCounter_FallsBackToStoredGrowthWithoutHeartbeats(t *testing.T) {
	var c Counter
	c.perMin = 1234
	if got := c.Rate(); got != 1234 {
		t.Fatalf("rate = %v with no live samples, want the stored-growth rate", got)
	}
	c.ObserveLiveRate(500)
	if got := c.Rate(); got != 500 {
		t.Errorf("rate = %v once a heartbeat arrived, want the live one", got)
	}
}

// The regression that made the counter vanish from the page at 4 of 30 samples.
//
// Invalidate used to signal staleness by zeroing measuredAt — which is also the
// flag the error path tests to decide whether a previous reading exists. So a
// failed read immediately after an ingest served NOTHING rather than the last
// good total, attachCounter dropped the counter, and the page simply stopped
// counting until the next successful read.
func TestCounter_InvalidateDoesNotDestroyTheFallback(t *testing.T) {
	var c Counter
	if _, _, _, err := c.Total(func() (int64, int64, error) { return 7, 7000, nil }); err != nil {
		t.Fatal(err)
	}

	c.Invalidate() // as every ingest does

	_, tokens, measuredAt, err := c.Total(func() (int64, int64, error) {
		return 0, 0, errors.New("database is locked")
	})
	if err != nil {
		t.Fatalf("a failed read after an ingest returned an error: %v — the counter "+
			"disappears from the page entirely", err)
	}
	if tokens != 7000 {
		t.Errorf("tokens = %d, want the last good reading (7000)", tokens)
	}
	if measuredAt.IsZero() {
		t.Error("no measurement time; the page cannot project")
	}
}

// Control: Invalidate must still force a recompute, or it does nothing at all.
func TestCounter_InvalidateStillForcesARecompute(t *testing.T) {
	var c Counter
	calls := 0
	load := func() (int64, int64, error) {
		calls++
		return int64(calls), int64(calls * 1000), nil
	}
	if _, _, _, err := c.Total(load); err != nil {
		t.Fatal(err)
	}
	if _, _, _, err := c.Total(load); err != nil { // cached
		t.Fatal(err)
	}
	if calls != 1 {
		t.Fatalf("cache not working: %d calls", calls)
	}

	c.Invalidate()
	if _, _, _, err := c.Total(load); err != nil {
		t.Fatal(err)
	}
	if calls != 2 {
		t.Errorf("Invalidate did not force a recompute: %d calls", calls)
	}
}
