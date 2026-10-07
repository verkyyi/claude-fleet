package store

import (
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"
)

// Re-keying a person (claude-fleet#2094).
//
// The enterprise-WeChat era recorded people under its own ids (CaoJian,
// YiLiangHui, zx …), and their logins are active on the machines under those
// rows. GitHub sign-in (EPIC #1982) keys a person gh:<id>, and a login has ONE
// principal (fleet_principals.login is UNIQUE), so a GitHub person mapped to
// such a login could never be recorded under it: AdoptPrincipal refused, the
// certificate page said "no active login". RekeyPrincipal moves the old row —
// and everything that names it — to the new id in one transaction. It is
// record-only: no op is queued, no machine is touched, the login keeps its
// name and its state.

// rekeyColumns is every (table, column) that holds a principal id, apart from
// fleet_principals itself and fleet_person_usage (merged, below). A table the
// hub never created (its module off) is skipped.
var rekeyColumns = [][2]string{
	{"fleet_accounts", "principal_id"},
	{"fleet_credentials", "principal_id"},
	{"fleet_cred_audit", "principal_id"},
	{"fleet_cred_revocations", "principal_id"},
	{"fleet_certs", "principal_id"},
	{"fleet_session_creds", "principal_id"},
	{"fleet_session_binds", "owner"},
	{"fleet_devices", "principal_id"},
	{"fleet_device_audit", "principal_id"},
	{"fleet_person_bundles", "principal"},
}

// Setting keys that name a principal: a budget moves with the person; an old
// map entry naming the same login (user.<old id>.machine_login) is dropped —
// the GitHub person's own map is on their hub_users row.
const (
	rekeyBudgetPrefix = "fleet.person_budget."
	rekeyMapKeyPrefix = "user."
	rekeyMapKeySuffix = ".machine_login"
)

// ErrRekeyTarget is returned when the new id already has a principal row.
var ErrRekeyTarget = errors.New("the new principal already has a login")

// RekeyResult is what a re-key moved: rows per table.
type RekeyResult struct {
	From      string           `json:"from"`
	To        string           `json:"to"`
	Login     string           `json:"login"`
	Hosts     []string         `json:"hosts"` // the machines the login is active on
	Moved     map[string]int64 `json:"moved"`
	Principal *Principal       `json:"principal"`
}

