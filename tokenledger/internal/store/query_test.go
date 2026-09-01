package store

import (
	"testing"
	"time"

	"github.com/verkyyi/ccquota/internal/model"
)

var base = time.Date(2026, 8, 31, 12, 0, 0, 0, time.UTC)

func seedTwoAccounts(t *testing.T, s *Store) {
	t.Helper()
	seedAccount(t, s, "acct-a", "ep-a1")
	seedAccount(t, s, "acct-b", "ep-b1")

	a1 := ev("acct-a", "ep-a1", "a-1", 100)
	a1.CWD = "/home/x/projects/alpha"
	a2 := ev("acct-a", "ep-a1", "a-2", 50)
	a2.CWD = "/home/x/projects/beta"

	b1 := ev("acct-b", "ep-b1", "b-1", 999999)
	b1.CWD = "/srv/other-company/secret"

	if _, _, err := s.InsertEvents([]model.UsageEvent{a1, a2, b1}); err != nil {
		t.Fatal(err)
	}
}

// THE isolation test. A hub holding several subscriptions must never let one
// account's rows appear in another's answer.
func TestQueries_AccountIsolation(t *testing.T) {
	s := newStore(t)
	seedTwoAccounts(t, s)

	start, end := base.Add(-time.Hour), base.Add(time.Hour)

	byEndpoint, err := s.UsageBy("acct-a", ByEndpoint, start, end, 50)
	if err != nil {
		t.Fatal(err)
	}
	for _, b := range byEndpoint {
		if b.Key == "ep-b1" {
			t.Fatal("acct-a's endpoint breakdown contains acct-b's endpoint")
		}
	}

	byProject, err := s.UsageBy("acct-a", ByProject, start, end, 50)
	if err != nil {
		t.Fatal(err)
	}
	for _, b := range byProject {
		if b.Key == "/srv/other-company/secret" {
			t.Fatal("acct-a's project breakdown leaked acct-b's working directory")
		}
	}

	hist, err := s.History("acct-a", Daily, start, end)
	if err != nil {
		t.Fatal(err)
	}
	var total int64
	for _, h := range hist {
		total += h.Tokens
	}
	if total != 150 {
		t.Fatalf("acct-a history totals %d tokens, want 150 — acct-b's 999999 leaked in", total)
	}

	evs, err := s.EventsInRange("acct-a", start, end)
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range evs {
		if e.AccountUUID != "acct-a" {
			t.Fatalf("EventsInRange returned an event for %s", e.AccountUUID)
		}
	}
}

// An unscoped aggregate is a bug, not a convenience. Refusing is safer than
// returning a mixed total that looks plausible.
func TestQueries_RefuseUnscopedAggregate(t *testing.T) {
	s := newStore(t)
	if _, err := s.UsageBy("", ByEndpoint, base, base.Add(time.Hour), 10); err == nil {
		t.Error("UsageBy with no account should be refused")
	}
	if _, err := s.History("", Daily, base, base.Add(time.Hour)); err == nil {
		t.Error("History with no account should be refused")
	}
}

// The dimension is a whitelist, so a caller cannot smuggle SQL through it.
func TestUsageBy_RejectsUnknownDimension(t *testing.T) {
	s := newStore(t)
	_, err := s.UsageBy("acct-a", Dimension("cwd; DROP TABLE usage_events--"), base, base.Add(time.Hour), 10)
	if err == nil {
		t.Fatal("an unknown dimension must be rejected, not interpolated")
	}
}

func TestUsageBy_CountsUnpricedSeparately(t *testing.T) {
	s := newStore(t)
	seedAccount(t, s, "acct-a", "ep-a1")

	priced := ev("acct-a", "ep-a1", "p", 10)
	unpriced := ev("acct-a", "ep-a1", "u", 10)
	unpriced.CostUSD = nil
	if _, _, err := s.InsertEvents([]model.UsageEvent{priced, unpriced}); err != nil {
		t.Fatal(err)
	}

	bs, err := s.UsageBy("acct-a", ByEndpoint, base.Add(-time.Hour), base.Add(time.Hour), 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(bs) != 1 {
		t.Fatalf("buckets = %d, want 1", len(bs))
	}
	if bs[0].Unpriced != 1 {
		t.Errorf("unpriced = %d, want 1", bs[0].Unpriced)
	}
	if bs[0].Events != 2 {
		t.Errorf("events = %d, want 2 — unpriced turns still happened", bs[0].Events)
	}
}

func TestUsageBy_LabelsEndpoints(t *testing.T) {
	s := newStore(t)
	seedAccount(t, s, "acct-a", "ep-a1")
	if _, _, err := s.InsertEvents([]model.UsageEvent{ev("acct-a", "ep-a1", "x", 10)}); err != nil {
		t.Fatal(err)
	}

	bs, err := s.UsageBy("acct-a", ByEndpoint, base.Add(-time.Hour), base.Add(time.Hour), 10)
	if err != nil {
		t.Fatal(err)
	}
	if bs[0].Label != "ep-a1" {
		t.Errorf("label = %q, want the endpoint's label", bs[0].Label)
	}
}

// No snapshot must read as "unknown", never as 0%.
func TestLatestLimits_AbsentIsNilNotZero(t *testing.T) {
	s := newStore(t)
	seedAccount(t, s, "acct-a", "ep-a1")

	snap, err := s.LatestLimits("acct-a")
	if err != nil {
		t.Fatal(err)
	}
	if snap != nil {
		t.Fatalf("snapshot = %+v, want nil when no endpoint ever read the limits", snap)
	}
}

func TestListAccounts_CountsEndpoints(t *testing.T) {
	s := newStore(t)
	seedAccount(t, s, "acct-a", "ep-a1")
	seedAccount(t, s, "acct-a", "ep-a2")
	seedAccount(t, s, "acct-b", "ep-b1")

	accts, err := s.ListAccounts()
	if err != nil {
		t.Fatal(err)
	}
	if len(accts) != 2 {
		t.Fatalf("accounts = %d, want 2", len(accts))
	}
	for _, a := range accts {
		want := map[string]int{"acct-a": 2, "acct-b": 1}[a.AccountUUID]
		if a.EndpointCount != want {
			t.Errorf("%s endpoint count = %d, want %d", a.AccountUUID, a.EndpointCount, want)
		}
	}
}
