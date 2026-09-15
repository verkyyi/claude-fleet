package store

import (
	"database/sql"
	"errors"
	"fmt"
	"log"
	"time"

	"github.com/verkyyi/ccquota/internal/model"
)

// rollupVersion is stamped into rollup_meta. Bump it when the rollup's key or
// columns change: Open then rebuilds the table from usage_events.
// Source was added by migrateSources without a rebuild: existing rows are
// known to be Claude usage, including those whose raw events were pruned.
const rollupVersion = "1"

func hourKey(t time.Time) string {
	return t.UTC().Truncate(time.Hour).Format("2006-01-02T15:00:00Z")
}

const rollupInsertSQL = `
INSERT INTO usage_hourly (
  hour, account_uuid, endpoint_id, session_id, os_user, cwd, model, provider, git_branch,
  effort, entrypoint, is_sidechain, source,
  events, input_tokens, output_tokens, cache_create_5m_tokens, cache_create_1h_tokens,
  cache_read_tokens, thinking_tokens, cost_usd, unpriced_events, min_ts, max_ts,cache_write_tokens,cache_write_known_events
) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?, 1,?,?,?,?,?,?,?,?,?,?,?,?)
ON CONFLICT(hour, account_uuid, endpoint_id, session_id, os_user, cwd, model, provider,
            git_branch, effort, entrypoint, is_sidechain, source) DO UPDATE SET
  events                 = events + 1,
  input_tokens           = input_tokens + excluded.input_tokens,
  output_tokens          = output_tokens + excluded.output_tokens,
  cache_create_5m_tokens = cache_create_5m_tokens + excluded.cache_create_5m_tokens,
  cache_create_1h_tokens = cache_create_1h_tokens + excluded.cache_create_1h_tokens,
  cache_read_tokens      = cache_read_tokens + excluded.cache_read_tokens,
  thinking_tokens        = thinking_tokens + excluded.thinking_tokens,
  cost_usd               = cost_usd + excluded.cost_usd,
  unpriced_events        = unpriced_events + excluded.unpriced_events,
  cache_write_tokens = cache_write_tokens + excluded.cache_write_tokens,
  cache_write_known_events = cache_write_known_events + excluded.cache_write_known_events,
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
	write, known := cacheWrite(e)
	_, err := stmt.Exec(
		hourKey(e.TS), e.AccountUUID, e.EndpointID, e.SessionID, e.OSUser, e.CWD, e.Model, e.Provider, e.GitBranch,
		e.Effort, e.Entrypoint, side, model.UsageSource(e.Source),
		e.InputTokens, e.OutputTokens, e.CacheCreate5m, e.CacheCreate1h,
		e.CacheRead, e.Thinking, cost, unpriced, ts, ts, write, known)
	return err
}

const rollupBackfillSQL = `
INSERT INTO usage_hourly (
  hour, account_uuid, endpoint_id, session_id, os_user, cwd, model, provider, git_branch,
  effort, entrypoint, is_sidechain, source,
  events, input_tokens, output_tokens, cache_create_5m_tokens, cache_create_1h_tokens,
  cache_read_tokens, thinking_tokens, cost_usd, unpriced_events, min_ts, max_ts,cache_write_tokens,cache_write_known_events)
SELECT strftime('%Y-%m-%dT%H:00:00Z', ts), account_uuid, endpoint_id, session_id, os_user, cwd, model, provider, git_branch,
       effort, entrypoint, is_sidechain, source,
       COUNT(*), SUM(input_tokens), SUM(output_tokens), SUM(cache_create_5m_tokens), SUM(cache_create_1h_tokens),
       SUM(cache_read_tokens), SUM(thinking_tokens), COALESCE(SUM(cost_usd), 0), /* cost-split-exempt: GROUP BY below includes source (column 13) */
       SUM(CASE WHEN cost_usd IS NULL THEN 1 ELSE 0 END), MIN(ts), MAX(ts),SUM(cache_write_tokens),SUM(cache_write_known_events)
