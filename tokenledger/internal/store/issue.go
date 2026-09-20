package store

import (
	"database/sql"
	"fmt"
	"strconv"
	"strings"
)

// The spend side's issue number: where it comes from, and what it refuses to
// guess. Design: docs/superpowers/specs/2026-09-19-cost-per-issue-seam-design.md
//
// A branch name is the only issue signal the hub already holds -- it arrives on
// every event from both sources (internal/scan/parse.go:27,
// internal/scan/codex.go:75) and the hub never reads git itself. So the number
// is read from the branch, by one anchored rule, or not at all.
//
// It is stored WITHOUT a repository, deliberately, and that is the mirror image
// of repo_issues carrying no account_uuid (schema.sql:361-367): a repository is
// not owned by a subscription, and a cwd is not a repository. `owner/name`
// appears nowhere on the spend side, so any read that binds these numbers to
// repo_issues has to be scoped to one repo by its caller -- see §5 of the
// design for the refusal that goes with it.

// issueRuleVersion stamps rollup_meta with the rule that produced the stored
// numbers. Bump it when IssueFromBranch changes: Open then re-derives every
// row in place, from git_branch alone.
//
// Deliberately NOT folded into rollupVersion. That constant rebuilds
// usage_hourly from usage_events, which refuses outright once retention has
// pruned the raw rows behind the oldest hours (unreconstructableRowsError) --
// so a tweak to a branch-parsing rule would become an operator incident. The
// number is a pure function of a column that stays on the row, so re-deriving
// it needs no raw events at all.
const issueRuleVersion = "1"

const issueRuleVersionKey = "issue_rule_version"

// IssueFromBranch reads the issue number out of a git branch name.
//
// The rule is `issue-<N>` or `issue-<N>-<anything>`, anchored on the whole
// name, and nothing else. Everything it declines is honestly unattributed:
// measured over 420,237 real events, this reads 36.5% of them and leaves 63.5%
// unattributed, of which 38.2% carry no number anywhere in the branch and 7.1%
// are a detached `HEAD`.
//
// The anchor is the whole point, and it is why "the first integer anywhere in
// the name" is not the rule. That looser version claims 25.4% more events, and
// its largest family is `scratch-<N>` (15.6% of all events) -- fleet scratch
// sessions, where N is a session ordinal that lands squarely inside the same
// repository's real issue-number space. `scratch-104` would resolve to a real
// issue #104, in the right repository, describing the wrong work, and nothing
// downstream could tell that row from a correct one. Even the respectable
// `<type>/<N>-<slug>` shape hides `release/2026-09-02-aicall-box`, which a
// loose rule files under issue #2026.
//
// A second reading is not a small error here: a wrong attribution is
// indistinguishable from a right one after the fact, while an unattributed row
// says so out loud.
func IssueFromBranch(branch string) (int64, bool) {
	rest, ok := strings.CutPrefix(branch, "issue-")
	if !ok {
		return 0, false
	}
	if i := strings.IndexByte(rest, '-'); i >= 0 {
		rest = rest[:i]
	}
	// No normalisation: a leading zero, a sign, spaces or an overflowing
	// number are all somebody else's convention, not this one.
	if rest == "" || rest != strings.TrimLeft(rest, "0") {
		return 0, false
	}
	n, err := strconv.ParseInt(rest, 10, 64)
	if err != nil || n <= 0 {
		return 0, false
	}
	return n, true
}

// issueNumber is IssueFromBranch as a bind value: the number, or nil so the
// column lands as SQL NULL.
//
// NULL, never 0 -- the same distinction cost_usd already makes three lines
// above it in the same table (schema.sql:164-166). Zero is a value and
// survives being summed by accident; the absence of a reading does not.
func issueNumber(branch string) any {
	if n, ok := IssueFromBranch(branch); ok {
		return n
	}
	return nil
}

