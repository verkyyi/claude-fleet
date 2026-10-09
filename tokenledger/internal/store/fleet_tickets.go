package store

import (
	"database/sql"
	"errors"
	"fmt"
	"strconv"
	"time"
)

// The ticket registry (claude-fleet#2676, EPIC #2668 C8) — ONE row per ticket a
// node opened: a session with no code to change (a design page, research, a
// release) is bound to a ticket all the same, filed on GitHub by
// bin/fleet-ticket.sh, and registered here so the next batch's 「我的单子」 grows
// out of one list. The row is the registry only — id · owner · title · state ·
// backend · url · origin session; the body and the thread stay on GitHub and are
// never written here.
//
// Created only with the fleet module on (EnsureNodes), like every fleet table.
const fleetTicketIndexSchema = `
CREATE TABLE IF NOT EXISTS fleet_ticket_index (
  id           TEXT PRIMARY KEY,
  owner        TEXT NOT NULL,
  title        TEXT NOT NULL,
  state        TEXT NOT NULL,
  backend      TEXT NOT NULL,
  url          TEXT NOT NULL,
  origin       TEXT NOT NULL,
  endpoint_id  TEXT NOT NULL,
  created_at   TEXT NOT NULL,
  updated_at   TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS fleet_ticket_index_owner ON fleet_ticket_index(owner, updated_at);`

// FleetTicket is one registered ticket.
type FleetTicket struct {
	ID         string    `json:"id"`
	Owner      string    `json:"owner"`
	Title      string    `json:"title"`
	State      string    `json:"state"`
	Backend    string    `json:"backend"`
	URL        string    `json:"url"`
	Origin     string    `json:"origin"`
	EndpointID string    `json:"endpoint_id"`
	CreatedAt  time.Time `json:"created_at"`
	UpdatedAt  time.Time `json:"updated_at"`
}

// ErrTicketOwner: the id is already registered to another person.
var ErrTicketOwner = errors.New("this ticket is registered to another person")

func (s *Store) ensureFleetTicketIndex() error {
	if _, err := s.write.Exec(s.d.ddl(fleetTicketIndexSchema)); err != nil {
		return fmt.Errorf("create fleet_ticket_index table: %w", err)
	}
	return nil
}

// RegisterTicket writes the row, or refreshes title · state · url · origin of an
// id already registered to the same owner (a re-register is never a second
// row). Another owner's id is refused with ErrTicketOwner; created_at and the
// owner never move. Returns the row as stored.
func (s *Store) RegisterTicket(t FleetTicket, now time.Time) (FleetTicket, error) {
	var owner string
	err := s.read.QueryRow(`SELECT owner FROM fleet_ticket_index WHERE id = ?`, t.ID).Scan(&owner)
	switch {
	case errors.Is(err, sql.ErrNoRows):
	case err != nil:
		return FleetTicket{}, err
	case owner != t.Owner:
		return FleetTicket{}, ErrTicketOwner
	}
	ts := now.UTC().Format(rfc)
	if _, err := s.write.Exec(`INSERT INTO fleet_ticket_index (id, owner, title, state, backend,
		url, origin, endpoint_id, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(id) DO UPDATE SET title = excluded.title, state = excluded.state,
		  url = excluded.url, origin = excluded.origin, endpoint_id = excluded.endpoint_id,
		  updated_at = excluded.updated_at`,
		t.ID, t.Owner, t.Title, t.State, t.Backend, t.URL, t.Origin, t.EndpointID, ts, ts); err != nil {
		return FleetTicket{}, err
	}
	return s.FleetTicket(t.ID)
}

// FleetTicket reads one row; sql.ErrNoRows when there is none.
func (s *Store) FleetTicket(id string) (FleetTicket, error) {
	rows, err := s.read.Query(`SELECT id, owner, title, state, backend, url, origin, endpoint_id,
		created_at, updated_at FROM fleet_ticket_index WHERE id = ?`, id)
	if err != nil {
		return FleetTicket{}, err
	}
	out, err := scanFleetTickets(rows)
	if err != nil {
		return FleetTicket{}, err
	}
	if len(out) == 0 {
		return FleetTicket{}, sql.ErrNoRows
	}
	return out[0], nil
}

// FleetTicketsFor lists one person's tickets, most recently touched first.
func (s *Store) FleetTicketsFor(owner string, limit int) ([]FleetTicket, error) {
	if limit <= 0 {
		limit = 100
	}
	rows, err := s.read.Query(`SELECT id, owner, title, state, backend, url, origin, endpoint_id,
		created_at, updated_at FROM fleet_ticket_index WHERE owner = ?
		ORDER BY updated_at DESC, id LIMIT `+strconv.Itoa(limit), owner)
	if err != nil {
		return nil, err
	}
	return scanFleetTickets(rows)
}

func scanFleetTickets(rows *sql.Rows) ([]FleetTicket, error) {
	defer rows.Close()
	var out []FleetTicket
	for rows.Next() {
		var t FleetTicket
		var created, updated string
		if err := rows.Scan(&t.ID, &t.Owner, &t.Title, &t.State, &t.Backend, &t.URL, &t.Origin,
			&t.EndpointID, &created, &updated); err != nil {
			return nil, err
		}
		t.CreatedAt, _ = time.Parse(rfc, created)
		t.UpdatedAt, _ = time.Parse(rfc, updated)
		out = append(out, t)
	}
	return out, rows.Err()
}
