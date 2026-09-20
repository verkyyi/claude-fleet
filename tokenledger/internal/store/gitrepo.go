package store

import (
	"fmt"

	"github.com/verkyyi/ccquota/internal/model"
)

// The repository a spend row was earned in: stored, never derived.
//
// Design: docs/superpowers/specs/2026-09-19-cost-per-issue-seam-design.md §6.
// The resolver lives in internal/agent/gitrepo.go, on the endpoint, because
// that is the only side standing inside the checkout. Everything here is the
// hub keeping its half of the bargain -- it stores what it was told and infers
// nothing, which is the same stance that put issue_number's rule in one small
// pure function instead of a heuristic.
//
// Three states, and the third is the one that has to survive:
//
//	'owner/name'  this row is that repository's spend
//	''            NOT DECLARED -- an older agent, a cwd that is no checkout
//	              (and, forever, every row written before this column existed)
//
// "Not declared" is not "not that repository", and a read that folds the two
// together is wrong in the flattering direction either way it folds them.

// declaredRepo is a declaration as a bind value: the name, or ” when the
// reporter said nothing this side can join on.
//
// Checked against the SAME model.ValidRepoName that guards the repo ingest, on
// purpose. The endpoint already applies it, so this is not distrust of the
// agent so much as the property that matters stated where it is relied upon: a
// value in this column is a key `repo_issues` could hold. Anything else is a
// string that would silently match nothing, and ” at least says so out loud.
func declaredRepo(repo string) string {
	if model.ValidRepoName(repo) != nil {
		return ""
	}
	return repo
}

// RepoDeclaration is how a window's spend divides by what it declared.
//
// Three buckets, never two. Scoping a cost-per-issue read to one repository
// used to be impossible and is now a WHERE clause -- but the clause silently
// drops every row that named no repository, and on a hub that has just been
// upgraded that is most of them. A filter whose discards are invisible turns
// "we cannot see this yet" into "this cost nothing", which is the same
// flattering error §4 of the design forbids for the unattributed bucket.
//
// So the read reports what it dropped and why: OtherRepos is spend that named
// a different repository (correctly excluded), Undeclared is spend that named
// none (excluded because "not declared" is not "not this repo"). Scoped +
// OtherRepos + Undeclared = Total, and a reader can check it.
type RepoDeclaration struct {
	Repo       string     `json:"repo"`
	Scoped     SpendTotal `json:"scoped"`
	OtherRepos SpendTotal `json:"other_repos"`
	Undeclared SpendTotal `json:"undeclared"`
	Total      SpendTotal `json:"total"`
}

// RepoDeclaration splits the window's spend into the three buckets above.
//
// f is the UNSCOPED window: its Repo is ignored, because the whole point is to
// measure what scoping to repo would leave out.
func (s *Store) RepoDeclaration(f Filter, repo string) (*RepoDeclaration, error) {
	f.Repo = ""
	where, args, err := f.where("hour")
	if err != nil {
		return nil, err
	}
	// The bucket name is chosen in SQL so the three shares come out of one
	// pass over the window; `repo` is the only caller string and it is a bind
	// parameter, as everywhere else here.
	rows, err := s.read.Query(fmt.Sprintf(`
		SELECT CASE WHEN git_repo = ? THEN 'scoped'
		            WHEN git_repo = '' THEN 'undeclared'
		            ELSE 'other' END AS bucket,
		       SUM(events), SUM%s, %s
		FROM usage_hourly %s
		GROUP BY bucket`,
		hourlyTokens, hourlyCostSplit.sel, where), append([]any{repo}, args...)...)
	if err != nil {
		return nil, fmt.Errorf("repo declaration split: %w", err)
	}
	defer rows.Close()

	out := &RepoDeclaration{Repo: repo}
	for rows.Next() {
		var bucket string
		var t SpendTotal
		cs := hourlyCostSplit.scan()
		if err := rows.Scan(append([]any{&bucket, &t.Events, &t.Tokens}, cs.dest()...)...); err != nil {
			return nil, err
		}
		t.Cost = cs.costs()
		t.Unpriced = t.Cost.Unpriced()
		switch bucket {
		case "scoped":
			out.Scoped.add(t)
		case "undeclared":
			out.Undeclared.add(t)
		default:
			out.OtherRepos.add(t)
		}
		out.Total.add(t)
	}
	return out, rows.Err()
}

// AnyRepoDeclared reports whether ANY hourly row names a repository.
//
// This is the one question that decides which regime the cost read is in, and
// it is deliberately hub-wide rather than per-repo. False means no endpoint on
// this hub can declare yet -- nothing has changed since the seam was built, so
// the §5 refusal is still the honest answer and scoping would return a zero
// that looks measured. True means the binding exists, and from then on a repo
// with no rows of its own gets an honest empty answer plus the undeclared
// figure explaining what it is still blind to.
func (s *Store) AnyRepoDeclared() (bool, error) {
	var n int64
	err := s.read.QueryRow(`SELECT EXISTS(SELECT 1 FROM usage_hourly WHERE git_repo != '')`).Scan(&n)
	if err != nil {
		return false, fmt.Errorf("any repo declared: %w", err)
	}
	return n != 0, nil
}
