package store

import (
	"fmt"
	"strings"
	"time"
)

// Filter is the scope every Review query runs under: one subscription (or
// all), a half-open time range, and at most one value per drill-down
// dimension. An empty string on a dimension means "no constraint".
type Filter struct {
	Account    string
	Start, End time.Time

	Endpoint, OSUser, CWD, Model, Branch, Team, Session string
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
	eq := func(col, v string) {
		if v != "" {
			parts = append(parts, col+" = ?")
			args = append(args, v)
		}
	}
	eq("endpoint_id", f.Endpoint)
	eq("os_user", f.OSUser)
	eq("cwd", f.CWD)
	eq("model", f.Model)
	eq("git_branch", f.Branch)
	eq("session_id", f.Session)
	if f.Team != "" {
		parts = append(parts, "endpoint_id IN (SELECT endpoint_id FROM endpoints WHERE team = ?)")
		args = append(args, f.Team)
	}
	parts = append(parts, tsCol+" >= ?", tsCol+" < ?")
	args = append(args, fmtTime(f.Start), fmtTime(f.End))
	return "WHERE " + strings.Join(parts, " AND "), args, nil
}
