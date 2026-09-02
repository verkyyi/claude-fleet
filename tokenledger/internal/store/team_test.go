package store

import (
	"testing"
	"time"

	"github.com/verkyyi/ccquota/internal/model"
)

func TestSetEndpointTeam(t *testing.T) {
	s := newStore(t)
	seedAccount(t, s, "acct-1", "ep-1")

	if err := s.SetEndpointTeam("ep-1", "platform"); err != nil {
		t.Fatal(err)
	}
	eps, err := s.ListEndpoints("")
	if err != nil {
		t.Fatal(err)
	}
	if len(eps) != 1 || eps[0].Team != "platform" {
		t.Fatalf("team not stored: %+v", eps)
	}

	// Naming a machine that is not enrolled is an operator typo, and silently
	// succeeding leaves them believing a team was assigned.
	if err := s.SetEndpointTeam("ep-nope", "platform"); err == nil {
		t.Error("SetEndpointTeam accepted an unknown endpoint")
	}
}

func TestUsageBy_Team(t *testing.T) {
	s := newStore(t)
	seedAccount(t, s, "acct-1", "ep-1")
	seedAccount(t, s, "acct-1", "ep-2")
	if err := s.SetEndpointTeam("ep-1", "platform"); err != nil {
		t.Fatal(err)
	}
	// ep-2 is deliberately left unassigned.

	if _, _, err := s.InsertEvents([]model.UsageEvent{
		ev("acct-1", "ep-1", "m1", 100),
		ev("acct-1", "ep-2", "m2", 30),
	}); err != nil {
		t.Fatal(err)
	}

	start := time.Date(2026, 8, 1, 0, 0, 0, 0, time.UTC)
	end := time.Date(2026, 9, 30, 0, 0, 0, 0, time.UTC)
	buckets, err := s.UsageBy(AllAccounts, ByTeam, start, end, 50)
	if err != nil {
		t.Fatal(err)
	}
	got := map[string]int64{}
	labels := map[string]string{}
	for _, b := range buckets {
		got[b.Key] = b.Tokens
		labels[b.Key] = b.Label
	}
	if got["platform"] != 100 {
		t.Errorf("platform tokens = %d, want 100", got["platform"])
	}
	// An endpoint with no team must still appear. Dropping it would make the
	// team totals silently smaller than the fleet total.
	if got[""] != 30 {
		t.Errorf("unassigned tokens = %d, want 30", got[""])
	}
	if labels[""] != "unassigned" {
		t.Errorf("unassigned bucket label = %q, want \"unassigned\"", labels[""])
	}
}

// Team is resolved by join, never stored on the event row. Re-assigning a
// machine must move its whole history, not just turns ingested afterwards.
func TestUsageBy_TeamFollowsReassignment(t *testing.T) {
	s := newStore(t)
	seedAccount(t, s, "acct-1", "ep-1")
	if err := s.SetEndpointTeam("ep-1", "platform"); err != nil {
		t.Fatal(err)
	}
	if _, _, err := s.InsertEvents([]model.UsageEvent{ev("acct-1", "ep-1", "m1", 100)}); err != nil {
		t.Fatal(err)
	}
	if err := s.SetEndpointTeam("ep-1", "infra"); err != nil {
		t.Fatal(err)
	}

	start := time.Date(2026, 8, 1, 0, 0, 0, 0, time.UTC)
	end := time.Date(2026, 9, 30, 0, 0, 0, 0, time.UTC)
	buckets, err := s.UsageBy(AllAccounts, ByTeam, start, end, 50)
	if err != nil {
		t.Fatal(err)
	}
	for _, b := range buckets {
		if b.Key == "platform" {
			t.Fatal("history stayed on the old team; team is being frozen at ingest")
		}
		if b.Key == "infra" && b.Tokens != 100 {
			t.Errorf("infra tokens = %d, want the full 100", b.Tokens)
		}
	}
}

// An endpoint that could name its own team could move its spend onto another
// team's budget. Only the operator assigns teams, so the ingest path must not
// touch the column.
func TestTouchEndpoint_CannotSetOrClearTeam(t *testing.T) {
	s := newStore(t)
	seedAccount(t, s, "acct-1", "ep-1")
	if err := s.SetEndpointTeam("ep-1", "platform"); err != nil {
		t.Fatal(err)
	}
	if _, _, err := s.TouchEndpoint("ep-1", ident("acct-1"), "v-test", true); err != nil {
		t.Fatal(err)
	}
	eps, err := s.ListEndpoints("")
	if err != nil {
		t.Fatal(err)
	}
	if eps[0].Team != "platform" {
		t.Fatalf("an ingest push changed the team to %q", eps[0].Team)
	}
}
