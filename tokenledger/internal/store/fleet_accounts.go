package store

import (
	"database/sql"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"
)

// Principals and their per-machine OS logins (claude-fleet#1411).
//
// A principal is one person, keyed by the WeCom userid the SSO ticket names
// (its `sub`). Each principal has ONE login name, generated here once and used
// on every machine — so "alice on m4" and "alice on m5" are the same person and
// a client can ssh to either without a lookup. An account row is (principal,
// machine): the hub's record of whether that login exists there yet.
//
// Like the node roster, these tables exist only when the fleet module is on
// (EnsureNodes creates them), so a hub that never turned it on is untouched.
const fleetAccountsSchema = `
CREATE TABLE IF NOT EXISTS fleet_principals (
  principal_id  TEXT PRIMARY KEY,
  login         TEXT NOT NULL UNIQUE,
  display_name  TEXT NOT NULL DEFAULT '',
  created_at    TEXT NOT NULL,
  last_login_at TEXT
);
CREATE TABLE IF NOT EXISTS fleet_accounts (
  principal_id TEXT NOT NULL REFERENCES fleet_principals(principal_id),
  hostname     TEXT NOT NULL,
  login        TEXT NOT NULL,
  state        TEXT NOT NULL,
  op           TEXT NOT NULL DEFAULT 'create',
  op_id        TEXT NOT NULL DEFAULT '',
  endpoint_id  TEXT NOT NULL DEFAULT '',
  detail       TEXT NOT NULL DEFAULT '',
  requested_at TEXT NOT NULL,
  updated_at   TEXT NOT NULL,
  PRIMARY KEY (principal_id, hostname),
  UNIQUE (hostname, login)
);
CREATE INDEX IF NOT EXISTS fleet_accounts_op ON fleet_accounts(op_id);`

// Account states.
//
// An op is recorded BEFORE it is sent (pending → creating/removing), and a
// result is applied by op_id. A link that drops with an op in flight leaves
// the row unknown — never retried on its own, because "did the login get
// made?" has no safe default: the operator retries it, or the node's late
// result (re-sent on reconnect) settles it.
const (
	AccountPending       = "pending"        // create queued, not sent
	AccountCreating      = "creating"       // create sent, no result yet
	AccountActive        = "active"         // the login exists on the machine
	AccountFailed        = "failed"         // the last op failed; detail says why
	AccountUnknown       = "unknown"        // the link dropped with an op in flight
	AccountRemovePending = "remove_pending" // remove queued, not sent
	AccountRemoving      = "removing"       // remove sent, no result yet
	AccountRemoved       = "removed"        // the login was closed
)

// Principal is one person.
type Principal struct {
	ID          string     `json:"principal_id"`
	Login       string     `json:"login"`
	DisplayName string     `json:"display_name"`
	CreatedAt   time.Time  `json:"created_at"`
	LastLoginAt *time.Time `json:"last_login_at,omitempty"`
}

// FleetAccount is one principal's login on one machine.
type FleetAccount struct {
	PrincipalID string    `json:"principal_id"`
	Hostname    string    `json:"hostname"`
	Login       string    `json:"login"`
	State       string    `json:"state"`
	Op          string    `json:"op"`
	OpID        string    `json:"op_id,omitempty"`
	EndpointID  string    `json:"endpoint_id,omitempty"`
	Detail      string    `json:"detail,omitempty"`
	RequestedAt time.Time `json:"requested_at"`
	UpdatedAt   time.Time `json:"updated_at"`
}

// ErrAccountState is returned when an account is not in a state the requested
// change can start from.
var ErrAccountState = errors.New("account is not in a state that allows this")

// ErrNoPrincipal is returned for an unknown principal.
var ErrNoPrincipal = errors.New("no such principal")

func (s *Store) ensureFleetAccounts() error {
	if _, err := s.write.Exec(fleetAccountsSchema); err != nil {
		return fmt.Errorf("create fleet account tables: %w", err)
	}
	// A hub that restarted has no open links, so nothing it sent is still
	// in flight: an op it never heard back on is unknown, not "running".
	now := time.Now().UTC().Format(rfc)
	_, err := s.write.Exec(`UPDATE fleet_accounts SET state = ?, updated_at = ?,
		detail = 'hub restarted before the node answered'
		WHERE state IN (?, ?)`, AccountUnknown, now, AccountCreating, AccountRemoving)
	return err
}

