package store

import (
	"database/sql"
	"regexp"
	"time"
)

// What a person used, read back from the scan (claude-fleet#3406).
//
// pool_usage only holds what a proxy reported since it was created (#3226):
// no history, and nothing a session sent past every proxy. The pages that
// show a person's usage (我的用量, the admin overview) read the transcript
// scan instead — usage_events, through its hourly rollup usage_hourly, which
// is built 1:1 from it and outlives retention pruning — and file each row
// under a person by its (endpoint, login): the reader cuts by an Owner
// (OwnerOf). A request a proxy reported AND a transcript recorded is counted
// once, because the pages read only the scan; pool_usage stays the budget's
// (fleet.person_budget) and nothing else.
//
// Rows come back as PoolUsage, so one set of sums serves both: Principal is
// left for the caller to fill, WorkerID is empty (a transcript names no fleet
// session), Session is the fleet key the branch names (issue-N, scratch-N),
// Node / Login are where it ran. A bucket's At is its hour's start.

// fleetKeyRE is a worker / scratch worktree's branch, which is its key.
var fleetKeyRE = regexp.MustCompile(`^(issue|scratch)-[1-9][0-9]*$`)

// EventUsageSince lists the scan's usage from since's hour on, one row per
// (hour, endpoint, login, source, model, branch, repo), oldest first. owner
// nil is everyone; an Owner with no logins reads nothing.
func (s *Store) EventUsageSince(owner *Owner, since time.Time) ([]PoolUsage, error) {
	q := `SELECT hour, endpoint_id, os_user, source, model, git_branch, git_repo, COALESCE(issue_number, 0),
		SUM(input_tokens), SUM(cache_create_5m_tokens + cache_create_1h_tokens), SUM(cache_read_tokens),
		SUM(output_tokens), SUM(events)
		FROM usage_hourly WHERE hour >= ?`
	args := []any{hourKey(since)}
	if owner != nil {
		w, a := owner.where()
		q += ` AND ` + w
		args = append(args, a...)
	}
	q += ` GROUP BY hour, endpoint_id, os_user, source, model, git_branch, git_repo, issue_number ORDER BY hour`
	rows, err := s.read.Query(q, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []PoolUsage
	for rows.Next() {
		var u PoolUsage
		var hour, branch string
		var issue int64
		if err := rows.Scan(&hour, &u.EndpointID, &u.Login, &u.Provider, &u.Model, &branch, &u.Repo, &issue,
			&u.In, &u.CacheWrite, &u.CacheRead, &u.Out, &u.Requests); err != nil {
			return nil, err
		}
		if u.At, err = time.Parse("2006-01-02T15:04:05Z", hour); err != nil {
			continue
		}
		u.Issue = int(issue)
		if fleetKeyRE.MatchString(branch) {
			u.Session = branch
		}
		if u.Provider != "codex" {
			u.Provider = "claude"
		}
		if u.Tokens() <= 0 && u.CacheRead <= 0 {
			continue
		}
		out = append(out, u)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	if len(out) == 0 {
		return out, nil
	}
	hosts, err := s.endpointHosts()
	if err != nil {
		return nil, err
	}
	for i := range out {
		out[i].Node = hosts[out[i].EndpointID]
	}
	return out, nil
}

// endpointHosts is every endpoint's machine name.
func (s *Store) endpointHosts() (map[string]string, error) {
	rows, err := s.read.Query(`SELECT endpoint_id, COALESCE(hostname, '') FROM endpoints`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[string]string{}
	for rows.Next() {
		var id, host string
		if err := rows.Scan(&id, &host); err != nil {
			return nil, err
		}
		out[id] = host
	}
	return out, rows.Err()
}

// EventUsageFirst is the hour of the scan's oldest surviving row, anyone's:
// the pages read nothing older, so a window that starts before it was not
// fully recorded. ok false = nothing recorded yet.
func (s *Store) EventUsageFirst() (first time.Time, ok bool, err error) {
	var hour sql.NullString
	if err := s.read.QueryRow(`SELECT MIN(hour) FROM usage_hourly`).Scan(&hour); err != nil {
		return time.Time{}, false, err
	}
	if !hour.Valid || hour.String == "" {
		return time.Time{}, false, nil
	}
	t, err := time.Parse("2006-01-02T15:04:05Z", hour.String)
	if err != nil {
		return time.Time{}, false, err
	}
	return t, true, nil
}
