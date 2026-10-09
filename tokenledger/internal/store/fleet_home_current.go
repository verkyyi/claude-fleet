package store

import (
	"database/sql"
	"errors"
	"fmt"
	"time"
)

// The person's current HOME session (claude-fleet#2564, EPIC #2563 C1).
//
// `fleet claude` / `fleet codex` opens a home session — no repo, in $HOME on a
// fleet machine. Until it is /exit-ed it stays the person's CURRENT one for
// that agent: the next `fleet claude`, from any of their computers, goes back
// to it instead of opening another. One row per (actor, agent): the session's
// worker_id and machine, or — for a start the hub answered before it finished
// — the operation it is still waiting on. The row is never the judge of
// liveness: the client-place handler checks it against the fleet's last
// inventory each time and treats a gone or exited session as none.
const fleetHomeCurrentSchema = `
CREATE TABLE IF NOT EXISTS fleet_home_current (
  actor        TEXT NOT NULL,
  agent        TEXT NOT NULL,
  worker_id    TEXT NOT NULL DEFAULT '',
  fleet_id     TEXT NOT NULL DEFAULT '',
  machine      TEXT NOT NULL DEFAULT '',
  operation_id TEXT NOT NULL DEFAULT '',
  lease        TEXT NOT NULL DEFAULT '',
  device       TEXT NOT NULL DEFAULT '',
  started_at   TEXT NOT NULL,
  PRIMARY KEY (actor, agent)
);`

// HomeCurrent is one person's current home session for one agent. WorkerID
// is empty while OperationID's start has no outcome yet. Lease / Device are
// the client that opened it.
type HomeCurrent struct {
	Actor       string
	Agent       string
	WorkerID    string
	FleetID     string
	Machine     string
	OperationID string
	Lease       string
	Device      string
	StartedAt   time.Time
}

// ErrNoHomeCurrent is returned when a person has no current home session.
var ErrNoHomeCurrent = errors.New("no current home session")

func (s *Store) ensureFleetHomeCurrent() error {
	if _, err := s.write.Exec(s.d.ddl(fleetHomeCurrentSchema)); err != nil {
		return fmt.Errorf("create fleet home current table: %w", err)
	}
	return nil
}

// FleetHomeCurrent is actor's current home session for agent.
func (s *Store) FleetHomeCurrent(actor, agent string) (HomeCurrent, error) {
	c := HomeCurrent{Actor: actor, Agent: agent}
	var at string
	err := s.write.QueryRow(`SELECT worker_id, fleet_id, machine, operation_id, lease, device, started_at
		FROM fleet_home_current WHERE actor = ? AND agent = ?`, actor, agent).
		Scan(&c.WorkerID, &c.FleetID, &c.Machine, &c.OperationID, &c.Lease, &c.Device, &at)
	if errors.Is(err, sql.ErrNoRows) {
		return c, ErrNoHomeCurrent
	}
	if err != nil {
		return c, err
	}
	c.StartedAt, _ = time.Parse(time.RFC3339, at)
	return c, nil
}

// PutFleetHomeCurrent makes c the current home session of (c.Actor, c.Agent),
// replacing whatever was.
func (s *Store) PutFleetHomeCurrent(c HomeCurrent) error {
	_, err := s.write.Exec(`INSERT INTO fleet_home_current
		(actor, agent, worker_id, fleet_id, machine, operation_id, lease, device, started_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT (actor, agent) DO UPDATE SET
		worker_id = excluded.worker_id, fleet_id = excluded.fleet_id, machine = excluded.machine,
		operation_id = excluded.operation_id, lease = excluded.lease, device = excluded.device,
		started_at = excluded.started_at`,
		c.Actor, c.Agent, c.WorkerID, c.FleetID, c.Machine, c.OperationID, c.Lease, c.Device,
		c.StartedAt.UTC().Format(sessRFC))
	return err
}

// ClearFleetHomeCurrent forgets (actor, agent)'s current home session — only
// while it is still the one named (worker_id, else operation_id), so a clear
// that raced a newer start leaves the newer one.
func (s *Store) ClearFleetHomeCurrent(c HomeCurrent) error {
	_, err := s.write.Exec(`DELETE FROM fleet_home_current
		WHERE actor = ? AND agent = ? AND worker_id = ? AND operation_id = ?`,
		c.Actor, c.Agent, c.WorkerID, c.OperationID)
	return err
}
