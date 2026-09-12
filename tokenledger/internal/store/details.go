package store

import (
	"database/sql"
	"encoding/json"
	"fmt"

	"github.com/verkyyi/ccquota/internal/model"
)

func migrateDetails(db *sql.DB) error {
	if _, err := db.Exec(`CREATE TABLE IF NOT EXISTS codex_request_keys(message_uuid TEXT PRIMARY KEY);
	INSERT OR IGNORE INTO codex_request_keys SELECT message_uuid FROM usage_events WHERE source='codex'`); err != nil {
		return err
	}
	for _, a := range []struct{ table, col, spec string }{
		{"usage_events", "details_json", "TEXT NOT NULL DEFAULT '{}'"},
		{"usage_events", "cache_write_tokens", "INTEGER NOT NULL DEFAULT 0"},
		{"usage_events", "cache_write_known_events", "INTEGER NOT NULL DEFAULT 0"},
		{"usage_hourly", "cache_write_tokens", "INTEGER NOT NULL DEFAULT 0"},
		{"usage_hourly", "cache_write_known_events", "INTEGER NOT NULL DEFAULT 0"},
	} {
		has, err := hasColumn(db, a.table, a.col)
		if err != nil {
			return err
		}
		if has {
			continue
		}
		if _, err := db.Exec(fmt.Sprintf("ALTER TABLE %s ADD COLUMN %s %s", a.table, a.col, a.spec)); err != nil {
			return err
		}
	}
	return nil
}

func cacheWrite(e *model.UsageEvent) (int64, int) {
	if e.Details != nil && e.Details.CacheWrite != nil {
		return *e.Details.CacheWrite, 1
	}
	return 0, 0
}

// A parser upgrade enriches the original request in place. Its account,
// endpoint, hour, event count and token totals remain exactly as ingested.
// Apply deltas only to the original hourly row; never rebuild pruned history.
func enrichCodex(tx *sql.Tx, e *model.UsageEvent) error {
	if e.Source != model.SourceCodex || e.Details == nil {
		return nil
	}
	var account, endpoint, session, user, cwd, m, branch, effort, entry, ts, oldJSON string
	var side int
	var input, output, read, oldWrite, oldKnown int64
	var oldCost sql.NullFloat64
	err := tx.QueryRow(`SELECT account_uuid,endpoint_id,session_id,os_user,cwd,model,git_branch,effort,entrypoint,is_sidechain,ts,input_tokens,output_tokens,cache_read_tokens,cost_usd,cache_write_tokens,cache_write_known_events,details_json FROM usage_events WHERE source='codex' AND message_uuid=?`, e.MessageUUID).Scan(&account, &endpoint, &session, &user, &cwd, &m, &branch, &effort, &entry, &side, &ts, &input, &output, &read, &oldCost, &oldWrite, &oldKnown, &oldJSON)
	if err == sql.ErrNoRows {
		return nil
	}
	if err != nil {
		return err
	}
	if input != e.InputTokens || output != e.OutputTokens || read != e.CacheRead || m != e.Model {
		return nil
	}
	// Older or less capable senders cannot erase known metadata or pricing.
	var old model.UsageDetails
	_ = json.Unmarshal([]byte(oldJSON), &old)
	if old.ClientVersion != "" && e.Details.ClientVersion == "" {
		return nil
	}
	if account == "codex:local" {
		e.Details.AccountBasis = "unassigned"
		e.Details.BillingMode = "unknown"
	}
	b, err := json.Marshal(e.Details)
	if err != nil {
		return err
	}
	write, known := cacheWrite(e)
	if oldKnown > 0 && known == 0 {
		write, known = oldWrite, 1
		e.Details.CacheWrite = &write
		b, _ = json.Marshal(e.Details)
	}
	var cost any
	nextCost := 0.0
	nextUnpriced := 1
	if e.CostUSD != nil {
		cost = *e.CostUSD
		nextCost = *e.CostUSD
		nextUnpriced = 0
	} else if oldCost.Valid {
		cost = oldCost.Float64
		nextCost = oldCost.Float64
		nextUnpriced = 0
	}
	oldUnpriced := 1
	if oldCost.Valid {
		oldUnpriced = 0
	}
	if _, err = tx.Exec(`UPDATE usage_events SET details_json=?,cost_usd=?,cache_write_tokens=?,cache_write_known_events=? WHERE source='codex' AND message_uuid=?`, string(b), cost, write, known, e.MessageUUID); err != nil {
		return err
	}
	_, err = tx.Exec(`UPDATE usage_hourly SET cost_usd=cost_usd+?,unpriced_events=unpriced_events+?,cache_write_tokens=cache_write_tokens+?,cache_write_known_events=cache_write_known_events+? WHERE hour=strftime('%Y-%m-%dT%H:00:00Z',?) AND account_uuid=? AND endpoint_id=? AND session_id=? AND os_user=? AND cwd=? AND model=? AND git_branch=? AND effort=? AND entrypoint=? AND is_sidechain=? AND source='codex'`, nextCost-oldCost.Float64, nextUnpriced-oldUnpriced, write-oldWrite, int64(known)-oldKnown, ts, account, endpoint, session, user, cwd, m, branch, effort, entry, side)
	return err
}
