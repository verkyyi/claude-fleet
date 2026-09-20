package store

import (
	"database/sql"
	"path/filepath"
	"testing"

	"github.com/verkyyi/ccquota/internal/model"
)

// The rule, and — more importantly — everything it refuses.
//
// The refusals are not hypothetical: every "false" case below except the
// synthetic ones was taken from the 2,415 distinct branch names measured
// across 420,237 real events while designing this
// (docs/superpowers/specs/2026-09-19-cost-per-issue-seam-design.md). Each of
// them would resolve to a REAL issue number under a looser rule, in the right
// repository, describing the wrong work.
func TestIssueFromBranch(t *testing.T) {
	cases := []struct {
		branch string
		want   int64
		ok     bool
	}{
		// What the rule reads: 36.5% of measured events.
		{"issue-57", 57, true},
		{"issue-4059", 4059, true},
		{"issue-4059-track-a", 4059, true},
		{"issue-1200-award-lock-free", 1200, true},

		// What it refuses, and why each one matters.
		{"scratch-94", 0, false},                    // 15.6% of events: a SESSION ordinal
		{"HEAD", 0, false},                          //  7.1%: a worktree at a detached SHA
		{"main", 0, false},                          // the largest family carries no number
		{"master", 0, false},                        //
		{"", 0, false},                              // no branch recorded at all
		{"release/2026-09-02-aicall-box", 0, false}, // a DATE, not issue #2026
		{"chore/2391-reseed-corpus", 0, false},      // real number, wrong shape
		{"fix/594-handoff-preserves-loop", 0, false},
		{"worktree-agent-a233c6fcd75937095", 0, false},
		{"release-ledger-2026-09-14-61bc376e", 0, false},

		// Anchoring and normalisation, stated once so nobody has to guess.
		{"issue-", 0, false},                    // the prefix alone says nothing
		{"issue-0", 0, false},                   // there is no issue #0
		{"issue-007", 0, false},                 // a padded number is another convention
		{"issue-12a", 0, false},                 // not a number
		{"issue--3", 0, false},                  // not a number
		{"my-issue-57", 0, false},               // unanchored: this is someone's slug
		{"ISSUE-57", 0, false},                  // no case folding
		{" issue-57", 0, false},                 // no trimming
		{"issue-9223372036854775808", 0, false}, // overflows int64
	}
	for _, c := range cases {
		got, ok := IssueFromBranch(c.branch)
		if ok != c.ok || got != c.want {
			t.Errorf("IssueFromBranch(%q) = %d, %v; want %d, %v", c.branch, got, ok, c.want, c.ok)
		}
	}
}

// issueOf reads the column back as it is actually stored: NULL stays NULL, so
// a test cannot mistake "not attributed" for issue 0.
func issueOf(t *testing.T, s *Store, table, branch string) (int64, bool) {
	t.Helper()
	var n sql.NullInt64
	err := s.read.QueryRow(
		`SELECT issue_number FROM `+table+` WHERE git_branch = ? LIMIT 1`, branch).Scan(&n)
	if err != nil {
		t.Fatalf("read %s.issue_number for %q: %v", table, branch, err)
	}
	return n.Int64, n.Valid
}

func evOnBranch(account, endpoint, uuid, branch string) model.UsageEvent {
	e := ev(account, endpoint, uuid, 10)
	e.GitBranch = branch
	e.SessionID = branch // keep each branch in its own hourly row
	return e
}

// Ingest stamps both tables, and an unattributable branch lands as NULL rather
// than 0 — the distinction cost_usd already makes in the same table.
func TestInsertStampsIssueNumber(t *testing.T) {
	s := newStore(t)
	seedAccount(t, s, "acc", "ep")
	if _, _, err := s.InsertEvents([]model.UsageEvent{
		evOnBranch("acc", "ep", "u1", "issue-57"),
		evOnBranch("acc", "ep", "u2", "issue-4059-track-a"),
		evOnBranch("acc", "ep", "u3", "scratch-94"),
		evOnBranch("acc", "ep", "u4", "HEAD"),
	}); err != nil {
		t.Fatal(err)
	}
	for _, table := range []string{"usage_events", "usage_hourly"} {
		if n, ok := issueOf(t, s, table, "issue-57"); !ok || n != 57 {
			t.Errorf("%s: issue-57 -> %d, %v; want 57, true", table, n, ok)
		}
		if n, ok := issueOf(t, s, table, "issue-4059-track-a"); !ok || n != 4059 {
			t.Errorf("%s: issue-4059-track-a -> %d, %v; want 4059, true", table, n, ok)
		}
		for _, branch := range []string{"scratch-94", "HEAD"} {
			if n, ok := issueOf(t, s, table, branch); ok {
				t.Errorf("%s: %q was attributed to %d; an unreadable branch must stay NULL", table, branch, n)
			}
		}
	}
}

