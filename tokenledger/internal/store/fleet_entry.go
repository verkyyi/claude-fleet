package store

import (
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"
)

// The direct door's book (claude-fleet#3068, EPIC #3067 C1): each person's
// public keys, their address name and their home — the one machine + login
// their address points at — and every entry through the door.
//
// One version counts every change a home machine must hear (a key added or
// revoked, a name, a home): it only goes up, and it is what the node's
// GET /v1/node/entry-keys answers and the entry_keys push carries.
//
// Created only with the fleet module on (EnsureNodes), like every fleet table.
// A table, never a file: nothing here holds a credential — a public key is
// public, a private key is refused before it reaches this file.
const fleetEntrySchema = `
CREATE TABLE IF NOT EXISTS fleet_entry_keys (
  id         TEXT PRIMARY KEY,
  person     TEXT NOT NULL,
  fp         TEXT NOT NULL,
  type       TEXT NOT NULL,
  b64        TEXT NOT NULL,
  name       TEXT NOT NULL DEFAULT '',
  created    TEXT NOT NULL,
  revoked_at TEXT NOT NULL DEFAULT '',
  last_used  TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS fleet_entry_keys_person ON fleet_entry_keys(person);
CREATE INDEX IF NOT EXISTS fleet_entry_keys_fp ON fleet_entry_keys(fp);
CREATE TABLE IF NOT EXISTS fleet_entry_names (
  name       TEXT NOT NULL,
  person     TEXT NOT NULL,
  created    TEXT NOT NULL,
  retired_at TEXT NOT NULL DEFAULT '',
  PRIMARY KEY (name, created)
);
CREATE INDEX IF NOT EXISTS fleet_entry_names_person ON fleet_entry_names(person);
CREATE TABLE IF NOT EXISTS fleet_entry_home (
  person  TEXT PRIMARY KEY,
  machine TEXT NOT NULL,
  login   TEXT NOT NULL,
  set_by  TEXT NOT NULL,
  set_at  TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS fleet_entry_audit (
  id        TEXT PRIMARY KEY,
  at        TEXT NOT NULL,
  kind      TEXT NOT NULL,
  person    TEXT NOT NULL DEFAULT '',
  login     TEXT NOT NULL DEFAULT '',
  fp        TEXT NOT NULL DEFAULT '',
  machine   TEXT NOT NULL DEFAULT '',
  source_ip TEXT NOT NULL DEFAULT '',
  result    TEXT NOT NULL DEFAULT '',
  actor     TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS fleet_entry_audit_at ON fleet_entry_audit(at);
CREATE TABLE IF NOT EXISTS fleet_entry_state (
  k       TEXT PRIMARY KEY,
  version INTEGER NOT NULL
);
`

// EntryNameKeep is how long a retired address name still answers for its
// person — and stays out of everyone else's reach.
const EntryNameKeep = 7 * 24 * time.Hour

// EntryKey is one public key on a person's list.
type EntryKey struct {
	ID        string     `json:"id"`
	Person    string     `json:"-"`
	FP        string     `json:"fp"`
	Type      string     `json:"type"`
	B64       string     `json:"-"`
	Name      string     `json:"name"`
	Created   time.Time  `json:"created"`
	RevokedAt *time.Time `json:"revoked_at,omitempty"`
	LastUsed  *time.Time `json:"last_used,omitempty"`
}

// EntryName is one address name a person holds or held.
type EntryName struct {
	Name      string     `json:"name"`
	Person    string     `json:"-"`
	Created   time.Time  `json:"created"`
	RetiredAt *time.Time `json:"retired_at,omitempty"`
}

// EntryHome is the machine + login a person's address points at.
type EntryHome struct {
	Person  string    `json:"-"`
	Machine string    `json:"machine"`
	Login   string    `json:"login"`
	SetBy   string    `json:"set_by"`
	SetAt   time.Time `json:"set_at"`
}

// EntryAudit is one line of the door's record: never a key body.
type EntryAudit struct {
	ID       string    `json:"id"`
	At       time.Time `json:"at"`
	Kind     string    `json:"kind"`
	Person   string    `json:"person,omitempty"`
	Login    string    `json:"login,omitempty"`
	FP       string    `json:"fp,omitempty"`
	Machine  string    `json:"machine,omitempty"`
	SourceIP string    `json:"source_ip,omitempty"`
	Result   string    `json:"result,omitempty"`
	Actor    string    `json:"actor,omitempty"`
}

var (
	// ErrEntryKeyTaken is a key another person already holds.
	ErrEntryKeyTaken = errors.New("that key is another person's")
	// ErrEntryKeyNotFound is a key id the person does not hold.
	ErrEntryKeyNotFound = errors.New("no such key")
	// ErrEntryNameTaken is a name another person holds, or held in the last 7 days.
	ErrEntryNameTaken = errors.New("that name is taken")
)

