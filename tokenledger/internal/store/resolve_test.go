package store

import (
	"testing"
	"time"

	"github.com/verkyyi/ccquota/internal/model"
	"github.com/verkyyi/ccquota/internal/sessions"
)

func seedSchedule(t *testing.T, s *Store, account string, sevenDay time.Time) {
	t.Helper()
	if err := s.UpsertAccount(ident(account), "max", ""); err != nil {
		t.Fatal(err)
	}
	five := sevenDay.Add(-3 * time.Hour)
	snap := &model.LimitsSnapshot{
		AccountUUID: account,
		ObservedAt:  time.Now().UTC(),
		FiveHour:    model.Window{Utilization: 10, ResetsAt: &five},
		SevenDay:    model.Window{Utilization: 20, ResetsAt: &sevenDay},
	}
	if err := s.InsertLimits(snap); err != nil {
		t.Fatal(err)
	}
}

// The phantom: a fingerprint standing next to the real account it describes.
// Both are the same subscription, and each held a slice of the usage.
func TestResolveFingerprint_MapsOntoTheRealAccount(t *testing.T) {
	s := newStore(t)
	seven := time.Date(2026, 9, 4, 14, 0, 0, 0, time.UTC)
	seedSchedule(t, s, "e58c27f3-real", seven)

	key := sessions.FingerprintFor(&seven)
	got, err := s.ResolveFingerprint(key)
	if err != nil {
		t.Fatal(err)
	}
	if got != "e58c27f3-real" {
		t.Fatalf("resolved to %q, want the real account — a fingerprint of a known "+
			"schedule is that account, not a new one", got)
	}
}

// Control: an unmatched fingerprint stays itself. Resolving everything onto the
// nearest account would be worse than the bug — it would merge subscriptions
// this hub has never seen logged in, which is the case fingerprinting exists for.
func TestResolveFingerprint_LeavesAnUnknownScheduleAlone(t *testing.T) {
	s := newStore(t)
	seedSchedule(t, s, "e58c27f3-real", time.Date(2026, 9, 4, 14, 0, 0, 0, time.UTC))

	stranger := time.Date(2026, 9, 7, 5, 0, 0, 0, time.UTC)
	key := sessions.FingerprintFor(&stranger)
	got, err := s.ResolveFingerprint(key)
	if err != nil {
		t.Fatal(err)
	}
	if got != key {
		t.Fatalf("resolved an unknown subscription onto %q", got)
	}
}

// A real uuid is never rewritten, whatever the schedules say.
func TestResolveFingerprint_NeverRewritesARealAccount(t *testing.T) {
	s := newStore(t)
	seven := time.Date(2026, 9, 4, 14, 0, 0, 0, time.UTC)
	seedSchedule(t, s, "acct-a", seven)
	seedSchedule(t, s, "acct-b", seven) // same schedule, still two accounts

	got, err := s.ResolveFingerprint("acct-b")
	if err != nil {
		t.Fatal(err)
	}
	if got != "acct-b" {
		t.Fatalf("a reported account uuid was rewritten to %q", got)
	}
}

func TestDuplicateAccountsBySchedule_RealAccountWins(t *testing.T) {
	s := newStore(t)
	seven := time.Date(2026, 9, 4, 14, 0, 0, 0, time.UTC)
	key := sessions.FingerprintFor(&seven)
	seedSchedule(t, s, "e58c27f3-real", seven)
	seedSchedule(t, s, key, seven)

	dupes, _, err := s.DuplicateAccountsBySchedule()
	if err != nil {
		t.Fatal(err)
	}
	if dupes[key] != "e58c27f3-real" {
		t.Fatalf("dupes = %v; the fingerprint should fold into the real account", dupes)
	}
	if _, wrong := dupes["e58c27f3-real"]; wrong {
		t.Error("the real account was scheduled for merging into a guess")
	}
}

