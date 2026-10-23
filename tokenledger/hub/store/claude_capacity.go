package store

import (
	"database/sql"
	"errors"
	"fmt"
	"time"
)

// Raw quota preserves missing, duplicate and model-scoped fields. The legacy
// display snapshot's zero-valued windows cannot establish routing eligibility.
func (s *Store) ClaudeCapacityRaw(identity string) ([]byte, time.Time, error) {
	var raw, at string
	err := s.read.QueryRow(`SELECT raw_json,observed_at FROM limit_snapshots WHERE account_uuid=? ORDER BY observed_at DESC LIMIT 1`, identity).Scan(&raw, &at)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, time.Time{}, nil
	}
	if err != nil {
		return nil, time.Time{}, err
	}
	// Equal-time divergent readings are not ordered by database row position.
	var count int
	if err := s.read.QueryRow(`SELECT COUNT(*) FROM limit_snapshots WHERE account_uuid=? AND observed_at=? AND raw_json<>?`, identity, at, raw).Scan(&count); err != nil {
		return nil, time.Time{}, err
	}
	if count > 0 {
		return nil, time.Time{}, fmt.Errorf("conflicting latest quota observations")
	}
	observed, err := time.Parse(rfc, at)
	return []byte(raw), observed, err
}

func (s *Store) ClaudeLiveBindLoads(exclude string, now time.Time) (map[string]int, error) {
	rows, err := s.write.Query(`SELECT b.owner,b.account,COUNT(DISTINCT b.worker_id) FROM fleet_session_binds b JOIN fleet_session_creds c ON c.worker_id=b.worker_id WHERE b.provider='claude' AND b.worker_id<>? AND c.revoked_at IS NULL AND c.expires_at>? AND (',' || c.providers || ',') LIKE '%,claude,%' GROUP BY b.owner,b.account`, exclude, now.UTC().Format(sessRFC))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[string]int{}
	for rows.Next() {
		var owner, account string
		var n int
		if err := rows.Scan(&owner, &account, &n); err != nil {
			return nil, err
		}
		out[owner+"\x00"+account] = n
	}
	return out, rows.Err()
}
