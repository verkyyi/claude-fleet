package store

import (
	"crypto/rand"
	"database/sql"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"
)

// Spare logins (claude-fleet#2263, EPIC #2259 C4).
//
// A spare is a login opened on a machine BEFORE anyone needs it, so a
// newcomer's first sign-in finds one ready instead of waiting a minute for
// useradd + the fleet's install. It is an ordinary principal + account row
// whose principal id carries SparePrefix: the create op runs exactly as a
// person's does (fleet-login-new.sh, same rails, same states). Claiming one is
// record-only — the spare's principal row and its account are re-keyed to the
// person in one transaction, nothing is sent to the machine — so the person's
// login on every machine is the spare's name from then on.
//
// A spare is nobody: Principals leaves it out, so it is in no people list,
// budget or usage view; the operator sees it as a count per machine.

// SparePrefix marks a spare login's principal id: spare:<machine>:<nonce>.
const SparePrefix = "spare:"

// SpareFullName is the display name a spare is opened under.
const SpareFullName = "fleet spare"

// spareLoginStem starts every spare login: fleetu1, fleetu2, … — a name a
// person reads, kept for good once the spare is theirs (never renamed).
const spareLoginStem = "fleetu"

// IsSparePrincipal says id is a spare login's principal, not a person.
func IsSparePrincipal(id string) bool {
	return len(id) >= len(SparePrefix) && strings.EqualFold(id[:len(SparePrefix)], SparePrefix)
}

// spareLikePattern matches every spare principal id in SQL.
const spareLikePattern = SparePrefix + "%"

// ErrNoSpare is returned when a machine holds no ready spare to claim.
var ErrNoSpare = errors.New("no ready spare login on this machine")

func randomLowerAlnum(n int) (string, error) {
	const alpha = "abcdefghijklmnopqrstuvwxyz0123456789"
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	for i := range b {
		b[i] = alpha[int(b[i])%len(alpha)]
	}
	return string(b), nil
}

// CreateSpare records a new spare on hostname and queues its creation there:
// a principal spare:<hostname>:<nonce> under the next free login fleetu<N>,
// and its account row pending — dispatchAccounts sends it like any other
// create. valid is the node's login whitelist (a candidate it refuses is
// skipped).
func (s *Store) CreateSpare(hostname string, valid func(string) bool, at time.Time) (*FleetAccount, error) {
	if hostname == "" {
		return nil, errors.New("empty hostname")
	}
	ts := at.UTC().Format(rfc)
	var n int
	if err := s.read.QueryRow(`SELECT COUNT(*) FROM fleet_principals WHERE login LIKE ?`, spareLoginStem+"%").Scan(&n); err != nil {
		return nil, err
	}
	for i := 1; i <= 200; i++ {
		login := spareLoginStem + strconv.Itoa(n+i)
		if !valid(login) {
			continue
		}
		// A spare a recorded person claimed (ClaimSpareFor) keeps its name
		// on an account row with no principal row of its own: the name is
		// still taken, on every machine (claude-fleet#3501).
		var held int
		if err := s.read.QueryRow(`SELECT COUNT(*) FROM fleet_accounts WHERE login = ?`, login).Scan(&held); err != nil {
			return nil, err
		}
		if held > 0 {
			continue
		}
		nonce, err := randomLowerAlnum(8)
		if err != nil {
			return nil, err
		}
		id := SparePrefix + strings.ToLower(hostname) + ":" + nonce
		tx, err := s.write.Begin()
		if err != nil {
			return nil, err
		}
		_, err = tx.Exec(`INSERT INTO fleet_principals (principal_id, login, display_name, created_at)
			VALUES (?, ?, ?, ?)`, id, login, SpareFullName, ts)
		if err == nil {
			_, err = tx.Exec(`INSERT INTO fleet_accounts (principal_id, hostname, login, state, op, detail, requested_at, updated_at)
				VALUES (?, ?, ?, ?, 'create', 'spare: opened ahead of a newcomer', ?, ?)`,
				id, hostname, login, AccountPending, ts, ts)
		}
		if err != nil {
			tx.Rollback()
			if isUniqueViolation(err) {
				continue // the name is taken somewhere: the next one
			}
			return nil, err
		}
		if err := tx.Commit(); err != nil {
			return nil, err
		}
		return &FleetAccount{PrincipalID: id, Hostname: hostname, Login: login, State: AccountPending,
			Op: "create", RequestedAt: at.UTC(), UpdatedAt: at.UTC()}, nil
	}
	return nil, errors.New("no free spare login name")
}

