package api

import (
	"testing"
	"time"

	"github.com/verkyyi/ccquota/internal/model"
	"github.com/verkyyi/ccquota/internal/store"
)

func intp(n int) *int { return &n }

// The login batch carries the reading; the guest and limits batches that
// follow it on the same endpoint do not, and must not erase it. This is the
// hub-side half of claude-fleet#644: the roster answers "which login's
// claude-fleet is behind trunk" from what the agent relayed.
func TestIngest_FleetVersionLandsOnTheEndpointAndSurvivesGuestBatches(t *testing.T) {
	h := newHarness(t)
	tok := h.enroll(t, "macmini")

	seen := time.Date(2026, 9, 24, 9, 30, 0, 0, time.UTC)
	login := batchFor("acct-a", "macmini", []string{"c1"}, "/a")
	login.AccountOrigin = model.OriginLogin
	login.FleetVersion = &model.FleetVersion{
		Head: "0164208", Branch: "master", Behind: nil, Ahead: nil, Fetched: false,
		Verdict: "UNKNOWN", FollowVerdict: "OFF", Error: "fetch refused", ObservedAt: seen,
	}
	if resp := h.push(t, tok, login); resp.StatusCode != 200 {
		t.Fatalf("HTTP %d", resp.StatusCode)
	}

	// A subscription merely seen in a session, then a limits-only batch.
	guest := batchFor("acct-b", "macmini", []string{"g1"}, "/a")
	guest.AccountOrigin = model.OriginSession
	if resp := h.push(t, tok, guest); resp.StatusCode != 200 {
		t.Fatalf("guest: HTTP %d", resp.StatusCode)
	}
	limits := batchFor("acct-a", "macmini", nil, "/a")
	limits.AccountOrigin = model.OriginLogin
	if resp := h.push(t, tok, limits); resp.StatusCode != 200 {
		t.Fatalf("limits: HTTP %d", resp.StatusCode)
	}

	var eps []store.Endpoint
	h.getJSON(t, "/v1/endpoints", &eps)
	if len(eps) != 1 {
		t.Fatalf("got %d endpoints, want 1", len(eps))
	}
	e := eps[0]
	if e.FleetHead != "0164208" || e.FleetVerdict != "UNKNOWN" || e.FleetFollow != "OFF" {
		t.Fatalf("fleet reading missing or overwritten after the guest batches: %+v", e)
	}
	if e.FleetBehind != nil {
		t.Fatalf("fleet_behind = %d; a null count must reach the roster as null, not 0", *e.FleetBehind)
	}
	if e.FleetError != "fetch refused" {
		t.Errorf("fleet_error = %q, want the script's explanation for the tooltip", e.FleetError)
	}
	if e.FleetSeenAt == nil || !e.FleetSeenAt.Equal(seen) {
		t.Errorf("fleet_seen_at = %v, want %v (when the agent ran the script)", e.FleetSeenAt, seen)
	}
	if e.LastSeen == nil || !e.LastSeen.After(seen) {
		t.Errorf("last_seen = %v; it should be the hub's now, later than the reading", e.LastSeen)
	}
}

// A newer reading replaces the older one whole, including a count that has
// become known again.
func TestIngest_NewerFleetVersionReplacesTheOlder(t *testing.T) {
	h := newHarness(t)
	tok := h.enroll(t, "macbook")

	first := batchFor("acct-a", "macbook", []string{"c1"}, "/a")
	first.AccountOrigin = model.OriginLogin
	first.FleetVersion = &model.FleetVersion{Head: "aaaaaaa", Behind: intp(12), Verdict: "BEHIND", Fetched: false}
	h.push(t, tok, first)

	second := batchFor("acct-a", "macbook", []string{"c2"}, "/a")
	second.AccountOrigin = model.OriginLogin
	second.FleetVersion = &model.FleetVersion{Head: "bbbbbbb", Behind: intp(0), Verdict: "CURRENT", Fetched: true, FollowVerdict: "OK"}
	h.push(t, tok, second)

	var eps []store.Endpoint
	h.getJSON(t, "/v1/endpoints", &eps)
	e := eps[0]
	if e.FleetHead != "bbbbbbb" || e.FleetVerdict != "CURRENT" || !e.FleetFetched || e.FleetFollow != "OK" {
		t.Fatalf("second reading did not replace the first: %+v", e)
	}
	if e.FleetBehind == nil || *e.FleetBehind != 0 {
		t.Fatalf("fleet_behind = %v, want 0 (a real zero, from a reading that said so)", e.FleetBehind)
	}
	if e.FleetSeenAt == nil {
		t.Fatal("a reading without observed_at must still stamp fleet_seen_at (hub now)")
	}
}