// A database that predates the column — or was written under an older rule —
// acquires the numbers on the next Open, from git_branch alone. Nothing here
// reads usage_events' own history, which is what makes this safe on a hub that
// has already pruned.
func TestIssueNumbersRederivedOnOpen(t *testing.T) {
	s := newStore(t)
	seedAccount(t, s, "acc", "ep")
	if _, _, err := s.InsertEvents([]model.UsageEvent{
		evOnBranch("acc", "ep", "u1", "issue-57"),
		evOnBranch("acc", "ep", "u2", "scratch-94"),
	}); err != nil {
		t.Fatal(err)
	}
	// Exactly the state an upgraded hub is in right after the ALTER: the
	// column exists and holds nothing, and rollup_meta has never heard of it.
	for _, table := range []string{"usage_events", "usage_hourly"} {
		if _, err := s.write.Exec(`UPDATE ` + table + ` SET issue_number = NULL`); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := s.write.Exec(`DELETE FROM rollup_meta WHERE key = ?`, issueRuleVersionKey); err != nil {
		t.Fatal(err)
	}

	if err := ensureIssueNumbers(s.write); err != nil {
		t.Fatal(err)
	}
	for _, table := range []string{"usage_events", "usage_hourly"} {
		if n, ok := issueOf(t, s, table, "issue-57"); !ok || n != 57 {
			t.Errorf("%s: re-derivation left issue-57 at %d, %v; want 57, true", table, n, ok)
		}
		if _, ok := issueOf(t, s, table, "scratch-94"); ok {
			t.Errorf("%s: re-derivation attributed scratch-94", table)
		}
	}
	var v string
	if err := s.read.QueryRow(`SELECT value FROM rollup_meta WHERE key = ?`, issueRuleVersionKey).Scan(&v); err != nil {
		t.Fatal(err)
	}
	if v != issueRuleVersion {
		t.Errorf("stored rule version %q, want %q", v, issueRuleVersion)
	}
}

// The actual upgrade: a database whose tables do not have the column at all,
// which is every hub running today. migrate() adds it and Open fills it, in
// one startup, without an operator doing anything.
func TestOpenUpgradesDatabaseWithoutTheColumn(t *testing.T) {
	path := filepath.Join(t.TempDir(), "old.db")
	s, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	seedAccount(t, s, "acc", "ep")
	if _, _, err := s.InsertEvents([]model.UsageEvent{
		evOnBranch("acc", "ep", "u1", "issue-57"),
		evOnBranch("acc", "ep", "u2", "scratch-94"),
	}); err != nil {
		t.Fatal(err)
	}
	// Roll the schema back to what a pre-#57 hub has on disk.
	for _, table := range []string{"usage_events", "usage_hourly"} {
		if _, err := s.write.Exec(`ALTER TABLE ` + table + ` DROP COLUMN issue_number`); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := s.write.Exec(`DELETE FROM rollup_meta WHERE key = ?`, issueRuleVersionKey); err != nil {
		t.Fatal(err)
	}
	if err := s.Close(); err != nil {
		t.Fatal(err)
	}

	up, err := Open(path)
	if err != nil {
		t.Fatalf("reopening a database without issue_number: %v", err)
	}
	t.Cleanup(func() { up.Close() })
	for _, table := range []string{"usage_events", "usage_hourly"} {
		if n, ok := issueOf(t, up, table, "issue-57"); !ok || n != 57 {
			t.Errorf("%s: upgrade left issue-57 at %d, %v; want 57, true", table, n, ok)
		}
		if _, ok := issueOf(t, up, table, "scratch-94"); ok {
			t.Errorf("%s: upgrade attributed scratch-94", table)
		}
	}
}

// A rollup rebuild carries the number through instead of dropping it: the
// hourly table is the one kept forever, so losing the attribution there would
// lose it for good once retention prunes the raw events.
func TestRebuildRollupKeepsIssueNumber(t *testing.T) {
	s := newStore(t)
	seedAccount(t, s, "acc", "ep")
	if _, _, err := s.InsertEvents([]model.UsageEvent{
		evOnBranch("acc", "ep", "u1", "issue-57"),
		evOnBranch("acc", "ep", "u2", "main"),
	}); err != nil {
		t.Fatal(err)
	}
	before, err := s.RollupRows()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.RebuildRollup(true); err != nil {
		t.Fatal(err)
	}
	after, err := s.RollupRows()
	if err != nil {
		t.Fatal(err)
	}
	// issue_number is a pure function of git_branch, so grouping by it must
	// not split a single hourly row into two.
	if before != after {
		t.Errorf("rebuild changed the rollup row count %d -> %d; issue_number added grain", before, after)
	}
	if n, ok := issueOf(t, s, "usage_hourly", "issue-57"); !ok || n != 57 {
		t.Errorf("rebuild lost the attribution: issue-57 -> %d, %v", n, ok)
	}
	if _, ok := issueOf(t, s, "usage_hourly", "main"); ok {
		t.Error("rebuild attributed branch main")
	}
}