// LoginBase turns a WeCom userid into a login stem: lowercase letters and
// digits only, starting with a letter, at most maxLoginLen.
func LoginBase(userid string, maxLen int) string {
	var b strings.Builder
	for _, c := range strings.ToLower(userid) {
		if (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') {
			b.WriteRune(c)
		}
	}
	s := b.String()
	if s == "" || s[0] < 'a' || s[0] > 'z' {
		s = "u" + s
	}
	if len(s) > maxLen {
		s = s[:maxLen]
	}
	if len(s) < 2 {
		s += "0"
	}
	return s
}

// EnsurePrincipal records a person, minting their login the first time.
//
// valid is the login whitelist the nodes enforce; a candidate it refuses (a
// reserved name) is skipped like a taken one. The login never changes after
// the first call: it is what every machine has, or will have, under that name.
func (s *Store) EnsurePrincipal(id, displayName string, maxLen int, valid func(string) bool, at time.Time) (*Principal, error) {
	if id == "" {
		return nil, errors.New("empty principal id")
	}
	if p, err := s.Principal(id); err == nil {
		_, err := s.write.Exec(`UPDATE fleet_principals SET last_login_at = ?,
			display_name = CASE WHEN ? <> '' THEN ? ELSE display_name END
			WHERE principal_id = ?`, at.UTC().Format(rfc), displayName, displayName, id)
		if err != nil {
			return nil, err
		}
		return s.Principal(p.ID)
	} else if !errors.Is(err, ErrNoPrincipal) {
		return nil, err
	}
	base := LoginBase(id, maxLen)
	for i := 0; i < 100; i++ {
		login := base
		if i > 0 {
			suf := strconv.Itoa(i + 1)
			stem := base
			if len(stem)+len(suf) > maxLen {
				stem = stem[:maxLen-len(suf)]
			}
			login = stem + suf
		}
		if !valid(login) {
			continue
		}
		if err := s.insertPrincipal(id, login, displayName, at); err == nil {
			return s.Principal(id)
		} else if !isUniqueViolation(err) {
			return nil, err
		}
		if p, err := s.Principal(id); err == nil {
			return p, nil // a concurrent first login won the insert
		}
	}
	return nil, fmt.Errorf("no free login for principal %q", id)
}

// AdoptPrincipal records a person whose login already exists somewhere (a
// colleague onboarded by hand before the hub knew them). It refuses to change
// the login of a principal that already has one.
func (s *Store) AdoptPrincipal(id, login, displayName string, at time.Time) (*Principal, error) {
	p, err := s.Principal(id)
	switch {
	case err == nil:
		if p.Login != login {
			return nil, fmt.Errorf("principal %q already has login %q", id, p.Login)
		}
		return p, nil
	case !errors.Is(err, ErrNoPrincipal):
		return nil, err
	}
	if err := s.insertPrincipal(id, login, displayName, at); err != nil {
		if isUniqueViolation(err) {
			return nil, fmt.Errorf("login %q belongs to another principal", login)
		}
		return nil, err
	}
	return s.Principal(id)
}

func (s *Store) insertPrincipal(id, login, displayName string, at time.Time) error {
	ts := at.UTC().Format(rfc)
	_, err := s.write.Exec(`INSERT INTO fleet_principals (principal_id, login, display_name, created_at, last_login_at)
		VALUES (?, ?, ?, ?, ?)`, id, login, displayName, ts, ts)
	return err
}

func isUniqueViolation(err error) bool {
	return err != nil && strings.Contains(err.Error(), "UNIQUE constraint failed")
}

// Principal reads one person.
func (s *Store) Principal(id string) (*Principal, error) {
	var p Principal
	var created string
	var last sql.NullString
	err := s.read.QueryRow(`SELECT principal_id, login, display_name, created_at, last_login_at
		FROM fleet_principals WHERE principal_id = ?`, id).Scan(&p.ID, &p.Login, &p.DisplayName, &created, &last)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNoPrincipal
	}
	if err != nil {
		return nil, err
	}
	p.CreatedAt, _ = time.Parse(rfc, created)
	p.LastLoginAt = parseNullTime(last)
	return &p, nil
}

