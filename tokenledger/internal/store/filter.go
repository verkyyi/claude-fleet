package store

import (
	"fmt"
	"strings"
	"time"
)

// Undeclared is what a dimension is set to in order to ask for the rows that
// declared NOTHING on it: the blank provider, the turn with no branch, the
// checkout that named no repository.
//
// It exists because "" was already taken. An empty string on a dimension means
// NO CONSTRAINT, so until this constant there was no way to express the other
// question, and the drill-down into a blank bucket asked the wrong one
// silently: the dashboard's "declares no upstream" row sent ?provider=, which
// `where` read as "no constraint", so expanding that row answered with every
// upstream on the hub (issue #134). A filter API that cannot say "just the
// blank ones" does not refuse the question — it answers a different one.
//
// The value is "(none)" rather than a control character because it has to
// survive being TYPED: it travels in a dashboard URL and in an MCP tool
// argument, which is how the question is asked. Parentheses appear in no
// hostname, model id, branch name, OS login, session id or `owner/name`, so it
// cannot collide with a real value. Same trade as AllAccounts ("*") a few
// files over: spanning every subscription, and asking for the blank side, are
// both things the caller has to state rather than fall into.
const Undeclared = "(none)"

// Filter is the scope every Review query runs under: one subscription (or
// all), a half-open time range, and at most one value per drill-down
// dimension. An empty string on a dimension means "no constraint"; Undeclared
// means "only the rows that declared nothing here".
type Filter struct {
	Account    string
	Start, End time.Time

	Endpoint, OSUser, CWD, Model, Provider, Branch, Team, Session, Source string

	// Repo scopes to rows whose endpoint DECLARED that repository
	// (`owner/name`, see internal/store/gitrepo.go). Rows that declared nothing
	// are excluded -- "not declared" is not "not this repo", and counting them
	// in would put one repository's issue #12 on another's money.
	//
	// That exclusion is exactly why it has a companion: whoever sets this is
	// expected to report DeclaredSpend's undeclared side beside the answer, so
	// the reader can see the size of what the filter dropped. Undeclared is
	// how that side is asked for directly.
	Repo string
}

// Prev is the period of the same length that ends where this one starts.
func (f Filter) Prev() Filter {
	p := f
	p.End = f.Start
	p.Start = f.Start.Add(-f.End.Sub(f.Start))
	return p
}

// AlignHours widens the range outward to whole UTC hours: the rollup can only
// answer at hour resolution, and cutting a bucket in half would under-count.
func (f Filter) AlignHours() Filter {
	a := f
	a.Start = f.Start.UTC().Truncate(time.Hour)
	if e := f.End.UTC(); e.Equal(e.Truncate(time.Hour)) {
		a.End = e
	} else {
		a.End = e.Truncate(time.Hour).Add(time.Hour)
	}
	return a
}

// where builds the WHERE fragment. Column names are fixed here — the caller's
// strings only ever become bind arguments — which is what keeps this
// injection-proof.
func (f Filter) where(tsCol string) (string, []any, error) {
	if f.Account == "" {
		return "", nil, fmt.Errorf("account is required: pass a uuid, or store.AllAccounts to span every subscription")
	}
	if tsCol != "ts" && tsCol != "hour" {
		return "", nil, fmt.Errorf("unknown time column %q", tsCol)
	}
	var parts []string
	var args []any
	if f.Account != AllAccounts {
		parts = append(parts, "account_uuid = ?")
		args = append(args, f.Account)
	}
	// Three states, not two: unset, "declared nothing", and a value. Every
	// dimension column below is TEXT NOT NULL DEFAULT '' (schema.sql), so the
	// blank state IS the empty string and the predicate needs no IS NULL arm;
	// the literal is written into the SQL rather than bound because it is this
	// package's own constant, never the caller's string.
	eq := func(col, v string) {
		switch v {
		case "":
			// No constraint on this dimension.
		case Undeclared:
			parts = append(parts, col+" = ''")
		default:
			parts = append(parts, col+" = ?")
			args = append(args, v)
		}
	}
	eq("endpoint_id", f.Endpoint)
	eq("os_user", f.OSUser)
	eq("cwd", f.CWD)
	eq("model", f.Model)
	eq("provider", f.Provider)
	eq("source", f.Source)
	eq("git_branch", f.Branch)
	eq("git_repo", f.Repo)
	eq("session_id", f.Session)
	// Team is the one dimension that is not a column on these tables, so it
	// cannot go through eq -- but it honours the same three states. Leaving it
	// out of the sentinel would be worse than not having one: Undeclared would
	// reach the bind below as a literal team name, match nothing, and report
	// "no unallocated spend" on a hub full of it.
	if f.Team == Undeclared {
		parts = append(parts, "endpoint_id IN (SELECT endpoint_id FROM endpoints WHERE team = '')")
	} else if f.Team != "" {
		parts = append(parts, "endpoint_id IN (SELECT endpoint_id FROM endpoints WHERE team = ?)")
		args = append(args, f.Team)
	}
	parts = append(parts, tsCol+" >= ?", tsCol+" < ?")
	args = append(args, fmtTime(f.Start), fmtTime(f.End))
	return "WHERE " + strings.Join(parts, " AND "), args, nil
}
