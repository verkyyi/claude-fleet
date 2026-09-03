package store

import (
	"database/sql"
	"fmt"
	"time"

	"github.com/verkyyi/ccquota/internal/model"
)

// rollupVersion is stamped into rollup_meta. Bump it when the rollup's key or
// columns change: Open then rebuilds the table from usage_events.
const rollupVersion = "1"

func hourKey(t time.Time) string {
	return t.UTC().Truncate(time.Hour).Format("2006-01-02T15:00:00Z")
}

const rollupInsertSQL = `
INSERT INTO usage_hourly (
  hour, account_uuid, endpoint_id, session_id, os_user, cwd, model, git_branch,
  effort, entrypoint, is_sidechain,
  events, input_tokens, output_tokens, cache_create_5m_tokens, cache_create_1h_tokens,
  cache_read_tokens, thinking_tokens, cost_usd, unpriced_events, min_ts, max_ts
) VALUES (?,?,?,?,?,?,?,?,?,?,?, 1,?,?,?,?,?,?,?,?,?,?)
ON CONFLICT(hour, account_uuid, endpoint_id, session_id, os_user, cwd, model,
            git_branch, effort, entrypoint, is_sidechain) DO UPDATE SET
  events                 = events + 1,
  input_tokens           = input_tokens + excluded.input_tokens,
  output_tokens          = output_tokens + excluded.output_tokens,
  cache_create_5m_tokens = cache_create_5m_tokens + excluded.cache_create_5m_tokens,
  cache_create_1h_tokens = cache_create_1h_tokens + excluded.cache_create_1h_tokens,
  cache_read_tokens      = cache_read_tokens + excluded.cache_read_tokens,
  thinking_tokens        = thinking_tokens + excluded.thinking_tokens,
  cost_usd               = cost_usd + excluded.cost_usd,
  unpriced_events        = unpriced_events + excluded.unpriced_events,
  min_ts                 = min(min_ts, excluded.min_ts),
  max_ts                 = max(max_ts, excluded.max_ts)`

// rollupUpsert folds one freshly inserted event into its hourly row.
func rollupUpsert(stmt *sql.Stmt, e *model.UsageEvent) error {
	var cost float64
	var unpriced int64
	if e.CostUSD != nil {
		cost = *e.CostUSD
	} else {
		unpriced = 1
	}
	side := 0
	if e.IsSidechain {
		side = 1
	}
	ts := fmtTime(e.TS)
	_, err := stmt.Exec(
		hourKey(e.TS), e.AccountUUID, e.EndpointID, e.SessionID, e.OSUser, e.CWD, e.Model, e.GitBranch,
		e.Effort, e.Entrypoint, side,
		e.InputTokens, e.OutputTokens, e.CacheCreate5m, e.CacheCreate1h,
		e.CacheRead, e.Thinking, cost, unpriced, ts, ts)
	return err
}

const rollupBackfillSQL = `
INSERT INTO usage_hourly (
  hour, account_uuid, endpoint_id, session_id, os_user, cwd, model, git_branch,
  effort, entrypoint, is_sidechain,
  events, input_tokens, output_tokens, cache_create_5m_tokens, cache_create_1h_tokens,
  cache_read_tokens, thinking_tokens, cost_usd, unpriced_events, min_ts, max_ts)
SELECT strftime('%Y-%m-%dT%H:00:00Z', ts), account_uuid, endpoint_id, session_id, os_user, cwd, model, git_branch,
       effort, entrypoint, is_sidechain,
       COUNT(*), SUM(input_tokens), SUM(output_tokens), SUM(cache_create_5m_tokens), SUM(cache_create_1h_tokens),
       SUM(cache_read_tokens), SUM(thinking_tokens), COALESCE(SUM(cost_usd), 0),
       SUM(CASE WHEN cost_usd IS NULL THEN 1 ELSE 0 END), MIN(ts), MAX(ts)
FROM usage_events
GROUP BY 1,2,3,4,5,6,7,8,9,10,11`