func (s *Store) ensureFleetEntry() error {
	if _, err := s.write.Exec(s.d.ddl(fleetEntrySchema)); err != nil {
		return fmt.Errorf("create fleet_entry tables: %w", err)
	}
	return s.ensureFleetEntryReach()
}

func parseOptTime(v string) *time.Time {
	if v == "" {
		return nil
	}
	t, err := time.Parse(rfc, v)
	if err != nil {
		return nil
	}
	return &t
}

// bumpEntry moves the one version up by one inside tx and returns it.
func (s *Store) bumpEntry(tx *sql.Tx) (int, error) {
	if _, err := tx.Exec(s.d.insertIgnore(`INSERT OR IGNORE INTO fleet_entry_state (k, version) VALUES ('v', 0)`)); err != nil {
		return 0, err
	}
	if _, err := tx.Exec(`UPDATE fleet_entry_state SET version = version + 1 WHERE k = 'v'`); err != nil {
		return 0, err
	}
	var v int
	err := tx.QueryRow(`SELECT version FROM fleet_entry_state WHERE k = 'v'`).Scan(&v)
	return v, err
}

// EntryVersion is the current version, 0 when nothing ever changed.
func (s *Store) EntryVersion() (int, error) {
	var v int
	err := s.read.QueryRow(`SELECT version FROM fleet_entry_state WHERE k = 'v'`).Scan(&v)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, nil
	}
	return v, err
}

const entryKeyCols = `id, person, fp, type, b64, name, created, revoked_at, last_used`

func scanEntryKey(sc interface{ Scan(...any) error }) (EntryKey, error) {
	var k EntryKey
	var created, revoked, used string
	if err := sc.Scan(&k.ID, &k.Person, &k.FP, &k.Type, &k.B64, &k.Name, &created, &revoked, &used); err != nil {
		return EntryKey{}, err
	}
	k.Created, _ = time.Parse(rfc, created)
	k.RevokedAt, k.LastUsed = parseOptTime(revoked), parseOptTime(used)
	return k, nil
}

// EntryKeys is a person's keys, newest first; revoked ones only with all.
func (s *Store) EntryKeys(person string, all bool) ([]EntryKey, error) {
	q := `SELECT ` + entryKeyCols + ` FROM fleet_entry_keys WHERE person = ?`
	if !all {
		q += ` AND revoked_at = ''`
	}
	rows, err := s.read.Query(q+` ORDER BY created DESC, id`, person)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []EntryKey{}
	for rows.Next() {
		k, err := scanEntryKey(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, k)
	}
	return out, rows.Err()
}

// AddEntryKey puts k on its person's list. A live key with the same
// fingerprint answers: the same person's → that key, unchanged (added=false);
// anyone else's → ErrEntryKeyTaken. A revoked key holds no one.
func (s *Store) AddEntryKey(k EntryKey) (EntryKey, bool, int, error) {
	tx, err := s.write.Begin()
	if err != nil {
		return EntryKey{}, false, 0, err
	}
	defer tx.Rollback() //nolint:errcheck — a no-op after Commit
	if err := s.d.claimWrites(tx, "fleet_entry_keys"); err != nil {
		return EntryKey{}, false, 0, err
	}
	cur, err := scanEntryKey(tx.QueryRow(`SELECT `+entryKeyCols+` FROM fleet_entry_keys
		WHERE fp = ? AND revoked_at = '' ORDER BY created LIMIT 1`, k.FP))
	switch {
	case err == nil && cur.Person == k.Person:
		return cur, false, 0, nil
	case err == nil:
		return EntryKey{}, false, 0, ErrEntryKeyTaken
	case !errors.Is(err, sql.ErrNoRows):
		return EntryKey{}, false, 0, err
	}
	if _, err := tx.Exec(`INSERT INTO fleet_entry_keys (`+entryKeyCols+`) VALUES (?, ?, ?, ?, ?, ?, ?, '', '')`,
		k.ID, k.Person, k.FP, k.Type, k.B64, k.Name, k.Created.UTC().Format(rfc)); err != nil {
		return EntryKey{}, false, 0, err
	}
	v, err := s.bumpEntry(tx)
	if err != nil {
		return EntryKey{}, false, 0, err
	}
	return k, true, v, tx.Commit()
}