// SpareAccounts lists every spare's account row, oldest first.
func (s *Store) SpareAccounts() ([]FleetAccount, error) {
	rows, err := s.read.Query(fleetAccountColumns+` WHERE principal_id LIKE ? ORDER BY requested_at, hostname`, spareLikePattern)
	if err != nil {
		return nil, err
	}
	return scanFleetAccounts(rows)
}

// ClaimSpare hands the oldest ready (active) spare on hostname to the person
// to: its principal row becomes theirs (display name set), its account row
// with it, and one hub_audit line says so. Record-only, in one transaction.
// to must have no principal row yet — a person already recorded takes a
// spare through ClaimSpareFor (claude-fleet#3501). ErrNoSpare when hostname
// has none ready.
func (s *Store) ClaimSpare(hostname, to, displayName, actor string, at time.Time) (*FleetAccount, error) {
	to = strings.TrimSpace(to)
	if to == "" || IsSparePrincipal(to) || to == PoolPrincipal {
		return nil, fmt.Errorf("principal id %q cannot claim a spare", to)
	}
	tx, err := s.write.Begin()
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	if _, err := tx.Exec(s.d.deferForeignKeys()); err != nil {
		return nil, err
	}
	var held string
	switch err := tx.QueryRow(`SELECT login FROM fleet_principals WHERE `+s.d.eqNocase("principal_id"), to).Scan(&held); {
	case err == nil:
		return nil, fmt.Errorf("%w: %s is already recorded with login %s", ErrRekeyTarget, to, held)
	case !errors.Is(err, sql.ErrNoRows):
		return nil, err
	}
	var spareID, login, name string
	err = tx.QueryRow(`SELECT a.principal_id, a.login, p.login FROM fleet_accounts a
		JOIN fleet_principals p ON p.principal_id = a.principal_id
		WHERE a.principal_id LIKE ? AND a.hostname = ? AND a.state = ? AND a.op = 'create'
		ORDER BY a.updated_at, a.principal_id LIMIT 1`, spareLikePattern, hostname, AccountActive).Scan(&spareID, &login, &name)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNoSpare
	}
	if err != nil {
		return nil, err
	}
	if name != login {
		// A recycled spare whose login a person's record still holds
		// (claude-fleet#3504): its record is no name to hand on.
		return nil, ErrSpareNameHeld
	}
	ts := at.UTC().Format(rfc)
	r, err := tx.Exec(`UPDATE fleet_principals SET principal_id = ?, display_name = ?, last_login_at = ?
		WHERE principal_id = ?`, to, displayName, ts, spareID)
	if err != nil {
		return nil, err
	}
	if n, _ := r.RowsAffected(); n != 1 {
		return nil, ErrNoSpare // another sign-in took it first
	}
	if _, err := tx.Exec(`UPDATE fleet_accounts SET principal_id = ?, detail = ?, updated_at = ?
		WHERE principal_id = ?`, to, "spare: claimed at first sign-in", ts, spareID); err != nil {
		return nil, err
	}
	if _, err := tx.Exec(`INSERT INTO hub_audit (created, actor, action, target, outcome, detail)
		VALUES (?, ?, 'spare.claim', ?, 'ok', ?)`, ts, actor, login,
		fmt.Sprintf("%s on %s → %s", spareID, hostname, to)); err != nil {
		return nil, err
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	as, err := s.FleetAccounts(to)
	if err != nil {
		return nil, err
	}
	for i := range as {
		if strings.EqualFold(as[i].Hostname, hostname) {
			return &as[i], nil
		}
	}
	return nil, fmt.Errorf("claimed spare %s on %s but its row is gone", login, hostname)
}

