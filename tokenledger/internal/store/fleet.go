package store

import (
	"database/sql"
	"errors"
	"fmt"
	"time"
)

// The Fleet Hub registry, moved into the hub (claude-fleet#1409): which
// machines exist, which fleets they host, and the journal of operations sent to
// them. It replaces the SSH-era bin/fleet_hub.py tables for the multi-machine
// case; the Python hub stays for single-machine / offline use.
//
// The rows are fed by the control channel's heartbeats, not by an operator's
// `register`: a machine registers itself by reporting. Identity follows the
// Python scheme exactly (internal/fleetid) so a fleet UUID minted on the SSH
// path is the same row here.
//
// Like the node roster, these tables exist only when CCQUOTA_FLEET=1 (created
// by EnsureNodes), and grow only through CREATE ... IF NOT EXISTS and additive
// ALTERs — never a recreate.
const fleetSchema = `
CREATE TABLE IF NOT EXISTS fleet_machines (
  machine_id  TEXT PRIMARY KEY,
  endpoint_id TEXT NOT NULL DEFAULT '',
  hostname    TEXT NOT NULL DEFAULT '',
  os_user     TEXT NOT NULL DEFAULT '',
  first_seen  TEXT NOT NULL,
  last_seen   TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS fleet_fleets (
  fleet_id     TEXT PRIMARY KEY,
  machine_id   TEXT NOT NULL REFERENCES fleet_machines(machine_id),
  name         TEXT NOT NULL DEFAULT '',
  repo         TEXT NOT NULL DEFAULT '',
  checkout     TEXT NOT NULL DEFAULT '',
  agent        TEXT NOT NULL DEFAULT '',
  state        TEXT NOT NULL DEFAULT '',
  worker_count INTEGER NOT NULL DEFAULT 0,
  workers_json TEXT NOT NULL DEFAULT '[]',
  present      INTEGER NOT NULL DEFAULT 1,
  first_seen   TEXT NOT NULL,
  observed_at  TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS fleet_fleets_machine ON fleet_fleets(machine_id);
CREATE TABLE IF NOT EXISTS fleet_operations (
  id         TEXT PRIMARY KEY,
  fleet_id   TEXT NOT NULL,
  action     TEXT NOT NULL,
  request    TEXT NOT NULL,
  actor      TEXT NOT NULL,
  idem       TEXT NOT NULL,
  status     TEXT NOT NULL,
  created    TEXT NOT NULL,
  updated    TEXT NOT NULL,
  result     TEXT,
  UNIQUE(actor, idem)
);
CREATE TABLE IF NOT EXISTS fleet_audit (
  id           INTEGER PRIMARY KEY,
  actor        TEXT NOT NULL DEFAULT '',
  action       TEXT NOT NULL,
  fleet_id     TEXT NOT NULL DEFAULT '',
  outcome      TEXT NOT NULL,
  operation_id TEXT NOT NULL DEFAULT '',
  created      TEXT NOT NULL
);`

// ErrFleetElsewhere is an identity conflict: a heartbeat claims a fleet UUID
// the registry already holds under a different machine. The row is kept as it
// was — a fleet UUID is derived from its machine, so the claim is wrong, not
// the registry.
var ErrFleetElsewhere = errors.New("fleet ID belongs to a different machine")

// FleetReport is one fleet as a heartbeat describes it.
type FleetReport struct {
	FleetID     string
	Name        string
	Repo        string
	Checkout    string
	Agent       string
	State       string
	WorkerCount int
	WorkersJSON string
}

// FleetRow is one registered fleet, with the machine it lives on.
type FleetRow struct {
	FleetID     string
	MachineID   string
	EndpointID  string
	Hostname    string
	OSUser      string
	Name        string
	Repo        string
	Checkout    string
	Agent       string
	State       string
	WorkerCount int
	WorkersJSON string
	Present     bool
	FirstSeen   time.Time
	ObservedAt  time.Time
}

// FleetOperation is one row of the operation journal.
type FleetOperation struct {
	ID      string
	FleetID string
	Action  string
	Request string
	Actor   string
	Idem    string
	Status  string
	Created time.Time
	Updated time.Time
	Result  string // JSON, empty when none yet
}

// RecordFleetSnapshot registers machineID (reporting through endpointID) and
// replaces its fleet list with fleets. A fleet the machine no longer reports
// stays in the registry with present=0 — a dispatcher holding its UUID gets
// "no longer configured", not "never existed".
//
// A fleet UUID already registered under another machine is refused (left
// untouched) and returned in rejected; the rest of the snapshot still lands.
func (s *Store) RecordFleetSnapshot(endpointID, hostname, osUser, machineID string, fleets []FleetReport, at time.Time) (rejected []string, err error) {
	ts := at.UTC().Format(rfc)
	tx, err := s.write.Begin()
	if err != nil {
		return nil, fmt.Errorf("begin: %w", err)
	}
	defer tx.Rollback()
	if _, err := tx.Exec(`
		INSERT INTO fleet_machines (machine_id, endpoint_id, hostname, os_user, first_seen, last_seen)
		VALUES (?, ?, ?, ?, ?, ?)
		ON CONFLICT(machine_id) DO UPDATE SET endpoint_id = excluded.endpoint_id,
		  hostname = excluded.hostname, os_user = excluded.os_user, last_seen = excluded.last_seen`,
		machineID, endpointID, hostname, osUser, ts, ts); err != nil {
		return nil, err
	}
	if _, err := tx.Exec(`UPDATE fleet_fleets SET present = 0 WHERE machine_id = ?`, machineID); err != nil {
		return nil, err
	}
	for _, f := range fleets {
		var owner string
		switch err := tx.QueryRow(`SELECT machine_id FROM fleet_fleets WHERE fleet_id = ?`, f.FleetID).Scan(&owner); {
		case errors.Is(err, sql.ErrNoRows):
		case err != nil:
			return nil, err
		case owner != machineID:
			rejected = append(rejected, f.FleetID)
			continue
		}
		workers := f.WorkersJSON
		if workers == "" {
			workers = "[]"
		}
		if _, err := tx.Exec(`
			INSERT INTO fleet_fleets (fleet_id, machine_id, name, repo, checkout, agent, state,
			                          worker_count, workers_json, present, first_seen, observed_at)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?)
			ON CONFLICT(fleet_id) DO UPDATE SET name = excluded.name, repo = excluded.repo,
			  checkout = excluded.checkout, agent = excluded.agent, state = excluded.state,
			  worker_count = excluded.worker_count, workers_json = excluded.workers_json,
			  present = 1, observed_at = excluded.observed_at`,
			f.FleetID, machineID, f.Name, f.Repo, f.Checkout, f.Agent, f.State,
			f.WorkerCount, workers, ts, ts); err != nil {
			return nil, err
		}
	}
	return rejected, tx.Commit()
}

