// internal/store/limits_history.go
package store

import (
	"fmt"
	"time"
)

// LimitPoint is one utilization observation.
type LimitPoint struct {
	AccountUUID string    `json:"account_uuid"`
	T           time.Time `json:"t"`
	FiveHour    float64   `json:"five_hour_pct"`
	SevenDay    float64   `json:"seven_day_pct"`
}

// LimitsHistory returns every snapshot in [start, end) for one account or all,
// ordered by account then time. Several endpoints may observe the same account;
// their readings agree (the figure is account-wide) and are all returned.
func (s *Store) LimitsHistory(account string, start, end time.Time, sources ...string) ([]LimitPoint, error) {
	if account == "" {
		return nil, fmt.Errorf("account is required")
	}
	filter := ""
	args := accountArgs(account, fmtTime(start), fmtTime(end))
	if len(sources) > 0 && sources[0] != "" {
		filter = ` AND account_uuid IN (SELECT account_uuid FROM accounts WHERE source=?)`
		args = append(args, sources[0])
	}
	q := `SELECT account_uuid, observed_at, five_hour_pct, seven_day_pct FROM limit_snapshots
	      WHERE ` + accountClause(account) + ` observed_at >= ? AND observed_at < ?
	      ` + filter + ` ORDER BY account_uuid, observed_at`
	rows, err := s.db.Query(q, args...)
	if err != nil {
		return nil, fmt.Errorf("limits history: %w", err)
	}
	defer rows.Close()
	var out []LimitPoint
	for rows.Next() {
		var p LimitPoint
		var at string
		if err := rows.Scan(&p.AccountUUID, &at, &p.FiveHour, &p.SevenDay); err != nil {
			return nil, err
		}
		p.T, _ = time.Parse(rfc, at)
		out = append(out, p)
	}
	return out, rows.Err()
}
