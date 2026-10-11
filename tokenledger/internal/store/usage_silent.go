package store

import (
	"database/sql"
	"time"
)

// AlertUsageSilent: a (machine, login) with sessions working for longer than
// the threshold while the hub took no usage from it in that time
// (claude-fleet#3204) — subject "<endpoint_id>/<source>". A login whose turns
// stop reaching the hub (no identity to file them under, a transcript
// directory nobody watches, an agent that skips a source) looks exactly like
// a login nobody is using; this is the row that tells the two apart.
const AlertUsageSilent = "usage_silent"

// AlertPoolUsageUnowned: a login's local proxy reported subscription-pool
// usage and no person is mapped to that login (claude-fleet#3376) — subject
// "<endpoint_id>/<login>". The pool has no ownerless rows, so the usage is
// not filed; this row is how an admin sees it was not, and is cleared by the
// first report the login files under a person.
const AlertPoolUsageUnowned = "pool_usage_unowned"

// LastUsageAt is the newest turn the hub holds from (endpoint, os_user,
// source) at or after since — zero when there is none. Read off the hourly
// rollup, whose key leads with the hour, so the sweep never scans the raw
// event table.
func (s *Store) LastUsageAt(endpointID, osUser, source string, since time.Time) (time.Time, error) {
	var last sql.NullString
	err := s.read.QueryRow(`SELECT MAX(max_ts) FROM usage_hourly
		WHERE hour >= ? AND endpoint_id = ? AND os_user = ? AND source = ?`,
		hourKey(since), endpointID, osUser, source).Scan(&last)
	if err != nil || !last.Valid || last.String == "" {
		return time.Time{}, err
	}
	t, err := time.Parse(rfc, last.String)
	if err != nil {
		return time.Time{}, nil
	}
	return t.UTC(), nil
}