// ClaimSpareFor hands the oldest ready spare on hostname to a person the hub
// already records (claude-fleet#3501): the spare's account row becomes theirs
// — its login (fleetu<N>) kept, so a person's login may differ from one
// machine to the next and every 「this person → their login there」 reads
// fleet_accounts, never fleet_principals.login — the spare's principal row is
// deleted and one hub_audit line says so. Record-only, in one transaction.
//
// A row the person already has on hostname is replaced only when nothing of
// it is on the machine: pending (never sent) or removed. Any other state
// leaves it theirs and answers ErrAccountState. ErrNoPrincipal when to is
// not recorded (ClaimSpare is that road); ErrNoSpare when hostname has none
// ready.
func (s *Store) ClaimSpareFor(hostname, to, actor string, at time.Time) (*FleetAccount, error) {
	to = strings.TrimSpace(to)
	if to == "" || IsSparePrincipal(to) || to == PoolPrincipal {
		return nil, fmt.Errorf("principal id %q cannot claim a spare", to)
	}
	tx, err := s.write.Begin()
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	if _, err := tx.Exec(s.d.deferForeignKeys()); err != nil {
		return nil, err
	}
	var pid string
	switch err := tx.QueryRow(`SELECT principal_id FROM fleet_principals WHERE `+s.d.eqNocase("principal_id"), to).Scan(&pid); {
	case errors.Is(err, sql.ErrNoRows):
		return nil, ErrNoPrincipal
	case err != nil:
		return nil, err
	}
	var held string
	switch err := tx.QueryRow(`SELECT state FROM fleet_accounts WHERE principal_id = ? AND hostname = ?`, pid, hostname).Scan(&held); {
	case errors.Is(err, sql.ErrNoRows):
	case err != nil:
		return nil, err
	case held == AccountPending || held == AccountRemoved:
		if _, err := tx.Exec(`DELETE FROM fleet_accounts WHERE principal_id = ? AND hostname = ?`, pid, hostname); err != nil {
			return nil, err
		}
	default:
		return nil, fmt.Errorf("%w: %s already has a login on %s (%s)", ErrAccountState, pid, hostname, held)
	}
	var spareID, login string
	err = tx.QueryRow(`SELECT principal_id, login FROM fleet_accounts
		WHERE principal_id LIKE ? AND hostname = ? AND state = ? AND op = 'create'
		ORDER BY updated_at, principal_id LIMIT 1`, spareLikePattern, hostname, AccountActive).Scan(&spareID, &login)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNoSpare
	}
	if err != nil {
		return nil, err
	}
	ts := at.UTC().Format(rfc)
	r, err := tx.Exec(`UPDATE fleet_accounts SET principal_id = ?, detail = ?, updated_at = ?
		WHERE principal_id = ? AND hostname = ? AND state = ?`,
		pid, "spare: claimed for a recorded person", ts, spareID, hostname, AccountActive)
	if err != nil {
		return nil, err
	}
	if n, _ := r.RowsAffected(); n != 1 {
		return nil, ErrNoSpare // another claim took it first
	}
	if _, err := tx.Exec(`DELETE FROM fleet_accounts WHERE principal_id = ?`, spareID); err != nil {
		return nil, err
	}
	if _, err := tx.Exec(`DELETE FROM fleet_principals WHERE principal_id = ?`, spareID); err != nil {
		return nil, err
	}
	if _, err := tx.Exec(`INSERT INTO hub_audit (created, actor, action, target, outcome, detail)
		VALUES (?, ?, 'spare.claim', ?, 'ok', ?)`, ts, actor, login,
		fmt.Sprintf("%s on %s → %s", spareID, hostname, pid)); err != nil {
		return nil, err
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	as, err := s.FleetAccounts(pid)
	if err != nil {
		return nil, err
	}
	for i := range as {
		if strings.EqualFold(as[i].Hostname, hostname) {
			return &as[i], nil
		}
	}
	return nil, fmt.Errorf("claimed spare %s on %s but its row is gone", login, hostname)
}