// Principals lists everyone, by login.
func (s *Store) Principals() ([]Principal, error) {
	rows, err := s.read.Query(`SELECT principal_id, login, display_name, created_at, last_login_at
		FROM fleet_principals ORDER BY login`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Principal{}
	for rows.Next() {
		var p Principal
		var created string
		var last sql.NullString
		if err := rows.Scan(&p.ID, &p.Login, &p.DisplayName, &created, &last); err != nil {
			return nil, err
		}
		p.CreatedAt, _ = time.Parse(rfc, created)
		p.LastLoginAt = parseNullTime(last)
		out = append(out, p)
	}
	return out, rows.Err()
}

const fleetAccountColumns = `SELECT principal_id, hostname, login, state, op, op_id, endpoint_id, detail, requested_at, updated_at FROM fleet_accounts`

func scanFleetAccounts(rows *sql.Rows) ([]FleetAccount, error) {
	defer rows.Close()
	out := []FleetAccount{}
	for rows.Next() {
		var a FleetAccount
		var req, upd string
		if err := rows.Scan(&a.PrincipalID, &a.Hostname, &a.Login, &a.State, &a.Op, &a.OpID,
			&a.EndpointID, &a.Detail, &req, &upd); err != nil {
			return nil, err
		}
		a.RequestedAt, _ = time.Parse(rfc, req)
		a.UpdatedAt, _ = time.Parse(rfc, upd)
		out = append(out, a)
	}
	return out, rows.Err()
}

// FleetAccounts lists accounts; principalID "" means everyone's.
func (s *Store) FleetAccounts(principalID string) ([]FleetAccount, error) {
	q, args := fleetAccountColumns+` ORDER BY principal_id, hostname`, []any{}
	if principalID != "" {
		q, args = fleetAccountColumns+` WHERE principal_id = ? ORDER BY hostname`, []any{principalID}
	}
	rows, err := s.read.Query(q, args...)
	if err != nil {
		return nil, err
	}
	return scanFleetAccounts(rows)
}

// FleetAccountsInState lists every account in one of states, oldest first.
func (s *Store) FleetAccountsInState(states ...string) ([]FleetAccount, error) {
	if len(states) == 0 {
		return []FleetAccount{}, nil
	}
	args := make([]any, len(states))
	for i, st := range states {
		args[i] = st
	}
	rows, err := s.read.Query(fleetAccountColumns+` WHERE state IN (?`+strings.Repeat(",?", len(states)-1)+
		`) ORDER BY requested_at, principal_id, hostname`, args...)
	if err != nil {
		return nil, err
	}
	return scanFleetAccounts(rows)
}

// RequestAccount queues the creation of p's login on hostname. A row that
// already exists is left alone unless retry is set and it ended badly
// (failed / unknown / removed) — so a second assignment never re-runs a
// creation that worked, and a create that may have half-run is re-run only
// on an explicit retry. created reports whether anything was queued.
func (s *Store) RequestAccount(p *Principal, hostname string, retry bool, at time.Time) (created bool, err error) {
	ts := at.UTC().Format(rfc)
	res, err := s.write.Exec(`INSERT INTO fleet_accounts (principal_id, hostname, login, state, op, requested_at, updated_at)
		VALUES (?, ?, ?, ?, 'create', ?, ?) ON CONFLICT(principal_id, hostname) DO NOTHING`,
		p.ID, hostname, p.Login, AccountPending, ts, ts)
	if err != nil {
		if isUniqueViolation(err) {
			return false, fmt.Errorf("login %q is already assigned to someone else on %s", p.Login, hostname)
		}
		return false, err
	}
	if n, _ := res.RowsAffected(); n == 1 {
		return true, nil
	}
	if !retry {
		return false, nil
	}
	res, err = s.write.Exec(`UPDATE fleet_accounts SET state = ?, op = 'create', op_id = '', endpoint_id = '',
		detail = '', requested_at = ?, updated_at = ?
		WHERE principal_id = ? AND hostname = ? AND state IN (?, ?, ?)`,
		AccountPending, ts, ts, p.ID, hostname, AccountFailed, AccountUnknown, AccountRemoved)
	if err != nil {
		return false, err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return false, ErrAccountState
	}
	return true, nil
}

// AdoptAccount records a login that already exists on hostname as active,
// without running anything there.
func (s *Store) AdoptAccount(p *Principal, hostname string, at time.Time) error {
	ts := at.UTC().Format(rfc)
	_, err := s.write.Exec(`INSERT INTO fleet_accounts (principal_id, hostname, login, state, op, detail, requested_at, updated_at)
		VALUES (?, ?, ?, ?, 'adopt', 'adopted: existed before the hub', ?, ?)
		ON CONFLICT(principal_id, hostname) DO UPDATE SET state = excluded.state, op = excluded.op,
		  detail = excluded.detail, op_id = '', updated_at = excluded.updated_at`,
		p.ID, hostname, p.Login, AccountActive, ts, ts)
	if isUniqueViolation(err) {
		return fmt.Errorf("login %q is already assigned to someone else on %s", p.Login, hostname)
	}
	return err
}

// AdoptAccountIfOpen is AdoptAccount for the roster-driven path
// (claude-fleet#1458): it records p's login on hostname as active only when
// the hub holds no row there yet, or a row that never reached the machine
// (pending / failed / removed — a queued create that must now NOT run, a
// create the node refused, a login the operator once closed that an agent
// is nevertheless running as). An op in flight (creating / removing /
// remove_pending), an unknown, and an active row are left exactly as they
// are. adopted reports whether a row was written.
func (s *Store) AdoptAccountIfOpen(p *Principal, hostname string, at time.Time) (adopted bool, err error) {
	ts := at.UTC().Format(rfc)
	res, err := s.write.Exec(`INSERT INTO fleet_accounts (principal_id, hostname, login, state, op, detail, requested_at, updated_at)
		VALUES (?, ?, ?, ?, 'adopt', 'adopted: an agent runs as this login', ?, ?)
		ON CONFLICT(principal_id, hostname) DO UPDATE SET state = excluded.state, op = excluded.op,
		  detail = excluded.detail, op_id = '', endpoint_id = '', updated_at = excluded.updated_at
		  WHERE fleet_accounts.state IN (?, ?, ?)`,
		p.ID, hostname, p.Login, AccountActive, ts, ts, AccountPending, AccountFailed, AccountRemoved)
	if isUniqueViolation(err) {
		return false, fmt.Errorf("login %q is already assigned to someone else on %s", p.Login, hostname)
	}
	if err != nil {
		return false, err
	}
	n, _ := res.RowsAffected()
	return n > 0, nil
}

// ForgetPrincipal drops the hub's record of an account that never reached a
// machine — or, with hostname "", of the person and every such row of theirs
// (claude-fleet#1458: a principal filed under the wrong identity, with a
// create still queued for a node that never connected). It runs nothing and
// sends nothing. Any row in another state refuses the whole call with
// ErrAccountState: an active login is removed, not forgotten; an op in
// flight or unknown is settled first.
func (s *Store) ForgetPrincipal(principalID, hostname string) error {
	if principalID == "" {
		return errors.New("empty principal id")
	}
	tx, err := s.write.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	q, args := `SELECT hostname, state FROM fleet_accounts WHERE principal_id = ?`, []any{principalID}
	if hostname != "" {
		q, args = q+` AND hostname = ?`, append(args, hostname)
	}
	rows, err := tx.Query(q, args...)
	if err != nil {
		return err
	}
	found := 0
	for rows.Next() {
		var h, st string
		if err := rows.Scan(&h, &st); err != nil {
			rows.Close()
			return err
		}
		found++
		switch st {
		case AccountPending, AccountFailed, AccountRemoved:
		default:
			rows.Close()
			return fmt.Errorf("%w: login on %s is %s", ErrAccountState, h, st)
		}
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return err
	}
	if hostname != "" {
		if found == 0 {
			return fmt.Errorf("%w: no account on %s", ErrAccountState, hostname)
		}
		if _, err := tx.Exec(`DELETE FROM fleet_accounts WHERE principal_id = ? AND hostname = ?`, principalID, hostname); err != nil {
			return err
		}
		return tx.Commit()
	}
	if _, err := tx.Exec(`DELETE FROM fleet_accounts WHERE principal_id = ?`, principalID); err != nil {
		return err
	}
	res, err := tx.Exec(`DELETE FROM fleet_principals WHERE principal_id = ?`, principalID)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrNoPrincipal
	}
	return tx.Commit()
}

