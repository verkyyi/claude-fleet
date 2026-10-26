package store

import (
	"database/sql"
	"fmt"
	"time"
)

const healthSchema = `
CREATE TABLE IF NOT EXISTS fleet_health_probes (
 component TEXT NOT NULL, at INTEGER NOT NULL, state TEXT NOT NULL, ms INTEGER NOT NULL,
 PRIMARY KEY(component, at)
);
CREATE INDEX IF NOT EXISTS fleet_health_probes_at ON fleet_health_probes(at);
CREATE TABLE IF NOT EXISTS fleet_health_events (
 id TEXT PRIMARY KEY, component TEXT NOT NULL, started INTEGER NOT NULL, ended INTEGER NOT NULL DEFAULT 0,
 note_zh TEXT NOT NULL DEFAULT '', note_en TEXT NOT NULL DEFAULT ''
);
CREATE TABLE IF NOT EXISTS fleet_chat_receipts (id TEXT PRIMARY KEY, at INTEGER NOT NULL);
`

type HealthProbe struct {
	Component string `json:"component"`
	At        int64  `json:"at"`
	State     string `json:"state"`
	MS        int64  `json:"ms"`
}
type HealthEvent struct {
	ID        string `json:"id"`
	Component string `json:"component"`
	Started   int64  `json:"started"`
	Ended     int64  `json:"ended"`
	NoteZH    string `json:"note_zh"`
	NoteEN    string `json:"note_en"`
}

func (s *Store) ensureHealth() error { _, err := s.write.Exec(s.d.ddl(healthSchema)); return err }

// RecordHealthProbe commits a minute once across replicas. Only a new incident
// returns true, so continued failures do not repeatedly notify the ops inbox.
func (s *Store) RecordHealthProbe(p HealthProbe, threshold int) (bool, error) {
	tx, err := s.write.Begin()
	if err != nil {
		return false, err
	}
	defer tx.Rollback()
	res, err := tx.Exec(`INSERT INTO fleet_health_probes(component,at,state,ms) VALUES(?,?,?,?) ON CONFLICT(component,at) DO NOTHING`, p.Component, p.At, p.State, p.MS)
	if err != nil {
		return false, err
	}
	n, err := res.RowsAffected()
	if err != nil || n == 0 {
		return false, err
	}
	created := false
	if p.State == "ok" {
		_, err = tx.Exec(`UPDATE fleet_health_events SET ended=? WHERE component=? AND ended=0`, p.At, p.Component)
	} else if p.State == "failed" {
		var fails int
		// A gap breaks the consecutive sequence, including across restarts.
		err = tx.QueryRow(`SELECT COUNT(*) FROM fleet_health_probes WHERE component=? AND at>=? AND at<=? AND state='failed'`, p.Component, p.At-int64(threshold-1)*60000, p.At).Scan(&fails)
		if err == nil && fails >= threshold {
			var active int
			err = tx.QueryRow(`SELECT COUNT(*) FROM fleet_health_events WHERE component=? AND ended=0`, p.Component).Scan(&active)
			if err == nil && active == 0 {
				_, err = tx.Exec(`INSERT INTO fleet_health_events(id,component,started) VALUES(?,?,?)`, fmt.Sprintf("%s-%d", p.Component, p.At), p.Component, p.At)
				created = err == nil
			}
		}
	}
	if err != nil {
		return false, err
	}
	return created, tx.Commit()
}
func (s *Store) HealthProbes(since time.Time) ([]HealthProbe, error) {
	rows, err := s.read.Query(`SELECT component,at,state,ms FROM fleet_health_probes WHERE at>=? ORDER BY at DESC,component`, since.UnixMilli())
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []HealthProbe{}
	for rows.Next() {
		var p HealthProbe
		if err := rows.Scan(&p.Component, &p.At, &p.State, &p.MS); err != nil {
			return nil, err
		}
		out = append(out, p)
	}
	return out, rows.Err()
}
func (s *Store) HealthEvents(since time.Time) ([]HealthEvent, error) {
	rows, err := s.read.Query(`SELECT id,component,started,ended,note_zh,note_en FROM fleet_health_events WHERE started>=? OR ended>=? OR ended=0 ORDER BY started DESC`, since.UnixMilli(), since.UnixMilli())
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []HealthEvent{}
	for rows.Next() {
		var e HealthEvent
		if err := rows.Scan(&e.ID, &e.Component, &e.Started, &e.Ended, &e.NoteZH, &e.NoteEN); err != nil {
			return nil, err
		}
		out = append(out, e)
	}
	return out, rows.Err()
}
func (s *Store) AnnotateHealthEvent(id, zh, en string) (bool, error) {
	r, e := s.write.Exec(`UPDATE fleet_health_events SET note_zh=?,note_en=? WHERE id=?`, zh, en, id)
	if e != nil {
		return false, e
	}
	n, e := r.RowsAffected()
	return n > 0, e
}
func (s *Store) PruneHealth(before time.Time) error {
	for _, q := range []string{`DELETE FROM fleet_health_probes WHERE at<?`, `DELETE FROM fleet_health_events WHERE ended>0 AND ended<?`, `DELETE FROM fleet_chat_receipts WHERE at<?`} {
		if _, e := s.write.Exec(q, before.UnixMilli()); e != nil {
			return e
		}
	}
	return nil
}

// HealthDBStats is this replica's connection pool, not RDS CPU or quota.
func (s *Store) HealthDBStats() sql.DBStats { return s.read.Stats() }
