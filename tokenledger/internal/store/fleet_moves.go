package store

import (
	"errors"
	"fmt"
	"time"
)

// Session moves through the hub (claude-fleet#1426, EPIC #1419 C7).
//
// A session moving from one machine to another carries its transcript, which
// is far too big for a control-channel frame (1 MiB) or a relay (16 KiB). So
// the source node uploads it here first (POST /v1/node/move/bundle), names it
// in the move it then asks for, and the TARGET node's agent downloads it
// (GET /v1/node/move/bundle/<id>) before handing the journalled
// worker_move_in to claude-fleet. Neither machine ever talks to the other.
//
// A bundle row is the move's whole record: who uploaded it, which worker it
// carries, and — once the move is asked for — the target endpoint (the only
// one allowed to download it), the worker_id it becomes there and the
// operation that runs it. The blob is dropped once the target fetched it and
// the operation settled, and every row expires after FleetMoveTTL.
const fleetMoveSchema = `
CREATE TABLE IF NOT EXISTS fleet_moves (
  id              TEXT PRIMARY KEY,
  from_endpoint   TEXT NOT NULL,
  from_wid        TEXT NOT NULL DEFAULT '',
  to_wid          TEXT NOT NULL DEFAULT '',
  target_endpoint TEXT NOT NULL DEFAULT '',
  repo            TEXT NOT NULL DEFAULT '',
  issue           INTEGER NOT NULL DEFAULT 0,
  operation_id    TEXT NOT NULL DEFAULT '',
  sha256          TEXT NOT NULL,
  size            INTEGER NOT NULL,
  bundle          BLOB,
  created         TEXT NOT NULL,
  fetched_at      TEXT NOT NULL DEFAULT '',
  settled         TEXT NOT NULL DEFAULT ''
);`

// FleetMoveTTL is how long an uploaded bundle waits to be moved and fetched.
// A move takes seconds; a day covers a hub restart and a retry.
const FleetMoveTTL = 24 * time.Hour

// FleetMove is one move's record, without its blob.
type FleetMove struct {
	ID             string
	FromEndpoint   string
	FromWID        string
	ToWID          string
	TargetEndpoint string
	Repo           string
	Issue          int
	OperationID    string
	SHA256         string
	Size           int64
	Created        time.Time
	FetchedAt      time.Time
	Settled        string
}

func (s *Store) ensureFleetMoves() error {
	if _, err := s.write.Exec(fleetMoveSchema); err != nil {
		return fmt.Errorf("create fleet_moves: %w", err)
	}
	return nil
}

// InsertFleetMoveBundle stores one uploaded transcript bundle.
func (s *Store) InsertFleetMoveBundle(m FleetMove, bundle []byte) error {
	_, err := s.write.Exec(`INSERT INTO fleet_moves (id, from_endpoint, sha256, size, bundle, created)
		VALUES (?, ?, ?, ?, ?, ?)`, m.ID, m.FromEndpoint, m.SHA256, m.Size, bundle, m.Created.UTC().Format(rfc))
	return err
}

const fleetMoveCols = `id, from_endpoint, from_wid, to_wid, target_endpoint, repo, issue, operation_id,
	sha256, size, created, fetched_at, settled`

func scanFleetMove(row interface{ Scan(...any) error }) (FleetMove, error) {
	var m FleetMove
	var created, fetched string
	err := row.Scan(&m.ID, &m.FromEndpoint, &m.FromWID, &m.ToWID, &m.TargetEndpoint, &m.Repo, &m.Issue,
		&m.OperationID, &m.SHA256, &m.Size, &created, &fetched, &m.Settled)
	if err != nil {
		return m, err
	}
	m.Created, _ = time.Parse(rfc, created)
	if fetched != "" {
		m.FetchedAt, _ = time.Parse(rfc, fetched)
	}
	return m, nil
}

// FleetMove reads one move's record (sql.ErrNoRows when there is none).
func (s *Store) FleetMove(id string) (FleetMove, error) {
	return scanFleetMove(s.write.QueryRow(`SELECT `+fleetMoveCols+` FROM fleet_moves WHERE id = ?`, id))
}

// FleetMoveByOperation reads the move an operation runs.
func (s *Store) FleetMoveByOperation(opID string) (FleetMove, error) {
	return scanFleetMove(s.write.QueryRow(`SELECT `+fleetMoveCols+` FROM fleet_moves WHERE operation_id = ?`, opID))
}

// ErrMoveClaimed is a bundle already bound to a different move.
var ErrMoveClaimed = errors.New("bundle already belongs to another move")

// BindFleetMove records which move a bundle carries. Binding the same bundle
// again to the same worker and target is a no-op (a retried request); to
// anything else it is ErrMoveClaimed.
func (s *Store) BindFleetMove(id, fromWID, toWID, targetEndpoint, repo string, issue int) error {
	res, err := s.write.Exec(`UPDATE fleet_moves SET from_wid = ?, to_wid = ?, target_endpoint = ?, repo = ?, issue = ?
		WHERE id = ? AND (from_wid = '' OR (from_wid = ? AND to_wid = ? AND target_endpoint = ?))`,
		fromWID, toWID, targetEndpoint, repo, issue, id, fromWID, toWID, targetEndpoint)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrMoveClaimed
	}
	return nil
}

// SetFleetMoveOperation records the operation that runs a move.
func (s *Store) SetFleetMoveOperation(id, opID string) error {
	_, err := s.write.Exec(`UPDATE fleet_moves SET operation_id = ? WHERE id = ?`, opID, id)
	return err
}

// FleetMoveBundle is a bundle's bytes, for its target to download; it marks
// the bundle fetched. sql.ErrNoRows when there is no such bundle or it was
// already dropped.
func (s *Store) FleetMoveBundle(id string, at time.Time) ([]byte, FleetMove, error) {
	m, err := s.FleetMove(id)
	if err != nil {
		return nil, m, err
	}
	var b []byte
	if err := s.write.QueryRow(`SELECT bundle FROM fleet_moves WHERE id = ? AND bundle IS NOT NULL`, id).Scan(&b); err != nil {
		return nil, m, err
	}
	_, _ = s.write.Exec(`UPDATE fleet_moves SET fetched_at = ? WHERE id = ?`, at.UTC().Format(rfc), id)
	return b, m, nil
}

// SettleFleetMove records a move's final outcome once and drops its blob.
// settled is false when it had already been settled.
func (s *Store) SettleFleetMove(id, outcome string) (settled bool, err error) {
	res, err := s.write.Exec(`UPDATE fleet_moves SET settled = ?, bundle = NULL WHERE id = ? AND settled = ''`, outcome, id)
	if err != nil {
		return false, err
	}
	n, _ := res.RowsAffected()
	return n > 0, nil
}

// ExpireFleetMoves drops every bundle older than ttl and forgets the rows.
func (s *Store) ExpireFleetMoves(ttl time.Duration, at time.Time) (int64, error) {
	res, err := s.write.Exec(`DELETE FROM fleet_moves WHERE created < ?`, at.Add(-ttl).UTC().Format(rfc))
	if err != nil {
		return 0, err
	}
	return res.RowsAffected()
}
