package store

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"log"
	"strings"
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
		if err := deleteRows(tx, t, fmt.Sprintf(`source IN (%s)`, in), done, map[string]bool{}); err != nil {
			return nil, fmt.Errorf("delete removed sources from %s: %w", t, err)
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

// deleteRows deletes table's rows matching where, after letting go of every
// row elsewhere that references one of them (claude-fleet#2050: production's
// endpoints pointed at the gateway / voice accounts, and the bare DELETE died
// on FOREIGN KEY constraint failed). The references come from PRAGMA
// foreign_key_list over every table, not from a list written here, so a table
// added later is covered: a nullable reference is set NULL (an endpoint goes
// back to "enrolled, never reported" and keeps its row), a NOT NULL one is
// deleted with its own dependents first. Counts land in done as
// "deleted.<table>" / "unlinked.<table>.<column>".
func deleteRows(tx *sql.Tx, table, where string, done map[string]int64, visiting map[string]bool) error {
	if visiting[table] {
		return fmt.Errorf("foreign keys cycle through %s", table)
	}
	visiting[table] = true
	defer delete(visiting, table)

	refs, err := referencesTo(tx, table)
	if err != nil {
		return err
	}
	for _, r := range refs {
		// The child rows whose key is one of the rows about to go.
		match := fmt.Sprintf(`(%s) IN (SELECT %s FROM %s WHERE %s)`,
			strings.Join(r.from, ", "), strings.Join(r.to, ", "), table, where)
		if r.nullable {
			set := make([]string, len(r.from))
			for i, c := range r.from {
				set[i] = c + " = NULL"
			}
			res, err := tx.Exec(fmt.Sprintf(`UPDATE %s SET %s WHERE %s`, r.child, strings.Join(set, ", "), match))
			if err != nil {
				return fmt.Errorf("unlink %s.%s: %w", r.child, strings.Join(r.from, ","), err)
			}
			if n, _ := res.RowsAffected(); n > 0 {
				done["unlinked."+r.child+"."+strings.Join(r.from, ",")] += n
			}
			continue
		}
		if err := deleteRows(tx, r.child, match, done, visiting); err != nil {
			return err
		}
	}
	res, err := tx.Exec(fmt.Sprintf(`DELETE FROM %s WHERE %s`, table, where))
	if err != nil {
		return fmt.Errorf("delete from %s: %w", table, err)
	}
	if n, _ := res.RowsAffected(); n > 0 {
		done["deleted."+table] += n
	}
	return nil
}

// fkRef is one foreign key from child(from…) to a parent's (to…).
type fkRef struct {
	child    string
	from, to []string
	nullable bool // every from column may hold NULL
}

// referencesTo lists every foreign key, in any table, that points at parent.
func referencesTo(tx *sql.Tx, parent string) ([]fkRef, error) {
	rows, err := tx.Query(`SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name`)
	if err != nil {
		return nil, err
	}
	var tables []string
	for rows.Next() {
		var n string
		if err := rows.Scan(&n); err != nil {
			rows.Close()
			return nil, err
		}
		tables = append(tables, n)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}

	var parentPK []string
	var out []fkRef
	for _, child := range tables {
		fks, err := tx.Query(`SELECT id, "table", "from", "to" FROM pragma_foreign_key_list(?) ORDER BY id, seq`, child)
		if err != nil {
			return nil, fmt.Errorf("foreign keys of %s: %w", child, err)
		}
		byID := map[int]*fkRef{}
		var ids []int
		for fks.Next() {
			var id int
			var tbl, from string
			var to sql.NullString
			if err := fks.Scan(&id, &tbl, &from, &to); err != nil {
				fks.Close()
				return nil, err
			}
			if !strings.EqualFold(tbl, parent) {
				continue
			}
			r := byID[id]
			if r == nil {
				r = &fkRef{child: child, nullable: true}
				byID[id] = r
				ids = append(ids, id)
			}
			r.from = append(r.from, from)
			r.to = append(r.to, to.String) // "" = the parent's primary key, filled below
		}
		fks.Close()
		if err := fks.Err(); err != nil {
			return nil, err
		}
		if len(ids) == 0 {
			continue
		}
		notnull, err := notNullColumns(tx, child)
		if err != nil {
			return nil, err
		}
		for _, id := range ids {
			r := byID[id]
			if r.to[0] == "" {
				if parentPK == nil {
					if parentPK, err = primaryKey(tx, parent); err != nil {
						return nil, err
					}
				}
				if len(parentPK) != len(r.from) {
					return nil, fmt.Errorf("foreign key %s → %s: %d columns against a %d-column key", child, parent, len(r.from), len(parentPK))
				}
				r.to = parentPK
			}
			for _, c := range r.from {
				if notnull[c] {
					r.nullable = false
				}
			}
			out = append(out, *r)
		}
	}
	return out, nil
}

// notNullColumns names table's columns that refuse NULL (a primary-key column
// counts: SQLite would let a non-integer one hold NULL, the hub never does).
func notNullColumns(tx *sql.Tx, table string) (map[string]bool, error) {
	rows, err := tx.Query(`SELECT name, "notnull", pk FROM pragma_table_info(?)`, table)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[string]bool{}
	for rows.Next() {
		var name string
		var nn, pk int
		if err := rows.Scan(&name, &nn, &pk); err != nil {
			return nil, err
		}
		out[name] = nn != 0 || pk != 0
	}
	return out, rows.Err()
}

// primaryKey lists table's primary-key columns in key order.
func primaryKey(tx *sql.Tx, table string) ([]string, error) {
	rows, err := tx.Query(`SELECT name FROM pragma_table_info(?) WHERE pk > 0 ORDER BY pk`, table)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var n string
		if err := rows.Scan(&n); err != nil {
			return nil, err
		}
		out = append(out, n)
	}
	if len(out) == 0 {
		out = []string{"rowid"}
	}
	return out, rows.Err()
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
