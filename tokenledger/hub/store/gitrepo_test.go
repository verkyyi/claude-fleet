package store

import (
	"path/filepath"
	"testing"

	"github.com/verkyyi/claude-fleet/tokenledger/shared/model"
)

// repoOf reads the column back for one branch, on either table.
func repoOf(t *testing.T, s *Store, table, branch string) string {
	t.Helper()
	var repo string
	if err := s.read.QueryRow(
		`SELECT git_repo FROM `+table+` WHERE git_branch = ? LIMIT 1`, branch).Scan(&repo); err != nil {
		t.Fatalf("read %s.git_repo for %q: %v", table, branch, err)
	}
	return repo
}

func evIn(account, endpoint, uuid, branch, repo string) model.UsageEvent {
	e := ev(account, endpoint, uuid, 10)
	e.GitBranch = branch
	e.SessionID = branch // keep each branch in its own hourly row
	e.GitRepo = repo
	return e
}

// What the reporter declared lands on both tables, verbatim, and silence lands
// as ” rather than as anything that could be mistaken for a repository.
func TestInsertStoresTheDeclaredRepo(t *testing.T) {
	s := newStore(t)
	seedAccount(t, s, "acc", "ep")
	if _, _, err := s.InsertEvents([]model.UsageEvent{
		evIn("acc", "ep", "u1", "issue-57", "frank/tokenledger"),
		evIn("acc", "ep", "u2", "issue-99", "verkyyi/claude-fleet"),
		evIn("acc", "ep", "u3", "main", ""),
	}); err != nil {
		t.Fatal(err)
	}
	for _, table := range []string{"usage_events", "usage_hourly"} {
		if got := repoOf(t, s, table, "issue-57"); got != "frank/tokenledger" {
			t.Errorf("%s: issue-57 declared %q", table, got)
		}
		if got := repoOf(t, s, table, "issue-99"); got != "verkyyi/claude-fleet" {
			t.Errorf("%s: issue-99 declared %q", table, got)
		}
		if got := repoOf(t, s, table, "main"); got != "" {
			t.Errorf("%s: an undeclared turn stored %q; want ''", table, got)
		}
	}
}

// A value in this column has to be a key repo_issues could hold. Anything else
// joins with nothing while looking, to a reader, like a repository nobody
// shipped progress for — so it is stored as ” instead, which says so.
func TestDeclaredRepoKeepsOnlyJoinableNames(t *testing.T) {
	for _, tc := range []struct{ in, want string }{
		{"frank/tokenledger", "frank/tokenledger"},
		{"", ""},
		{"tokenledger", ""},
		{"group/sub/app", ""},
		{" frank/tokenledger", ""},
		{"frank/", ""},
		{"/tokenledger", ""},
	} {
		if got := declaredRepo(tc.in); got != tc.want {
			t.Errorf("declaredRepo(%q) = %q; want %q", tc.in, got, tc.want)
		}
	}
}

// The rule both upsert paths state: a declaration wins over silence, and
// silence never erases a declaration.
//
// git_repo is not in the hourly key, so an endpoint that upgrades mid-hour
// folds declaring and non-declaring events into the SAME row. Plain assignment
// would let arrival order decide, and half the time that is the older agent
// undoing the newer one.
func TestHourlyKeepsTheDeclarationAcrossAnUpgrade(t *testing.T) {
	s := newStore(t)
	seedAccount(t, s, "acc", "ep")

	// The old agent reports first, then the upgraded one, then the old one
	// again — a fleet mid-rollout, or a queued spool draining out of order.
	for i, repo := range []string{"", "frank/tokenledger", ""} {
		e := evIn("acc", "ep", "u"+string(rune('1'+i)), "issue-57", repo)
		if _, _, err := s.InsertEvents([]model.UsageEvent{e}); err != nil {
			t.Fatal(err)
		}
	}
	if got := repoOf(t, s, "usage_hourly", "issue-57"); got != "frank/tokenledger" {
		t.Fatalf("usage_hourly.git_repo = %q; a later '' erased the declaration", got)
	}
	// And the three turns are still one hourly row: the column adds no grain.
	var rows int
	if err := s.read.QueryRow(
		`SELECT COUNT(*) FROM usage_hourly WHERE git_branch = 'issue-57'`).Scan(&rows); err != nil {
		t.Fatal(err)
	}
	if rows != 1 {
		t.Errorf("issue-57 occupies %d hourly rows; want 1", rows)
	}
}

// A rebuild folds events back into hours, and must not lose the declaration or
// split a row over it. MAX() is what makes both true — grouping by git_repo
// would produce two rows that then collide on a key it is not part of.
func TestRebuildRollupKeepsTheDeclaration(t *testing.T) {
	s := newStore(t)
	seedAccount(t, s, "acc", "ep")
	if _, _, err := s.InsertEvents([]model.UsageEvent{
		evIn("acc", "ep", "u1", "issue-57", ""),
		evIn("acc", "ep", "u2", "issue-57", "frank/tokenledger"),
		evIn("acc", "ep", "u3", "main", ""),
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
	if before != after {
		t.Errorf("rebuild changed the rollup row count %d -> %d; git_repo added grain", before, after)
	}
	if got := repoOf(t, s, "usage_hourly", "issue-57"); got != "frank/tokenledger" {
		t.Errorf("rebuild lost the declaration: git_repo = %q", got)
	}
	if got := repoOf(t, s, "usage_hourly", "main"); got != "" {
		t.Errorf("rebuild invented a declaration for main: %q", got)
	}
}

// A hub upgrading from before the column keeps every row it had, with ” on
// them — which is the truth: nobody ever told it. Unlike issue_number there is
// nothing to fill them in with afterwards, and the read discloses that rather
// than guessing.
func TestOpenUpgradesDatabaseWithoutTheRepoColumn(t *testing.T) {
	path := filepath.Join(t.TempDir(), "old.db")
	s, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	seedAccount(t, s, "acc", "ep")
	if _, _, err := s.InsertEvents([]model.UsageEvent{
		evIn("acc", "ep", "u1", "issue-57", "frank/tokenledger"),
	}); err != nil {
		t.Fatal(err)
	}
	for _, table := range []string{"usage_events", "usage_hourly"} {
		if _, err := s.write.Exec(`ALTER TABLE ` + table + ` DROP COLUMN git_repo`); err != nil {
			t.Fatal(err)
		}
	}
	if err := s.Close(); err != nil {
		t.Fatal(err)
	}

	up, err := Open(path)
	if err != nil {
		t.Fatalf("reopening a database without git_repo: %v", err)
	}
	t.Cleanup(func() { up.Close() })
	for _, table := range []string{"usage_events", "usage_hourly"} {
		if got := repoOf(t, up, table, "issue-57"); got != "" {
			t.Errorf("%s: upgrade invented %q for a row written before the column", table, got)
		}
	}
}
