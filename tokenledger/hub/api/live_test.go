package api

import (
	"bytes"
	"encoding/json"
	"math"
	"net/http"
	"testing"
	"time"
)

func TestLive_RatesComeFromConsecutiveReports(t *testing.T) {
	l := NewLive()

	// A single report carries running totals and cannot express a rate.
	l.Report("ep1", "web-01", []LiveSession{{SessionID: "s1", InputTokens: 1000, CostUSD: 1.0}})
	snap := l.Snapshot()
	if snap.TokensPerMin != 0 {
		t.Errorf("tokens/min = %v from one report; a rate needs two", snap.TokensPerMin)
	}

	// Backdate the stored report so the second one is a measurable interval later.
	l.mu.Lock()
	l.sessions[liveKey(LiveSession{EndpointID: "ep1", Source: "claude", SessionID: "s1"})].ObservedAt = time.Now().UTC().Add(-time.Minute)
	l.mu.Unlock()

	l.Report("ep1", "web-01", []LiveSession{{SessionID: "s1", InputTokens: 4000, CostUSD: 2.0}})
	snap = l.Snapshot()
	if math.Abs(snap.TokensPerMin-3000) > 100 {
		t.Errorf("tokens/min = %v, want ~3000", snap.TokensPerMin)
	}
	if math.Abs(snap.USDPerHour-60) > 3 {
		t.Errorf("$/hour = %v, want ~60 ($1 in a minute)", snap.USDPerHour)
	}
}

// A session that restarts reports LOWER totals than before. Treating that as a
// negative rate would show the fleet earning tokens back.
func TestLive_CountersGoingBackwardsDoNotProduceNegativeRates(t *testing.T) {
	l := NewLive()
	l.Report("ep1", "web-01", []LiveSession{{SessionID: "s1", InputTokens: 9000, CostUSD: 9}})
	l.mu.Lock()
	l.sessions[liveKey(LiveSession{EndpointID: "ep1", Source: "claude", SessionID: "s1"})].ObservedAt = time.Now().UTC().Add(-time.Minute)
	l.mu.Unlock()
	l.Report("ep1", "web-01", []LiveSession{{SessionID: "s1", InputTokens: 10, CostUSD: 0.01}})

	snap := l.Snapshot()
	if snap.TokensPerMin < 0 || snap.USDPerHour < 0 {
		t.Fatalf("negative rates from a restarted session: %+v", snap)
	}
}

// A finished session must leave the live view rather than sit there implying
// work that is not happening.
func TestLive_StaleSessionsExpire(t *testing.T) {
	l := NewLive()
	l.Report("ep1", "web-01", []LiveSession{{SessionID: "gone", InputTokens: 5}})
	l.mu.Lock()
	l.sessions[liveKey(LiveSession{EndpointID: "ep1", Source: "claude", SessionID: "gone"})].SeenAt = time.Now().UTC().Add(-2 * activeWindow)
	l.mu.Unlock()

	if snap := l.Snapshot(); snap.ActiveSessions != 0 {
		t.Fatalf("active = %d, want 0 for a session last seen %v ago", snap.ActiveSessions, 2*activeWindow)
	}
}

func TestLive_AggregatesAcrossEndpoints(t *testing.T) {
	l := NewLive()
	l.Report("ep1", "web-01", []LiveSession{{SessionID: "a"}, {SessionID: "b"}})
	l.Report("ep2", "laptop", []LiveSession{{SessionID: "c"}})

	snap := l.Snapshot()
	if snap.ActiveSessions != 3 {
		t.Errorf("sessions = %d, want 3", snap.ActiveSessions)
	}
	if snap.Endpoints != 2 {
		t.Errorf("endpoints = %d, want 2", snap.Endpoints)
	}
	if snap.Note == "" {
		t.Error("the live view must say it is not the stored totals")
	}
}

