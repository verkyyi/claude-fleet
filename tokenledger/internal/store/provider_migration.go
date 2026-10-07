package store

import (
	"database/sql"
	"fmt"
	"log"
	"strings"
)

// migrateHourlyProvider adds usage_hourly.provider to the PRIMARY KEY.
//
// SQLite cannot alter a primary key, so this is the rename-recreate-copy dance
// migrateSources already performs for `source`, and it copies rather than
// rebuilds for the same reason: rollup history outlives the raw events it came
// from, and reconstructing from usage_events would silently drop every hour
// whose raw rows have been pruned.
//
// Existing rows get ” -- NOT a provider inferred from source or model. Those
// hours genuinely predate the dimension; a fabricated breakdown that adds up is
// worse than an honest blank one that does not, and ProviderNote was what told
// a reader which is which.
func migrateHourlyProvider(db *sql.DB) error {
	has, err := hasColumn(db, "usage_hourly", "provider")
	if err != nil || has {
		return err
	}
	tx, err := db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()

	if _, err := tx.Exec(`ALTER TABLE usage_hourly RENAME TO usage_hourly_before_provider`); err != nil {
		return err
	}
	start := strings.Index(schemaSQL, "CREATE TABLE IF NOT EXISTS usage_hourly (")
	if start < 0 {
		return fmt.Errorf("usage_hourly definition not found in schema.sql")
	}
	end := start + strings.Index(schemaSQL[start:], ";") + 1
	if _, err := tx.Exec(dialectOf(db).ddl(schemaSQL[start:end])); err != nil {
		return err
	}
	// Copy whatever the old table actually has, not a hard-coded list: columns
	// reach usage_hourly by two routes -- schema.sql and migrateDetails' ALTERs
	// -- so the shape on disk depends on which version created the database.
	// A fixed list drops a column on one of those histories, silently.
	keep, err := commonColumns(dialectOf(db), tx, "usage_hourly_before_provider", "usage_hourly")
	if err != nil {
		return err
	}
	cols := strings.Join(keep, ", ")
	var carried int64
	if err := tx.QueryRow(`SELECT COUNT(*) FROM usage_hourly_before_provider`).Scan(&carried); err != nil {
		return err
	}
	if _, err := tx.Exec(`INSERT INTO usage_hourly (` + cols + `, provider)
		SELECT ` + cols + `, '' FROM usage_hourly_before_provider;
		DROP TABLE usage_hourly_before_provider;
		CREATE INDEX IF NOT EXISTS idx_hourly_account_hour ON usage_hourly(account_uuid, hour);
		CREATE INDEX IF NOT EXISTS idx_hourly_session ON usage_hourly(account_uuid, session_id)`); err != nil {
		return fmt.Errorf("migrate hourly provider: %w", err)
	}
	if carried > 0 {
		// Say it out loud. Every read path for a breakdown goes through
		// usage_hourly, so until these rows are re-derived the provider
		// dimension answers "" for ALL history and the feature looks broken
		// rather than empty. The operator cannot infer that from a silent
		// migration, and the rebuild is their call: it is expensive and it
		// touches history, which is not something a startup should do behind
		// their back.
		log.Printf("provider: carried %d pre-existing usage_hourly row(s) across with an empty provider — "+
			"raw events keep theirs, but every breakdown reads the rollup, so the provider dimension "+
			"will report nothing for this history until you run "+
			"`ccquota hub --rebuild-rollup --rebuild-rollup-force`, which re-derives whatever raw events "+
			"still cover and leaves pre-retention hours untouched", carried)
	}
	return tx.Commit()
}

// commonColumns lists the columns both tables have, excluding provider (which
// the old table by definition lacks). Order follows the old table, so the
// SELECT and the INSERT line up.
func commonColumns(d dialect, tx *sql.Tx, from, to string) ([]string, error) {
	cols := func(table string) (map[string]bool, []string, error) {
		cs, err := d.columns(tx, table)
		if err != nil {
			return nil, nil, err
		}
		set, order := map[string]bool{}, []string(nil)
		for _, c := range cs {
			set[c.name] = true
			order = append(order, c.name)
		}
		return set, order, nil
	}
	_, oldOrder, err := cols(from)
	if err != nil {
		return nil, err
	}
	newSet, _, err := cols(to)
	if err != nil {
		return nil, err
	}
	var keep []string
	for _, c := range oldOrder {
		if c != "provider" && newSet[c] {
			keep = append(keep, c)
		}
	}
	if len(keep) == 0 {
		return nil, fmt.Errorf("no columns in common between %s and %s", from, to)
	}
	return keep, nil
}
