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

// Account is now an ordinary axis, not a mode the whole hub is stuck in.
func TestUsageBy_Account(t *testing.T) {
	s := newStore(t)
	seedTwoAccounts(t, s)

	bs, err := s.UsageBy(AllAccounts, ByAccount, base.Add(-time.Hour), base.Add(time.Hour), 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(bs) != 2 {
		t.Fatalf("buckets = %d, want one per subscription", len(bs))
	}
	byKey := map[string]Bucket{}
	for _, b := range bs {
		byKey[b.Key] = b
	}
	if byKey["acct-a"].Tokens != 150 {
		t.Errorf("acct-a tokens = %d, want 150", byKey["acct-a"].Tokens)
	}
	if byKey["acct-b"].Tokens != 999999 {
		t.Errorf("acct-b tokens = %d, want 999999", byKey["acct-b"].Tokens)
	}
	if byKey["acct-a"].Label == "" {
		t.Error("account buckets should be labelled with the email, not just a uuid")
	}
}

// Spanning subscriptions is allowed, but only when asked for by name.
func TestUsageBy_AllAccountsSpansEverything(t *testing.T) {
	s := newStore(t)
	seedTwoAccounts(t, s)

	bs, err := s.UsageBy(AllAccounts, ByEndpoint, base.Add(-time.Hour), base.Add(time.Hour), 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(bs) != 2 {
		t.Fatalf("endpoints = %d, want both machines regardless of subscription", len(bs))
	}
	var total int64
	for _, b := range bs {
		total += b.Tokens
	}
	if total != 150+999999 {
		t.Errorf("total = %d, want the sum across subscriptions", total)
	}
}

// The empty string is what an uninitialised variable looks like; blending
// subscriptions on an accident is the failure the guard exists for.
func TestUsageBy_EmptyAccountIsStillRefused(t *testing.T) {
	s := newStore(t)
	seedTwoAccounts(t, s)

	if _, err := s.UsageBy("", ByEndpoint, base, base.Add(time.Hour), 10); err == nil {
		t.Fatal("an empty account was accepted; only AllAccounts may span subscriptions")
	}
	if _, err := s.History("", Daily, base, base.Add(time.Hour)); err == nil {
		t.Fatal("History accepted an empty account")
	}
}

func TestHistory_AllAccounts(t *testing.T) {
	s := newStore(t)
	seedTwoAccounts(t, s)

	h, err := s.History(AllAccounts, Daily, base.Add(-time.Hour), base.Add(time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	var total int64
	for _, b := range h {
		total += b.Tokens
	}
	if total != 150+999999 {
		t.Errorf("history total = %d, want both subscriptions", total)
	}
}

// Scoping to one subscription must still exclude the other — the new
// cross-account capability must not have loosened the default.
func TestUsageBy_ScopedStillIsolates(t *testing.T) {
	s := newStore(t)
	seedTwoAccounts(t, s)

	bs, err := s.UsageBy("acct-a", ByProject, base.Add(-time.Hour), base.Add(time.Hour), 10)
	if err != nil {
		t.Fatal(err)
	}
	for _, b := range bs {
		if b.Key == "/srv/other-company/secret" {
			t.Fatal("scoping to acct-a leaked acct-b's directory")
		}
	}
}

func TestEventsInRange_AllAccountsStampsEachRow(t *testing.T) {
	s := newStore(t)
	seedTwoAccounts(t, s)

	evs, err := s.EventsInRange(AllAccounts, base.Add(-time.Hour), base.Add(time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	seen := map[string]bool{}
	for _, e := range evs {
		if e.AccountUUID == "" {
			t.Fatal("a cross-account row came back with no subscription on it")
		}
		seen[e.AccountUUID] = true
	}
	if len(seen) != 2 {
		t.Fatalf("saw %d subscriptions, want 2", len(seen))
	}
}

// Two subscriptions can carry the same display name — on the hub this was
// written against, two of three were both "Lee". Labelling by display name
// renders them identically, so a machine running both looks like it is running
// one subscription twice. Emails are unique; names are not.
func TestEndpointAccounts_DistinguishesAccountsSharingADisplayName(t *testing.T) {
	s := newStore(t)

	for _, a := range []struct{ uuid, email string }{
		{"acct-a", "one@example.com"},
		{"acct-b", "two@example.com"},
	} {
		id := ident(a.uuid)
		id.Email = a.email
		id.DisplayName = "Lee" // the same human, two subscriptions
		if err := s.UpsertAccount(id, "max", ""); err != nil {
			t.Fatal(err)
		}
	}
	if err := s.Enroll("ep-1", "laptop", "h"); err != nil {
		t.Fatal(err)
	}
	for _, a := range []string{"acct-a", "acct-b"} {
		if err := s.RecordEndpointAccount("ep-1", a, model.OriginSession); err != nil {
			t.Fatal(err)
		}
	}

	rows, err := s.EndpointAccounts(10)
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 2 {
		t.Fatalf("rows = %d, want 2", len(rows))
	}
	if rows[0].AccountName == rows[1].AccountName {
		t.Fatalf("both subscriptions rendered as %q — the card cannot tell them apart",
			rows[0].AccountName)
	}
}
