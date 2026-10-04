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
	if _, _, err := s.TouchEndpoint(endpoint, ident(account), "test", true, nil); err != nil {
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

	prev, prevWasLogin, err := s.TouchEndpoint("ep-1", ident("acct-a"), "v1", true, nil)
	if err != nil {
		t.Fatal(err)
	}
	if prev != "" {
		t.Fatalf("first touch previous account = %q, want empty", prev)
	}
	if prevWasLogin {
		t.Error("nothing preceded the first touch, so there was no login to succeed")
	}
	if err := s.RecordEndpointAccount("ep-1", "acct-a", model.OriginLogin); err != nil {
		t.Fatal(err)
	}

	prev, prevWasLogin, err = s.TouchEndpoint("ep-1", ident("acct-b"), "v1", true, nil)
	if err != nil {
		t.Fatal(err)
	}
	if prev != "acct-a" {
		t.Fatalf("previous account = %q, want acct-a — the switch would otherwise be invisible", prev)
	}
	if !prevWasLogin {
		t.Error("acct-a was this endpoint's own login, so replacing it IS a switch")
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

// A per-model cap outlives the snapshot that carried it. Most snapshots come
// from a statusLine that never sees the Fable window, so if the cap only lived
// on its snapshot, the next free reading would hide it. And a late-delivered
// older reading must not roll it back.
func TestInsertLimits_ModelClaimsKeepTheLatestPerModel(t *testing.T) {
	s := newStore(t)
	seedAccount(t, s, "acct-a", "ep-1")

	t0 := time.Date(2026, 9, 23, 10, 0, 0, 0, time.UTC)
	reset := time.Date(2026, 9, 28, 18, 0, 0, 0, time.UTC)
	snapAt := func(at time.Time, claims ...model.ModelClaim) *model.LimitsSnapshot {
		return &model.LimitsSnapshot{
			AccountUUID: "acct-a", EndpointID: "ep-1", ObservedAt: at,
			SevenDay: model.Window{Utilization: 80}, ModelClaims: claims,
		}
	}
	fable := func(at time.Time, pct float64, status string) model.ModelClaim {
		return model.ModelClaim{Model: "claude-fable-5-1", Claim: "7d_oi",
			Utilization: pct, Status: status, ResetsAt: &reset, ObservedAt: at}
	}

	for _, snap := range []*model.LimitsSnapshot{
		snapAt(t0, fable(t0, 90, "allowed_warning")),
		snapAt(t0.Add(5*time.Minute), fable(t0.Add(5*time.Minute), 100, "rejected")),
		snapAt(t0.Add(6 * time.Minute)),                                                // a statusLine reading: no claims
		snapAt(t0.Add(time.Minute), fable(t0.Add(time.Minute), 91, "allowed_warning")), // late
	} {
		if err := s.InsertLimits(snap); err != nil {
			t.Fatal(err)
		}
	}

	got, err := s.LatestModelClaims("acct-a")
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 1 {
		t.Fatalf("got %d claims, want 1: %+v", len(got), got)
	}
	c := got[0]
	if c.Utilization != 100 || c.Status != "rejected" || !c.ObservedAt.Equal(t0.Add(5*time.Minute)) {
		t.Errorf("claim = %+v, want the 100%% rejected reading from t0+5m", c)
	}
	if c.ResetsAt == nil || !c.ResetsAt.Equal(reset) {
		t.Errorf("reset = %v, want %v", c.ResetsAt, reset)
	}

	if none, err := s.LatestModelClaims("acct-b"); err != nil || len(none) != 0 {
		t.Errorf("an account never probed has claims %+v (err %v)", none, err)
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

// A name given by hand must survive every later automatic report, or naming a
// fingerprinted subscription becomes a chore repeated after each restart —
// which is not a workflow anyone keeps up with.
func TestSetAccountLabel_SurvivesAutomaticReports(t *testing.T) {
	s := newStore(t)
	if err := s.UpsertAccount(ident("win_abc"), "max", ""); err != nil {
		t.Fatal(err)
	}
	if err := s.SetAccountLabel("win_abc", "ly297@georgetown.edu"); err != nil {
		t.Fatal(err)
	}

	// An agent reports again, carrying a different (automatic) email and, on a
	// later cycle, no email at all.
	other := ident("win_abc")
	other.Email = "wrong@example.com"
	if err := s.UpsertAccount(other, "max", ""); err != nil {
		t.Fatal(err)
	}
	blank := ident("win_abc")
	blank.Email = ""
	if err := s.UpsertAccount(blank, "max", ""); err != nil {
		t.Fatal(err)
	}

	accts, err := s.ListAccounts()
	if err != nil {
		t.Fatal(err)
	}
	if len(accts) != 1 {
		t.Fatalf("accounts = %d, want 1", len(accts))
	}
	if got := accts[0].Label(); got != "ly297@georgetown.edu" {
		t.Fatalf("label = %q; an automatic report overwrote a deliberate name", got)
	}
	if !accts[0].LabelLocked {
		t.Error("the name should be marked as deliberate")
	}
}

// Control: an UNNAMED account must still accept automatic naming, or the lock
// would be indistinguishable from never updating anything.
func TestUpsertAccount_UnlockedStillTakesAutomaticNames(t *testing.T) {
	s := newStore(t)
	blank := ident("acct-x")
	blank.Email = ""
	if err := s.UpsertAccount(blank, "max", ""); err != nil {
		t.Fatal(err)
	}
	named := ident("acct-x")
	named.Email = "discovered@example.com"
	if err := s.UpsertAccount(named, "max", ""); err != nil {
		t.Fatal(err)
	}

	accts, _ := s.ListAccounts()
	if accts[0].Label() != "discovered@example.com" {
		t.Fatalf("label = %q; an unnamed account should accept what the login reports", accts[0].Label())
	}
}

func TestSetAccountLabel_ClearUnlocks(t *testing.T) {
	s := newStore(t)
	if err := s.UpsertAccount(ident("win_abc"), "max", ""); err != nil {
		t.Fatal(err)
	}
	if err := s.SetAccountLabel("win_abc", "chosen"); err != nil {
		t.Fatal(err)
	}
	if err := s.SetAccountLabel("win_abc", ""); err != nil {
		t.Fatal(err)
	}

	auto := ident("win_abc")
	auto.Email = "auto@example.com"
	if err := s.UpsertAccount(auto, "max", ""); err != nil {
		t.Fatal(err)
	}
	accts, _ := s.ListAccounts()
	if accts[0].Label() != "auto@example.com" {
		t.Fatalf("label = %q; clearing should let automatic naming resume", accts[0].Label())
	}
}

func TestSetAccountLabel_UnknownAccountIsAnError(t *testing.T) {
	s := newStore(t)
	if err := s.SetAccountLabel("nope", "x"); err == nil {
		t.Fatal("naming a subscription this hub has never seen should fail loudly")
	}
}

// Every surface resolves the name the same way, or one page shows one account
// under two names.
func TestAccount_LabelPrecedence(t *testing.T) {
	cases := []struct {
		a    Account
		want string
	}{
		{Account{AccountUUID: "u", Email: "e@x", DisplayName: "d"}, "e@x"},
		{Account{AccountUUID: "u", DisplayName: "d"}, "d"},
		{Account{AccountUUID: "u"}, "u"},
	}
	for _, c := range cases {
		if got := c.a.Label(); got != c.want {
			t.Errorf("Label() = %q, want %q", got, c.want)
		}
	}
	if !(Account{AccountUUID: "win_x"}).Inferred() {
		t.Error("a fingerprinted account must report as inferred")
	}
	if (Account{AccountUUID: "uuid"}).Inferred() {
		t.Error("a login-identified account must not report as inferred")
	}
}
