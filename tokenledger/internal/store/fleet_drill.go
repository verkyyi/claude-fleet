package store

import (
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"
)

// A drill person (claude-fleet#2010) is the stand-in colleague an onboarding
// drill (bin/fleet-onboard-drill.sh) confirms its scan as — never the operator
// signed in on the browser. An admin mints one with a short life; the hub hands
// back a one-time approve code that confirms ONE device login as that person.
// It is an ordinary principal (fleet_principals + one adopted account on the
// drill machine, so a certificate can be signed for it) plus this row, which
// is what makes it a drill: no credentials, no session passes, and it can
// delete itself. When the row expires the sweep deletes the person, its
// devices and its nodes — a drill never leaves anyone behind on the hub.
const fleetDrillSchema = `
CREATE TABLE IF NOT EXISTS fleet_drill_people (
  principal_id TEXT PRIMARY KEY,
  login        TEXT NOT NULL,
  hostname     TEXT NOT NULL,
  code_hash    TEXT NOT NULL UNIQUE,
  created_by   TEXT NOT NULL DEFAULT '',
  created_at   INTEGER NOT NULL,
  expires_at   INTEGER NOT NULL,
  used_at      INTEGER NOT NULL DEFAULT 0
);`

// DrillKind is the kind a drill person reports.
const DrillKind = "drill"

// ErrDrillCode: the approve code is unknown, already used or expired.
var ErrDrillCode = errors.New("approve code unknown, used or expired")

// DrillPerson is one drill person.
type DrillPerson struct {
	PrincipalID string    `json:"person_id"`
	Login       string    `json:"login"`
	Hostname    string    `json:"hostname"`
	CodeHash    string    `json:"-"`
	CreatedBy   string    `json:"created_by,omitempty"`
	CreatedAt   time.Time `json:"created_at"`
	ExpiresAt   time.Time `json:"expires_at"`
	UsedAt      time.Time `json:"used_at,omitempty"`
}

// DrillDeleted is what DeleteDrill took off the hub.
type DrillDeleted struct {
	PrincipalID string   `json:"person_id"`
	Devices     int      `json:"devices"`
	Accounts    int      `json:"accounts"`
	Nodes       []string `json:"nodes"`

	// LeftForOperator is every login@machine the hub opened for it that is
	// still on its machine, handed to the operator (claude-fleet#2728): its
	// account row — and so the person row it points at — is kept, so
	// `fleet hub accounts` lists it until the operator closes and forgets it.
	LeftForOperator []string `json:"left_for_operator,omitempty"`
}

func (s *Store) ensureFleetDrill() error {
	if _, err := s.write.Exec(s.d.ddl(fleetDrillSchema)); err != nil {
		return fmt.Errorf("create fleet_drill_people table: %w", err)
	}
	return nil
}

// CreateDrill records the person, its one account (login on hostname, active
// — the drill's own throwaway OS login) and the drill row, in one transaction.
func (s *Store) CreateDrill(d DrillPerson) error {
	if d.PrincipalID == "" || d.Login == "" || d.Hostname == "" || d.CodeHash == "" {
		return errors.New("drill person: empty field")
	}
	if d.PrincipalID == PoolPrincipal {
		return fmt.Errorf("principal id %q is reserved", d.PrincipalID)
	}
	tx, err := s.write.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	ts := d.CreatedAt.UTC().Format(rfc)
	if _, err := tx.Exec(`INSERT INTO fleet_principals (principal_id, login, display_name, created_at, last_login_at)
		VALUES (?, ?, ?, ?, ?)`, d.PrincipalID, d.Login, "演练同事 "+d.Login, ts, ts); err != nil {
		if isUniqueViolation(err) {
			return fmt.Errorf("login %q belongs to someone already", d.Login)
		}
		return err
	}
	if _, err := tx.Exec(`INSERT INTO fleet_accounts (principal_id, hostname, login, state, op, detail, requested_at, updated_at)
		VALUES (?, ?, ?, ?, ?, 'drill person: the drill''s own login', ?, ?)`,
		d.PrincipalID, d.Hostname, d.Login, AccountActive, AccountOpAdopt, ts, ts); err != nil {
		if isUniqueViolation(err) {
			return fmt.Errorf("login %q is already someone's on %s", d.Login, d.Hostname)
		}
		return err
	}
	if _, err := tx.Exec(`INSERT INTO fleet_drill_people (principal_id, login, hostname, code_hash, created_by, created_at, expires_at)
		VALUES (?, ?, ?, ?, ?, ?, ?)`, d.PrincipalID, d.Login, d.Hostname, d.CodeHash, d.CreatedBy,
		d.CreatedAt.Unix(), d.ExpiresAt.Unix()); err != nil {
		return err
	}
	return tx.Commit()
}

