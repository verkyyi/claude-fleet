package store

import (
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"
)

// Recycling a login (claude-fleet#3504, EPIC #3500 C12).
//
// Removing a person's login on a machine that keeps spares washes it for the
// next person instead of deleting the OS user: the row goes reset_pending →
// resetting, the admin node runs the remove script's --recycle mode, and a
// clean, credential-separated answer turns the row into a NEW spare under the
// same login name — a fresh principal spare:<machine>:<nonce>, active, handed
// out like any other. Anything else leaves the person's row failed and the
// login is never handed out. The person's own principal row stays (their other
// machines, their history); hub_audit's spare.recycle line is the record.

// ErrSpareNameHeld is ClaimSpare's answer for a recycled spare whose login a
// person's record still holds as its own name (fleet_principals.login is
// unique): the claimer is recorded first and takes it through ClaimSpareFor.
var ErrSpareNameHeld = errors.New("the spare's login is still a person's recorded name")

// RequestAccountReset queues washing principalID's login on hostname for the
// next person — RequestAccountRemoval's twin, from the same states.
func (s *Store) RequestAccountReset(principalID, hostname string, at time.Time) error {
	ts := at.UTC().Format(rfc)
	res, err := s.write.Exec(`UPDATE fleet_accounts SET state = ?, op = 'reset', op_id = '', endpoint_id = '',
		detail = '', requested_at = ?, updated_at = ?
		WHERE `+s.d.eqNocase("principal_id")+` AND hostname = ? AND state IN (?, ?, ?) AND op <> ?`,
		AccountResetPending, ts, ts, principalID, hostname, AccountActive, AccountFailed, AccountUnknown, AccountOpLogin)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrAccountState
	}
	return nil
}

// ResetToRemove turns a reset still queued into the remove it replaced: the
// machine's admin cannot recycle (an older node), so the login is closed the
// old way. It reports whether the row moved.
func (s *Store) ResetToRemove(principalID, hostname, detail string, at time.Time) (bool, error) {
	res, err := s.write.Exec(`UPDATE fleet_accounts SET state = ?, op = 'remove', detail = ?, updated_at = ?
		WHERE principal_id = ? AND hostname = ? AND state = ?`,
		AccountRemovePending, detail, at.UTC().Format(rfc), principalID, hostname, AccountResetPending)
	if err != nil {
		return false, err
	}
	n, _ := res.RowsAffected()
	return n == 1, nil
}

// RecycleAccount settles a clean reset (op opID, answered by endpointID): in
// one transaction the person's row on that machine goes, and the same login
// is recorded as a new ready spare there — principal spare:<machine>:<nonce>,
// account active — with one hub_audit spare.recycle line. A stale or foreign
// answer moves nothing (applied false). It returns the spare's row and the
// person the login was taken from.
func (s *Store) RecycleAccount(opID, endpointID, actor string, at time.Time) (spare *FleetAccount, from string, applied bool, err error) {
	if opID == "" {
		return nil, "", false, nil
	}
	tx, err := s.write.Begin()
	if err != nil {
		return nil, "", false, err
	}
	defer tx.Rollback()
	if _, err := tx.Exec(s.d.deferForeignKeys()); err != nil {
		return nil, "", false, err
	}
	var host, login, state string
	err = tx.QueryRow(`SELECT principal_id, hostname, login, state FROM fleet_accounts
		WHERE op_id = ? AND endpoint_id = ? AND op = 'reset' AND state IN (?, ?)`,
		opID, endpointID, AccountResetting, AccountUnknown).Scan(&from, &host, &login, &state)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, "", false, nil
	}
	if err != nil {
		return nil, "", false, err
	}
	nonce, err := randomLowerAlnum(8)
	if err != nil {
		return nil, "", false, err
	}
	id := SparePrefix + strings.ToLower(host) + ":" + nonce
	// The spare's record carries the login as its name unless a person's
	// record still holds it (theirs is unique); then a name no node would
	// ever make, and a claimer is recorded first (ErrSpareNameHeld).
	name := login
	var held int
	if err := tx.QueryRow(`SELECT COUNT(*) FROM fleet_principals WHERE login = ?`, login).Scan(&held); err != nil {
		return nil, "", false, err
	}
	if held > 0 {
		name = "spare." + nonce
	}
	ts := at.UTC().Format(rfc)
	if _, err := tx.Exec(`DELETE FROM fleet_accounts WHERE principal_id = ? AND hostname = ?`, from, host); err != nil {
		return nil, "", false, err
	}
	if _, err := tx.Exec(`INSERT INTO fleet_principals (principal_id, login, display_name, created_at)
		VALUES (?, ?, ?, ?)`, id, name, SpareFullName, ts); err != nil {
		return nil, "", false, err
	}
	detail := "spare: recycled from " + from
	if _, err := tx.Exec(`INSERT INTO fleet_accounts (principal_id, hostname, login, state, op, op_id, endpoint_id, detail, requested_at, updated_at)
		VALUES (?, ?, ?, ?, 'create', ?, ?, ?, ?, ?)`,
		id, host, login, AccountActive, opID, endpointID, detail, ts, ts); err != nil {
		return nil, "", false, err
	}
	if _, err := tx.Exec(`INSERT INTO hub_audit (created, actor, action, target, outcome, detail)
		VALUES (?, ?, 'spare.recycle', ?, 'ok', ?)`, ts, actor, login,
		fmt.Sprintf("%s on %s: %s → %s %s", from, host, state, id, AccountActive)); err != nil {
		return nil, "", false, err
	}
	if err := tx.Commit(); err != nil {
		return nil, "", false, err
	}
	return &FleetAccount{PrincipalID: id, Hostname: host, Login: login, State: AccountActive, Op: "create",
		OpID: opID, EndpointID: endpointID, Detail: detail, RequestedAt: at.UTC(), UpdatedAt: at.UTC()}, from, true, nil
}
