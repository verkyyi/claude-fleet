package store

import (
	"time"
)

// Expiry ends journal tracking, not execution: it never changes a task binding,
// grants a retry, or claims the node stopped. Keep request/result byte for byte.
const FleetOperationMaxAge = 24 * time.Hour

func FleetOperationTerminal(status string) bool {
	return status == "succeeded" || status == "failed" || status == "expired"
}

// ExpireFleetOperations handles the historical backlog and future timeouts by
// the same transactional path. Each changed row gets exactly one audit entry.
func (s *Store) ExpireFleetOperations(now time.Time) (int, error) {
	tx, err := s.write.Begin()
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()
	rows, err := tx.Query(`SELECT id,actor,fleet_id,status FROM fleet_operations WHERE status NOT IN ('succeeded','failed','expired') AND created < ? ORDER BY id`+s.d.forUpdate(), now.Add(-FleetOperationMaxAge).UTC().Format(rfc))
	if err != nil {
		return 0, err
	}
	var ops []FleetOperation
	for rows.Next() {
		var o FleetOperation
		if err := rows.Scan(&o.ID, &o.Actor, &o.FleetID, &o.Status); err != nil {
			rows.Close()
			return 0, err
		}
		ops = append(ops, o)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return 0, err
	}
	for _, o := range ops {
		if _, err := tx.Exec(`UPDATE fleet_operations SET status='expired',updated=? WHERE id=?`, now.UTC().Format(rfc), o.ID); err != nil {
			return 0, err
		}
		if _, err := tx.Exec(`INSERT INTO fleet_audit(actor,action,fleet_id,outcome,operation_id,created) VALUES(?,'operation_expire',?,?,?,?)`, o.Actor, o.FleetID, "expired after 24h; prior_status="+o.Status+"; execution outcome unchanged", o.ID, now.UTC().Format(rfc)); err != nil {
			return 0, err
		}
	}
	return len(ops), tx.Commit()
}

// UnfinishedFleetOperations is bounded and oldest-observation first, so no
// caller has to keep polling for the operation's completion to be recorded.
func (s *Store) UnfinishedFleetOperations(now time.Time, limit int) ([]FleetOperation, error) {
	rows, err := s.read.Query(`SELECT id FROM fleet_operations WHERE status IN ('pending','accepted','running','unknown') AND fleet_id <> '' AND updated < ? ORDER BY updated,id LIMIT ?`, now.Add(-time.Minute).UTC().Format(rfc), limit)
	if err != nil {
		return nil, err
	}
	var ids []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			rows.Close()
			return nil, err
		}
		ids = append(ids, id)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}
	var out []FleetOperation
	for _, id := range ids {
		o, err := s.FleetOperation(id)
		if err != nil {
			return nil, err
		}
		if !FleetOperationTerminal(o.Status) {
			out = append(out, o)
		}
	}
	return out, nil
}

// TouchUnfinishedOperation advances only the reconciliation cursor; a result
// arriving concurrently keeps its terminal status and original result.
func (s *Store) TouchUnfinishedOperation(id string, at time.Time) error {
	_, err := s.write.Exec(`UPDATE fleet_operations SET updated=? WHERE id=? AND status NOT IN ('succeeded','failed','expired')`, at.UTC().Format(rfc), id)
	return err
}
