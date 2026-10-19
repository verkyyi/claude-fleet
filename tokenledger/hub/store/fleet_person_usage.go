package store

import (
	"fmt"
	"time"
)

// Per-person usage — the tokens each person's sessions spent through a
// credential proxy (claude-fleet#1977, EPIC #1967 R2). Both proxies count a
// response's own `usage` and report it here: the login's local proxy with its
// node token (the person is the login's), the cluster credential proxy with
// its own token (the person rides the session pass). A person's budget
// (fleet.person_budget.<principal>) is read against the sums of the last five
// hours and the last seven days, in ten-minute buckets.
//
// Since claude-fleet#3226 those buckets are summed from pool_usage, one row a
// request; this table is no longer written (a re-key still moves what is left
// of it).
const fleetPersonUsageSchema = `
CREATE TABLE IF NOT EXISTS fleet_person_usage (
  principal  TEXT NOT NULL,
  provider   TEXT NOT NULL,
  bucket     INTEGER NOT NULL,
  tokens     INTEGER NOT NULL DEFAULT 0,
  requests   INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (principal, provider, bucket)
);`

// PersonUsageBucket is the width of one usage row.
const PersonUsageBucket = 10 * time.Minute

func (s *Store) ensureFleetPersonUsage() error {
	if _, err := s.write.Exec(s.d.ddl(fleetPersonUsageSchema)); err != nil {
		return fmt.Errorf("create fleet person usage table: %w", err)
	}
	return nil
}

func personBucket(t time.Time) int64 { return t.Unix() / int64(PersonUsageBucket/time.Second) }

// PersonBucketStart is when a bucket number begins.
func PersonBucketStart(b int64) time.Time {
	return time.Unix(b*int64(PersonUsageBucket/time.Second), 0).UTC()
}

// AddPersonUsage files one aggregate report — a login's local proxy's, which
// counts tokens per provider and no more — as one pool_usage row under the
// person (claude-fleet#3226): its tokens as input, requests as reported.
func (s *Store) AddPersonUsage(principal, provider string, tokens, requests int64, at time.Time) error {
	if principal == "" || tokens <= 0 {
		return nil
	}
	return s.AddPoolUsage(PoolUsage{Principal: principal, Provider: provider, In: tokens, Requests: requests, At: at})
}

// PersonUsageRow is one bucket of one person's usage, every provider summed.
type PersonUsageRow struct {
	Principal string
	Bucket    int64
	Tokens    int64
	Requests  int64
}

// PersonUsageSince lists the buckets at or after since, oldest first — for
// one person, or everyone when principal is "". It sums pool_usage
// (claude-fleet#3226) into the ten-minute buckets the budget reads, so a
// person's limit is held against exactly the rows their page shows.
func (s *Store) PersonUsageSince(principal string, since time.Time) ([]PersonUsageRow, error) {
	w := int64(PersonUsageBucket / time.Second)
	q := fmt.Sprintf(`SELECT principal, at_unix / %d, SUM(tokens_in + cache_write + tokens_out), SUM(requests)
		FROM pool_usage WHERE at_unix >= ?`, w)
	args := []any{personBucket(since) * w}
	if principal != "" {
		q += ` AND principal = ?`
		args = append(args, principal)
	}
	rows, err := s.write.Query(q+fmt.Sprintf(` GROUP BY principal, at_unix / %d ORDER BY principal, at_unix / %d`, w, w), args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []PersonUsageRow
	for rows.Next() {
		var r PersonUsageRow
		if err := rows.Scan(&r.Principal, &r.Bucket, &r.Tokens, &r.Requests); err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}
