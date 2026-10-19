package store

import (
	"github.com/verkyyi/claude-fleet/tokenledger/shared/model"
)

// The repository a spend row was earned in: stored, never derived.
//
// The resolver lives in agent/gitrepo.go, on the endpoint, because
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
