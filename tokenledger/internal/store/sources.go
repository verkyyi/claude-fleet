package store

import (
	"database/sql"
	"fmt"
	"strings"

	"github.com/verkyyi/ccquota/internal/model"
)

func (s *Store) SourceForAccount(account string) (string, error) {
	var source string
	err := s.read.QueryRow(`SELECT source FROM accounts WHERE account_uuid = ?`, account).Scan(&source)
	if err == sql.ErrNoRows {
		return model.SourceClaude, nil
	}
	return model.UsageSource(source), err
}

// migrateSources preserves every historical rollup row, including rows whose
// raw events have been pruned. All pre-source history is Claude usage, so this
// key migration needs no reconstruction from usage_events.
func migrateSources(db *sql.DB) error {
	hasSource, err := hasColumn(db, "usage_hourly", "source")
	if err != nil {
		return err
	}
	tx, err := db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.Exec(`CREATE UNIQUE INDEX IF NOT EXISTS idx_events_source_dedup
		ON usage_events(account_uuid, source, message_uuid);
		CREATE UNIQUE INDEX IF NOT EXISTS idx_codex_request_dedup ON usage_events(source, message_uuid) WHERE source = 'codex';
		DROP INDEX IF EXISTS idx_events_dedup`); err != nil {
		return fmt.Errorf("migrate source dedup: %w", err)
	}
	if !hasSource {
		if _, err := tx.Exec(`ALTER TABLE usage_hourly RENAME TO usage_hourly_before_sources`); err != nil {
			return err
		}
		start := strings.Index(schemaSQL, "CREATE TABLE IF NOT EXISTS usage_hourly (")
		end := start + strings.Index(schemaSQL[start:], ";") + 1
		if _, err := tx.Exec(schemaSQL[start:end]); err != nil {
			return err
		}
		const columns = `hour, account_uuid, endpoint_id, session_id, os_user, cwd, model, git_branch,
			effort, entrypoint, is_sidechain, events, input_tokens, output_tokens,
			cache_create_5m_tokens, cache_create_1h_tokens, cache_read_tokens, thinking_tokens,
			cost_usd, unpriced_events, min_ts, max_ts`
		if _, err := tx.Exec(`INSERT INTO usage_hourly (` + columns + `, source)
			SELECT ` + columns + `, 'claude' FROM usage_hourly_before_sources;
			DROP TABLE usage_hourly_before_sources;
			CREATE INDEX idx_hourly_account_hour ON usage_hourly(account_uuid, hour);
			CREATE INDEX idx_hourly_session ON usage_hourly(account_uuid, session_id)`); err != nil {
			return fmt.Errorf("migrate hourly sources: %w", err)
		}
	}
	return tx.Commit()
}
