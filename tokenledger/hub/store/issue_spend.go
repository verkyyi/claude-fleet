// internal/store/issue_spend.go
package store

// The issue axis, read side. #57 stamped usage_hourly.issue_number from the
// branch name; this is the aggregate that puts money on that axis.
// Design: docs/superpowers/specs/2026-09-19-cost-per-issue-seam-design.md
//
// Two invariants live here and every caller inherits them.
//
//   - ATTRIBUTED + UNATTRIBUTED = TOTAL, and the unattributed bucket is a row
//     like any other rather than a filter. On the corpus the rule was measured
//     against it is 63.5% of events (§4 of the design): a chart that drops it
//     is not slightly optimistic, it is wrong by a factor of three in the
//     flattering direction. So SpendByIssue always returns it, even empty, and
//     always returns the totals a reader needs to check the sum.
//   - Cost never leaves this package as one number. Every figure below is a
//     CostBySource, the same as every other cost aggregate here, because the
//     three kinds of money this hub holds mean nothing added together.
//
// What is NOT here is any notion of a repository. A spend row names a number
// and nothing else (§5), so binding these numbers to repo_issues is the
// caller's job, and the refusal that has to go with it lives in the API layer
// where the hub's repo list is visible.

import (
	"fmt"
	"strings"
)

// SpendTotal is spend over some scope, with cost kept apart by source.
type SpendTotal struct {
	Events int64 `json:"events"`
	Tokens int64 `json:"tokens"`
	// Cost is per source and has no total, deliberately: see CostBySource.
	Cost     CostBySource `json:"cost"`
	Unpriced int64        `json:"unpriced_events"`
}

// add folds another scope's figures in. Tokens and events are additive; cost
// is folded per source, never across them.
func (t *SpendTotal) add(in SpendTotal) {
	t.Events += in.Events
	t.Tokens += in.Tokens
	t.Cost.Add(in.Cost)
	t.Unpriced = t.Cost.Unpriced()
}

// IssueSpend is one issue's share of the money.
type IssueSpend struct {
	// Number is the issue the branch named. It carries no repository, because
	// the branch did not: see the package comment.
	Number int64 `json:"number"`
	SpendTotal
}

// UnattributedBranch is one branch inside the unattributed bucket.
//
// This is what makes "63% unattributed" explicable rather than alarming: the
// branch stayed on the row, so the bucket breaks down into `HEAD`,
// `scratch-<N>`, `main` and feature slugs for free, and a reader can see that
// it is work whose branch never said what it was for -- not spend that went
// missing. §4 of the design is why there is no issue_source column instead.
type UnattributedBranch struct {
	Branch string `json:"branch"`
	Events int64  `json:"events"`
	Tokens int64  `json:"tokens"`
}

// UnattributedSpend is the bucket for rows whose branch named no issue.
type UnattributedSpend struct {
	SpendTotal
	// Branches is the largest contributors by tokens, so the bucket can be
	// explained rather than merely disclosed.
	Branches []UnattributedBranch `json:"branches"`
}

// IssueSpendPage is the whole issue axis over one window.
//
// Issues is truncated; Attributed is not. That pairing is the point: a reader
// handed only a top-N cannot tell a long tail from a short one, and the shape
// of the distribution ("do a few issues eat the lot, or is it spread flat")
// is the question this exists to answer.
type IssueSpendPage struct {
	// Issues is the top spenders, largest first, truncated to the limit.
	Issues []IssueSpend `json:"issues"`
	// Distinct is how many issues the window actually touched, before
	// truncation.
	Distinct int `json:"distinct_issues"`
	// Attributed is every attributed issue, including the ones Issues dropped.
	Attributed SpendTotal `json:"attributed"`
	// Unattributed is always present, even when empty.
	Unattributed UnattributedSpend `json:"unattributed"`
	// Total is Attributed + Unattributed, so a reader can check the sum
	// instead of trusting it.
	Total SpendTotal `json:"total"`
}

// maxUnattributedBranches caps the breakdown. Enough to name the families the
// design measured (HEAD, scratch-*, main, feature slugs) and not so many that
// the bucket becomes its own backlog.
const maxUnattributedBranches = 12

// defaultIssueSpendLimit is the top-N when the caller names none.
const defaultIssueSpendLimit = 50

