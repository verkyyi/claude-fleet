package store

import (
	"database/sql"
	"encoding/json"
	"time"

	"github.com/verkyyi/ccquota/internal/model"
)

func (s *Store) InsertQuota(q model.QuotaSnapshot) error {
	b, err := json.Marshal(q)
	if err != nil {
		return err
	}
	_, err = s.write.Exec(`INSERT OR IGNORE INTO quota_snapshots VALUES(?,?,?,?,?,?,?)`, q.AccountUUID, q.Source, q.ProfileID, q.EndpointID, observationTime(q.ObservedAt), q.Observation, string(b))
	return err
}

func (s *Store) LatestQuota(account string) (*model.QuotaSnapshot, error) {
	var b string
	err := s.read.QueryRow(`SELECT data_json FROM quota_snapshots WHERE account_uuid=? ORDER BY observed_at DESC, observation ASC LIMIT 1`, account).Scan(&b)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var q model.QuotaSnapshot
	if err = json.Unmarshal([]byte(b), &q); err != nil {
		return nil, err
	}
	if q.Observation == "app_server" || time.Since(q.ObservedAt) > 10*time.Minute {
		return &q, nil
	}
	// A log update may cover one model pool while the account API covers all
	// pools. Choose the latest observation per pool, stopping at the latest
	// complete account read so removed pools cannot reappear from older data.
	rows, err := s.QuotaHistory(account, q.Source, time.Now().Add(-10*time.Minute), q.ObservedAt.Add(time.Nanosecond))
	if err != nil {
		return nil, err
	}
	out := q
	out.Windows, out.Credits, out.Pools = nil, nil, nil
	out.Blocked, out.Reason = false, ""
	seen := map[string]bool{}
	for i := len(rows) - 1; i >= 0; i-- {
		row := rows[i]
		if out.Plan == "" {
			out.Plan = row.Plan
		}
		for _, pool := range quotaPools(row) {
			if seen[pool.LimitID] {
				continue
			}
			seen[pool.LimitID] = true
			out.Pools = append(out.Pools, pool)
			if pool.Blocked {
				out.Blocked, out.Reason = true, pool.Reason
			}
			for _, w := range row.Windows {
				if w.LimitID == pool.LimitID {
					at := row.ObservedAt
					w.ObservedAt = &at
					out.Windows = append(out.Windows, w)
				}
			}
			for _, c := range row.Credits {
				if c.LimitID == pool.LimitID {
					out.Credits = append(out.Credits, c)
				}
			}
		}
		if row.Observation == "app_server" {
			break
		}
	}
	return &out, nil
}

func quotaPools(q model.QuotaSnapshot) []model.QuotaPool {
	if len(q.Pools) > 0 {
		return q.Pools
	}
	// Compatibility with the first generic snapshot format.
	out := []model.QuotaPool{}
	seen := map[string]bool{}
	add := func(id string) {
		if !seen[id] {
			seen[id] = true
			out = append(out, model.QuotaPool{LimitID: id, Blocked: q.Blocked, Reason: q.Reason})
		}
	}
	for _, w := range q.Windows {
		add(w.LimitID)
	}
	for _, c := range q.Credits {
		add(c.LimitID)
	}
	if len(out) == 0 && q.Blocked {
		add("account")
	}
	return out
}

