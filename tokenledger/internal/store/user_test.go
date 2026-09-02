package store

import (
	"testing"
	"time"

	"github.com/verkyyi/ccquota/internal/model"
)

func userEv(account, endpoint, uuid, osUser, cwd string, out int64) model.UsageEvent {
	c := 2.0
	return model.UsageEvent{
		AccountUUID: account, EndpointID: endpoint, MessageUUID: uuid,
		SessionID: "s-" + uuid, TS: time.Date(2026, 8, 31, 12, 0, 0, 0, time.UTC),
		Model: "claude-opus-5", OutputTokens: out, CostUSD: &c,
		CWD: cwd, OSUser: osUser, GitBranch: "main",
	}
}

func seedUsers(t *testing.T, s *Store) (start, end time.Time) {
	t.Helper()
	seedAccount(t, s, "acct-1", "ep-1")
	seedAccount(t, s, "acct-1", "ep-2")
	if err := s.SetEndpointTeam("ep-1", "platform"); err != nil {
		t.Fatal(err)
	}
	if _, _, err := s.InsertEvents([]model.UsageEvent{
		userEv("acct-1", "ep-1", "m1", "alice", "/repo/a", 100),
		userEv("acct-1", "ep-2", "m2", "alice", "/repo/b", 50),
		userEv("acct-1", "ep-1", "m3", "bob", "/repo/a", 7),
	}); err != nil {
		t.Fatal(err)
	}
	return time.Date(2026, 8, 1, 0, 0, 0, 0, time.UTC),
		time.Date(2026, 9, 30, 0, 0, 0, 0, time.UTC)
}

func TestUserSummary(t *testing.T) {
	s := newStore(t)
	start, end := seedUsers(t, s)

	got, err := s.UserSummary("alice", start, end)
	if err != nil {
		t.Fatal(err)
	}
	if got.Turns != 2 {
		t.Errorf("turns = %d, want 2", got.Turns)
	}
	if got.Tokens != 150 {
		t.Errorf("tokens = %d, want 150", got.Tokens)
	}
	if got.Projects != 2 {
		t.Errorf("projects = %d, want 2", got.Projects)
	}
	if got.Machines != 2 {
		t.Errorf("machines = %d, want 2", got.Machines)
	}
	// alice works on one assigned machine and one unassigned one. Reporting a
	// single team would attribute half her spend to a team that never got it.
	if len(got.Teams) != 1 || got.Teams[0] != "platform" {
		t.Errorf("teams = %v, want [platform]", got.Teams)
	}
}

// An unknown login is not an error -- it is a page that says "no usage".
func TestUserSummary_UnknownLoginIsEmptyNotAnError(t *testing.T) {
	s := newStore(t)
	start, end := seedUsers(t, s)
	got, err := s.UserSummary("nobody", start, end)
	if err != nil {
		t.Fatal(err)
	}
	if got.Turns != 0 || got.Tokens != 0 {
		t.Errorf("unknown login reported usage: %+v", got)
	}
}

func TestUsageByUser_ScopesToOneLogin(t *testing.T) {
	s := newStore(t)
	start, end := seedUsers(t, s)

	buckets, err := s.UsageByUser("alice", ByProject, start, end, 50)
	if err != nil {
		t.Fatal(err)
	}
	total := int64(0)
	for _, b := range buckets {
		total += b.Tokens
		if b.Key == "/repo/a" && b.Tokens != 100 {
			t.Errorf("/repo/a = %d tokens, want 100 (bob's 7 must not be included)", b.Tokens)
		}
	}
	if total != 150 {
		t.Errorf("total across alice's projects = %d, want 150", total)
	}
}

// The two totals on the page come from different queries. If their token
// expressions ever diverge by a cache column, the page contradicts itself.
func TestUserSummary_AgreesWithUsageByUser(t *testing.T) {
	s := newStore(t)
	start, end := seedUsers(t, s)

	sum, err := s.UserSummary("alice", start, end)
	if err != nil {
		t.Fatal(err)
	}
	buckets, err := s.UsageByUser("alice", ByProject, start, end, 1000)
	if err != nil {
		t.Fatal(err)
	}
	var viaBuckets int64
	for _, b := range buckets {
		viaBuckets += b.Tokens
	}
	if sum.Tokens != viaBuckets {
		t.Errorf("summary says %d tokens, the breakdown sums to %d", sum.Tokens, viaBuckets)
	}
}