// UpdateFleetWorkers stores a fresher window list for one fleet (a live
// fleet_status read), leaving its inventory fields alone.
func (s *Store) UpdateFleetWorkers(fleetID, state string, count int, workersJSON string, at time.Time) error {
	_, err := s.write.Exec(`UPDATE fleet_fleets SET state = ?, worker_count = ?, workers_json = ?, observed_at = ?
		WHERE fleet_id = ?`, state, count, workersJSON, at.UTC().Format(rfc), fleetID)
	return err
}

const fleetCols = `f.fleet_id, f.machine_id, m.endpoint_id, m.hostname, m.os_user, f.name, f.repo,
	f.checkout, f.agent, f.state, f.worker_count, f.workers_json, f.present, f.first_seen, f.observed_at`

func scanFleet(sc interface{ Scan(...any) error }) (FleetRow, error) {
	var r FleetRow
	var present int
	var first, obs string
	err := sc.Scan(&r.FleetID, &r.MachineID, &r.EndpointID, &r.Hostname, &r.OSUser, &r.Name, &r.Repo,
		&r.Checkout, &r.Agent, &r.State, &r.WorkerCount, &r.WorkersJSON, &present, &first, &obs)
	r.Present = present != 0
	r.FirstSeen, _ = time.Parse(rfc, first)
	r.ObservedAt, _ = time.Parse(rfc, obs)
	return r, err
}

// Fleets lists every registered fleet, by host, login, then name.
func (s *Store) Fleets() ([]FleetRow, error) {
	rows, err := s.read.Query(`SELECT ` + fleetCols + `
		  FROM fleet_fleets f JOIN fleet_machines m ON m.machine_id = f.machine_id
		 ORDER BY m.hostname, m.os_user, f.name, f.fleet_id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []FleetRow{}
	for rows.Next() {
		r, err := scanFleet(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

// Fleet reads one registered fleet; sql.ErrNoRows when unknown.
func (s *Store) Fleet(fleetID string) (FleetRow, error) {
	return scanFleet(s.read.QueryRow(`SELECT `+fleetCols+`
		  FROM fleet_fleets f JOIN fleet_machines m ON m.machine_id = f.machine_id
		 WHERE f.fleet_id = ?`, fleetID))
}

// FleetOperation reads one journal row; sql.ErrNoRows when unknown.
func (s *Store) FleetOperation(id string) (FleetOperation, error) {
	var o FleetOperation
	var created, updated string
	var result sql.NullString
	err := s.read.QueryRow(`SELECT id, fleet_id, action, request, actor, idem, status, created, updated, result
		FROM fleet_operations WHERE id = ?`, id).Scan(&o.ID, &o.FleetID, &o.Action, &o.Request, &o.Actor,
		&o.Idem, &o.Status, &created, &updated, &result)
	o.Created, _ = time.Parse(rfc, created)
	o.Updated, _ = time.Parse(rfc, updated)
	o.Result = result.String
	return o, err
}

// InsertFleetOperation journals a new operation. The (actor, idem) pair is
// unique: a retry with the same key finds the first row instead of a second
// side effect. C3 writes through this; C2 only reads the journal.
func (s *Store) InsertFleetOperation(o FleetOperation) error {
	_, err := s.write.Exec(`INSERT INTO fleet_operations
		(id, fleet_id, action, request, actor, idem, status, created, updated, result)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, NULLIF(?, ''))`,
		o.ID, o.FleetID, o.Action, o.Request, o.Actor, o.Idem, o.Status,
		o.Created.UTC().Format(rfc), o.Updated.UTC().Format(rfc), o.Result)
	return err
}

// UpdateFleetOperation records a newer status and result for an operation.
func (s *Store) UpdateFleetOperation(id, status, resultJSON string, at time.Time) error {
	_, err := s.write.Exec(`UPDATE fleet_operations SET status = ?, result = NULLIF(?, ''), updated = ? WHERE id = ?`,
		status, resultJSON, at.UTC().Format(rfc), id)
	return err
}

// FleetAudit records one fleet tool call: who, what, on which fleet, and how
// it ended. Every call is recorded, refusals included.
func (s *Store) FleetAudit(actor, action, fleetID, outcome, operationID string, at time.Time) error {
	_, err := s.write.Exec(`INSERT INTO fleet_audit (actor, action, fleet_id, outcome, operation_id, created)
		VALUES (?, ?, ?, ?, ?, ?)`, actor, action, fleetID, outcome, operationID, at.UTC().Format(rfc))
	return err
}
