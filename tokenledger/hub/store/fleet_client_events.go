package store

import (
	"fmt"
	"strconv"
	"strings"
	"time"
)

// A client's connection events (claude-fleet T689, 稳定性①). The `fleet`
// client on a person's computer writes what its line did — a start, the view
// drawn (up, with how long the reconnect took), a drop and ssh's last word,
// a connection that would not come up and why, a change of home, «my own
// line is down» — and sends them here, so a drop is read off the hub instead
// of the person's word. Metadata only: every field is a short code, a machine
// name or a number (the handler refuses anything else); never a credential,
// never a byte of the terminal.
//
// id is the client's own id for the event, prefixed with the person: a batch
// sent twice (the answer lost on the way back) is written once. Rows older
// than ClientEventsKeep are dropped as new ones arrive.
//
// Created only with the fleet module on (EnsureNodes), like every fleet table.
const fleetClientEventsSchema = `
CREATE TABLE IF NOT EXISTS fleet_client_events (
  id           TEXT PRIMARY KEY,
  principal_id TEXT NOT NULL,
  device_fp    TEXT NOT NULL DEFAULT '',
  device       TEXT NOT NULL DEFAULT '',
  at           TEXT NOT NULL,
  received_at  TEXT NOT NULL,
  event        TEXT NOT NULL,
  start_id     TEXT NOT NULL DEFAULT '',
  phase        TEXT NOT NULL DEFAULT '',
  home         TEXT NOT NULL DEFAULT '',
  route        TEXT NOT NULL DEFAULT '',
  to_home      TEXT NOT NULL DEFAULT '',
  ms           INTEGER NOT NULL DEFAULT 0,
  rc           INTEGER NOT NULL DEFAULT 0,
  reason       TEXT NOT NULL DEFAULT '',
  version      TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS fleet_client_events_at ON fleet_client_events(at);
CREATE INDEX IF NOT EXISTS fleet_client_events_principal ON fleet_client_events(principal_id, at);`

// ClientEventsKeep is how long a client event is kept.
const ClientEventsKeep = 30 * 24 * time.Hour

// clientAt is the one time format of the table: fixed width, so a string
// comparison is a time comparison in both dialects.
const clientAt = "2006-01-02T15:04:05Z"

// FleetClientEvent is one connection event a client reported.
type FleetClientEvent struct {
	ID          string    `json:"id"`
	PrincipalID string    `json:"principal_id"`
	DeviceFP    string    `json:"device_fp,omitempty"`
	Device      string    `json:"device"`
	At          time.Time `json:"at"`
	ReceivedAt  time.Time `json:"received_at"`
	Event       string    `json:"event"`
	Start       string    `json:"start,omitempty"`
	Phase       string    `json:"phase,omitempty"`
	Home        string    `json:"home,omitempty"`
	Route       string    `json:"route,omitempty"`
	To          string    `json:"to,omitempty"`
	MS          int64     `json:"ms,omitempty"`
	RC          int64     `json:"rc,omitempty"`
	Reason      string    `json:"reason,omitempty"`
	Version     string    `json:"version,omitempty"`
}

func (s *Store) ensureFleetClientEvents() error {
	if _, err := s.write.Exec(s.d.ddl(fleetClientEventsSchema)); err != nil {
		return fmt.Errorf("create fleet_client_events table: %w", err)
	}
	return nil
}

// AddClientEvents writes a batch; an id already written is skipped. Returns
// how many were new. Rows past ClientEventsKeep go on the same call.
func (s *Store) AddClientEvents(evs []FleetClientEvent, now time.Time) (int, error) {
	added := 0
	q := s.d.insertIgnore(`INSERT OR IGNORE INTO fleet_client_events (id, principal_id, device_fp, device,
		at, received_at, event, start_id, phase, home, route, to_home, ms, rc, reason, version)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`)
	for _, e := range evs {
		res, err := s.write.Exec(q, e.ID, e.PrincipalID, e.DeviceFP, e.Device,
			e.At.UTC().Format(clientAt), now.UTC().Format(clientAt), e.Event, e.Start, e.Phase,
			e.Home, e.Route, e.To, e.MS, e.RC, e.Reason, e.Version)
		if err != nil {
			return added, err
		}
		if n, _ := res.RowsAffected(); n > 0 {
			added++
		}
	}
	if _, err := s.write.Exec(`DELETE FROM fleet_client_events WHERE at < ?`,
		now.Add(-ClientEventsKeep).UTC().Format(clientAt)); err != nil {
		return added, err
	}
	return added, nil
}

// ClientEvents lists events at or after since, oldest first; principalID ""
// is everyone's, device "" every device's. limit <= 0 means 5000.
func (s *Store) ClientEvents(principalID, device string, since time.Time, limit int) ([]FleetClientEvent, error) {
	if limit <= 0 {
		limit = 5000
	}
	where := []string{"at >= ?"}
	args := []any{since.UTC().Format(clientAt)}
	if principalID != "" {
		where, args = append(where, "principal_id = ?"), append(args, principalID)
	}
	if device != "" {
		where, args = append(where, "device = ?"), append(args, device)
	}
	rows, err := s.read.Query(`SELECT id, principal_id, device_fp, device, at, received_at, event,
		start_id, phase, home, route, to_home, ms, rc, reason, version FROM fleet_client_events
		WHERE `+strings.Join(where, " AND ")+` ORDER BY at, id LIMIT `+strconv.Itoa(limit), args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []FleetClientEvent{}
	for rows.Next() {
		var e FleetClientEvent
		var at, recv string
		if err := rows.Scan(&e.ID, &e.PrincipalID, &e.DeviceFP, &e.Device, &at, &recv, &e.Event,
			&e.Start, &e.Phase, &e.Home, &e.Route, &e.To, &e.MS, &e.RC, &e.Reason, &e.Version); err != nil {
			return nil, err
		}
		e.At, _ = time.Parse(clientAt, at)
		e.ReceivedAt, _ = time.Parse(clientAt, recv)
		out = append(out, e)
	}
	return out, rows.Err()
}