// Busiest first: the point of the view is spotting what is burning right now.
func TestLive_SortedByBurnRate(t *testing.T) {
	l := NewLive()
	l.Report("ep1", "e", []LiveSession{{SessionID: "slow"}, {SessionID: "fast"}})
	l.mu.Lock()
	for _, s := range l.sessions {
		s.ObservedAt = time.Now().UTC().Add(-time.Minute)
	}
	l.mu.Unlock()
	l.Report("ep1", "e", []LiveSession{
		{SessionID: "slow", InputTokens: 100},
		{SessionID: "fast", InputTokens: 100000},
	})

	snap := l.Snapshot()
	if snap.Sessions[0].SessionID != "fast" {
		t.Fatalf("first session = %q, want the fastest burner", snap.Sessions[0].SessionID)
	}
}

// A subscriber that stops reading must not wedge the agents reporting in.
func TestLive_SlowSubscriberDoesNotBlockReports(t *testing.T) {
	l := NewLive()
	ch := l.subscribe()
	defer l.unsubscribe(ch)

	done := make(chan struct{})
	go func() {
		for i := 0; i < 50; i++ {
			l.Report("ep1", "e", []LiveSession{{SessionID: "s"}})
		}
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("reports blocked on a subscriber that never read")
	}
}

func TestLive_SnapshotSerialises(t *testing.T) {
	l := NewLive()
	l.Report("ep1", "web-01", []LiveSession{{SessionID: "s", Model: "Opus 5", CostUSD: 1.5}})
	b, err := json.Marshal(l.Snapshot())
	if err != nil {
		t.Fatal(err)
	}
	var back Snapshot
	if err := json.Unmarshal(b, &back); err != nil {
		t.Fatal(err)
	}
	if len(back.Sessions) != 1 || back.Sessions[0].Model != "Opus 5" {
		t.Fatalf("round trip lost data: %+v", back)
	}
}

// os_user does not ride on an agent's live heartbeat -- Live has no store
// access of its own -- so it is filled in server-side, from each endpoint's
// own record, through the REAL enrich chain Handler() wires up (attachCounter
// chained with attachOSUsers), not by calling the cache in isolation. This
// goes through newHarness -> srv.Handler() -> GET /v1/live end to end.
func TestLive_OSUserEnrichedFromEndpointRecord(t *testing.T) {
	h := newHarness(t)
	tok := h.enroll(t, "workstation")

	// Establishes endpoints.os_user = "alice" for ep_workstation, the same
	// way a real ingest batch does: handleIngest stamps os_user server-side
	// from the batch's identity (see ingest.go).
	b := batchFor("acct-a", "workstation", []string{"e1"}, "/proj")
	b.Identity.OSUser = "alice"
	if resp := h.push(t, tok, b); resp.StatusCode != http.StatusOK {
		t.Fatalf("seed push: %d", resp.StatusCode)
	}

	h.srv.LiveStore.Report("ep_workstation", "workstation", []LiveSession{{SessionID: "s1"}})
	// Negative case: a session on an endpoint nothing has ever enrolled or
	// reported identity for must not invent an os_user.
	h.srv.LiveStore.Report("ep-ghost", "ghost", []LiveSession{{SessionID: "s-ghost"}})

	var snap Snapshot
	h.getJSON(t, "/v1/live", &snap)

	byID := map[string]LiveSession{}
	for _, s := range snap.Sessions {
		byID[s.SessionID] = s
	}
	if got := byID["s1"].OSUser; got != "alice" {
		t.Errorf("os_user = %q, want %q", got, "alice")
	}
	if got := byID["s-ghost"].OSUser; got != "" {
		t.Errorf("a session on an unknown endpoint invented os_user %q, want none", got)
	}
}

