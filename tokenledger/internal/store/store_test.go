package store

import (
	"path/filepath"
	"testing"
	"time"

	"github.com/verkyyi/ccquota/internal/model"
)

func newStore(t *testing.T) *Store {
	t.Helper()
	s, err := Open(filepath.Join(t.TempDir(), "test.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.Close() })
	return s
}

func ident(account string) model.Identity {
	return model.Identity{
		AccountUUID: account, Email: "a@example.com", OrgName: "Org",
		Hostname: "host-1", OS: "linux", Arch: "amd64", MachineID: "m1",
	}
}

func ev(account, endpoint, uuid string, out int64) model.UsageEvent {
	c := 1.5
	return model.UsageEvent{
		AccountUUID: account, EndpointID: endpoint, MessageUUID: uuid,
		SessionID: "s1", TS: time.Date(2026, 8, 31, 12, 0, 0, 0, time.UTC),
		Model: "claude-sonnet-5", OutputTokens: out, CostUSD: &c,
		CWD: "/w", GitBranch: "main",
	}
}

func seedAccount(t *testing.T, s *Store, account, endpoint string) {
	t.Helper()
	if err := s.UpsertAccount(ident(account), "max", "default_claude_max_20x"); err != nil {
		t.Fatal(err)
	}
	if err := s.Enroll(endpoint, endpoint, "hash-"+endpoint); err != nil {
		t.Fatal(err)
	}
	if _, err := s.TouchEndpoint(endpoint, ident(account), "test"); err != nil {
		t.Fatal(err)
	}
}

func TestInsertEvents_DedupsOnReplay(t *testing.T) {
	s := newStore(t)
	seedAccount(t, s, "acct-a", "ep-1")

	batch := []model.UsageEvent{ev("acct-a", "ep-1", "u1", 10), ev("acct-a", "ep-1", "u2", 20)}

	ins, dup, err := s.InsertEvents(batch)
	if err != nil {
		t.Fatal(err)
	}
	if ins != 2 || dup != 0 {
		t.Fatalf("first insert: %d new / %d dup, want 2/0", ins, dup)
	}

	// An agent whose cursor was lost re-ships the same batch.
	ins, dup, err = s.InsertEvents(batch)
	if err != nil {
		t.Fatal(err)
	}
	if ins != 0 || dup != 2 {
		t.Fatalf("replay: %d new / %d dup, want 0/2", ins, dup)
	}
}

// The same uuid under a DIFFERENT subscription is a different fact and must
// not be swallowed by dedup — the key is (account, uuid), not uuid alone.
func TestInsertEvents_DedupIsScopedToAccount(t *testing.T) {
	s := newStore(t)
	seedAccount(t, s, "acct-a", "ep-1")
	seedAccount(t, s, "acct-b", "ep-2")

	if _, _, err := s.InsertEvents([]model.UsageEvent{ev("acct-a", "ep-1", "same-uuid", 10)}); err != nil {
		t.Fatal(err)
	}
	ins, dup, err := s.InsertEvents([]model.UsageEvent{ev("acct-b", "ep-2", "same-uuid", 10)})
	if err != nil {
		t.Fatal(err)
	}
	if ins != 1 || dup != 0 {
		t.Fatalf("cross-account: %d new / %d dup, want 1/0", ins, dup)
	}
}

// nil cost means "this model is not in the pricing table". Storing 0 would
// claim the work was free.
func TestInsertEvents_NilCostStaysNull(t *testing.T) {
	s := newStore(t)
	seedAccount(t, s, "acct-a", "ep-1")

	e := ev("acct-a", "ep-1", "u1", 10)
	e.CostUSD = nil
	if _, _, err := s.InsertEvents([]model.UsageEvent{e}); err != nil {
		t.Fatal(err)
	}

	var isNull bool
	err := s.DB().QueryRow(`SELECT cost_usd IS NULL FROM usage_events WHERE message_uuid='u1'`).Scan(&isNull)
	if err != nil {
		t.Fatal(err)
	}
	if !isNull {
		t.Fatal("cost_usd should be NULL for an unpriced model, not 0")
	}
}

func TestUpsertAccount_DoesNotBlankKnownTier(t *testing.T) {
	s := newStore(t)
	if err := s.UpsertAccount(ident("acct-a"), "max", "default_claude_max_20x"); err != nil {
		t.Fatal(err)
	}
	// A second endpoint that could not read the local credential file reports
	// empty tier fields.
	if err := s.UpsertAccount(ident("acct-a"), "", ""); err != nil {
		t.Fatal(err)
	}

	var subType, tier string
	err := s.DB().QueryRow(`SELECT subscription_type, rate_limit_tier FROM accounts WHERE account_uuid='acct-a'`).
		Scan(&subType, &tier)
	if err != nil {
		t.Fatal(err)
	}
	if subType != "max" || tier != "default_claude_max_20x" {
		t.Fatalf("tier was blanked by an endpoint that could not read it: %q/%q", subType, tier)
	}
}

func TestEnrollAndResolveToken(t *testing.T) {
	s := newStore(t)
	if err := s.Enroll("ep-1", "web-01", "hashed-secret"); err != nil {
		t.Fatal(err)
	}
	got, err := s.EndpointByTokenHash("hashed-secret")
	if err != nil {
		t.Fatal(err)
	}
	if got.ID != "ep-1" || got.Label != "web-01" {
		t.Fatalf("resolved %+v", got)
	}

	if _, err := s.EndpointByTokenHash("wrong"); err == nil {
		t.Fatal("an unknown token must not resolve to an endpoint")
	}
}

func TestTouchEndpoint_ReportsPreviousAccount(t *testing.T) {
	s := newStore(t)
	if err := s.UpsertAccount(ident("acct-a"), "max", ""); err != nil {
		t.Fatal(err)
	}
	if err := s.UpsertAccount(ident("acct-b"), "pro", ""); err != nil {
		t.Fatal(err)
	}
	if err := s.Enroll("ep-1", "host", "h"); err != nil {
		t.Fatal(err)
	}

	prev, err := s.TouchEndpoint("ep-1", ident("acct-a"), "v1")
	if err != nil {
		t.Fatal(err)
	}
	if prev != "" {
		t.Fatalf("first touch previous account = %q, want empty", prev)
	}

	prev, err = s.TouchEndpoint("ep-1", ident("acct-b"), "v1")
	if err != nil {
		t.Fatal(err)
	}
	if prev != "acct-a" {
		t.Fatalf("previous account = %q, want acct-a — the switch would otherwise be invisible", prev)
	}
}

func TestInsertLimits(t *testing.T) {
	s := newStore(t)
	seedAccount(t, s, "acct-a", "ep-1")

	reset := time.Date(2026, 9, 1, 8, 29, 59, 0, time.UTC)
	snap := &model.LimitsSnapshot{
		AccountUUID: "acct-a", EndpointID: "ep-1", ObservedAt: time.Now().UTC(),
		FiveHour: model.Window{Utilization: 4, ResetsAt: &reset},
		SevenDay: model.Window{Utilization: 8},
		Scoped:   []model.ScopedWindow{{Kind: "weekly_scoped", Model: "Fable"}},
		RawJSON:  `{"five_hour":{}}`,
	}
	if err := s.InsertLimits(snap); err != nil {
		t.Fatal(err)
	}

	var pct float64
	var scoped string
	err := s.DB().QueryRow(`SELECT five_hour_pct, scoped_json FROM limit_snapshots WHERE account_uuid='acct-a'`).
		Scan(&pct, &scoped)
	if err != nil {
		t.Fatal(err)
	}
	if pct != 4 {
		t.Errorf("five_hour_pct = %v", pct)
	}
	if scoped == "" || scoped == "null" {
		t.Errorf("scoped_json = %q", scoped)
	}
}

func TestPruneEvents(t *testing.T) {
	s := newStore(t)
	seedAccount(t, s, "acct-a", "ep-1")

	old := ev("acct-a", "ep-1", "old", 1)
	old.TS = time.Now().AddDate(0, 0, -100).UTC()
	recent := ev("acct-a", "ep-1", "recent", 1)
	recent.TS = time.Now().UTC()
	if _, _, err := s.InsertEvents([]model.UsageEvent{old, recent}); err != nil {
		t.Fatal(err)
	}

	n, err := s.PruneEvents(time.Now().AddDate(0, 0, -90))
	if err != nil {
		t.Fatal(err)
	}
	if n != 1 {
		t.Fatalf("pruned %d, want 1", n)
	}

	var remaining int
	if err := s.DB().QueryRow(`SELECT COUNT(*) FROM usage_events`).Scan(&remaining); err != nil {
		t.Fatal(err)
	}
	if remaining != 1 {
		t.Fatalf("remaining = %d, want 1", remaining)
	}
}