func (s *Store) QuotaHistory(account, source string, start, end time.Time) ([]model.QuotaSnapshot, error) {
	if account == "all" {
		account = AllAccounts
	}
	query := `SELECT data_json FROM quota_snapshots WHERE observed_at>=? AND observed_at<?`
	args := []any{observationTime(start), observationTime(end)}
	if account != "" && account != AllAccounts {
		query += ` AND account_uuid=?`
		args = append(args, account)
	}
	if source != "" {
		query += ` AND source=?`
		args = append(args, source)
	}
	query += ` ORDER BY account_uuid, observed_at`
	rows, err := s.read.Query(query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []model.QuotaSnapshot{}
	for rows.Next() {
		var b string
		if err := rows.Scan(&b); err != nil {
			return nil, err
		}
		var q model.QuotaSnapshot
		if err := json.Unmarshal([]byte(b), &q); err != nil {
			return nil, err
		}
		out = append(out, q)
	}
	return out, rows.Err()
}

func (s *Store) UpsertCollector(c model.CollectorStatus) error {
	tx, err := s.write.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var prev, at, oldJSON string
	err = tx.QueryRow(`SELECT account_uuid,observed_at,data_json FROM source_collectors WHERE endpoint_id=? AND source=? AND profile_id=?`, c.EndpointID, c.Source, c.ProfileID).Scan(&prev, &at, &oldJSON)
	if err != nil && err != sql.ErrNoRows {
		return err
	}
	if at != "" && at >= observationTime(c.ObservedAt) {
		return nil
	}
	var old model.CollectorStatus
	if json.Unmarshal([]byte(oldJSON), &old) == nil {
		if c.LastEventAt == nil || (old.LastEventAt != nil && old.LastEventAt.After(*c.LastEventAt)) {
			c.LastEventAt = old.LastEventAt
		}
	}
	b, err := json.Marshal(c)
	if err != nil {
		return err
	}
	if prev != "" && prev != c.AccountUUID {
		if _, err = tx.Exec(`INSERT OR IGNORE INTO source_account_switches VALUES(?,?,?,?,?,?)`, c.EndpointID, c.Source, c.ProfileID, prev, c.AccountUUID, observationTime(c.ObservedAt)); err != nil {
			return err
		}
	}
	_, err = tx.Exec(`INSERT INTO source_collectors VALUES(?,?,?,?,?,?) ON CONFLICT(endpoint_id,source,profile_id) DO UPDATE SET account_uuid=excluded.account_uuid,observed_at=excluded.observed_at,data_json=excluded.data_json`, c.EndpointID, c.Source, c.ProfileID, c.AccountUUID, observationTime(c.ObservedAt), string(b))
	if err != nil {
		return err
	}
	return tx.Commit()
}

func (s *Store) Collectors(account, source string) ([]model.CollectorStatus, error) {
	if account == "all" {
		account = AllAccounts
	}
	q := `SELECT data_json FROM source_collectors WHERE 1=1`
	args := []any{}
	if account != "" && account != AllAccounts {
		q += ` AND account_uuid=?`
		args = append(args, account)
	}
	if source != "" {
		q += ` AND source=?`
		args = append(args, source)
	}
	q += ` ORDER BY endpoint_id,source,profile_id`
	rows, err := s.read.Query(q, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []model.CollectorStatus{}
	for rows.Next() {
		var b string
		if err := rows.Scan(&b); err != nil {
			return nil, err
		}
		var c model.CollectorStatus
		if err := json.Unmarshal([]byte(b), &c); err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

func (s *Store) InsertAccountUsage(u model.AccountUsage) error {
	b, err := json.Marshal(u)
	if err != nil {
		return err
	}
	_, err = s.write.Exec(`INSERT OR IGNORE INTO account_usage_observations VALUES(?,?,?,?,?)`, u.AccountUUID, u.Source, u.EndpointID, observationTime(u.ObservedAt), string(b))
	return err
}

func (s *Store) AccountUsage(account, source string) ([]model.AccountUsage, error) {
	if account == "all" {
		account = AllAccounts
	}
	q := `SELECT data_json FROM (SELECT *,ROW_NUMBER() OVER (PARTITION BY account_uuid,source ORDER BY observed_at DESC) AS n FROM account_usage_observations) WHERE n=1`
	args := []any{}
	if account != "" && account != AllAccounts {
		q += ` AND account_uuid=?`
		args = append(args, account)
	}
	if source != "" {
		q += ` AND source=?`
		args = append(args, source)
	}
	rows, err := s.read.Query(q, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []model.AccountUsage{}
	for rows.Next() {
		var b string
		if err := rows.Scan(&b); err != nil {
			return nil, err
		}
		var u model.AccountUsage
		if err := json.Unmarshal([]byte(b), &u); err != nil {
			return nil, err
		}
		out = append(out, u)
	}
	return out, rows.Err()
}

func observationTime(t time.Time) string { return t.UTC().Format("2006-01-02T15:04:05.000000000Z") }
