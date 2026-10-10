package store

import (
	"database/sql"
	"errors"
	"fmt"
	"time"
)

// Debug tickets (claude-fleet#2891, EPIC #2889 C2): the one thing a computer
// that never signed in holds to reach the hub's /v1/fleet/debug/* doors. The
// ticket itself is HMAC-signed by the hub (the api package); this table is
// what the signature cannot carry — which tickets were issued (and from
// where, for the issue rate limits), which were superseded or revoked, the
// fingerprint an admin-issued ticket bound to on its first use — and the
// per-ticket, per-day use counters the quotas read.
//
// Created only with the fleet module on (EnsureNodes), like every fleet table.
const fleetDebugTicketsSchema = `
CREATE TABLE IF NOT EXISTS fleet_debug_tickets (
  id           TEXT PRIMARY KEY,
  owner        TEXT NOT NULL,
  fp           TEXT NOT NULL,
  issued_by    TEXT NOT NULL,
  ip           TEXT NOT NULL,
  version      TEXT NOT NULL,
  created_at   TEXT NOT NULL,
  expires_at   TEXT NOT NULL,
  revoked_at   TEXT NOT NULL,
  revoked_why  TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS fleet_debug_tickets_created ON fleet_debug_tickets(created_at);
CREATE INDEX IF NOT EXISTS fleet_debug_tickets_fp ON fleet_debug_tickets(fp);
CREATE TABLE IF NOT EXISTS fleet_debug_uses (
  ticket_id    TEXT NOT NULL,
  kind         TEXT NOT NULL,
  day          TEXT NOT NULL,
  n            INTEGER NOT NULL,
  PRIMARY KEY (ticket_id, kind, day)
);`

// DebugUseAll is the ticket_id of the hub-wide counter row (a real ticket id
// always starts "dt_").
const DebugUseAll = "*"

// DebugTicket is one issued ticket's row.
type DebugTicket struct {
	ID         string    `json:"id"`
	Owner      string    `json:"owner,omitempty"`
	FP         string    `json:"fp,omitempty"`
	IssuedBy   string    `json:"by"`
	IP         string    `json:"ip,omitempty"`
	Version    string    `json:"version,omitempty"`
	CreatedAt  time.Time `json:"created_at"`
	ExpiresAt  time.Time `json:"expires_at"`
	RevokedAt  time.Time `json:"revoked_at,omitzero"`
	RevokedWhy string    `json:"revoked_why,omitempty"`
}

// ErrDebugQuota: the counter is at its limit for the day.
var ErrDebugQuota = errors.New("debug quota spent for today")

func (s *Store) ensureFleetDebugTickets() error {
	if _, err := s.write.Exec(s.d.ddl(fleetDebugTicketsSchema)); err != nil {
		return fmt.Errorf("create fleet_debug_tickets tables: %w", err)
	}
	return nil
}

const debugTicketCols = `id, owner, fp, issued_by, ip, version, created_at, expires_at, revoked_at, revoked_why`

func scanDebugTicket(sc interface{ Scan(...any) error }) (*DebugTicket, error) {
	var t DebugTicket
	var created, expires, revoked string
	if err := sc.Scan(&t.ID, &t.Owner, &t.FP, &t.IssuedBy, &t.IP, &t.Version, &created, &expires, &revoked, &t.RevokedWhy); err != nil {
		return nil, err
	}
	t.CreatedAt, _ = time.Parse(rfc, created)
	t.ExpiresAt, _ = time.Parse(rfc, expires)
	if revoked != "" {
		t.RevokedAt, _ = time.Parse(rfc, revoked)
	}
	return &t, nil
}

// IssueDebugTicket writes a new ticket and retires, in the same breath, every
// active ticket it replaces — the same fingerprint's, and (when it has an
// owner) the same owner's: a re-issue overwrites, never adds (EPIC #2889
// 共同约定 3). Returns how many it retired.
func (s *Store) IssueDebugTicket(t DebugTicket) (int64, error) {
	now := t.CreatedAt.UTC().Format(rfc)
	tx, err := s.write.Begin()
	if err != nil {
		return 0, err
	}
	defer tx.Rollback() //nolint:errcheck // a committed tx makes this a no-op
	var n int64
	if t.FP != "" {
		res, err := tx.Exec(`UPDATE fleet_debug_tickets SET revoked_at = ?, revoked_why = ? WHERE fp = ? AND revoked_at = ''`,
			now, "superseded by "+t.ID, t.FP)
		if err != nil {
			return 0, err
		}
		k, _ := res.RowsAffected()
		n += k
	}
	if t.Owner != "" {
		res, err := tx.Exec(`UPDATE fleet_debug_tickets SET revoked_at = ?, revoked_why = ? WHERE owner = ? AND revoked_at = ''`,
			now, "superseded by "+t.ID, t.Owner)
		if err != nil {
			return 0, err
		}
		k, _ := res.RowsAffected()
		n += k
	}
	if _, err := tx.Exec(`INSERT INTO fleet_debug_tickets (`+debugTicketCols+`) VALUES (?, ?, ?, ?, ?, ?, ?, ?, '', '')`,
		t.ID, t.Owner, t.FP, t.IssuedBy, t.IP, t.Version, now, t.ExpiresAt.UTC().Format(rfc)); err != nil {
		return 0, err
	}
	return n, tx.Commit()
}