// SpendByIssue aggregates the window's spend onto the issue axis.
//
// Ranking is by TOKENS, not by cost, and that is forced rather than chosen:
// cost comes back split by source because the kinds of money cannot be added,
// so there is no single cost figure to sort on. Tokens are one physical
// quantity and are additive across every source -- the same ordering
// UsageByFiltered already uses.
//
// Nothing is truncated in SQL. The number of distinct issues a window touches
// is bounded by the number of distinct `issue-<N>` branches worked in it
// (hundreds at the very most, against 2,415 distinct branches of every shape
// in the design's corpus), so the whole axis is folded in Go and truncated
// afterwards. Truncating in SQL would make Attributed a total of the visible
// rows only, which is exactly the flattering error the package comment
// forbids.
func (s *Store) SpendByIssue(f Filter, limit int) (*IssueSpendPage, error) {
	where, args, err := f.where("hour")
	if err != nil {
		return nil, err
	}
	if limit <= 0 {
		limit = defaultIssueSpendLimit
	}

	rows, err := s.read.Query(fmt.Sprintf(`
		SELECT issue_number, SUM(events), SUM%s, %s
		FROM usage_hourly %s
		GROUP BY issue_number
		ORDER BY 3 DESC, issue_number`,
		hourlyTokens, hourlyCostSplit.sel, where), args...)
	if err != nil {
		return nil, fmt.Errorf("spend by issue: %w", err)
	}
	defer rows.Close()

	page := &IssueSpendPage{Issues: []IssueSpend{}}
	page.Unattributed.Branches = []UnattributedBranch{}
	for rows.Next() {
		// NULL is the unattributed bucket. Scanning into a pointer rather than
		// a plain int64 is what keeps it distinct from issue 0 -- which the
		// rule can never produce (IssueFromBranch refuses n <= 0), but a
		// COALESCE here would invent.
		var number *int64
		var t SpendTotal
		cs := hourlyCostSplit.scan()
		if err := rows.Scan(append([]any{&number, &t.Events, &t.Tokens}, cs.dest()...)...); err != nil {
			return nil, err
		}
		t.Cost = cs.costs()
		t.Unpriced = t.Cost.Unpriced()
		if number == nil {
			page.Unattributed.SpendTotal = t
			continue
		}
		page.Attributed.add(t)
		page.Issues = append(page.Issues, IssueSpend{Number: *number, SpendTotal: t})
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}

	page.Distinct = len(page.Issues)
	if len(page.Issues) > limit {
		page.Issues = page.Issues[:limit]
	}
	page.Total.add(page.Attributed)
	page.Total.add(page.Unattributed.SpendTotal)

	// Only worth a second query when there is something in the bucket. An
	// empty breakdown under an empty bucket says nothing.
	if page.Unattributed.Events > 0 || page.Unattributed.Tokens > 0 {
		branches, err := s.unattributedBranches(where, args)
		if err != nil {
			return nil, err
		}
		page.Unattributed.Branches = branches
	}
	return page, nil
}

// unattributedBranches names the largest branches the rule declined to read.
func (s *Store) unattributedBranches(where string, args []any) ([]UnattributedBranch, error) {
	rows, err := s.read.Query(fmt.Sprintf(`
		SELECT git_branch, SUM(events), SUM%s
		FROM usage_hourly %s AND issue_number IS NULL
		GROUP BY git_branch ORDER BY 3 DESC, git_branch LIMIT ?`,
		hourlyTokens, where), append(append([]any{}, args...), maxUnattributedBranches)...)
	if err != nil {
		return nil, fmt.Errorf("unattributed branches: %w", err)
	}
	defer rows.Close()
	out := []UnattributedBranch{}
	for rows.Next() {
		var b UnattributedBranch
		if err := rows.Scan(&b.Branch, &b.Events, &b.Tokens); err != nil {
			return nil, err
		}
		out = append(out, b)
	}
	return out, rows.Err()
}

// IssueLifetimeSpend totals ALL spend ever attributed to each of numbers,
// with no time bound at all.
//
// "What did this issue cost from open to close" is deliberately not computed
// as the spend between created_at and closed_at. Attribution here runs through
// the branch, and a branch named `issue-<N>` is work on issue N whenever it
// happened -- including the turn that reopened it a week after it closed, and
// the ones before somebody remembered to file it. Windowing by the issue's own
// dates would silently drop both and present the remainder as the whole bill.
//
// usage_hourly is the table for this because it is kept forever while
// usage_events is bounded by --retention-days (§3): an issue outlives the raw
// ledger, so a lifetime figure read from events would shrink as history aged
// out.
//
// account scopes to one subscription, or store.AllAccounts to span every one.
// A repository is worked by endpoints on several plans at once, so spanning is
// the normal reading here, not the exception.
//
// repo scopes to the repository the endpoint declared, or "" to span every row
// -- which is only sound while the hub holds one repository, and is the caller's
// call to make (api.issueScope). A lifetime figure needs it more than a windowed
// one does, not less: it reaches back across ALL of history, so blending two
// repositories' issue #12 here would be a bigger error than doing it for a week.
func (s *Store) IssueLifetimeSpend(account, repo string, numbers []int64) (map[int64]SpendTotal, error) {
	out := map[int64]SpendTotal{}
	if len(numbers) == 0 {
		return out, nil
	}
	if account == "" {
		return nil, fmt.Errorf("account is required: pass a uuid, or store.AllAccounts to span every subscription")
	}

	var where []string
	var args []any
	if account != AllAccounts {
		where = append(where, "account_uuid = ?")
		args = append(args, account)
	}
	if repo != "" {
		where = append(where, "git_repo = ?")
		args = append(args, repo)
	}
	// The numbers are int64 read back from our own column, never caller
	// strings, but they still go in as bind parameters: an IN list built by
	// string concatenation is a habit that survives the day the input changes.
	where = append(where, "issue_number IN ("+strings.TrimSuffix(strings.Repeat("?,", len(numbers)), ",")+")")
	for _, n := range numbers {
		args = append(args, n)
	}

	rows, err := s.read.Query(fmt.Sprintf(`
		SELECT issue_number, SUM(events), SUM%s, %s
		FROM usage_hourly WHERE %s
		GROUP BY issue_number`,
		hourlyTokens, hourlyCostSplit.sel, strings.Join(where, " AND ")), args...)
	if err != nil {
		return nil, fmt.Errorf("issue lifetime spend: %w", err)
	}
	defer rows.Close()
	for rows.Next() {
		var number int64
		var t SpendTotal
		cs := hourlyCostSplit.scan()
		if err := rows.Scan(append([]any{&number, &t.Events, &t.Tokens}, cs.dest()...)...); err != nil {
			return nil, err
		}
		t.Cost = cs.costs()
		t.Unpriced = t.Cost.Unpriced()
		out[number] = t
	}
	return out, rows.Err()
}
