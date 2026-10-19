package store

import (
	"fmt"
	"time"
)

// Attachments a client's writing area sends with a task (claude-fleet#2393,
// EPIC #2482 C1).
//
// A file dropped into the writing area exists on the CLIENT computer; the
// session it starts runs on another machine. The client sends each file's
// bytes with its signed place request, the hub keeps them here — never in the
// operation journal, never on the 1 MiB control channel — and names them in
// the start it sends the chosen node; that node's agent downloads each one
// (GET /v1/node/attachment/<id>, its own token: only the endpoint the start
// was sent to may) before claude-fleet runs the start. The hub only passes
// them through: every row expires after FleetAttachmentTTL.
const fleetAttachmentSchema = `
CREATE TABLE IF NOT EXISTS fleet_attachments (
  id              TEXT PRIMARY KEY,
  actor           TEXT NOT NULL,
  target_endpoint TEXT NOT NULL DEFAULT '',
  name            TEXT NOT NULL,
  sha256          TEXT NOT NULL,
  size            INTEGER NOT NULL,
  data            BLOB,
  created         TEXT NOT NULL
);`

// FleetAttachmentTTL is how long an attachment waits to be fetched: a start
// takes seconds; an hour covers a retry and a slow machine.
const FleetAttachmentTTL = time.Hour

// FleetAttachment is one attachment's record, without its bytes.
type FleetAttachment struct {
	ID             string
	Actor          string
	TargetEndpoint string
	Name           string
	SHA256         string
	Size           int64
	Created        time.Time
}

func (s *Store) ensureFleetAttachments() error {
	if _, err := s.write.Exec(s.d.ddl(fleetAttachmentSchema)); err != nil {
		return fmt.Errorf("create fleet_attachments: %w", err)
	}
	return nil
}

// PutFleetAttachment stores one attachment. Its id is derived from the
// request it came with, so a repeated request stores nothing new.
func (s *Store) PutFleetAttachment(a FleetAttachment, data []byte) error {
	_, err := s.write.Exec(s.d.insertIgnore(`INSERT OR IGNORE INTO fleet_attachments (id, actor, name, sha256, size, data, created)
		VALUES (?, ?, ?, ?, ?, ?, ?)`), a.ID, a.Actor, a.Name, a.SHA256, a.Size, data, a.Created.UTC().Format(rfc))
	return err
}

// BindFleetAttachment names the endpoint a start carrying the attachment is
// sent to — the only one that may download it. A start tried on the next
// machine rebinds it.
func (s *Store) BindFleetAttachment(id, endpoint string) error {
	_, err := s.write.Exec(`UPDATE fleet_attachments SET target_endpoint = ? WHERE id = ?`, endpoint, id)
	return err
}

// FleetAttachmentData is an attachment's record and bytes; sql.ErrNoRows when
// there is no such attachment.
func (s *Store) FleetAttachmentData(id string) (FleetAttachment, []byte, error) {
	var a FleetAttachment
	var created string
	var data []byte
	err := s.write.QueryRow(`SELECT id, actor, target_endpoint, name, sha256, size, created, data
		FROM fleet_attachments WHERE id = ? AND data IS NOT NULL`, id).
		Scan(&a.ID, &a.Actor, &a.TargetEndpoint, &a.Name, &a.SHA256, &a.Size, &created, &data)
	if err != nil {
		return a, nil, err
	}
	a.Created, _ = time.Parse(rfc, created)
	return a, data, nil
}

// ExpireFleetAttachments drops every attachment older than ttl.
func (s *Store) ExpireFleetAttachments(ttl time.Duration, at time.Time) (int64, error) {
	res, err := s.write.Exec(`DELETE FROM fleet_attachments WHERE created < ?`, at.Add(-ttl).UTC().Format(rfc))
	if err != nil {
		return 0, err
	}
	return res.RowsAffected()
}
