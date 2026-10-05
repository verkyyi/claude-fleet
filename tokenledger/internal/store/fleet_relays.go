package store

import (
	"fmt"
	"time"
)

// Node-to-node relays (claude-fleet#1421, EPIC #1419 C2): a child's report to
// a parent on another machine, or a message to a worker on another machine.
// The sending node hands one to the hub over its control channel; the hub
// stores it HERE first and only then pushes it down the target node's channel,
// so a target that is offline gets it when it reconnects.
//
// The id is the sender's idempotency key (a child report's is
// `<child worker_id>#<seq>`): the table's primary key, so a resend — the
// sender's outbox retries until the hub acks — is a no-op, never a second
// delivery.
const fleetRelaySchema = `
CREATE TABLE IF NOT EXISTS fleet_relays (
  id              TEXT PRIMARY KEY,
  kind            TEXT NOT NULL,
  from_wid        TEXT NOT NULL,
  to_wid          TEXT NOT NULL,
  from_endpoint   TEXT NOT NULL,
  target_endpoint TEXT NOT NULL,
  payload         TEXT NOT NULL,
  status          TEXT NOT NULL,
  attempts        INTEGER NOT NULL DEFAULT 0,
  detail          TEXT NOT NULL DEFAULT '',
  created         TEXT NOT NULL,
  updated         TEXT NOT NULL,
  sent_at         TEXT NOT NULL DEFAULT '',
  receipt         TEXT NOT NULL DEFAULT '',
  receipt_at      TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS fleet_relays_pending ON fleet_relays(target_endpoint, status);`

// Receipt states (claude-fleet#1647): a settled relay owes its SENDER a
// receipt — delivered, failed or expired — so the sending machine's book says
// what became of it instead of the last word being "queued". Empty → due when the
// relay settles, sent when pushed down the sender's channel, done when the
// sender's node answered.
const (
	ReceiptDue  = "due"
	ReceiptSent = "sent"
	ReceiptDone = "done"
)

// Relay states. pending → delivered | failed; pending → expired after
// RelayTTL with no node to take it.
const (
	RelayPending   = "pending"
	RelayDelivered = "delivered"
	RelayFailed    = "failed"
	RelayExpired   = "expired"
)

// FleetRelay is one stored relay.
type FleetRelay struct {
	ID             string
	Kind           string
	FromWID        string
	ToWID          string
	FromEndpoint   string
	TargetEndpoint string
	Payload        string
	Status         string
	Attempts       int
	Detail         string
	Created        time.Time
	Updated        time.Time
	SentAt         time.Time
	Receipt        string
	ReceiptAt      time.Time
}

func (s *Store) ensureFleetRelays() error {
	if _, err := s.write.Exec(fleetRelaySchema); err != nil {
		return fmt.Errorf("create fleet_relays: %w", err)
	}
	// claude-fleet#1647: a database created before receipts. Additive only.
	for _, col := range []string{"receipt", "receipt_at"} {
		var n int
		if err := s.write.QueryRow(`SELECT COUNT(*) FROM pragma_table_info('fleet_relays') WHERE name = ?`, col).Scan(&n); err != nil {
			return err
		}
		if n == 0 {
			if _, err := s.write.Exec(`ALTER TABLE fleet_relays ADD COLUMN ` + col + ` TEXT NOT NULL DEFAULT ''`); err != nil {
				return fmt.Errorf("add fleet_relays.%s: %w", col, err)
			}
		}
	}
	return nil
}

// InsertFleetRelay stores r as pending. A relay whose id is already stored is
// left exactly as it is: inserted reports false, and the caller acks the
// sender all the same — the first copy is the one that gets delivered.
func (s *Store) InsertFleetRelay(r FleetRelay) (inserted bool, err error) {
	at := r.Created.UTC().Format(rfc)
	res, err := s.write.Exec(`INSERT INTO fleet_relays
		(id, kind, from_wid, to_wid, from_endpoint, target_endpoint, payload, status, created, updated)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(id) DO NOTHING`,
		r.ID, r.Kind, r.FromWID, r.ToWID, r.FromEndpoint, r.TargetEndpoint, r.Payload, RelayPending, at, at)
	if err != nil {
		return false, err
	}
	n, _ := res.RowsAffected()
	return n > 0, nil
}

const fleetRelayCols = `id, kind, from_wid, to_wid, from_endpoint, target_endpoint, payload, status,
	attempts, detail, created, updated, sent_at, receipt, receipt_at`