// Merging must move the usage, not drop it — the whole reason to repair rather
// than just delete the phantom.
func TestMergeAccount_MovesEventsAndRemovesTheSource(t *testing.T) {
	s := newStore(t)
	seven := time.Date(2026, 9, 4, 14, 0, 0, 0, time.UTC)
	key := sessions.FingerprintFor(&seven)
	seedSchedule(t, s, "real", seven)
	seedSchedule(t, s, key, seven)
	if err := s.Enroll("ep-1", "laptop", "h"); err != nil {
		t.Fatal(err)
	}

	now := time.Now().UTC()
	evs := []model.UsageEvent{
		{AccountUUID: key, EndpointID: "ep-1", MessageUUID: "m1", TS: now, OutputTokens: 10},
		{AccountUUID: key, EndpointID: "ep-1", MessageUUID: "m2", TS: now, OutputTokens: 20},
		{AccountUUID: "real", EndpointID: "ep-1", MessageUUID: "m3", TS: now, OutputTokens: 30},
	}
	if _, _, err := s.InsertEvents(evs); err != nil {
		t.Fatal(err)
	}

	moved, _, err := s.MergeAccount(key, "real")
	if err != nil {
		t.Fatal(err)
	}
	if moved != 2 {
		t.Fatalf("moved %d events, want 2", moved)
	}

	accts, err := s.ListAccounts()
	if err != nil {
		t.Fatal(err)
	}
	if len(accts) != 1 || accts[0].AccountUUID != "real" {
		t.Fatalf("accounts = %+v, want only the real one", accts)
	}

	b, err := s.UsageBy("real", ByAccount, now.Add(-time.Hour), now.Add(time.Hour), 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(b) != 1 || b[0].Events != 3 {
		t.Fatalf("merged account has %+v, want all 3 turns", b)
	}
}

// A turn already present under the destination must not resurrect as an orphan
// pointing at an account that no longer exists.
func TestMergeAccount_DropsDuplicateTurnsRatherThanOrphaningThem(t *testing.T) {
	s := newStore(t)
	seven := time.Date(2026, 9, 4, 14, 0, 0, 0, time.UTC)
	key := sessions.FingerprintFor(&seven)
	seedSchedule(t, s, "real", seven)
	seedSchedule(t, s, key, seven)
	if err := s.Enroll("ep-1", "laptop", "h"); err != nil {
		t.Fatal(err)
	}

	now := time.Now().UTC()
	if _, _, err := s.InsertEvents([]model.UsageEvent{
		{AccountUUID: key, EndpointID: "ep-1", MessageUUID: "same", TS: now, OutputTokens: 10},
		{AccountUUID: "real", EndpointID: "ep-1", MessageUUID: "same", TS: now, OutputTokens: 10},
	}); err != nil {
		t.Fatal(err)
	}

	if _, _, err := s.MergeAccount(key, "real"); err != nil {
		t.Fatal(err)
	}
	var orphans int
	if err := s.db.QueryRow(`SELECT COUNT(*) FROM usage_events WHERE account_uuid = ?`, key).
		Scan(&orphans); err != nil {
		t.Fatal(err)
	}
	if orphans != 0 {
		t.Fatalf("%d events still point at the merged-away account", orphans)
	}
}

// A subscription that has never been seen logged in exists only as a
// fingerprint. If resolution matched real uuids only, it could never recognise
// itself, and every change to the fingerprint's definition — or a stale batch
// still spooled on an endpoint — would mint a fresh identity beside it. That is
// exactly what happened to the georgetown subscription here.
func TestResolveFingerprint_FoldsOntoAnotherFingerprintWithTheSameSchedule(t *testing.T) {
	s := newStore(t)
	seven := time.Date(2026, 9, 7, 5, 0, 0, 0, time.UTC)

	// The account as it already exists: a fingerprint from an older definition.
	seedSchedule(t, s, "win_oldstylekey00", seven)

	// What the current definition computes for the very same schedule.
	current := sessions.FingerprintFor(&seven)
	if current == "win_oldstylekey00" {
		t.Skip("fingerprint definition happens to match the fixture")
	}
	got, err := s.ResolveFingerprint(current)
	if err != nil {
		t.Fatal(err)
	}
	if got != "win_oldstylekey00" {
		t.Fatalf("resolved to %q; a second fingerprint for one schedule is the same "+
			"subscription, not a new one", got)
	}
}

// ...and a fingerprint must never resolve onto itself, which would be a no-op
// dressed up as a match and could hide a real failure to converge.
func TestResolveFingerprint_DoesNotMatchItself(t *testing.T) {
	s := newStore(t)
	seven := time.Date(2026, 9, 7, 5, 0, 0, 0, time.UTC)
	key := sessions.FingerprintFor(&seven)
	seedSchedule(t, s, key, seven)

	got, err := s.ResolveFingerprint(key)
	if err != nil {
		t.Fatal(err)
	}
	if got != key {
		t.Fatalf("resolved onto %q instead of staying itself", got)
	}
}

// An account with no limits reading has not been shown to be distinct — nothing
// about it was examined. Reporting "no duplicates" while silently skipping one
// is how a duplicate hides, and it happened: a freshly logged-in account was
// checked before its first limits poll landed, and dedupe declared every
// account distinct.
func TestDuplicateAccountsBySchedule_ReportsWhatItCouldNotCheck(t *testing.T) {
	s := newStore(t)
	seven := time.Date(2026, 9, 7, 5, 0, 0, 0, time.UTC)
	seedSchedule(t, s, "has-snapshot", seven)

	// Logged in, reported, but no limits poll has landed yet.
	if err := s.UpsertAccount(ident("no-snapshot-yet"), "max", ""); err != nil {
		t.Fatal(err)
	}

	dupes, skipped, err := s.DuplicateAccountsBySchedule()
	if err != nil {
		t.Fatal(err)
	}
	if len(dupes) != 0 {
		t.Fatalf("dupes = %v, want none among the checkable accounts", dupes)
	}
	if len(skipped) != 1 || skipped[0] != "no-snapshot-yet" {
		t.Fatalf("skipped = %v; an unexamined account must be reported, not "+
			"counted as distinct", skipped)
	}
}

// The case this exists for: a pool of usage whose raw events retention has
// already deleted. usage_hourly is then the ONLY record of that history, so a
// merge that moves only usage_events moves nothing at all — and deletes the
// account row the orphaned hour-rows still point at.
func TestMergeAccount_MovesRollupRowsWhoseRawEventsWerePruned(t *testing.T) {
	s := newStore(t)
	if err := s.UpsertAccount(ident("pool"), "", ""); err != nil {
		t.Fatal(err)
	}
	if err := s.UpsertAccount(ident("real"), "max", ""); err != nil {
		t.Fatal(err)
	}
	if err := s.Enroll("ep-1", "laptop", "h"); err != nil {
		t.Fatal(err)
	}
	old := time.Date(2026, 2, 1, 9, 0, 0, 0, time.UTC)
	e := ev("pool", "ep-1", "m1", 100)
	e.TS = old
	if _, _, err := s.InsertEvents([]model.UsageEvent{e}); err != nil {
		t.Fatal(err)
	}
	// Retention pruning: raw gone, rollup kept.
	if _, err := s.PruneEvents(time.Date(2026, 6, 1, 0, 0, 0, 0, time.UTC)); err != nil {
		t.Fatal(err)
	}
	beforeTurns, beforeTokens, err := s.LifetimeTotals()
	if err != nil {
		t.Fatal(err)
	}

	moved, folded, err := s.MergeAccount("pool", "real")
	if err != nil {
		t.Fatal(err)
	}
	if moved != 0 || folded != 1 {
		t.Fatalf("moved=%d folded=%d, want 0 raw turns and 1 rollup turn", moved, folded)
	}

	var orphans int
	if err := s.db.QueryRow(`SELECT COUNT(*) FROM usage_hourly WHERE account_uuid = ?`, "pool").
		Scan(&orphans); err != nil {
		t.Fatal(err)
	}
	if orphans != 0 {
		t.Fatalf("%d hour-row(s) still point at the merged-away account", orphans)
	}
	afterTurns, afterTokens, err := s.LifetimeTotals()
	if err != nil {
		t.Fatal(err)
	}
	if afterTurns != beforeTurns || afterTokens != beforeTokens {
		t.Fatalf("lifetime totals changed across a merge: %d/%d -> %d/%d",
			beforeTurns, beforeTokens, afterTurns, afterTokens)
	}
	var tokens int64
	if err := s.db.QueryRow(`SELECT COALESCE(SUM(output_tokens),0) FROM usage_hourly WHERE account_uuid = ?`, "real").
		Scan(&tokens); err != nil {
		t.Fatal(err)
	}
	if tokens != 100 {
		t.Fatalf("destination holds %d output tokens, want the pool's 100", tokens)
	}
}

// Both accounts already have a row for the same hour and the same shape. The
// rollup's key includes the account, so the two rows are distinct until the
// merge — and folding them must ADD, not pick one. UPDATE OR IGNORE would
// keep the destination's row and silently drop the source's tokens.
func TestMergeAccount_FoldsCollidingHourRowsInsteadOfDroppingThem(t *testing.T) {
	s := newStore(t)
	if err := s.UpsertAccount(ident("pool"), "", ""); err != nil {
		t.Fatal(err)
	}
	if err := s.UpsertAccount(ident("real"), "max", ""); err != nil {
		t.Fatal(err)
	}
	if err := s.Enroll("ep-1", "laptop", "h"); err != nil {
		t.Fatal(err)
	}
	a, b := ev("pool", "ep-1", "m1", 10), ev("real", "ep-1", "m2", 30)
	if _, _, err := s.InsertEvents([]model.UsageEvent{a, b}); err != nil {
		t.Fatal(err)
	}
	if _, _, err := s.MergeAccount("pool", "real"); err != nil {
		t.Fatal(err)
	}
	var rows, events, tokens int64
	if err := s.db.QueryRow(
		`SELECT COUNT(*), COALESCE(SUM(events),0), COALESCE(SUM(output_tokens),0)
		   FROM usage_hourly WHERE account_uuid = ?`, "real").Scan(&rows, &events, &tokens); err != nil {
		t.Fatal(err)
	}
	if rows != 1 || events != 2 || tokens != 40 {
		t.Fatalf("rollup after merge: %d row(s), %d turn(s), %d tokens; want 1/2/40", rows, events, tokens)
	}
}

// Everything else keyed by the account moves too. A quota reading or a
// collector row left behind points at an account that no longer exists, and
// the source's own history of "who was logged in here" disappears from the
// destination it now belongs to.
func TestMergeAccount_MovesTheOtherAccountKeyedTables(t *testing.T) {
	s := newStore(t)
	if err := s.UpsertAccount(ident("pool"), "", ""); err != nil {
		t.Fatal(err)
	}
	if err := s.UpsertAccount(ident("real"), "max", ""); err != nil {
		t.Fatal(err)
	}
	if err := s.Enroll("ep-1", "laptop", "h"); err != nil {
		t.Fatal(err)
	}
	exec := func(q string, args ...any) {
		t.Helper()
		if _, err := s.db.Exec(q, args...); err != nil {
			t.Fatal(err)
		}
	}
	exec(`INSERT INTO quota_snapshots(account_uuid,source,profile_id,endpoint_id,observed_at,observation,data_json)
	      VALUES('pool','codex','p','ep-1','2026-02-01T09:00:00Z','o','{}')`)
	exec(`INSERT INTO account_usage_observations(account_uuid,source,endpoint_id,observed_at,data_json)
	      VALUES('pool','codex','ep-1','2026-02-01T09:00:00Z','{}')`)
	exec(`INSERT INTO source_collectors(endpoint_id,source,profile_id,account_uuid,observed_at,data_json)
	      VALUES('ep-1','codex','p','pool','2026-02-01T09:00:00Z','{}')`)
	exec(`INSERT INTO account_switches(endpoint_id,from_account,to_account,observed_at)
	      VALUES('ep-1','pool','other','2026-02-01T09:00:00Z')`)
	exec(`INSERT INTO source_account_switches(endpoint_id,source,profile_id,from_account,to_account,observed_at)
	      VALUES('ep-1','codex','p','other','pool','2026-02-01T09:00:00Z')`)
	// A switch between the two accounts being merged is not a switch at all
	// once they are one account.
	exec(`INSERT INTO account_switches(endpoint_id,from_account,to_account,observed_at)
	      VALUES('ep-1','pool','real','2026-02-02T09:00:00Z')`)

	if _, _, err := s.MergeAccount("pool", "real"); err != nil {
		t.Fatal(err)
	}
	for _, q := range []string{
		`SELECT COUNT(*) FROM quota_snapshots WHERE account_uuid='pool'`,
		`SELECT COUNT(*) FROM account_usage_observations WHERE account_uuid='pool'`,
		`SELECT COUNT(*) FROM source_collectors WHERE account_uuid='pool'`,
		`SELECT COUNT(*) FROM account_switches WHERE from_account='pool' OR to_account='pool'`,
		`SELECT COUNT(*) FROM source_account_switches WHERE from_account='pool' OR to_account='pool'`,
		`SELECT COUNT(*) FROM account_switches WHERE from_account = to_account`,
	} {
		var n int
		if err := s.db.QueryRow(q).Scan(&n); err != nil {
			t.Fatal(err)
		}
		if n != 0 {
			t.Errorf("%d row(s) left by: %s", n, q)
		}
	}
}

// The destination is typed by hand. A typo would move the usage under a name
// nothing reports on, and the source account row is deleted in the same
// transaction, so there would be nothing left to name it back from.
func TestMergeAccount_RefusesAnUnknownDestination(t *testing.T) {
	s := newStore(t)
	if err := s.UpsertAccount(ident("pool"), "", ""); err != nil {
		t.Fatal(err)
	}
	if _, _, err := s.MergeAccount("pool", "typo"); err == nil {
		t.Fatal("merged into an account this hub has never seen")
	}
	accts, err := s.ListAccounts()
	if err != nil {
		t.Fatal(err)
	}
	if len(accts) != 1 {
		t.Fatalf("accounts = %+v, want the source still there", accts)
	}
}

// The pool comes back without this: every Codex session recorded before its
// profile was logged in is unclaimable forever, so the next scan re-creates
// codex:local and the merge has to be re-run by hand.
func TestResolvePool_BoundPoolLandsOnTheRealAccount(t *testing.T) {
	s := newStore(t)
	if err := s.UpsertAccount(ident("codex:real"), "", ""); err != nil {
		t.Fatal(err)
	}

	// Unbound: the pool stays the pool. A hub that never said which
	// subscription pays must not have one guessed for it.
	got, err := s.ResolvePool("codex", "codex:local")
	if err != nil {
		t.Fatal(err)
	}
	if got != "codex:local" {
		t.Fatalf("unbound pool resolved to %q, want it untouched", got)
	}

	if err := s.BindSourcePool("codex", "codex:real"); err != nil {
		t.Fatal(err)
	}
	got, err = s.ResolvePool("codex", "codex:local")
	if err != nil {
		t.Fatal(err)
	}
	if got != "codex:real" {
		t.Fatalf("bound pool resolved to %q, want codex:real", got)
	}

	// Only the pool is rewritten: a real account, and another source's pool,
	// pass through untouched.
	for _, c := range []struct{ source, account string }{
		{"codex", "codex:account:abc"},
		{"claude", "claude:local"},
		{"claude", "e58c27f3"},
	} {
		got, err := s.ResolvePool(c.source, c.account)
		if err != nil {
			t.Fatal(err)
		}
		if got != c.account {
			t.Errorf("ResolvePool(%q, %q) = %q, want it unchanged", c.source, c.account, got)
		}
	}
}

func TestBindSourcePool_RefusesAnUnknownAccount(t *testing.T) {
	s := newStore(t)
	if err := s.BindSourcePool("codex", "typo"); err == nil {
		t.Fatal("bound a source's usage to an account this hub has never seen")
	}
}