// "Nobody has told us anything" and "nothing is running" are the same empty
// map, and the page renders them very differently. Live is in-memory by
// design, so the first state is the normal one for the seconds after a hub
// restart — which is exactly when someone is watching.
func TestLive_ColdHubIsUnknownNotZero(t *testing.T) {
	l := NewLive()

	snap := l.Snapshot()
	if snap.EverReported {
		t.Error("a hub that has never been reported to says ever_reported=true; " +
			"the page would render an unmeasured 0 as a measured one")
	}
	if snap.ActiveSessions != 0 {
		t.Errorf("active_sessions = %d on a fresh store, want 0", snap.ActiveSessions)
	}
	if snap.StartedAt.IsZero() {
		t.Error("started_at is zero, so the page cannot say how long it has been ignorant")
	}

	// An endpoint reporting "nothing is running here" is still news: from here
	// on, an empty picture is a measured zero.
	l.Report("ep1", "web-01", nil)
	if snap = l.Snapshot(); !snap.EverReported {
		t.Error("an empty report did not flip ever_reported; an endpoint saying " +
			"'nothing running' has told us as much as one listing a session")
	}
	if snap.ActiveSessions != 0 {
		t.Errorf("active_sessions = %d after an empty report, want 0", snap.ActiveSessions)
	}

	// And it never goes back: a hub that has heard from an agent does not
	// become ignorant again when that agent's sessions age out.
	l.Report("ep1", "web-01", []LiveSession{{SessionID: "s1", InputTokens: 10}})
	l.mu.Lock()
	for _, s := range l.sessions {
		s.SeenAt = time.Now().UTC().Add(-time.Hour)
	}
	l.mu.Unlock()
	if snap = l.Snapshot(); !snap.EverReported || snap.ActiveSessions != 0 {
		t.Errorf("after everything expired: ever_reported=%v active=%d, want true/0",
			snap.EverReported, snap.ActiveSessions)
	}
}

// The card cannot state the rule behind "active" unless the snapshot carries
// it, and a number copied into the dashboard's own source is a number that can
// drift from the one the count was actually computed with.
func TestLive_SnapshotDeclaresItsActiveWindow(t *testing.T) {
	snap := NewLive().Snapshot()
	if want := int(activeWindow / time.Second); snap.ActiveWindowSec != want {
		t.Errorf("active_window_sec = %d, want %d -- the page states this number verbatim",
			snap.ActiveWindowSec, want)
	}
	b, err := json.Marshal(snap)
	if err != nil {
		t.Fatal(err)
	}
	for _, key := range []string{`"active_window_sec"`, `"started_at"`, `"ever_reported"`} {
		if !bytes.Contains(b, []byte(key)) {
			t.Errorf("%s missing from the serialised snapshot: %s", key, b)
		}
	}
}

// FilterLive rebuilds the snapshot from scratch, which is how a scoped viewer
// once lost fields that describe the hub rather than the selection. A chip
// narrows which sessions count; it cannot change how long the hub has been up
// or whether anyone has reported to it.
func TestFilterLive_KeepsHubFactsAcrossScoping(t *testing.T) {
	l := NewLive()
	l.Report("ep1", "web-01", []LiveSession{
		{SessionID: "s1", Account: "acct-a", Source: "claude", InputTokens: 10},
		{SessionID: "s2", Account: "acct-b", Source: "claude", InputTokens: 20},
	})
	s := &Server{}
	full := l.Snapshot()

	out := s.FilterLive(full, "acct-a", "")
	if out.ActiveSessions != 1 {
		t.Fatalf("scoped active_sessions = %d, want 1", out.ActiveSessions)
	}
	if !out.EverReported {
		t.Error("ever_reported dropped by scoping -- every chipped viewer would be " +
			"told this hub had just restarted")
	}
	if out.ActiveWindowSec != full.ActiveWindowSec {
		t.Errorf("active_window_sec = %d after scoping, want %d", out.ActiveWindowSec, full.ActiveWindowSec)
	}
	if !out.StartedAt.Equal(full.StartedAt) {
		t.Errorf("started_at = %v after scoping, want %v", out.StartedAt, full.StartedAt)
	}
}