// RekeyPrincipal moves principal from — its row, every account, credential,
// certificate, device, session and usage row — to the id to, keeping the
// login. displayName, when set, replaces the row's name. The move is audited
// in hub_audit (actor, from → to, the login) inside the same transaction.
// to must have no principal row of its own (ErrRekeyTarget); from must exist
// (ErrNoPrincipal). Nothing is sent anywhere.
func (s *Store) RekeyPrincipal(from, to, displayName, actor string, at time.Time) (*RekeyResult, error) {
	from, to = strings.TrimSpace(from), strings.TrimSpace(to)
	if from == "" || to == "" {
		return nil, errors.New("rekey needs both principal ids")
	}
	if from == PoolPrincipal || to == PoolPrincipal {
		return nil, fmt.Errorf("principal id %q is reserved for shared-pool credentials", PoolPrincipal)
	}
	if strings.EqualFold(from, to) {
		return nil, errors.New("rekey: the two principal ids are the same person")
	}
	if s.IsDrill(from) || s.IsDrill(to) {
		return nil, errors.New("rekey: a drill person is not re-keyed — delete the drill instead")
	}
	tx, err := s.write.Begin()
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	// fleet_accounts references fleet_principals; the parent and its children
	// change together, so the check waits for the commit.
	if _, err := tx.Exec(s.d.deferForeignKeys()); err != nil {
		return nil, err
	}
	var oldID, login string
	err = tx.QueryRow(`SELECT principal_id, login FROM fleet_principals WHERE `+s.d.eqNocase("principal_id"), from).
		Scan(&oldID, &login)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil, ErrNoPrincipal
		}
		return nil, err
	}
	var held string
	switch err := tx.QueryRow(`SELECT login FROM fleet_principals WHERE `+s.d.eqNocase("principal_id"), to).Scan(&held); {
	case err == nil:
		return nil, fmt.Errorf("%w: %s is already recorded with login %s — forget that row first", ErrRekeyTarget, to, held)
	case !errors.Is(err, sql.ErrNoRows):
		return nil, err
	}
	res := &RekeyResult{From: oldID, To: to, Login: login, Hosts: []string{}, Moved: map[string]int64{}}
	rows, err := tx.Query(`SELECT hostname FROM fleet_accounts WHERE principal_id = ? AND state = ? ORDER BY hostname`,
		oldID, AccountActive)
	if err != nil {
		return nil, err
	}
	for rows.Next() {
		var h string
		if err := rows.Scan(&h); err != nil {
			rows.Close()
			return nil, err
		}
		res.Hosts = append(res.Hosts, h)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}
	have := map[string]bool{}
	names, err := s.d.tables(tx)
	if err != nil {
		return nil, err
	}
	for _, n := range names {
		have[n] = true
	}

	r, err := tx.Exec(`UPDATE fleet_principals SET principal_id = ?,
		display_name = CASE WHEN ? <> '' THEN ? ELSE display_name END
		WHERE principal_id = ?`, to, displayName, displayName, oldID)
	if err != nil {
		return nil, err
	}
	res.Moved["fleet_principals"], _ = r.RowsAffected()
	for _, tc := range rekeyColumns {
		if !have[tc[0]] {
			continue
		}
		r, err := tx.Exec(`UPDATE `+tc[0]+` SET `+tc[1]+` = ? WHERE `+s.d.eqNocase(tc[1]), to, oldID)
		if err != nil {
			return nil, fmt.Errorf("rekey %s: %w", tc[0], err)
		}
		if n, _ := r.RowsAffected(); n > 0 {
			res.Moved[tc[0]] = n
		}
	}
	if have["fleet_person_usage"] {
		// Usage buckets add up: the person's tokens in a window are theirs
		// under either id.
		if _, err := tx.Exec(`INSERT INTO fleet_person_usage (principal, provider, bucket, tokens, requests)
			SELECT ?, provider, bucket, tokens, requests FROM fleet_person_usage WHERE `+s.d.eqNocase("principal")+`
			ON CONFLICT(principal, provider, bucket) DO UPDATE SET
			  tokens = fleet_person_usage.tokens + excluded.tokens, requests = fleet_person_usage.requests + excluded.requests`, to, oldID); err != nil {
			return nil, fmt.Errorf("rekey fleet_person_usage: %w", err)
		}
		r, err := tx.Exec(`DELETE FROM fleet_person_usage WHERE `+s.d.eqNocase("principal"), oldID)
		if err != nil {
			return nil, err
		}
		if n, _ := r.RowsAffected(); n > 0 {
			res.Moved["fleet_person_usage"] = n
		}
	}
	if have["fleet_settings"] {
		var budget string
		err := tx.QueryRow(`SELECT value FROM fleet_settings WHERE `+s.d.eqNocase("key"), rekeyBudgetPrefix+oldID).Scan(&budget)
		if err == nil {
			if _, err := tx.Exec(`DELETE FROM fleet_settings WHERE `+s.d.eqNocase("key"), rekeyBudgetPrefix+oldID); err != nil {
				return nil, err
			}
			if _, err := tx.Exec(`INSERT INTO fleet_settings (key, value, updated) VALUES (?, ?, ?)
				ON CONFLICT(key) DO NOTHING`, rekeyBudgetPrefix+to, budget, at.UTC().Format(rfc)); err != nil {
				return nil, err
			}
			res.Moved["fleet_settings"]++
		} else if !errors.Is(err, sql.ErrNoRows) {
			return nil, err
		}
		r, err := tx.Exec(`DELETE FROM fleet_settings WHERE `+s.d.eqNocase("key")+` AND value = ?`,
			rekeyMapKeyPrefix+oldID+rekeyMapKeySuffix, login)
		if err != nil {
			return nil, err
		}
		if n, _ := r.RowsAffected(); n > 0 {
			res.Moved["fleet_settings"] += n
		}
	}
	detail := fmt.Sprintf("%s → %s, login %s", oldID, to, login)
	if len(res.Hosts) > 0 {
		detail += " (active on " + strings.Join(res.Hosts, ", ") + ")"
	}
	if _, err := tx.Exec(`INSERT INTO hub_audit (created, actor, action, target, outcome, detail)
		VALUES (?, ?, 'principal.rekey', ?, 'ok', ?)`, at.UTC().Format(rfc), actor, login, detail); err != nil {
		return nil, err
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	p, err := s.Principal(to)
	if err != nil {
		return nil, err
	}
	res.Principal = p
	return res, nil
}

// PrincipalByLogin is the person whose login this is, ErrNoPrincipal when nobody's.
func (s *Store) PrincipalByLogin(login string) (*Principal, error) {
	var id string
	err := s.read.QueryRow(`SELECT principal_id FROM fleet_principals WHERE login = ?`, login).Scan(&id)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil, ErrNoPrincipal
		}
		return nil, err
	}
	return s.Principal(id)
}
