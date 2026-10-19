package store

import (
	"database/sql"
	"encoding/json"
	"errors"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/shared/fleetid"
)

// Settling a legacy task record (claude-fleet#4867). A version-0 record's
// states are placing / open / refused / unknown: nothing ever ends it, so one
// that was once attached to a worker stays in repoAuthorityBlockers' "legacy
// task owner is unverified" forever. TaskClosed is its one terminal state, and
// it is written ONLY here, on evidence: the record's issue is closed (the caller
// reads that — the hub's own ticket, else GitHub) AND its worker holds nothing —
// no lease row, no unclosed local start of the repo, not in its fleet's current
// inventory. The worker half is re-read inside the transaction that writes.
// A node never writes `closed` through the record's update road.
const TaskClosed = "closed"

// LegacySettleCandidates lists the legacy records of repo that block the
// authority switch: attached to a worker and not ended. owner "" = everyone's
// (the operator's door).
func (s *Store) LegacySettleCandidates(repo, owner string) ([]FleetTask, error) {
	q, args := `SELECT `+fleetTaskCols+` FROM fleet_tasks WHERE repo = ? AND authority_version = 0 AND worker_id <> '' AND state NOT IN (?, ?)`,
		[]any{NormRepo(repo), TaskClosed, TaskRefused}
	if owner != "" {
		q, args = q+` AND owner = ?`, append(args, owner)
	}
	rows, err := s.read.Query(q+` ORDER BY id`, args...)
	if err != nil {
		return nil, err
	}
	return scanFleetTasks(rows)
}

// LegacyWorkerLive says why worker may still be executing for repo; "" when
// nothing on the hub's books holds it.
func (s *Store) LegacyWorkerLive(repo, worker string) (string, error) {
	return legacyWorkerLive(s.read, NormRepo(repo), worker)
}

func legacyWorkerLive(q querier, repo, worker string) (string, error) {
	var n int
	if err := q.QueryRow(`SELECT COUNT(*) FROM fleet_leases WHERE worker_id = ?`, worker).Scan(&n); err != nil {
		return "", err
	}
	if n > 0 {
		return "lease held", nil
	}
	starts, err := localStarts(q, func(st RepoLocalStart) bool { return st.Repo == repo })
	if err != nil {
		return "", err
	}
	for _, st := range starts {
		if st.WorkerID == worker && !repoStartClosed(st.Phase) {
			return "local start retained", nil
		}
	}
	fid, _, err := fleetid.ParseWorkerID(worker)
	if err != nil {
		return "", nil // not a worker id any fleet could report
	}
	var raw string
	err = q.QueryRow(`SELECT workers_json FROM fleet_fleets WHERE fleet_id = ?`, fid).Scan(&raw)
	if errors.Is(err, sql.ErrNoRows) {
		return "", nil
	}
	if err != nil {
		return "", err
	}
	var ws []map[string]any
	if json.Unmarshal([]byte(raw), &ws) != nil {
		return "inventory unreadable", nil
	}
	for _, w := range ws {
		if id, _ := w["worker_id"].(string); id == worker {
			return "in inventory", nil
		}
	}
	return "", nil
}

// SettleLegacyTask ends one legacy record whose issue the caller found closed.
// It refuses (ErrTaskConflict) when the record is no longer an open legacy
// record of that worker, or the worker is live by the time it writes.
func (s *Store) SettleLegacyTask(id int64, worker, evidence string, now time.Time) error {
	tx, err := s.write.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var repo, owner, state, w string
	var version int
	if err = tx.QueryRow(`SELECT repo, owner, state, worker_id, authority_version FROM fleet_tasks WHERE id = ?`, id).Scan(&repo, &owner, &state, &w, &version); err != nil {
		return err
	}
	if version != 0 || w == "" || w != worker || state == TaskClosed || state == TaskRefused {
		return ErrTaskConflict
	}
	if err = s.lockOwnerAuthority(tx, owner); err != nil {
		return err
	}
	live, err := legacyWorkerLive(tx, repo, worker)
	if err != nil {
		return err
	}
	if live != "" {
		return ErrTaskConflict
	}
	res, err := tx.Exec(`UPDATE fleet_tasks SET state = ?, note = ?, updated_at = ? WHERE id = ? AND authority_version = 0 AND worker_id = ? AND state = ?`,
		TaskClosed, clipNote(evidence), now.UTC().Format(rfc), id, worker, state)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrTaskConflict
	}
	return tx.Commit()
}

func clipNote(s string) string {
	s = strings.TrimSpace(s)
	if r := []rune(s); len(r) > 500 {
		s = string(r[:500])
	}
	return s
}
