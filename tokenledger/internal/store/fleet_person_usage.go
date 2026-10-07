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
// hours and the last seven days, so rows are kept in ten-minute buckets and
// anything older than eight days is dropped.
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

// personUsageKeep is how far back rows are kept: the week window plus a day.
const personUsageKeep = 8 * 24 * time.Hour

func (s *Store) ensureFleetPersonUsage() error {
	if _, err := s.write.Exec(fleetPersonUsageSchema); err != nil {
		return fmt.Errorf("create fleet person usage table: %w", err)
	}
	return nil
}

func personBucket(t time.Time) int64 { return t.Unix() / int64(PersonUsageBucket/time.Second) }

// PersonBucketStart is when a bucket number begins.
func PersonBucketStart(b int64) time.Time {
	return time.Unix(b*int64(PersonUsageBucket/time.Second), 0).UTC()
}

// AddPersonUsage adds one report's tokens (and request count) to a person's
// bucket for at, and drops rows past the keep window.
func (s *Store) AddPersonUsage(principal, provider string, tokens, requests int64, at time.Time) error {
	if principal == "" || (tokens <= 0 && requests <= 0) {
		return nil
	}
	if _, err := s.write.Exec(`INSERT INTO fleet_person_usage (principal, provider, bucket, tokens, requests)
		VALUES (?, ?, ?, ?, ?) ON CONFLICT (principal, provider, bucket) DO UPDATE SET
		tokens = fleet_person_usage.tokens + excluded.tokens,
		requests = fleet_person_usage.requests + excluded.requests`,
		principal, provider, personBucket(at), tokens, requests); err != nil {
		return err
	}
	_, err := s.write.Exec(`DELETE FROM fleet_person_usage WHERE bucket < ?`, personBucket(at.Add(-personUsageKeep)))
	return err
}

// PersonUsageRow is one bucket of one person's usage, every provider summed.
type PersonUsageRow struct {
	Principal string
	Bucket    int64
	Tokens    int64
	Requests  int64
}

// PersonUsageSince lists the buckets at or after since, oldest first — for
// one person, or everyone when principal is "".
func (s *Store) PersonUsageSince(principal string, since time.Time) ([]PersonUsageRow, error) {
	q := `SELECT principal, bucket, SUM(tokens), SUM(requests) FROM fleet_person_usage WHERE bucket >= ?`
	args := []any{personBucket(since)}
	if principal != "" {
		q += ` AND principal = ?`
		args = append(args, principal)
	}
	rows, err := s.write.Query(q+` GROUP BY principal, bucket ORDER BY principal, bucket`, args...)
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
