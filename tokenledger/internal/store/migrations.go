package store

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"log"
	"time"
)

// Numbered migrations: the changes a database cannot get from schema.sql's
// CREATE IF NOT EXISTS and migrate()'s added columns — a table dropped, rows
// deleted. Each runs once, in its own transaction, and is recorded in
// hub_migrations with what it did; the number is what the deploy RUNBOOK
// names (deploy/k8s/RUNBOOK.md «库迁移»). Rolling one back is the previous
// image plus the snapshot hub-deploy takes before every release — there is no
// down migration.

// migration is one numbered step.
type migration struct {
	ID   int
	Name string
	Run  func(tx *sql.Tx) (map[string]int64, error)
}

// migrations is every numbered step, in order. Never renumber or edit one
// that has shipped: a database records the number it ran.
var migrations = []migration{
	{ID: 1, Name: "remove-company-business", Run: removeCompanyBusiness},
}

// RemovedSources are the usage sources migration 1 deleted (claude-fleet#1987):
// a gateway's metered calls, vendor invoices and voice-call usage. Nothing on
// this hub takes them any more; the rows that remain are Claude and Codex.
var RemovedSources = []string{"gateway", "vendor_bill", "voice"}

// removedTables are the tables of the features migration 1 removed: the
// business ledger, repo progress, share links, the findings notifier's memory.
var removedTables = []string{
	"growth_facts",
	"repo_issues", "repo_days", "repo_health", "repo_human_steps", "repo_human_days",
	"share_links",
	"finding_notices",
}

// sourceTables carry a `source` column; migration 1 deletes the removed
// sources' rows from each and leaves every other row alone.
var sourceTables = []string{
	"usage_events", "usage_hourly", "accounts", "quota_snapshots",
	"source_collectors", "source_account_switches", "source_pool_bindings",
	"account_usage_observations", "subscription_plans",
}

func removeCompanyBusiness(tx *sql.Tx) (map[string]int64, error) {
	done := map[string]int64{}
	in := "'" + RemovedSources[0] + "'"
	for _, src := range RemovedSources[1:] {
		in += ", '" + src + "'"
	}
	for _, t := range sourceTables {
		res, err := tx.Exec(fmt.Sprintf(`DELETE FROM %s WHERE source IN (%s)`, t, in))
		if err != nil {
			return nil, fmt.Errorf("delete removed sources from %s: %w", t, err)
		}
		if n, _ := res.RowsAffected(); n > 0 {
			done["deleted."+t] = n
		}
	}
	for _, t := range removedTables {
		var n int64
		if err := tx.QueryRow(`SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?`, t).Scan(&n); err != nil {
			return nil, err
		}
		if n == 0 {
			continue
		}
		if err := tx.QueryRow(fmt.Sprintf(`SELECT COUNT(*) FROM %s`, t)).Scan(&n); err != nil {
			return nil, err
		}
		if _, err := tx.Exec(`DROP TABLE ` + t); err != nil {
			return nil, fmt.Errorf("drop %s: %w", t, err)
		}
		done["dropped."+t] = n
	}
	// The shippers' tokens pushed into what was just dropped; nothing on this
	// hub accepts their data now, so they stop authenticating anywhere.
	res, err := tx.Exec(`UPDATE endpoints SET retired_at = ?
		WHERE kind IN ('repo_shipper', 'growth_shipper', 'growth_reader') AND retired_at IS NULL`,
		fmtTime(time.Now()))
	if err != nil {
		return nil, fmt.Errorf("retire shipper enrollments: %w", err)
	}
	if n, _ := res.RowsAffected(); n > 0 {
		done["retired.shippers"] = n
	}
	return done, nil
}

// runMigrations applies every numbered migration this database has not run.
func runMigrations(db *sql.DB) error {
	if _, err := db.Exec(`CREATE TABLE IF NOT EXISTS hub_migrations (
		id         INTEGER PRIMARY KEY,
		name       TEXT NOT NULL,
		applied_at TEXT NOT NULL,
		detail     TEXT NOT NULL DEFAULT '{}'
	)`); err != nil {
		return fmt.Errorf("create hub_migrations: %w", err)
	}
	for _, m := range migrations {
		var n int
		if err := db.QueryRow(`SELECT COUNT(*) FROM hub_migrations WHERE id = ?`, m.ID).Scan(&n); err != nil {
			return fmt.Errorf("read hub_migrations: %w", err)
		}
		if n > 0 {
			continue
		}
		tx, err := db.Begin()
		if err != nil {
			return err
		}
		done, err := m.Run(tx)
		if err != nil {
			tx.Rollback()
			return fmt.Errorf("migration %d (%s): %w", m.ID, m.Name, err)
		}
		detail, _ := json.Marshal(done)
		if _, err := tx.Exec(`INSERT INTO hub_migrations (id, name, applied_at, detail) VALUES (?, ?, ?, ?)`,
			m.ID, m.Name, fmtTime(time.Now()), string(detail)); err != nil {
			tx.Rollback()
			return fmt.Errorf("record migration %d: %w", m.ID, err)
		}
		if err := tx.Commit(); err != nil {
			return fmt.Errorf("migration %d (%s): %w", m.ID, m.Name, err)
		}
		log.Printf("store: migration %d (%s) applied: %s", m.ID, m.Name, detail)
	}
	return nil
}

// Migration is one applied numbered migration, as hub_migrations holds it.
type Migration struct {
	ID        int
	Name      string
	AppliedAt string
	Detail    string
}

// Migrations lists the numbered migrations this database has run.
func (s *Store) Migrations() ([]Migration, error) {
	rows, err := s.read.Query(`SELECT id, name, applied_at, detail FROM hub_migrations ORDER BY id`)
	if err != nil {
		return nil, fmt.Errorf("list migrations: %w", err)
	}
	defer rows.Close()
	var out []Migration
	for rows.Next() {
		var m Migration
		if err := rows.Scan(&m.ID, &m.Name, &m.AppliedAt, &m.Detail); err != nil {
			return nil, err
		}
		out = append(out, m)
	}
	return out, rows.Err()
}