func scanFleetRelay(sc interface{ Scan(...any) error }) (FleetRelay, error) {
	var r FleetRelay
	var created, updated, sent, rcptAt string
	err := sc.Scan(&r.ID, &r.Kind, &r.FromWID, &r.ToWID, &r.FromEndpoint, &r.TargetEndpoint, &r.Payload,
		&r.Status, &r.Attempts, &r.Detail, &created, &updated, &sent, &r.Receipt, &rcptAt)
	r.Created, _ = time.Parse(rfc, created)
	r.Updated, _ = time.Parse(rfc, updated)
	if sent != "" {
		r.SentAt, _ = time.Parse(rfc, sent)
	}
	if rcptAt != "" {
		r.ReceiptAt, _ = time.Parse(rfc, rcptAt)
	}
	return r, err
}

// FleetRelay reads one relay; sql.ErrNoRows when unknown.
func (s *Store) FleetRelay(id string) (FleetRelay, error) {
	return scanFleetRelay(s.write.QueryRow(`SELECT `+fleetRelayCols+` FROM fleet_relays WHERE id = ?`, id))
}

// PendingFleetRelays lists what still waits for targetEndpoint, oldest first.
func (s *Store) PendingFleetRelays(targetEndpoint string) ([]FleetRelay, error) {
	rows, err := s.write.Query(`SELECT `+fleetRelayCols+` FROM fleet_relays
		WHERE target_endpoint = ? AND status = ? ORDER BY created, id`, targetEndpoint, RelayPending)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []FleetRelay{}
	for rows.Next() {
		r, err := scanFleetRelay(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

// MarkFleetRelaySent records one push of a pending relay down its target's
// channel; the answer comes back as FinishFleetRelay.
func (s *Store) MarkFleetRelaySent(id string, at time.Time) error {
	_, err := s.write.Exec(`UPDATE fleet_relays SET attempts = attempts + 1, sent_at = ?, updated = ?
		WHERE id = ? AND status = ?`, at.UTC().Format(rfc), at.UTC().Format(rfc), id, RelayPending)
	return err
}

// FinishFleetRelay records the target node's final answer. Only a pending
// relay moves: a late duplicate answer never rewrites a settled one.
func (s *Store) FinishFleetRelay(id, status, detail string, at time.Time) error {
	_, err := s.write.Exec(`UPDATE fleet_relays SET status = ?, detail = ?, updated = ?, receipt = ?
		WHERE id = ? AND status = ?`, status, detail, at.UTC().Format(rfc), ReceiptDue, id, RelayPending)
	return err
}

// ExpireFleetRelays settles every relay still pending after ttl as expired.
func (s *Store) ExpireFleetRelays(ttl time.Duration, now time.Time) (int64, error) {
	res, err := s.write.Exec(`UPDATE fleet_relays SET status = ?, detail = 'no node took it within the relay TTL', updated = ?,
		receipt = ? WHERE status = ? AND created < ?`, RelayExpired, now.UTC().Format(rfc), ReceiptDue, RelayPending,
		now.Add(-ttl).UTC().Format(rfc))
	if err != nil {
		return 0, err
	}
	return res.RowsAffected()
}

// DueFleetRelayReceipts lists the settled relays fromEndpoint sent whose
// receipt is owed: never pushed, or pushed more than resend ago with no answer.
func (s *Store) DueFleetRelayReceipts(fromEndpoint string, resend time.Duration, now time.Time) ([]FleetRelay, error) {
	rows, err := s.write.Query(`SELECT `+fleetRelayCols+` FROM fleet_relays
		WHERE from_endpoint = ? AND (receipt = ? OR (receipt = ? AND receipt_at < ?)) ORDER BY updated, id`,
		fromEndpoint, ReceiptDue, ReceiptSent, now.Add(-resend).UTC().Format(rfc))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []FleetRelay{}
	for rows.Next() {
		r, err := scanFleetRelay(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

// MarkFleetRelayReceipt moves a relay's receipt to sent (pushed at at) or
// done (the sender's node answered). Done is final.
func (s *Store) MarkFleetRelayReceipt(id, state string, at time.Time) error {
	_, err := s.write.Exec(`UPDATE fleet_relays SET receipt = ?, receipt_at = ? WHERE id = ? AND receipt IN (?, ?)`,
		state, at.UTC().Format(rfc), id, ReceiptDue, ReceiptSent)
	return err
}