// OwnComputer says a is the drill's own computer — the row CreateDrill
// adopted for the bare login `fleet drill invite` named — never a login the
// hub opened for it (op create, even on the same machine under the same
// name; claude-fleet#2549).
func (d *DrillPerson) OwnComputer(a FleetAccount) bool {
	return d != nil && a.Op == AccountOpAdopt && strings.EqualFold(a.Hostname, d.Hostname) && a.Login == d.Login
}

const drillCols = `principal_id, login, hostname, code_hash, created_by, created_at, expires_at, used_at`

func scanDrill(row interface{ Scan(...any) error }) (*DrillPerson, error) {
	var d DrillPerson
	var c, e, u int64
	if err := row.Scan(&d.PrincipalID, &d.Login, &d.Hostname, &d.CodeHash, &d.CreatedBy, &c, &e, &u); err != nil {
		return nil, err
	}
	d.CreatedAt, d.ExpiresAt = time.Unix(c, 0).UTC(), time.Unix(e, 0).UTC()
	if u > 0 {
		d.UsedAt = time.Unix(u, 0).UTC()
	}
	return &d, nil
}

// Drill reads the drill row of pid; nil, nil when pid is not a drill person.
func (s *Store) Drill(pid string) (*DrillPerson, error) {
	d, err := scanDrill(s.read.QueryRow(`SELECT `+drillCols+` FROM fleet_drill_people
		WHERE `+s.d.eqNocase("principal_id"), pid))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	return d, err
}

// IsDrill reports whether pid is a drill person. A read error counts as one:
// the callers use it to REFUSE something, and refusing is the safe answer.
func (s *Store) IsDrill(pid string) bool {
	d, err := s.Drill(pid)
	return err != nil || d != nil
}

// DrillByCode finds the drill person an approve code belongs to, used or not,
// while it is alive — what DELETE /v1/self accepts before a certificate exists.
func (s *Store) DrillByCode(codeHash string, now time.Time) (*DrillPerson, error) {
	d, err := scanDrill(s.read.QueryRow(`SELECT `+drillCols+` FROM fleet_drill_people
		WHERE code_hash = ? AND expires_at > ?`, codeHash, now.Unix()))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrDrillCode
	}
	return d, err
}

// UseDrillCode spends an approve code: once, and only before it expires.
func (s *Store) UseDrillCode(codeHash string, now time.Time) (*DrillPerson, error) {
	res, err := s.write.Exec(`UPDATE fleet_drill_people SET used_at = ?
		WHERE code_hash = ? AND used_at = 0 AND expires_at > ?`, now.Unix(), codeHash, now.Unix())
	if err != nil {
		return nil, err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return nil, ErrDrillCode
	}
	return s.DrillByCode(codeHash, now)
}

// UnuseDrillCode gives a code back when the confirmation it was spent on
// failed before anything was issued (no certificate, no device).
func (s *Store) UnuseDrillCode(codeHash string) error {
	_, err := s.write.Exec(`UPDATE fleet_drill_people SET used_at = 0 WHERE code_hash = ?`, codeHash)
	return err
}

// ExpiredDrills lists the drill people whose life is over at now.
func (s *Store) ExpiredDrills(now time.Time) ([]DrillPerson, error) {
	rows, err := s.read.Query(`SELECT `+drillCols+` FROM fleet_drill_people WHERE expires_at <= ?`, now.Unix())
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []DrillPerson
	for rows.Next() {
		d, err := scanDrill(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *d)
	}
	return out, rows.Err()
}