// RebuildRollup recomputes usage_hourly from usage_events in one transaction
// and stamps the current version. Returns the number of rollup rows (re)built.
//
// Only hours at or after the earliest surviving raw event are touched: rows
// for older hours, if any, are the ONLY remaining record of history that
// retention pruning has already deleted from usage_events, and rebuilding
// from usage_events would silently and irreversibly truncate them. When such
// rows exist, RebuildRollup refuses outright unless force is true — even a
// rebuild that only touches the reconstructable hours would leave those older
// rows sitting untouched under a schema/key that the rest of the table has
// just moved on from, which is a state worth an operator's explicit say-so,
// not a default. Pass force to proceed anyway, accepting that those older
// hours will keep whatever shape they already have.
func (s *Store) RebuildRollup(force bool) (int64, error) {
	tx, err := s.db.Begin()
	if err != nil {
		return 0, fmt.Errorf("begin: %w", err)
	}
	defer tx.Rollback()

	// The earliest hour usage_events can still attest to. NULL when
	// usage_events is empty (nothing survives to rebuild from at all).
	var earliestHour sql.NullString
	if err := tx.QueryRow(
		`SELECT strftime('%Y-%m-%dT%H:00:00Z', MIN(ts)) FROM usage_events`,
	).Scan(&earliestHour); err != nil {
		return 0, fmt.Errorf("find earliest surviving event: %w", err)
	}

	if !force {
		var unreconstructable int64
		var err error
		if earliestHour.Valid {
			err = tx.QueryRow(`SELECT COUNT(*) FROM usage_hourly WHERE hour < ?`, earliestHour.String).Scan(&unreconstructable)
		} else {
			// No raw events survive at all: every existing rollup row is
			// unreconstructable.
			err = tx.QueryRow(`SELECT COUNT(*) FROM usage_hourly`).Scan(&unreconstructable)
		}
		if err != nil {
			return 0, fmt.Errorf("check for unreconstructable rollup rows: %w", err)
		}
		if unreconstructable > 0 {
			return 0, fmt.Errorf(
				"refusing to rebuild: usage_hourly holds %d hour-row(s) older than the earliest "+
					"raw event still in usage_events (retention pruning has already deleted their "+
					"source) — rebuilding would erase the only surviving record of that history for "+
					"good; pass force to rebuild anyway and leave those older rows untouched",
				unreconstructable)
		}
	}

	// Never delete hours usage_events can no longer reconstruct, force or not
	// — force only overrides the refusal above, not this scoping.
	if earliestHour.Valid {
		if _, err := tx.Exec(`DELETE FROM usage_hourly WHERE hour >= ?`, earliestHour.String); err != nil {
			return 0, fmt.Errorf("clear reconstructable rollup rows: %w", err)
		}
	} else {
		if _, err := tx.Exec(`DELETE FROM usage_hourly`); err != nil {
			return 0, fmt.Errorf("clear rollup: %w", err)
		}
	}
	res, err := tx.Exec(rollupBackfillSQL)
	if err != nil {
		return 0, fmt.Errorf("backfill rollup: %w", err)
	}
	n, _ := res.RowsAffected()
	if _, err := tx.Exec(`INSERT INTO rollup_meta(key, value) VALUES ('usage_hourly_version', ?)
		ON CONFLICT(key) DO UPDATE SET value = excluded.value`, rollupVersion); err != nil {
		return 0, fmt.Errorf("stamp rollup version: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return 0, fmt.Errorf("commit: %w", err)
	}
	return n, nil
}

// RollupRows counts usage_hourly.
func (s *Store) RollupRows() (int64, error) {
	var n int64
	err := s.db.QueryRow(`SELECT COUNT(*) FROM usage_hourly`).Scan(&n)
	return n, err
}

// ensureRollup rebuilds the rollup when it is missing or from another version.
// Called from Open; returns how many rows were built (0 = nothing to do).
//
// Never passes force: an automatic rebuild at startup has no operator present
// to weigh "leave stale rows in place" against "erase pre-retention history",
// so if RebuildRollup would have to destroy history to proceed it returns an
// error here instead, which fails Open. That is a deliberate refusal to start
// up on a rollup it cannot safely bring current — the fix is for an operator
// to run `ccquota hub --rebuild-rollup --force` by hand, after reading what
// the error says would be lost.
func ensureRollup(s *Store) (int64, error) {
	var version string
	err := s.db.QueryRow(`SELECT value FROM rollup_meta WHERE key = 'usage_hourly_version'`).Scan(&version)
	if err != nil && err != sql.ErrNoRows {
		return 0, fmt.Errorf("read rollup version: %w", err)
	}
	rows, err := s.RollupRows()
	if err != nil {
		return 0, err
	}
	var events int64
	if err := s.db.QueryRow(`SELECT COUNT(*) FROM usage_events`).Scan(&events); err != nil {
		return 0, err
	}
	if version == rollupVersion && (rows > 0 || events == 0) {
		return 0, nil
	}
	return s.RebuildRollup(false)
}
