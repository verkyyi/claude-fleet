package store

import (
	"crypto/rand"
	"database/sql"
	"errors"
	"fmt"
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

// spareLoginStem starts every spare login: "fl" + six letters and digits.
const spareLoginStem = "fl"

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
// a principal spare:<hostname>:<nonce> under a fresh login fl<6>, and its
// account row pending — dispatchAccounts sends it like any other create.
// valid is the node's login whitelist (a candidate it refuses is skipped).
func (s *Store) CreateSpare(hostname string, valid func(string) bool, at time.Time) (*FleetAccount, error) {
	if hostname == "" {
		return nil, errors.New("empty hostname")
	}
	ts := at.UTC().Format(rfc)
	for i := 0; i < 20; i++ {
		suf, err := randomLowerAlnum(6)
		if err != nil {
			return nil, err
		}
		login := spareLoginStem + suf
		if !valid(login) {
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
				continue // the name is taken somewhere: draw another
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
// to must have no principal row yet — a person already recorded keeps their
// login and is opened the usual way. ErrNoSpare when hostname has none ready.
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