// RequestAccountRemoval queues closing p's login on hostname.
func (s *Store) RequestAccountRemoval(principalID, hostname string, at time.Time) error {
	ts := at.UTC().Format(rfc)
	res, err := s.write.Exec(`UPDATE fleet_accounts SET state = ?, op = 'remove', op_id = '', endpoint_id = '',
		detail = '', requested_at = ?, updated_at = ?
		WHERE principal_id = ? AND hostname = ? AND state IN (?, ?, ?)`,
		AccountRemovePending, ts, ts, principalID, hostname, AccountActive, AccountFailed, AccountUnknown)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrAccountState
	}
	return nil
}

// MarkAccountSent records that an op left (or is about to leave) for a node:
// written BEFORE the send, so a hub that dies mid-send restarts into unknown,
// never into a silent pending that would run the op a second time.
func (s *Store) MarkAccountSent(principalID, hostname, fromState, toState, opID, endpointID string, at time.Time) (bool, error) {
	res, err := s.write.Exec(`UPDATE fleet_accounts SET state = ?, op_id = ?, endpoint_id = ?, detail = '', updated_at = ?
		WHERE principal_id = ? AND hostname = ? AND state = ?`,
		toState, opID, endpointID, at.UTC().Format(rfc), principalID, hostname, fromState)
	if err != nil {
		return false, err
	}
	n, _ := res.RowsAffected()
	return n == 1, nil
}