// RevokeEntryKey revokes person's key id. A key already revoked answers as
// it is with version 0 (nothing changed); another person's is not found.
func (s *Store) RevokeEntryKey(person, id string, at time.Time) (EntryKey, int, error) {
	tx, err := s.write.Begin()
	if err != nil {
		return EntryKey{}, 0, err
	}
	defer tx.Rollback() //nolint:errcheck — a no-op after Commit
	k, err := scanEntryKey(tx.QueryRow(`SELECT `+entryKeyCols+` FROM fleet_entry_keys WHERE id = ? AND person = ?`, id, person))
	if errors.Is(err, sql.ErrNoRows) {
		return EntryKey{}, 0, ErrEntryKeyNotFound
	} else if err != nil {
		return EntryKey{}, 0, err
	}
	if k.RevokedAt != nil {
		return k, 0, nil
	}
	if _, err := tx.Exec(`UPDATE fleet_entry_keys SET revoked_at = ? WHERE id = ?`, at.UTC().Format(rfc), id); err != nil {
		return EntryKey{}, 0, err
	}
	v, err := s.bumpEntry(tx)
	if err != nil {
		return EntryKey{}, 0, err
	}
	t := at.UTC()
	k.RevokedAt = &t
	return k, v, tx.Commit()
}

// RenameEntryKey changes the label person gave key id — nothing a machine
// reads, so the version stays.
func (s *Store) RenameEntryKey(person, id, name string) (EntryKey, error) {
	res, err := s.write.Exec(`UPDATE fleet_entry_keys SET name = ? WHERE id = ? AND person = ?`, name, id, person)
	if err != nil {
		return EntryKey{}, err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return EntryKey{}, ErrEntryKeyNotFound
	}
	return scanEntryKey(s.read.QueryRow(`SELECT `+entryKeyCols+` FROM fleet_entry_keys WHERE id = ?`, id))
}

// TouchEntryKey stamps the last time a live key with fingerprint fp let
// person in.
func (s *Store) TouchEntryKey(person, fp string, at time.Time) error {
	_, err := s.write.Exec(`UPDATE fleet_entry_keys SET last_used = ?
		WHERE person = ? AND fp = ? AND revoked_at = '' AND last_used < ?`,
		at.UTC().Format(rfc), person, fp, at.UTC().Format(rfc))
	return err
}

// EntryName is person's current name; ok=false when they have none.
func (s *Store) EntryName(person string) (EntryName, bool, error) {
	var n EntryName
	var created string
	err := s.read.QueryRow(`SELECT name, person, created FROM fleet_entry_names
		WHERE person = ? AND retired_at = '' ORDER BY created DESC LIMIT 1`, person).Scan(&n.Name, &n.Person, &created)
	if errors.Is(err, sql.ErrNoRows) {
		return EntryName{}, false, nil
	} else if err != nil {
		return EntryName{}, false, err
	}
	n.Created, _ = time.Parse(rfc, created)
	return n, true, nil
}

// EntryNames is every name that answers right now — current ones and those
// retired less than EntryNameKeep ago — for the address records.
func (s *Store) EntryNames(now time.Time) ([]EntryName, error) {
	rows, err := s.read.Query(`SELECT name, person, created, retired_at FROM fleet_entry_names
		WHERE retired_at = '' OR retired_at > ? ORDER BY name, created`, now.Add(-EntryNameKeep).UTC().Format(rfc))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []EntryName{}
	for rows.Next() {
		var n EntryName
		var created, retired string
		if err := rows.Scan(&n.Name, &n.Person, &created, &retired); err != nil {
			return nil, err
		}
		n.Created, _ = time.Parse(rfc, created)
		n.RetiredAt = parseOptTime(retired)
		out = append(out, n)
	}
	return out, rows.Err()
}

// SetEntryName makes name person's one current name; the old one retires and
// keeps answering for EntryNameKeep. A name someone else holds — or held less
// than EntryNameKeep ago — is ErrEntryNameTaken. The same name again changes
// nothing (version 0).
func (s *Store) SetEntryName(person, name string, now time.Time) (int, error) {
	tx, err := s.write.Begin()
	if err != nil {
		return 0, err
	}
	defer tx.Rollback() //nolint:errcheck — a no-op after Commit
	if err := s.d.claimWrites(tx, "fleet_entry_names"); err != nil {
		return 0, err
	}
	keep := now.Add(-EntryNameKeep).UTC().Format(rfc)
	var other int
	if err := tx.QueryRow(`SELECT COUNT(*) FROM fleet_entry_names
		WHERE name = ? AND person <> ? AND (retired_at = '' OR retired_at > ?)`, name, person, keep).Scan(&other); err != nil {
		return 0, err
	}
	if other > 0 {
		return 0, ErrEntryNameTaken
	}
	var cur string
	err = tx.QueryRow(`SELECT name FROM fleet_entry_names WHERE person = ? AND retired_at = ''
		ORDER BY created DESC LIMIT 1`, person).Scan(&cur)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return 0, err
	}
	if cur == name {
		return 0, nil
	}
	at := now.UTC().Format(rfc)
	if _, err := tx.Exec(`UPDATE fleet_entry_names SET retired_at = ? WHERE person = ? AND retired_at = ''`, at, person); err != nil {
		return 0, err
	}
	// Taking back one of one's own retired names: it is current again.
	if _, err := tx.Exec(`DELETE FROM fleet_entry_names WHERE name = ? AND person = ? AND retired_at <> ''`, name, person); err != nil {
		return 0, err
	}
	if _, err := tx.Exec(`INSERT INTO fleet_entry_names (name, person, created, retired_at) VALUES (?, ?, ?, '')`, name, person, at); err != nil {
		return 0, err
	}
	v, err := s.bumpEntry(tx)
	if err != nil {
		return 0, err
	}
	return v, tx.Commit()
}