// deriveIssueNumbers recomputes issue_number in place on both tables.
//
// This is how a rule change reaches rows written under the old rule. Both
// tables keep git_branch, so it needs nothing retention may have deleted.
//
// It goes through a temporary branch -> number map rather than one
// `UPDATE ... WHERE git_branch = ?` per branch, and the difference is not
// cosmetic: git_branch carries no index, so the per-branch form is a full
// table scan EACH time, and the live corpus this was measured on holds 2,415
// distinct branches. That is 2,415 scans of the largest table in the database,
// inside Open, on a hub nobody is watching. The map form is one scan plus a
// primary-key lookup per row: 228ms for 60,000 events and 12,000 hourly rows
// over 2,400 branches, once, on the upgrade that adds the column.
func deriveIssueNumbers(tx *sql.Tx) error {
	if _, err := tx.Exec(`
		CREATE TEMP TABLE IF NOT EXISTS issue_branch_map (
		  git_branch   TEXT PRIMARY KEY,
		  issue_number INTEGER
		);
		DELETE FROM issue_branch_map`); err != nil {
		return fmt.Errorf("prepare branch map: %w", err)
	}
	defer tx.Exec(`DROP TABLE IF EXISTS issue_branch_map`)

	for _, table := range []string{"usage_events", "usage_hourly"} {
		branches, err := distinctBranches(tx, table)
		if err != nil {
			return err
		}
		for _, b := range branches {
			if _, err := tx.Exec(
				`INSERT INTO issue_branch_map(git_branch, issue_number) VALUES(?,?)
				 ON CONFLICT(git_branch) DO NOTHING`, b, issueNumber(b)); err != nil {
				return fmt.Errorf("map branch %q: %w", b, err)
			}
		}
	}
	for _, table := range []string{"usage_events", "usage_hourly"} {
		// Writes NULL back for a branch the rule no longer reads, which is what
		// makes this a re-derivation rather than a fill.
		if _, err := tx.Exec(fmt.Sprintf(`
			UPDATE %[1]s SET issue_number =
			  (SELECT m.issue_number FROM issue_branch_map m WHERE m.git_branch = %[1]s.git_branch)`,
			table)); err != nil {
			return fmt.Errorf("derive issue numbers on %s: %w", table, err)
		}
	}
	return nil
}

func distinctBranches(tx *sql.Tx, table string) ([]string, error) {
	rows, err := tx.Query(fmt.Sprintf(`SELECT DISTINCT git_branch FROM %s`, table))
	if err != nil {
		return nil, fmt.Errorf("scan branches of %s: %w", table, err)
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var b string
		if err := rows.Scan(&b); err != nil {
			return nil, err
		}
		out = append(out, b)
	}
	return out, rows.Err()
}

// ensureIssueNumbers re-derives the column when the stored rule version is not
// the current one -- a fresh database, a hub upgraded past the ALTER that added
// the column, or a changed rule. A matching version is the common case and
// costs one row read.
func ensureIssueNumbers(db *sql.DB) error {
	var have string
	err := db.QueryRow(`SELECT value FROM rollup_meta WHERE key = ?`, issueRuleVersionKey).Scan(&have)
	if err != nil && err != sql.ErrNoRows {
		return fmt.Errorf("read %s: %w", issueRuleVersionKey, err)
	}
	if have == issueRuleVersion {
		return nil
	}
	tx, err := db.Begin()
	if err != nil {
		return fmt.Errorf("begin: %w", err)
	}
	defer tx.Rollback()
	if err := deriveIssueNumbers(tx); err != nil {
		return err
	}
	if err := stampIssueRuleVersion(tx); err != nil {
		return err
	}
	return tx.Commit()
}

func stampIssueRuleVersion(tx *sql.Tx) error {
	_, err := tx.Exec(
		`INSERT INTO rollup_meta(key, value) VALUES(?, ?)
		 ON CONFLICT(key) DO UPDATE SET value = excluded.value`,
		issueRuleVersionKey, issueRuleVersion)
	if err != nil {
		return fmt.Errorf("stamp %s: %w", issueRuleVersionKey, err)
	}
	return nil
}