// RevertAccountSent puts an op that provably never left the hub back in the
// queue.
func (s *Store) RevertAccountSent(opID, toState, detail string, at time.Time) error {
	_, err := s.write.Exec(`UPDATE fleet_accounts SET state = ?, op_id = '', endpoint_id = '', detail = ?, updated_at = ?
		WHERE op_id = ?`, toState, detail, at.UTC().Format(rfc), opID)
	return err
}

// AccountByOp reads the account an op_id was sent for.
func (s *Store) AccountByOp(opID string) (*FleetAccount, error) {
	rows, err := s.read.Query(fleetAccountColumns+` WHERE op_id = ? AND op_id <> ''`, opID)
	if err != nil {
		return nil, err
	}
	out, err := scanFleetAccounts(rows)
	if err != nil {
		return nil, err
	}
	if len(out) == 0 {
		return nil, sql.ErrNoRows
	}
	return &out[0], nil
}

// FinishAccountOp applies a node's result to the op it answers. It matches the
// op_id only, and only while the row is still waiting for it (in flight or
// unknown): a duplicate or stale result changes nothing. applied reports
// whether a row moved.
//
// endpointID must be the node the op was sent to: an answer from any other
// connection is not an answer.
func (s *Store) FinishAccountOp(opID, endpointID, state, detail string, at time.Time) (applied bool, err error) {
	if opID == "" {
		return false, nil
	}
	res, err := s.write.Exec(`UPDATE fleet_accounts SET state = ?, detail = ?, updated_at = ?
		WHERE op_id = ? AND endpoint_id = ? AND state IN (?, ?, ?)`,
		state, detail, at.UTC().Format(rfc), opID, endpointID, AccountCreating, AccountRemoving, AccountUnknown)
	if err != nil {
		return false, err
	}
	n, _ := res.RowsAffected()
	return n > 0, nil
}

// LoseAccountOps marks every op in flight through endpointID unknown: its link
// is gone and nobody can say whether the op ran.
func (s *Store) LoseAccountOps(endpointID string, at time.Time) error {
	_, err := s.write.Exec(`UPDATE fleet_accounts SET state = ?, detail = 'control channel closed before the node answered',
		updated_at = ? WHERE endpoint_id = ? AND state IN (?, ?)`,
		AccountUnknown, at.UTC().Format(rfc), endpointID, AccountCreating, AccountRemoving)
	return err
}