// EntryHomeOf is person's home; ok=false when none was set.
func (s *Store) EntryHomeOf(person string) (EntryHome, bool, error) {
	var h EntryHome
	var at string
	err := s.read.QueryRow(`SELECT person, machine, login, set_by, set_at FROM fleet_entry_home WHERE person = ?`, person).
		Scan(&h.Person, &h.Machine, &h.Login, &h.SetBy, &at)
	if errors.Is(err, sql.ErrNoRows) {
		return EntryHome{}, false, nil
	} else if err != nil {
		return EntryHome{}, false, err
	}
	h.SetAt, _ = time.Parse(rfc, at)
	return h, true, nil
}

// EntryHomes is every person's home.
func (s *Store) EntryHomes() ([]EntryHome, error) {
	rows, err := s.read.Query(`SELECT person, machine, login, set_by, set_at FROM fleet_entry_home ORDER BY person`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []EntryHome{}
	for rows.Next() {
		var h EntryHome
		var at string
		if err := rows.Scan(&h.Person, &h.Machine, &h.Login, &h.SetBy, &at); err != nil {
			return nil, err
		}
		h.SetAt, _ = time.Parse(rfc, at)
		out = append(out, h)
	}
	return out, rows.Err()
}

// SetEntryHome points person's address at h. The same machine and login
// again changes nothing (version 0).
func (s *Store) SetEntryHome(h EntryHome) (int, error) {
	tx, err := s.write.Begin()
	if err != nil {
		return 0, err
	}
	defer tx.Rollback() //nolint:errcheck — a no-op after Commit
	var m, l string
	err = tx.QueryRow(`SELECT machine, login FROM fleet_entry_home WHERE person = ?`, h.Person).Scan(&m, &l)
	if err == nil && strings.EqualFold(m, h.Machine) && l == h.Login {
		return 0, nil
	} else if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return 0, err
	}
	if _, err := tx.Exec(s.d.insertReplace(`INSERT OR REPLACE INTO fleet_entry_home (person, machine, login, set_by, set_at)
		VALUES (?, ?, ?, ?, ?)`, "person"), h.Person, h.Machine, h.Login, h.SetBy, h.SetAt.UTC().Format(rfc)); err != nil {
		return 0, err
	}
	v, err := s.bumpEntry(tx)
	if err != nil {
		return 0, err
	}
	return v, tx.Commit()
}

// AddEntryAudit records lines; one whose id is already there is skipped, so
// a node sending its backlog twice records it once. It returns how many
// were new.
func (s *Store) AddEntryAudit(lines []EntryAudit) (int, error) {
	tx, err := s.write.Begin()
	if err != nil {
		return 0, err
	}
	defer tx.Rollback() //nolint:errcheck — a no-op after Commit
	q := s.d.insertIgnore(`INSERT OR IGNORE INTO fleet_entry_audit (id, at, kind, person, login, fp, machine, source_ip, result, actor)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`)
	n := 0
	for _, a := range lines {
		res, err := tx.Exec(q, a.ID, a.At.UTC().Format(rfc), a.Kind, a.Person, a.Login, a.FP, a.Machine, a.SourceIP, a.Result, a.Actor)
		if err != nil {
			return 0, err
		}
		if c, _ := res.RowsAffected(); c > 0 {
			n++
		}
	}
	return n, tx.Commit()
}

// EntryAudits is the newest lines first; person "" is everyone's.
func (s *Store) EntryAudits(person string, limit int) ([]EntryAudit, error) {
	if limit <= 0 {
		limit = 50
	}
	q := `SELECT id, at, kind, person, login, fp, machine, source_ip, result, actor FROM fleet_entry_audit`
	args := []any{}
	if person != "" {
		q += ` WHERE person = ?`
		args = append(args, person)
	}
	rows, err := s.read.Query(q+fmt.Sprintf(` ORDER BY at DESC, id LIMIT %d`, limit), args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []EntryAudit{}
	for rows.Next() {
		var a EntryAudit
		var at string
		if err := rows.Scan(&a.ID, &at, &a.Kind, &a.Person, &a.Login, &a.FP, &a.Machine, &a.SourceIP, &a.Result, &a.Actor); err != nil {
			return nil, err
		}
		a.At, _ = time.Parse(rfc, at)
		out = append(out, a)
	}
	return out, rows.Err()
}