FROM usage_events
GROUP BY 1,2,3,4,5,6,7,8,9,10,11,12,13`

// unreconstructableRowsError is RebuildRollup(false)'s refusal to rebuild
// over usage_hourly rows older than the earliest surviving usage_events row
// — retention pruning has already deleted their only other record. It is a
// distinct type (not a bare fmt.Errorf) so ensureRollup can tell this
// specific, expected refusal apart from a genuine failure via errors.As: the
// refusal is not a reason to fail Open, only a real error is.
type unreconstructableRowsError struct{ n int64 }

func (e *unreconstructableRowsError) Error() string {
	return fmt.Sprintf(
		"refusing to rebuild: usage_hourly holds %d hour-row(s) older than the earliest "+
			"raw event still in usage_events (retention pruning has already deleted their "+
			"source) — rebuilding would erase the only surviving record of that history for "+
			"good; pass force to rebuild anyway and leave those older rows untouched",
		e.n)
}

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
	tx, err := s.write.Begin()
	if err != nil {
		return 0, fmt.Errorf("begin: %w", err)
	}
	defer tx.Rollback()

	n, err := rebuildRollupTx(tx, force)
	if err != nil {
		return 0, err
	}
	if err := tx.Commit(); err != nil {
		return 0, fmt.Errorf("commit: %w", err)
	}
	return n, nil
}

// rebuildRollupTx is RebuildRollup's body, minus the transaction.
//
// Split out so a caller that has already changed usage_events in a transaction
// can refold the rollup inside that SAME transaction — Store.Reprice does, and
// must: between rewriting an event's cost and refolding the hour that contains
// it there is a state where the raw rows and every dashboard figure disagree
// about money. One commit means that state is never observable.
func rebuildRollupTx(tx *sql.Tx, force bool) (int64, error) {
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
			return 0, &unreconstructableRowsError{n: unreconstructable}
		}
	}

	// Never delete hours usage_events can no longer reconstruct, force or not
	// — force only overrides the refusal above, not this scoping. When
	// earliestHour is NULL, usage_events is empty: there is no hour left to
	// reconstruct from, so the correct delete set is EMPTY, not "all of
	// usage_hourly". Deleting nothing here means the backfill below (which
	// inserts 0 rows from an empty usage_events) leaves the rollup exactly as
	// it was — which is what force promises: those rows "keep whatever shape
	// they already have."
	if earliestHour.Valid {
		if _, err := tx.Exec(`DELETE FROM usage_hourly WHERE hour >= ?`, earliestHour.String); err != nil {
			return 0, fmt.Errorf("clear reconstructable rollup rows: %w", err)
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
	return n, nil
}

// RollupRows counts usage_hourly.
func (s *Store) RollupRows() (int64, error) {
	var n int64
	err := s.read.QueryRow(`SELECT COUNT(*) FROM usage_hourly`).Scan(&n)
	return n, err
}

// ensureRollup rebuilds the rollup when it is missing or from another version.
// Called from Open; returns how many rows were built (0 = nothing to do).
//
// Tries RebuildRollup(false) first, exactly like an operator's interactive
// --rebuild-rollup would. If that refuses only because usage_hourly holds
// pre-retention rows (unreconstructableRowsError — retention pruning has
// already deleted their source), that is not a reason to fail Open: an
// automatic rebuild at startup has no operator present to read the refusal
// and answer it, and refusing to boot a database that has ever pruned would
// make the design's own version-bump upgrade path — and every other command
// that opens the store — permanently unstartable on it. So instead it falls
// back to RebuildRollup(true), which rebuilds every reconstructable hour and
// leaves the pre-retention rows exactly as they are (never deleted, never
// rebuilt) — the same non-destructive contract force always promises — and
// logs loudly what it preserved and why, so an operator can still see and
// act on it. Any other error from RebuildRollup still fails Open: refusing
// an explicit operator command is right, refusing to boot silently through a
// real problem is not.
func ensureRollup(s *Store) (int64, error) {
	var version string
	err := s.read.QueryRow(`SELECT value FROM rollup_meta WHERE key = 'usage_hourly_version'`).Scan(&version)
	if err != nil && err != sql.ErrNoRows {
		return 0, fmt.Errorf("read rollup version: %w", err)
	}
	rows, err := s.RollupRows()
	if err != nil {
		return 0, err
	}
	var events int64
	if err := s.read.QueryRow(`SELECT COUNT(*) FROM usage_events`).Scan(&events); err != nil {
		return 0, err
	}
	if version == rollupVersion && (rows > 0 || events == 0) {
		return 0, nil
	}

	n, err := s.RebuildRollup(false)
	if err == nil {
		return n, nil
	}
	var unrec *unreconstructableRowsError
	if !errors.As(err, &unrec) {
		return 0, err
	}
	n, ferr := s.RebuildRollup(true)
	if ferr != nil {
		return 0, ferr
	}
	log.Printf("rollup: usage_hourly holds %d pre-retention hour-row(s) usage_events can no "+
		"longer reconstruct (retention pruning already deleted their source); startup rebuilt "+
		"the %d reconstructable hour-row(s) instead and left those older rows exactly as they "+
		"are — the same outcome `ccquota hub --rebuild-rollup --rebuild-rollup-force` gives by "+
		"hand", unrec.n, n)
	return n, nil
}
