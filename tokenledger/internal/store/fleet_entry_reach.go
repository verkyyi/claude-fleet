package store

import (
	"fmt"
	"strings"
	"time"
)

// Whether the outside can reach a home machine's entry port
// (claude-fleet#3072, EPIC #3067 C6): one row per address the hub dialled
// on the machine's last report — reachable or not, and why not — with the
// last time it answered. The hub writes a machine's whole set at once; the
// address record (C7) and the client's route (C9) read only the reachable,
// fresh ones.
const fleetEntryReachSchema = `
CREATE TABLE IF NOT EXISTS fleet_entry_reach (
  machine    TEXT NOT NULL,
  addr       TEXT NOT NULL,
  port       INTEGER NOT NULL,
  family     TEXT NOT NULL,
  via        TEXT NOT NULL DEFAULT '',
  reachable  INTEGER NOT NULL DEFAULT 0,
  reason     TEXT NOT NULL DEFAULT '',
  last_ok    TEXT NOT NULL DEFAULT '',
  checked_at TEXT NOT NULL,
  PRIMARY KEY (machine, addr, port)
);
CREATE INDEX IF NOT EXISTS fleet_entry_reach_machine ON fleet_entry_reach(machine);
`

// EntryReach is one address of a machine the hub tried.
type EntryReach struct {
	Machine   string
	Addr      string
	Port      int
	Family    string
	Via       string
	Reachable bool
	Reason    string
	LastOK    *time.Time
	CheckedAt time.Time
}

func (s *Store) ensureFleetEntryReach() error {
	if _, err := s.write.Exec(s.d.ddl(fleetEntryReachSchema)); err != nil {
		return fmt.Errorf("create fleet_entry_reach: %w", err)
	}
	return nil
}

// SetEntryReach replaces machine's rows with rows, carrying each address's
// last success forward when it did not answer this time. It returns the rows
// as written.
func (s *Store) SetEntryReach(machine string, rows []EntryReach) ([]EntryReach, error) {
	machine = strings.ToLower(machine)
	tx, err := s.write.Begin()
	if err != nil {
		return nil, err
	}
	defer tx.Rollback() //nolint:errcheck — a no-op after Commit
	prev := map[string]string{}
	q, err := tx.Query(`SELECT addr, port, last_ok FROM fleet_entry_reach WHERE machine = ?`, machine)
	if err != nil {
		return nil, err
	}
	for q.Next() {
		var a, l string
		var p int
		if err := q.Scan(&a, &p, &l); err != nil {
			q.Close()
			return nil, err
		}
		prev[fmt.Sprintf("%s|%d", a, p)] = l
	}
	q.Close()
	if err := q.Err(); err != nil {
		return nil, err
	}
	if _, err := tx.Exec(`DELETE FROM fleet_entry_reach WHERE machine = ?`, machine); err != nil {
		return nil, err
	}
	out := make([]EntryReach, 0, len(rows))
	for _, r := range rows {
		r.Machine = machine
		at := r.CheckedAt.UTC().Format(rfc)
		lastOK := prev[fmt.Sprintf("%s|%d", r.Addr, r.Port)]
		if r.Reachable {
			lastOK, r.Reason = at, ""
		}
		r.LastOK = parseOptTime(lastOK)
		ok := 0
		if r.Reachable {
			ok = 1
		}
		if _, err := tx.Exec(`INSERT INTO fleet_entry_reach (machine, addr, port, family, via, reachable, reason, last_ok, checked_at)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`, machine, r.Addr, r.Port, r.Family, r.Via, ok, r.Reason, lastOK, at); err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, tx.Commit()
}

// EntryReachAll is every machine's rows, by machine and address.
func (s *Store) EntryReachAll() ([]EntryReach, error) {
	rows, err := s.read.Query(`SELECT machine, addr, port, family, via, reachable, reason, last_ok, checked_at
		FROM fleet_entry_reach ORDER BY machine, family, addr, port`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []EntryReach
	for rows.Next() {
		var r EntryReach
		var ok int
		var lastOK, at string
		if err := rows.Scan(&r.Machine, &r.Addr, &r.Port, &r.Family, &r.Via, &ok, &r.Reason, &lastOK, &at); err != nil {
			return nil, err
		}
		r.Reachable = ok != 0
		r.LastOK = parseOptTime(lastOK)
		r.CheckedAt, _ = time.Parse(rfc, at)
		out = append(out, r)
	}
	return out, rows.Err()
}
