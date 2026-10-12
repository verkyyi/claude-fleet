package store

import (
	"database/sql"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"
)

// The people on the hub (claude-fleet#1984, #3603). See the hub_users /
// hub_identities / hub_user_names / hub_audit tables in schema.sql.

// Hub roles. The deploy names the admins; an admin adds users on the web.
const (
	RoleAdmin = "admin"
	RoleUser  = "user"
)

// GitHubPrincipalPrefix starts the principal of every person who came in
// through GitHub before claude-fleet#3603: gh:<GitHub ID>. It is a spelling
// of an ACCOUNT, kept forever (a principal never changes); whether a
// principal is a person is api's isPerson, never this prefix.
const GitHubPrincipalPrefix = "gh:"

// The kinds of hub_identities (claude-fleet#3603): the ways a person signs in.
// A new way is one more kind here, and nothing else in the table changes.
const (
	IdentityGitHub = "github" // subject: the numeric GitHub ID
	IdentityEmail  = "email"  // subject: the address, lower-cased
	IdentityWeChat = "wechat" // subject: the unionid
)

// IdentityKinds is every kind the hub knows, in the order a page lists them.
var IdentityKinds = []string{IdentityWeChat, IdentityEmail, IdentityGitHub}

// KnownIdentityKind reports whether kind is one of IdentityKinds.
func KnownIdentityKind(kind string) bool {
	for _, k := range IdentityKinds {
		if k == kind {
			return true
		}
	}
	return false
}

// HubUser is one person on the list. PrincipalID is who they are; GitHubID is
// the GitHub numeric ID behind a gh: person, 0 for a person with none.
type HubUser struct {
	PrincipalID  string     `json:"principal_id"`
	GitHubID     int64      `json:"github_id"`
	Login        string     `json:"login"`
	Role         string     `json:"role"`
	MachineLogin string     `json:"machine_login"`
	AddedBy      string     `json:"added_by"`
	AddedAt      time.Time  `json:"added_at"`
	LastSeen     *time.Time `json:"last_seen,omitempty"`
}

