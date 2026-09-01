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

	moved, err := s.MergeAccount(key, "real")
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

	if _, err := s.MergeAccount(key, "real"); err != nil {
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