// DeleteDrill takes a drill person off the hub: its nodes (every endpoint whose
// agent runs as its login — deleted when it never reported, else retired, and
// its roster row dropped), its devices, its accounts, the person and the drill
// row. Only a drill person: anyone else is refused with ErrNoPrincipal.
//
// keepHosts names the machines whose login the hub could not close and hands
// to the operator (claude-fleet#2728): those account rows stay, marked so in
// their detail, and with them the person row they reference — the drill row,
// its devices and nodes go all the same, so it can no longer sign in.
func (s *Store) DeleteDrill(pid, actor string, now time.Time, keepHosts ...string) (*DrillDeleted, error) {
	d, err := s.Drill(pid)
	if err != nil {
		return nil, err
	}
	if d == nil {
		return nil, ErrNoPrincipal
	}
	out := &DrillDeleted{PrincipalID: d.PrincipalID, Nodes: []string{}}
	// Nodes first, outside the transaction: DeleteEndpoint reads its own
	// footprint, and a retire is the answer when it refuses.
	eps, err := s.endpointsOfLogin(d.Login)
	if err != nil {
		return nil, err
	}
	for _, id := range eps {
		if err := s.DeleteEndpoint(id); err != nil {
			// It has history (or only a roster row is left): retire it.
			if _, err := s.RetireEndpoint(id); err != nil {
				return nil, err
			}
		}
		if _, err := s.write.Exec(`DELETE FROM nodes WHERE endpoint_id = ?`, id); err != nil {
			return nil, err
		}
		out.Nodes = append(out.Nodes, id)
	}
	tx, err := s.write.Begin()
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	devs, err := tx.Query(`SELECT fingerprint FROM fleet_devices WHERE `+s.d.eqNocase("principal_id"), d.PrincipalID)
	if err != nil {
		return nil, err
	}
	var fps []string
	for devs.Next() {
		var fp string
		if err := devs.Scan(&fp); err != nil {
			devs.Close()
			return nil, err
		}
		fps = append(fps, fp)
	}
	devs.Close()
	for _, fp := range fps {
		if _, err := tx.Exec(`DELETE FROM fleet_devices WHERE fingerprint = ?`, fp); err != nil {
			return nil, err
		}
		if _, err := tx.Exec(`INSERT INTO fleet_device_audit (at, action, fingerprint, principal_id, actor, detail)
			VALUES (?, ?, ?, ?, ?, 'drill person deleted')`, now.UTC().Format(rfc), DeviceRevoke, fp, d.PrincipalID, actor); err != nil {
			return nil, err
		}
	}
	out.Devices = len(fps)
	kept := 0
	for _, host := range keepHosts {
		res, err := tx.Exec(`UPDATE fleet_accounts SET detail = ? || detail, updated_at = ?
			WHERE `+s.d.eqNocase("principal_id")+` AND hostname = ?`,
			"drill person deleted ("+actor+"): left for the operator — close it, then forget it. ", now.UTC().Format(rfc), d.PrincipalID, host)
		if err != nil {
			return nil, err
		}
		if n, _ := res.RowsAffected(); n > 0 {
			kept++
		}
	}
	del := `DELETE FROM fleet_accounts WHERE ` + s.d.eqNocase("principal_id")
	args := []any{d.PrincipalID}
	for _, host := range keepHosts {
		del += ` AND hostname <> ?`
		args = append(args, host)
	}
	res, err := tx.Exec(del, args...)
	if err != nil {
		return nil, err
	}
	n, _ := res.RowsAffected()
	out.Accounts = int(n)
	if kept == 0 {
		if _, err := tx.Exec(`DELETE FROM fleet_principals WHERE `+s.d.eqNocase("principal_id"), d.PrincipalID); err != nil {
			return nil, err
		}
	}
	if _, err := tx.Exec(`DELETE FROM fleet_drill_people WHERE principal_id = ?`, d.PrincipalID); err != nil {
		return nil, err
	}
	return out, tx.Commit()
}

// endpointsOfLogin is every live endpoint whose agent runs as login — on the
// enrollment row or on the roster.
func (s *Store) endpointsOfLogin(login string) ([]string, error) {
	rows, err := s.read.Query(`SELECT endpoint_id FROM endpoints WHERE os_user = ? AND retired_at IS NULL
		UNION SELECT endpoint_id FROM nodes WHERE os_user = ?`, login, login)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		out = append(out, id)
	}
	return out, rows.Err()
}