// HubIdentity is one way a person signs in.
type HubIdentity struct {
	Kind        string    `json:"kind"`
	Subject     string    `json:"subject"`
	PrincipalID string    `json:"principal_id"`
	VerifiedAt  time.Time `json:"verified_at"`
	AddedBy     string    `json:"added_by,omitempty"`
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

// ErrIdentityTaken is a way of signing in that already lets another person in.
var ErrIdentityTaken = errors.New("this sign-in already belongs to another person")

// ErrLastIdentity refuses removing a person's only way of signing in.
var ErrLastIdentity = errors.New("a person keeps at least one way of signing in")

// normLogin is the pin key: GitHub usernames are case-insensitive.
func normLogin(login string) string { return strings.ToLower(strings.TrimSpace(login)) }

// NormIdentitySubject is how a subject is stored and looked up: an address
// folds case, an ID or a unionid is kept as given (trimmed).
func NormIdentitySubject(kind, subject string) string {
	subject = strings.TrimSpace(subject)
	if kind == IdentityEmail {
		return strings.ToLower(subject)
	}
	return subject
}

const hubUserCols = `principal_id, github_id, login, role, machine_login, added_by, added_at, last_seen`

func scanHubUser(row interface{ Scan(...any) error }) (*HubUser, error) {
	var u HubUser
	var gid sql.NullInt64
	var added string
	var last sql.NullString
	if err := row.Scan(&u.PrincipalID, &gid, &u.Login, &u.Role, &u.MachineLogin, &u.AddedBy, &added, &last); err != nil {
		return nil, err
	}
	u.GitHubID = gid.Int64
	u.AddedAt, _ = time.Parse(rfc, added)
	if last.Valid {
		t, _ := time.Parse(rfc, last.String)
		u.LastSeen = &t
	}
	return &u, nil
}

func (s *Store) hubUserWhere(where string, arg any) (*HubUser, error) {
	u, err := scanHubUser(s.read.QueryRow(`SELECT `+hubUserCols+` FROM hub_users WHERE `+where, arg))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	return u, err
}

// HubUserByPrincipal is the list's row for a person, nil when there is none.
func (s *Store) HubUserByPrincipal(pid string) (*HubUser, error) {
	if pid == "" {
		return nil, nil
	}
	return s.hubUserWhere(`principal_id = ?`, pid)
}

// HubUserByID is the list's row for a GitHub ID, nil when there is none.
func (s *Store) HubUserByID(id int64) (*HubUser, error) {
	if id <= 0 {
		return nil, nil
	}
	return s.hubUserWhere(`github_id = ?`, id)
}

// HubUsers is the whole list, admins first, then by username.
func (s *Store) HubUsers() ([]HubUser, error) {
	rows, err := s.read.Query(`SELECT ` + hubUserCols + ` FROM hub_users
		ORDER BY CASE role WHEN 'admin' THEN 0 ELSE 1 END, ` + s.d.nocase("login") + `, principal_id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []HubUser{}
	for rows.Next() {
		u, err := scanHubUser(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *u)
	}
	return out, rows.Err()
}

// UpsertHubUser writes a row. An existing row keeps its added_by / added_at
// (who first put them on the list), its last_seen and its GitHub ID; login,
// role and machine_login take the new values. AddedAt zero means now; an
// empty PrincipalID with a GitHub ID means gh:<id>, the GitHub person's.
func (s *Store) UpsertHubUser(u HubUser) error {
	if u.PrincipalID == "" && u.GitHubID > 0 {
		u.PrincipalID = GitHubPrincipalPrefix + strconv.FormatInt(u.GitHubID, 10)
	}
	if u.PrincipalID == "" || u.Login == "" {
		return fmt.Errorf("hub user needs a principal (or a GitHub ID) and a username")
	}
	if u.Role != RoleAdmin && u.Role != RoleUser {
		return fmt.Errorf("hub user role %q is not admin or user", u.Role)
	}
	if u.AddedAt.IsZero() {
		u.AddedAt = time.Now()
	}
	var gid any
	if u.GitHubID > 0 {
		gid = u.GitHubID
	}
	_, err := s.write.Exec(`INSERT INTO hub_users (principal_id, github_id, login, role, machine_login, added_by, added_at)
		VALUES (?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(principal_id) DO UPDATE SET login = excluded.login, role = excluded.role,
			machine_login = excluded.machine_login,
			github_id = COALESCE(hub_users.github_id, excluded.github_id)`,
		u.PrincipalID, gid, u.Login, u.Role, u.MachineLogin, u.AddedBy, u.AddedAt.UTC().Format(rfc))
	return err
}

// TouchHubUser records a GitHub sign-in: the username GitHub reported this
// time (a person may rename themselves; the ID is what stays) and when.
func (s *Store) TouchHubUser(id int64, login string, at time.Time) error {
	_, err := s.write.Exec(`UPDATE hub_users SET login = ?, last_seen = ? WHERE github_id = ?`,
		login, at.UTC().Format(rfc), id)
	return err
}

// TouchHubPrincipal records a sign-in by any way: when, and the name it
// carried when it carried one ("" keeps the row's).
func (s *Store) TouchHubPrincipal(pid, login string, at time.Time) error {
	_, err := s.write.Exec(`UPDATE hub_users SET login = CASE WHEN ? <> '' THEN ? ELSE login END, last_seen = ?
		WHERE principal_id = ?`, login, login, at.UTC().Format(rfc), pid)
	return err
}

// DeleteHubUser takes a GitHub person off the list. Their next request is
// refused. Reports whether a row was removed. The username pin and the
// person's ways of signing in stay: added again, they are the same person.
func (s *Store) DeleteHubUser(id int64) (bool, error) {
	res, err := s.write.Exec(`DELETE FROM hub_users WHERE github_id = ?`, id)
	if err != nil {
		return false, err
	}
	n, _ := res.RowsAffected()
	return n > 0, nil
}

// DeleteHubPrincipal is DeleteHubUser for any person.
func (s *Store) DeleteHubPrincipal(pid string) (bool, error) {
	res, err := s.write.Exec(`DELETE FROM hub_users WHERE principal_id = ?`, pid)
	if err != nil {
		return false, err
	}
	n, _ := res.RowsAffected()
	return n > 0, nil
}

// IdentityPrincipal is the person a way of signing in lets in, "" when it
// lets in nobody yet.
func (s *Store) IdentityPrincipal(kind, subject string) (string, error) {
	var pid string
	err := s.read.QueryRow(`SELECT principal_id FROM hub_identities WHERE kind = ? AND subject = ?`,
		kind, NormIdentitySubject(kind, subject)).Scan(&pid)
	if errors.Is(err, sql.ErrNoRows) {
		return "", nil
	}
	return pid, err
}

// HubIdentities are a person's ways of signing in, in IdentityKinds order.
func (s *Store) HubIdentities(pid string) ([]HubIdentity, error) {
	rows, err := s.read.Query(`SELECT kind, subject, principal_id, verified_at, added_by FROM hub_identities
		WHERE principal_id = ? ORDER BY kind, subject`, pid)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var all []HubIdentity
	for rows.Next() {
		var i HubIdentity
		var v string
		if err := rows.Scan(&i.Kind, &i.Subject, &i.PrincipalID, &v, &i.AddedBy); err != nil {
			return nil, err
		}
		i.VerifiedAt, _ = time.Parse(rfc, v)
		all = append(all, i)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	out := []HubIdentity{}
	for _, k := range IdentityKinds {
		for _, i := range all {
			if i.Kind == k {
				out = append(out, i)
			}
		}
	}
	for _, i := range all {
		if !KnownIdentityKind(i.Kind) {
			out = append(out, i)
		}
	}
	return out, nil
}

// AddHubIdentity hangs a way of signing in on a person, or re-verifies one
// they have. One that lets another person in is ErrIdentityTaken and changes
// nothing: a sign-in never moves between people.
func (s *Store) AddHubIdentity(i HubIdentity) error {
	if !KnownIdentityKind(i.Kind) || strings.TrimSpace(i.Subject) == "" || i.PrincipalID == "" {
		return fmt.Errorf("identity needs a known kind, a subject and a person")
	}
	i.Subject = NormIdentitySubject(i.Kind, i.Subject)
	if i.VerifiedAt.IsZero() {
		i.VerifiedAt = time.Now()
	}
	_, err := s.write.Exec(s.d.insertIgnore(`INSERT OR IGNORE INTO hub_identities (kind, subject, principal_id, verified_at, added_by)
		VALUES (?, ?, ?, ?, ?)`), i.Kind, i.Subject, i.PrincipalID, i.VerifiedAt.UTC().Format(rfc), i.AddedBy)
	if err != nil {
		return err
	}
	owner, err := s.IdentityPrincipal(i.Kind, i.Subject)
	if err != nil {
		return err
	}
	if owner != i.PrincipalID {
		return ErrIdentityTaken
	}
	_, err = s.write.Exec(`UPDATE hub_identities SET verified_at = ? WHERE kind = ? AND subject = ? AND principal_id = ?`,
		i.VerifiedAt.UTC().Format(rfc), i.Kind, i.Subject, i.PrincipalID)
	return err
}

// RemoveHubIdentity takes a way of signing in off a person: ok=false when
// they have no such one, ErrLastIdentity when it is their only one. The
// count and the delete are one statement, so two removals racing leave one.
func (s *Store) RemoveHubIdentity(pid, kind, subject string) (bool, error) {
	subject = NormIdentitySubject(kind, subject)
	res, err := s.write.Exec(`DELETE FROM hub_identities WHERE principal_id = ? AND kind = ? AND subject = ?
		AND (SELECT COUNT(*) FROM hub_identities WHERE principal_id = ?) > 1`, pid, kind, subject, pid)
	if err != nil {
		return false, err
	}
	if n, _ := res.RowsAffected(); n > 0 {
		return true, nil
	}
	owner, err := s.IdentityPrincipal(kind, subject)
	if err != nil {
		return false, err
	}
	if owner == pid {
		return false, ErrLastIdentity
	}
	return false, nil
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

// PinnedLogin is the username most recently pinned to a GitHub ID, "" when
// none: how a github identity reads on a page.
func (s *Store) PinnedLogin(id int64) (string, error) {
	var login string
	err := s.read.QueryRow(`SELECT login FROM hub_user_names WHERE github_id = ? ORDER BY pinned_at DESC, login LIMIT 1`, id).Scan(&login)
	if errors.Is(err, sql.ErrNoRows) {
		return "", nil
	}
	return login, err
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
