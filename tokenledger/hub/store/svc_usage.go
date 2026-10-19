package store

import (
	"fmt"
	"time"
)

// Service usage by tenant (claude-fleet#4006, the SPACE EPIC C4): a service
// run's model calls are pool_usage rows under the service principal
// (svc:livepage) with the tenant its pass was minted for. A service's budget
// (fleet.svc_budget.<name>) is held against all of its rows, a tenant's
// (fleet.svc_tenant_budget.<name>) against that tenant's alone.

// SvcUsageRow is one ten-minute bucket of one tenant's metered usage.
type SvcUsageRow struct {
	Tenant     string
	Bucket     int64
	In         int64
	CacheWrite int64
	CacheRead  int64
	Out        int64
	Requests   int64
}

// Tokens is what a budget counts: input + cache writes + output.
func (r SvcUsageRow) Tokens() int64 { return r.In + r.CacheWrite + r.Out }

// SvcUsageSince lists principal's buckets at or after since (and before until,
// unless zero), by tenant, oldest first; tenant "" is every tenant.
func (s *Store) SvcUsageSince(principal, tenant string, since, until time.Time) ([]SvcUsageRow, error) {
	w := int64(PersonUsageBucket / time.Second)
	q := fmt.Sprintf(`SELECT tenant, at_unix / %d, SUM(tokens_in), SUM(cache_write), SUM(cache_read), SUM(tokens_out),
		SUM(requests) FROM pool_usage WHERE principal = ? AND at_unix >= ?`, w)
	args := []any{principal, since.Unix()}
	if !until.IsZero() {
		q += ` AND at_unix < ?`
		args = append(args, until.Unix())
	}
	if tenant != "" {
		q += ` AND tenant = ?`
		args = append(args, tenant)
	}
	rows, err := s.write.Query(q+fmt.Sprintf(` GROUP BY tenant, at_unix / %d ORDER BY at_unix / %d, tenant`, w, w), args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []SvcUsageRow
	for rows.Next() {
		var r SvcUsageRow
		if err := rows.Scan(&r.Tenant, &r.Bucket, &r.In, &r.CacheWrite, &r.CacheRead, &r.Out, &r.Requests); err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

// SvcRunByKey is principal's run for an idempotency key (sql.ErrNoRows: none).
func (s *Store) SvcRunByKey(principal, key string) (SvcRun, error) {
	return s.svcRunBy(`principal = ? AND idempotency_key = ?`, principal, key)
}

// SvcRunsEnded lists principal's runs that ended at or after since (and before
// until, unless zero), oldest first; tenant "" is every tenant — the runs whose
// callbacks carried usage in the window.
func (s *Store) SvcRunsEnded(principal, tenant string, since, until time.Time) ([]SvcRun, error) {
	q := `SELECT ` + svcRunCols + ` FROM svc_runs WHERE principal = ? AND finished_at >= ?`
	args := []any{principal, svcTime(since)}
	if !until.IsZero() {
		q += ` AND finished_at < ?`
		args = append(args, svcTime(until))
	}
	if tenant != "" {
		q += ` AND tenant = ?`
		args = append(args, tenant)
	}
	rows, err := s.write.Query(q+` ORDER BY finished_at, id`, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []SvcRun
	for rows.Next() {
		r, err := scanSvcRun(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}
