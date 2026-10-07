package store

import (
	"fmt"
	"strconv"
	"strings"
	"time"
)

// What a worker on ANOTHER machine leaves behind (claude-fleet#1609, EPIC
// #1645 C9). A member the hub placed on m4 captured its 改动前 / 改动后 there and
// was reaped there, so the machine that ran the EPIC saw 无证据 and no history
// row. Now the node that reaps a worker hands the hub what it left — each
// evidence file (text first, images shrunk on the node) and its history ledger
// row — keyed by worker_id; any node of the same owner reads them back by repo
// + issue / EPIC. Kept 30 days (WorkerRecordTTL), then dropped.
//
// Created only with the fleet module on (EnsureNodes), like every fleet table.
const fleetWorkerRecordsSchema = `
CREATE TABLE IF NOT EXISTS fleet_worker_records (
  id          TEXT PRIMARY KEY,
  worker_id   TEXT NOT NULL,
  fleet_id    TEXT NOT NULL,
  origin_wid  TEXT NOT NULL DEFAULT '',
  owner       TEXT NOT NULL,
  endpoint_id TEXT NOT NULL,
  node        TEXT NOT NULL DEFAULT '',
  repo        TEXT NOT NULL,
  issue       INTEGER NOT NULL DEFAULT 0,
  key         TEXT NOT NULL DEFAULT '',
  epic        INTEGER NOT NULL DEFAULT 0,
  kind        TEXT NOT NULL,
  name        TEXT NOT NULL,
  stage       TEXT NOT NULL DEFAULT '',
  ts          TEXT NOT NULL DEFAULT '',
  note        TEXT NOT NULL DEFAULT '',
  content     BLOB,
  size        INTEGER NOT NULL DEFAULT 0,
  created_at  TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS fleet_worker_records_repo ON fleet_worker_records(owner, repo, issue);
CREATE INDEX IF NOT EXISTS fleet_worker_records_epic ON fleet_worker_records(owner, repo, epic);
CREATE INDEX IF NOT EXISTS fleet_worker_records_wid ON fleet_worker_records(worker_id);
CREATE INDEX IF NOT EXISTS fleet_worker_records_created ON fleet_worker_records(created_at);`

// WorkerRecordTTL is how long the hub keeps a worker's evidence and history.
const WorkerRecordTTL = 30 * 24 * time.Hour

// FleetWorkerRecord is one file or ledger row a worker left behind.
type FleetWorkerRecord struct {
	ID         string    `json:"id"`
	WorkerID   string    `json:"worker_id"`
	FleetID    string    `json:"fleet_id"`
	OriginWID  string    `json:"origin_wid,omitempty"`
	Owner      string    `json:"-"`
	EndpointID string    `json:"-"`
	Node       string    `json:"node"`
	Repo       string    `json:"repo"`
	Issue      int       `json:"issue,omitempty"`
	Key        string    `json:"key,omitempty"`
	Epic       int       `json:"epic,omitempty"`
	Kind       string    `json:"kind"` // evidence | history
	Name       string    `json:"name"`
	Stage      string    `json:"stage,omitempty"`
	TS         string    `json:"ts,omitempty"`
	Note       string    `json:"note,omitempty"`
	Content    []byte    `json:"content,omitempty"` // base64 in JSON
	Size       int       `json:"size"`
	CreatedAt  time.Time `json:"created_at"`
}

// WorkerRecordQuery selects records of one owner: every set field narrows.
type WorkerRecordQuery struct {
	Owner    string
	Repo     string
	Issue    int
	Epic     int
	Kind     string
	WorkerID string
	Content  bool // false: leave the bytes out (a listing)
	Limit    int
}

func (s *Store) ensureFleetWorkerRecords() error {
	if _, err := s.write.Exec(s.d.ddl(fleetWorkerRecordsSchema)); err != nil {
		return fmt.Errorf("create fleet_worker_records table: %w", err)
	}
	return nil
}

// PutWorkerRecords upserts records in one transaction: an upload sent twice
// (the ship report, then the reap) replaces, never doubles.
func (s *Store) PutWorkerRecords(recs []FleetWorkerRecord) error {
	tx, err := s.write.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	for _, r := range recs {
		if _, err := tx.Exec(s.d.insertReplace(`INSERT OR REPLACE INTO fleet_worker_records (id, worker_id, fleet_id,
			origin_wid, owner, endpoint_id, node, repo, issue, key, epic, kind, name, stage, ts, note,
			content, size, created_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`, "id"),
			r.ID, r.WorkerID, r.FleetID, r.OriginWID, r.Owner, r.EndpointID, r.Node, r.Repo, r.Issue,
			r.Key, r.Epic, r.Kind, r.Name, r.Stage, r.TS, r.Note, r.Content, len(r.Content),
			r.CreatedAt.UTC().Format(rfc)); err != nil {
			return err
		}
	}
	return tx.Commit()
}

// WorkerRecords reads the records q selects, oldest first.
func (s *Store) WorkerRecords(q WorkerRecordQuery) ([]FleetWorkerRecord, error) {
	where := []string{"owner = ?"}
	args := []any{q.Owner}
	if q.Repo != "" {
		where, args = append(where, "repo = ?"), append(args, q.Repo)
	}
	if q.Issue > 0 {
		where, args = append(where, "issue = ?"), append(args, q.Issue)
	}
	if q.Epic > 0 {
		where, args = append(where, "epic = ?"), append(args, q.Epic)
	}
	if q.Kind != "" {
		where, args = append(where, "kind = ?"), append(args, q.Kind)
	}
	if q.WorkerID != "" {
		where, args = append(where, "worker_id = ?"), append(args, q.WorkerID)
	}
	limit := q.Limit
	if limit <= 0 || limit > 5000 {
		limit = 5000
	}
	content := "NULL"
	if q.Content {
		content = "content"
	}
	rows, err := s.read.Query(`SELECT id, worker_id, fleet_id, origin_wid, node, repo, issue, key, epic,
		kind, name, stage, ts, note, `+content+`, size, created_at FROM fleet_worker_records
		WHERE `+strings.Join(where, " AND ")+` ORDER BY created_at, id LIMIT `+strconv.Itoa(limit), args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []FleetWorkerRecord{}
	for rows.Next() {
		var r FleetWorkerRecord
		var created string
		var blob []byte
		if err := rows.Scan(&r.ID, &r.WorkerID, &r.FleetID, &r.OriginWID, &r.Node, &r.Repo, &r.Issue,
			&r.Key, &r.Epic, &r.Kind, &r.Name, &r.Stage, &r.TS, &r.Note, &blob, &r.Size, &created); err != nil {
			return nil, err
		}
		if len(blob) > 0 { // empty reads as none on both stores: SQLite says nil, Postgres []byte{}
			r.Content = blob
		}
		r.CreatedAt, _ = time.Parse(rfc, created)
		out = append(out, r)
	}
	return out, rows.Err()
}

// ExpireWorkerRecords drops what is older than ttl.
func (s *Store) ExpireWorkerRecords(ttl time.Duration, now time.Time) (int64, error) {
	res, err := s.write.Exec(`DELETE FROM fleet_worker_records WHERE created_at < ?`,
		now.Add(-ttl).UTC().Format(rfc))
	if err != nil {
		return 0, err
	}
	return res.RowsAffected()
}
