package store

import (
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
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
  observed_at  TEXT NOT NULL,
  repos_json   TEXT NOT NULL DEFAULT ''
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
);
CREATE TABLE IF NOT EXISTS fleet_settings (
  key     TEXT PRIMARY KEY,
  value   TEXT NOT NULL,
  updated TEXT NOT NULL
);`

// ErrFleetElsewhere is an identity conflict: a heartbeat claims a fleet UUID
// the registry already holds under a different machine. The row is kept as it
// was — a fleet UUID is derived from its machine, so the claim is wrong, not
// the registry.
var ErrFleetElsewhere = errors.New("fleet ID belongs to a different machine")

// FleetReport is one fleet as a heartbeat describes it.
type FleetReport struct {
	FleetID  string
	Name     string
	Repo     string
	Checkout string
	Agent    string
	// Repos is every repo the fleet hosts (claude-fleet#1512), nil when the
	// agent did not say (older than that): readers then use [Repo].
	Repos       []string
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
	Repos       []string // nil = not reported; see HostedRepos
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
	// Placement is why the hub put a worker_start where it did
	// (claude-fleet#1410): the chosen machine and every candidate's verdict,
	// JSON. Empty for an operation that named its fleet.
	Placement string
	// WorkerID is the session a node's call was made for (claude-fleet#1810):
	// the worker_id of a verified worker assertion, "" for everyone else.
	WorkerID string
}

// fleetStateUnknown is control.FleetStateUnknown (claude-fleet#1465): a fleet
// whose fleet_status read failed on its node, sent with no window list. That
// is "could not read", never "no windows" (claude-fleet#1795): the stored list
// stays the last one read, so fleet_sessions does not drop every row of that
// machine for the seconds a read times out — the sidebar on every client
// collapsed to the one row it was standing on, then came back. The machine's
// count still reads unknown off the state.
const fleetStateUnknown = "unknown"

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
			                          worker_count, workers_json, present, first_seen, observed_at, repos_json)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?)
			ON CONFLICT(fleet_id) DO UPDATE SET name = excluded.name, repo = excluded.repo,
			  checkout = excluded.checkout, agent = excluded.agent, state = excluded.state,
			  worker_count = excluded.worker_count,
			  workers_json = CASE WHEN excluded.state = '`+fleetStateUnknown+`' THEN fleet_fleets.workers_json
			                      ELSE excluded.workers_json END,
			  present = 1, observed_at = excluded.observed_at, repos_json = excluded.repos_json`,
			f.FleetID, machineID, f.Name, f.Repo, f.Checkout, f.Agent, f.State,
			f.WorkerCount, workers, ts, ts, reposJSON(f.Repos)); err != nil {
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
	f.checkout, f.agent, f.state, f.worker_count, f.workers_json, f.present, f.first_seen, f.observed_at,
	f.repos_json`

// reposJSON stores a fleet's repo list: "" when the agent sent none, so a
// row from an older agent stays distinguishable from a reported list.
func reposJSON(repos []string) string {
	if len(repos) == 0 {
		return ""
	}
	b, _ := json.Marshal(repos)
	return string(b)
}

// HostedRepos is every repo the fleet hosts: the reported list, else its
// one repo (an agent older than claude-fleet#1512), else none.
func (r FleetRow) HostedRepos() []string {
	if len(r.Repos) > 0 {
		return r.Repos
	}
	if r.Repo == "" {
		return nil
	}
	return []string{r.Repo}
}

func scanFleet(sc interface{ Scan(...any) error }) (FleetRow, error) {
	var r FleetRow
	var present int
	var first, obs, repos string
	err := sc.Scan(&r.FleetID, &r.MachineID, &r.EndpointID, &r.Hostname, &r.OSUser, &r.Name, &r.Repo,
		&r.Checkout, &r.Agent, &r.State, &r.WorkerCount, &r.WorkersJSON, &present, &first, &obs, &repos)
	if repos != "" {
		_ = json.Unmarshal([]byte(repos), &r.Repos)
	}
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
	return scanFleetOperation(s.read.QueryRow(`SELECT `+fleetOpCols+` FROM fleet_operations WHERE id = ?`, id))
}

// FleetOperationByIdem reads the operation actor journalled under idem;
// sql.ErrNoRows when that key is unused.
func (s *Store) FleetOperationByIdem(actor, idem string) (FleetOperation, error) {
	return scanFleetOperation(s.write.QueryRow(`SELECT `+fleetOpCols+` FROM fleet_operations
		WHERE actor = ? AND idem = ?`, actor, idem))
}

const fleetOpCols = `id, fleet_id, action, request, actor, idem, status, created, updated, result, placement, worker_id`

func scanFleetOperation(row *sql.Row) (FleetOperation, error) {
	var o FleetOperation
	var created, updated string
	var result sql.NullString
	err := row.Scan(&o.ID, &o.FleetID, &o.Action, &o.Request, &o.Actor,
		&o.Idem, &o.Status, &created, &updated, &result, &o.Placement, &o.WorkerID)
	o.Created, _ = time.Parse(rfc, created)
	o.Updated, _ = time.Parse(rfc, updated)
	o.Result = result.String
	return o, err
}

// ErrIdemTaken is InsertFleetOperation losing a race: another call by the
// same actor journalled the same idempotency key first.
var ErrIdemTaken = errors.New("idempotency key already journalled")

// InsertFleetOperation journals a new operation. The (actor, idem) pair is
// unique: a retry with the same key finds the first row instead of a second
// side effect. C3 writes through this; C2 only reads the journal.
//
// The insert is ON CONFLICT DO NOTHING on (actor, idem): a concurrent retry
// that loses gets ErrIdemTaken and reads the winner's row, so two calls with
// one key never both reach a node.
func (s *Store) InsertFleetOperation(o FleetOperation) error {
	res, err := s.write.Exec(`INSERT INTO fleet_operations
		(id, fleet_id, action, request, actor, idem, status, created, updated, result, placement, worker_id)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, NULLIF(?, ''), ?, ?)
		ON CONFLICT(actor, idem) DO NOTHING`,
		o.ID, o.FleetID, o.Action, o.Request, o.Actor, o.Idem, o.Status,
		o.Created.UTC().Format(rfc), o.Updated.UTC().Format(rfc), o.Result, o.Placement, o.WorkerID)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrIdemTaken
	}
	return nil
}

// UpdateFleetOperation records a newer status and result for an operation.
func (s *Store) UpdateFleetOperation(id, status, resultJSON string, at time.Time) error {
	_, err := s.write.Exec(`UPDATE fleet_operations SET status = ?, result = NULLIF(?, ''), updated = ? WHERE id = ?`,
		status, resultJSON, at.UTC().Format(rfc), id)
	return err
}

// ensureFleetColumns adds the columns later issues gave the fleet tables to a
// database created before them. Additive only.
func (s *Store) ensureFleetColumns() error {
	if err := s.addColumn("fleet_operations", "placement", "TEXT NOT NULL DEFAULT ''"); err != nil {
		return err
	}
	// claude-fleet#1512: every repo a fleet hosts, "" = the agent did not say.
	if err := s.addColumn("fleet_fleets", "repos_json", "TEXT NOT NULL DEFAULT ''"); err != nil {
		return err
	}
	// claude-fleet#1810: the session a node's call was made for (a verified
	// worker assertion) — in the journal and in the audit.
	for _, c := range []struct{ table, col string }{
		{"fleet_operations", "worker_id"}, {"fleet_audit", "worker_id"}, {"fleet_audit", "worker_key"},
	} {
		if err := s.addColumn(c.table, c.col, "TEXT NOT NULL DEFAULT ''"); err != nil {
			return err
		}
	}
	return nil
}

// addColumn adds table.col (spec, in SQLite's spelling) to a database created
// before it. Additive only; a column already there is left as it is.
func (s *Store) addColumn(table, col, spec string) error {
	has, err := hasColumn(s.write, table, col)
	if err != nil || has {
		return err
	}
	if _, err := s.write.Exec(s.d.ddl(`ALTER TABLE ` + table + ` ADD COLUMN ` + col + ` ` + spec)); err != nil {
		return fmt.Errorf("add %s.%s: %w", table, col, err)
	}
	return nil
}

// FleetSettings returns the hub's fleet settings (claude-fleet#1410), key →
// value. Only keys someone set are here; defaults live with their readers.
func (s *Store) FleetSettings() (map[string]string, error) {
	rows, err := s.read.Query(`SELECT key, value FROM fleet_settings`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[string]string{}
	for rows.Next() {
		var k, v string
		if err := rows.Scan(&k, &v); err != nil {
			return nil, err
		}
		out[k] = v
	}
	return out, rows.Err()
}

// SetFleetSetting stores one setting; an empty value deletes it, so the
// default applies again.
func (s *Store) SetFleetSetting(key, value string, at time.Time) error {
	if value == "" {
		_, err := s.write.Exec(`DELETE FROM fleet_settings WHERE key = ?`, key)
		return err
	}
	_, err := s.write.Exec(`INSERT INTO fleet_settings (key, value, updated) VALUES (?, ?, ?)
		ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated = excluded.updated`,
		key, value, at.UTC().Format(rfc))
	return err
}

// FleetAudit records one fleet tool call: who, what, on which fleet, and how
// it ended. Every call is recorded, refusals included.
func (s *Store) FleetAudit(actor, action, fleetID, outcome, operationID string, at time.Time) error {
	return s.FleetAuditWorker(actor, "", "", action, fleetID, outcome, operationID, at)
}

// FleetAuditWorker is FleetAudit for a node's call made for one of its
// sessions (claude-fleet#1810): workerID is the verified worker_id
// (<fleet UUID>/<fleet_id>), workerKey the key it had (issue-N), both "" for
// a call that named no session.
func (s *Store) FleetAuditWorker(actor, workerID, workerKey, action, fleetID, outcome, operationID string, at time.Time) error {
	_, err := s.write.Exec(`INSERT INTO fleet_audit (actor, worker_id, worker_key, action, fleet_id, outcome, operation_id, created)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?)`, actor, workerID, workerKey, action, fleetID, outcome, operationID, at.UTC().Format(rfc))
	return err
}

// FleetAuditEntry is one fleet_audit row, as the admin Audit page reads it
// (claude-fleet#1990).
type FleetAuditEntry struct {
	ID          int64     `json:"id"`
	Created     time.Time `json:"created"`
	Actor       string    `json:"actor"`
	WorkerKey   string    `json:"worker_key,omitempty"`
	Action      string    `json:"action"`
	FleetID     string    `json:"fleet_id"`
	Outcome     string    `json:"outcome"`
	OperationID string    `json:"operation_id,omitempty"`
}

// FleetAuditLog is the newest fleet_audit rows, newest first (limit ≤ 0 =
// 200), leaving out the actions skip names — the read tools, which a page
// polling the fleet writes a row for every half minute.
func (s *Store) FleetAuditLog(limit int, skip ...string) ([]FleetAuditEntry, error) {
	if limit <= 0 {
		limit = 200
	}
	q := `SELECT id, created, actor, worker_key, action, fleet_id, outcome, operation_id FROM fleet_audit`
	args := []any{}
	if len(skip) > 0 {
		q += ` WHERE action NOT IN (?` + strings.Repeat(`, ?`, len(skip)-1) + `)`
		for _, a := range skip {
			args = append(args, a)
		}
	}
	rows, err := s.read.Query(q+` ORDER BY id DESC LIMIT ?`, append(args, limit)...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []FleetAuditEntry{}
	for rows.Next() {
		var e FleetAuditEntry
		var created string
		if err := rows.Scan(&e.ID, &created, &e.Actor, &e.WorkerKey, &e.Action, &e.FleetID, &e.Outcome, &e.OperationID); err != nil {
			return nil, err
		}
		e.Created, _ = time.Parse(rfc, created)
		out = append(out, e)
	}
	return out, rows.Err()
}
