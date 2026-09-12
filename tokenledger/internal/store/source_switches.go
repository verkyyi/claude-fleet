package store

import "time"

// SourceSwitches includes observed Codex profile login changes. Legacy Claude
// login seams keep their original meaning and never include Codex heartbeats.
func (s *Store) SourceSwitches(account, source string, limit int) ([]AccountSwitch, error) {
	if account == "all" {
		account = AllAccounts
	}
	if limit <= 0 || limit > 500 {
		limit = 50
	}
	q := `SELECT endpoint_id,from_account,to_account,observed_at,source,profile_id FROM (
	SELECT endpoint_id,from_account,to_account,observed_at,'claude' AS source,'' AS profile_id FROM account_switches
	UNION ALL SELECT endpoint_id,from_account,to_account,observed_at,source,profile_id FROM source_account_switches) WHERE 1=1`
	args := []any{}
	if account != "" && account != AllAccounts {
		q += ` AND (from_account=? OR to_account=?)`
		args = append(args, account, account)
	}
	if source != "" {
		q += ` AND source=?`
		args = append(args, source)
	}
	q += ` ORDER BY observed_at DESC LIMIT ?`
	args = append(args, limit)
	rows, err := s.db.Query(q, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []AccountSwitch{}
	for rows.Next() {
		var v AccountSwitch
		var at string
		if err := rows.Scan(&v.EndpointID, &v.FromAccount, &v.ToAccount, &at, &v.Source, &v.ProfileID); err != nil {
			return nil, err
		}
		v.ObservedAt, _ = time.Parse(rfc, at)
		out = append(out, v)
	}
	return out, rows.Err()
}