// DebugTicketByID is one ticket's row; nil, nil when there is none.
func (s *Store) DebugTicketByID(id string) (*DebugTicket, error) {
	t, err := scanDebugTicket(s.read.QueryRow(`SELECT `+debugTicketCols+` FROM fleet_debug_tickets WHERE id = ?`, id))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	return t, err
}

// BindDebugTicket ties an unbound ticket (an admin's re-issue) to the
// fingerprint of the computer that first used it, retiring every other active
// ticket on that fingerprint. One conditional UPDATE, so two computers racing
// on one pasted ticket bind exactly one; false = it was already bound (re-read
// the row to see to whom).
func (s *Store) BindDebugTicket(id, fp string, now time.Time) (bool, error) {
	ts := now.UTC().Format(rfc)
	tx, err := s.write.Begin()
	if err != nil {
		return false, err
	}
	defer tx.Rollback() //nolint:errcheck
	res, err := tx.Exec(`UPDATE fleet_debug_tickets SET fp = ? WHERE id = ? AND fp = ''`, fp, id)
	if err != nil {
		return false, err
	}
	if k, _ := res.RowsAffected(); k == 0 {
		return false, nil
	}
	if _, err := tx.Exec(`UPDATE fleet_debug_tickets SET revoked_at = ?, revoked_why = ? WHERE fp = ? AND id <> ? AND revoked_at = ''`,
		ts, "superseded by "+id, fp, id); err != nil {
		return false, err
	}
	return true, tx.Commit()
}

// CountDebugTickets counts the tickets issued since since — from ip, or from
// anywhere when ip is "" — leaving out the admin's re-issues (those are not
// what the issue limits guard against).
func (s *Store) CountDebugTickets(ip string, since time.Time) (int, error) {
	q := `SELECT COUNT(*) FROM fleet_debug_tickets WHERE created_at >= ? AND issued_by NOT LIKE 'admin:%'`
	args := []any{since.UTC().Format(rfc)}
	if ip != "" {
		q += ` AND ip = ?`
		args = append(args, ip)
	}
	var n int
	err := s.read.QueryRow(q, args...).Scan(&n)
	return n, err
}

// DebugTickets lists the tickets issued since since, newest first.
func (s *Store) DebugTickets(since time.Time, limit int) ([]DebugTicket, error) {
	if limit <= 0 {
		limit = 200
	}
	rows, err := s.read.Query(`SELECT `+debugTicketCols+` FROM fleet_debug_tickets WHERE created_at >= ? ORDER BY created_at DESC, id LIMIT ?`,
		since.UTC().Format(rfc), limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []DebugTicket{}
	for rows.Next() {
		t, err := scanDebugTicket(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *t)
	}
	return out, rows.Err()
}

// UseDebug takes one of the day's limit uses of kind for ticketID: the
// counter goes up by one only while it is under limit (one conditional
// UPDATE, so concurrent uses never overshoot). ErrDebugQuota when it is spent.
func (s *Store) UseDebug(ticketID, kind, day string, limit int) error {
	if _, err := s.write.Exec(`INSERT INTO fleet_debug_uses (ticket_id, kind, day, n) VALUES (?, ?, ?, 0)
		ON CONFLICT(ticket_id, kind, day) DO NOTHING`, ticketID, kind, day); err != nil {
		return err
	}
	res, err := s.write.Exec(`UPDATE fleet_debug_uses SET n = n + 1 WHERE ticket_id = ? AND kind = ? AND day = ? AND n < ?`,
		ticketID, kind, day, limit)
	if err != nil {
		return err
	}
	if k, _ := res.RowsAffected(); k == 0 {
		return ErrDebugQuota
	}
	return nil
}

// UnuseDebug gives one use back (a use taken for a request that then failed
// further on — the hub-wide counter when the ticket's own was spent).
func (s *Store) UnuseDebug(ticketID, kind, day string) error {
	_, err := s.write.Exec(`UPDATE fleet_debug_uses SET n = n - 1 WHERE ticket_id = ? AND kind = ? AND day = ? AND n > 0`,
		ticketID, kind, day)
	return err
}

// DebugUses is the day's counters of one ticket: kind → n.
func (s *Store) DebugUses(ticketID, day string) (map[string]int, error) {
	rows, err := s.read.Query(`SELECT kind, n FROM fleet_debug_uses WHERE ticket_id = ? AND day = ?`, ticketID, day)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[string]int{}
	for rows.Next() {
		var k string
		var n int
		if err := rows.Scan(&k, &n); err != nil {
			return nil, err
		}
		out[k] = n
	}
	return out, rows.Err()
}
