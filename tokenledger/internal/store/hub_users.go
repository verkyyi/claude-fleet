package store

import (
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"
)

// The people who may sign in with GitHub (claude-fleet#1984). See the
// hub_users / hub_user_names / hub_audit tables in schema.sql.

// Hub roles. The deploy names the admins; an admin adds users on the web.
const (
	RoleAdmin = "admin"
	RoleUser  = "user"
)

// HubUser is one person on the list.
type HubUser struct {
	GitHubID     int64      `json:"github_id"`
	Login        string     `json:"login"`
	Role         string     `json:"role"`
	MachineLogin string     `json:"machine_login"`
	AddedBy      string     `json:"added_by"`
	AddedAt      time.Time  `json:"added_at"`
	LastSeen     *time.Time `json:"last_seen,omitempty"`
}

// HubAuditEntry is one row of hub_audit.
type HubAuditEntry struct {
	ID      int64     `json:"id"`
	Created time.Time `json:"created"`
	Actor   string    `json:"actor"`
	Action  string    `json:"action"`
	Target  string    `json:"target"`
	Outcome string    `json:"outcome"`
	Detail  string    `json:"detail"`
}

// ErrPinConflict is a username already pinned to a different GitHub ID.
var ErrPinConflict = errors.New("username is pinned to a different GitHub ID")

// normLogin is the pin key: GitHub usernames are case-insensitive.
func normLogin(login string) string { return strings.ToLower(strings.TrimSpace(login)) }

// HubUserByID is the list's row for a GitHub ID, nil when there is none.
func (s *Store) HubUserByID(id int64) (*HubUser, error) {
	var u HubUser
	var added string
	var last sql.NullString
	err := s.read.QueryRow(`SELECT github_id, login, role, machine_login, added_by, added_at, last_seen
		FROM hub_users WHERE github_id = ?`, id).Scan(&u.GitHubID, &u.Login, &u.Role, &u.MachineLogin, &u.AddedBy, &added, &last)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	u.AddedAt, _ = time.Parse(rfc, added)
	if last.Valid {
		t, _ := time.Parse(rfc, last.String)
		u.LastSeen = &t
	}
	return &u, nil
}

// HubUsers is the whole list, admins first, then by username.
func (s *Store) HubUsers() ([]HubUser, error) {
	rows, err := s.read.Query(`SELECT github_id FROM hub_users
		ORDER BY CASE role WHEN 'admin' THEN 0 ELSE 1 END, login COLLATE NOCASE`)
	if err != nil {
		return nil, err
	}
	var ids []int64
	for rows.Next() {
		var id int64
		if err := rows.Scan(&id); err != nil {
			rows.Close()
			return nil, err
		}
		ids = append(ids, id)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}
	out := []HubUser{}
	for _, id := range ids {
		u, err := s.HubUserByID(id)
		if err != nil {
			return nil, err
		}
		if u != nil {
			out = append(out, *u)
		}
	}
	return out, nil
}

// UpsertHubUser writes a row. An existing row keeps its added_by / added_at
// (who first put them on the list) and its last_seen; login, role and
// machine_login take the new values. AddedAt zero means now.
func (s *Store) UpsertHubUser(u HubUser) error {
	if u.GitHubID <= 0 || u.Login == "" {
		return fmt.Errorf("hub user needs a GitHub ID and a username")
	}
	if u.Role != RoleAdmin && u.Role != RoleUser {
		return fmt.Errorf("hub user role %q is not admin or user", u.Role)
	}
	if u.AddedAt.IsZero() {
		u.AddedAt = time.Now()
	}
	_, err := s.write.Exec(`INSERT INTO hub_users (github_id, login, role, machine_login, added_by, added_at)
		VALUES (?, ?, ?, ?, ?, ?)
		ON CONFLICT(github_id) DO UPDATE SET login = excluded.login, role = excluded.role,
			machine_login = excluded.machine_login`,
		u.GitHubID, u.Login, u.Role, u.MachineLogin, u.AddedBy, u.AddedAt.UTC().Format(rfc))
	return err
}

// TouchHubUser records a sign-in: the username GitHub reported this time (a
// person may rename themselves; the ID is what stays) and when.
func (s *Store) TouchHubUser(id int64, login string, at time.Time) error {
	_, err := s.write.Exec(`UPDATE hub_users SET login = ?, last_seen = ? WHERE github_id = ?`,
		login, at.UTC().Format(rfc), id)
	return err
}

// DeleteHubUser takes a person off the list. Their next request is refused.
// Reports whether a row was removed. The username pin stays: the name still
// means that ID if they are added again.
func (s *Store) DeleteHubUser(id int64) (bool, error) {
	res, err := s.write.Exec(`DELETE FROM hub_users WHERE github_id = ?`, id)
	if err != nil {
		return false, err
	}
	n, _ := res.RowsAffected()
	return n > 0, nil
}

// PinnedID is the GitHub ID a username is pinned to; ok=false when the name
// has never been seen.
func (s *Store) PinnedID(login string) (id int64, ok bool, err error) {
	err = s.read.QueryRow(`SELECT github_id FROM hub_user_names WHERE login = ?`, normLogin(login)).Scan(&id)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, false, nil
	}
	if err != nil {
		return 0, false, err
	}
	return id, true, nil
}

// PinLogin records that login belongs to id, the first time it is seen.
// Pinning the same pair again is a no-op (created=false); a name already
// pinned to another ID is ErrPinConflict and changes nothing.
func (s *Store) PinLogin(login string, id int64, at time.Time) (created bool, err error) {
	name := normLogin(login)
	if name == "" || id <= 0 {
		return false, fmt.Errorf("pin needs a username and a GitHub ID")
	}
	res, err := s.write.Exec(`INSERT INTO hub_user_names (login, github_id, pinned_at) VALUES (?, ?, ?)
		ON CONFLICT(login) DO NOTHING`, name, id, at.UTC().Format(rfc))
	if err != nil {
		return false, err
	}
	if n, _ := res.RowsAffected(); n > 0 {
		return true, nil
	}
	got, ok, err := s.PinnedID(name)
	if err != nil {
		return false, err
	}
	if ok && got != id {
		return false, ErrPinConflict
	}
	return false, nil
}

// HubAudit records one sign-in or people-list event.
func (s *Store) HubAudit(actor, action, target, outcome, detail string, at time.Time) error {
	_, err := s.write.Exec(`INSERT INTO hub_audit (created, actor, action, target, outcome, detail)
		VALUES (?, ?, ?, ?, ?, ?)`, at.UTC().Format(rfc), actor, action, target, outcome, detail)
	return err
}

// HubAuditLog is the newest entries first.
func (s *Store) HubAuditLog(limit int) ([]HubAuditEntry, error) {
	if limit <= 0 {
		limit = 100
	}
	rows, err := s.read.Query(`SELECT id, created, actor, action, target, outcome, detail
		FROM hub_audit ORDER BY id DESC LIMIT ?`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []HubAuditEntry{}
	for rows.Next() {
		var e HubAuditEntry
		var created string
		if err := rows.Scan(&e.ID, &created, &e.Actor, &e.Action, &e.Target, &e.Outcome, &e.Detail); err != nil {
			return nil, err
		}
		e.Created, _ = time.Parse(rfc, created)
		out = append(out, e)
	}
	return out, rows.Err()
}
