// internal/store/rollup_query.go
package store

import (
	"database/sql"
	"fmt"
	"strings"
	"time"
)

// hourlyTokens is the same column list as tokenSumExpr (query.go), unwrapped:
// usage_hourly's rows are already per-hour sums, so callers here wrap this in
// SUM() to total across hours, or use it bare inside a CASE branch. Built
// from tokenColumnsExpr rather than retyped, so the two can never drift.
const hourlyTokens = tokenColumnsExpr

// UsageByFiltered is UsageBy over the rollup, under a Filter, with the token
// composition filled in. Team is a join, as in UsageBy.
func (s *Store) UsageByFiltered(f Filter, d Dimension, limit int) ([]Bucket, error) {
	col, err := d.column()
	if err != nil {
		return nil, err
	}
	if d == ByTeam {
		col = `COALESCE((SELECT e.team FROM endpoints e WHERE e.endpoint_id = usage_hourly.endpoint_id), '')`
	}
	where, args, err := f.where("hour")
	if err != nil {
		return nil, err
	}
	if limit <= 0 {
		limit = 50
	}
	q := fmt.Sprintf(`
		SELECT %s AS k, SUM(events), SUM%s, SUM(cost_usd), SUM(unpriced_events),
		       SUM(CASE WHEN is_sidechain = 1 THEN %s ELSE 0 END),
		       SUM(input_tokens), SUM(output_tokens), SUM(cache_read_tokens),
		       SUM(cache_create_5m_tokens + cache_create_1h_tokens), SUM(thinking_tokens)
		FROM usage_hourly %s
		GROUP BY k ORDER BY 3 DESC, k LIMIT ?`, col, hourlyTokens, hourlyTokens, where)
	rows, err := s.db.Query(q, append(args, limit)...)
	if err != nil {
		return nil, fmt.Errorf("usage by %s (rollup): %w", d, err)
	}
	defer rows.Close()
	var out []Bucket
	for rows.Next() {
		var b Bucket
		if err := rows.Scan(&b.Key, &b.Events, &b.Tokens, &b.CostUSD, &b.Unpriced, &b.Sidechain,
			&b.InputTokens, &b.OutputTokens, &b.CacheReadTokens, &b.CacheCreateTokens, &b.ThinkingTokens); err != nil {
			return nil, err
		}
		out = append(out, b)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	switch d {
	case ByEndpoint:
		s.labelEndpoints(out)
	case ByAccount:
		s.labelAccounts(out)
	case ByTeam:
		labelTeams(out)
	}
	return out, nil
}

// HourRow is one (hour, model) cell of the rollup.
type HourRow struct {
	Hour      string  `json:"hour"`
	Model     string  `json:"model"`
	Events    int64   `json:"events"`
	Tokens    int64   `json:"tokens"`
	CostUSD   float64 `json:"cost_usd"`
	Unpriced  int64   `json:"unpriced_events"`
	Sidechain int64   `json:"sidechain_tokens"`
}

// HourlyByModel returns the rollup grouped by hour and model, oldest first.
// Callers fold it into coarser buckets; hours are the finest the store knows.
func (s *Store) HourlyByModel(f Filter) ([]HourRow, error) {
	where, args, err := f.where("hour")
	if err != nil {
		return nil, err
	}
	rows, err := s.db.Query(fmt.Sprintf(`
		SELECT hour, model, SUM(events), SUM%s, SUM(cost_usd), SUM(unpriced_events),
		       SUM(CASE WHEN is_sidechain = 1 THEN %s ELSE 0 END)
		FROM usage_hourly %s GROUP BY hour, model ORDER BY hour, model`, hourlyTokens, hourlyTokens, where), args...)
	if err != nil {
		return nil, fmt.Errorf("hourly by model: %w", err)
	}
	defer rows.Close()
	var out []HourRow
	for rows.Next() {
		var r HourRow
		if err := rows.Scan(&r.Hour, &r.Model, &r.Events, &r.Tokens, &r.CostUSD, &r.Unpriced, &r.Sidechain); err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

// Summary is the KPI strip's data: everything additive over a Filter.
type Summary struct {
	Events            int64   `json:"events"`
	Tokens            int64   `json:"tokens"`
	Sessions          int64   `json:"sessions"`
	CostUSD           float64 `json:"cost_usd"`
	Unpriced          int64   `json:"unpriced_events"`
	InputTokens       int64   `json:"input_tokens"`
	OutputTokens      int64   `json:"output_tokens"`
	CacheReadTokens   int64   `json:"cache_read_tokens"`
	CacheCreateTokens int64   `json:"cache_create_tokens"`
	ThinkingTokens    int64   `json:"thinking_tokens"`
	SidechainTokens   int64   `json:"sidechain_tokens"`
	SidechainEvents   int64   `json:"sidechain_events"`
}

func (s *Store) Summary(f Filter) (*Summary, error) {
	where, args, err := f.where("hour")
	if err != nil {
		return nil, err
	}
	var sum Summary
	err = s.db.QueryRow(fmt.Sprintf(`
		SELECT COALESCE(SUM(events),0), COALESCE(SUM%s,0), COUNT(DISTINCT session_id),
		       COALESCE(SUM(cost_usd),0), COALESCE(SUM(unpriced_events),0),
		       COALESCE(SUM(input_tokens),0), COALESCE(SUM(output_tokens),0), COALESCE(SUM(cache_read_tokens),0),
		       COALESCE(SUM(cache_create_5m_tokens + cache_create_1h_tokens),0), COALESCE(SUM(thinking_tokens),0),
		       COALESCE(SUM(CASE WHEN is_sidechain = 1 THEN %s ELSE 0 END),0),
		       COALESCE(SUM(CASE WHEN is_sidechain = 1 THEN events ELSE 0 END),0)
		FROM usage_hourly %s`, hourlyTokens, hourlyTokens, where), args...).Scan(
		&sum.Events, &sum.Tokens, &sum.Sessions, &sum.CostUSD, &sum.Unpriced,
		&sum.InputTokens, &sum.OutputTokens, &sum.CacheReadTokens, &sum.CacheCreateTokens, &sum.ThinkingTokens,
		&sum.SidechainTokens, &sum.SidechainEvents)
	if err != nil {
		return nil, fmt.Errorf("summary: %w", err)
	}
	return &sum, nil
}

// SessionRow is one session as the sessions table shows it.
type SessionRow struct {
	SessionID   string    `json:"session_id"`
	AccountUUID string    `json:"account_uuid"`
	EndpointID  string    `json:"endpoint_id"`
	Endpoint    string    `json:"endpoint"`
	OSUser      string    `json:"os_user"`
	CWD         string    `json:"cwd"`
	Model       string    `json:"model"`  // the model with the most tokens
	Models      []string  `json:"models"` // every model seen, most tokens first
	Started     time.Time `json:"started"`
	Ended       time.Time `json:"ended"`
	Turns       int64     `json:"turns"`
	Tokens      int64     `json:"tokens"`
	CostUSD     float64   `json:"cost_usd"`
	Unpriced    int64     `json:"unpriced_events"`

	OutputTokens      int64 `json:"output_tokens"`
	InputTokens       int64 `json:"input_tokens"`
	CacheReadTokens   int64 `json:"cache_read_tokens"`
	CacheCreateTokens int64 `json:"cache_create_tokens"`
	SidechainTokens   int64 `json:"sidechain_tokens"`

	CacheHit       float64 `json:"cache_hit"`       // cache_read / (cache_read + input + cache_create)
	SidechainShare float64 `json:"sidechain_share"` // sidechain_tokens / tokens
}

var sessionSorts = map[string]string{
	"tokens":   "tokens DESC",
	"cost":     "cost_usd DESC",
	"started":  "started DESC",
	"duration": "(julianday(ended) - julianday(started)) DESC",
	"turns":    "turns DESC",
}

// Sessions lists sessions under a Filter, from the rollup. The Filter's
// Session field narrows to one session (used by Session).
func (s *Store) Sessions(f Filter, sortBy string, limit, offset int) ([]SessionRow, error) {
	order, ok := sessionSorts[sortBy]
	if sortBy == "" {
		order, ok = sessionSorts["tokens"], true
	}
	if !ok {
		return nil, fmt.Errorf("unknown sort %q", sortBy)
	}
	where, args, err := f.where("hour")
	if err != nil {
		return nil, err
	}
	if limit <= 0 || limit > 500 {
		limit = 50
	}
	q := fmt.Sprintf(`
		SELECT * FROM (
		  SELECT session_id, MAX(account_uuid) AS account_uuid, MAX(endpoint_id) AS endpoint_id,
		         MAX(os_user) AS os_user, MAX(cwd) AS cwd,
		         MIN(min_ts) AS started, MAX(max_ts) AS ended,
		         SUM(events) AS turns, SUM%s AS tokens, SUM(cost_usd) AS cost_usd, SUM(unpriced_events) AS unpriced,
		         SUM(output_tokens) AS output_tokens, SUM(input_tokens) AS input_tokens,
		         SUM(cache_read_tokens) AS cache_read, SUM(cache_create_5m_tokens + cache_create_1h_tokens) AS cache_create,
		         SUM(CASE WHEN is_sidechain = 1 THEN %s ELSE 0 END) AS sidechain
		  FROM usage_hourly %s AND session_id != ''
		  GROUP BY session_id
		) ORDER BY %s LIMIT ? OFFSET ?`, hourlyTokens, hourlyTokens, where, order)
	rows, err := s.db.Query(q, append(args, limit, offset)...)
	if err != nil {
		return nil, fmt.Errorf("sessions: %w", err)
	}
	defer rows.Close()
	var out []SessionRow
	var ids []string
	for rows.Next() {
		var r SessionRow
		var started, ended string
		if err := rows.Scan(&r.SessionID, &r.AccountUUID, &r.EndpointID, &r.OSUser, &r.CWD, &started, &ended,
			&r.Turns, &r.Tokens, &r.CostUSD, &r.Unpriced, &r.OutputTokens, &r.InputTokens,
			&r.CacheReadTokens, &r.CacheCreateTokens, &r.SidechainTokens); err != nil {
			return nil, err
		}
		r.Started, _ = time.Parse(rfc, started)
		r.Ended, _ = time.Parse(rfc, ended)
		if d := r.CacheReadTokens + r.InputTokens + r.CacheCreateTokens; d > 0 {
			r.CacheHit = float64(r.CacheReadTokens) / float64(d)
		}
		if r.Tokens > 0 {
			r.SidechainShare = float64(r.SidechainTokens) / float64(r.Tokens)
		}
		out = append(out, r)
		ids = append(ids, r.SessionID)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	if err := s.fillSessionModels(f.Account, out, ids); err != nil {
		return nil, err
	}
	s.labelSessionEndpoints(out)
	return out, nil
}

// SessionTokenMedian returns the median token count across sessions with at
// least 2 turns in the filter's window -- the same population rule
// findings.runaway() applies to its own candidate list (internal/findings).
// 0 when no such session exists.
//
// This exists because runaway()'s threshold used to be derived from whatever
// slice of sessions the caller happened to hand it -- correct only when that
// slice IS the whole population, and silently wrong (by orders of magnitude,
// measured against a real hub) once a caller passes a bounded top-N sample:
// the median of "the biggest N sessions" is nowhere near the median of "every
// session," and a threshold built from it stops firing on genuine outliers.
// Computing it here, once, over the full population under the SAME Filter
// the gatherer already has, is what makes GatherReview's own session pull
// safe to bound.
//
// SQLite has no MEDIAN aggregate. per_session is referenced twice below --
// once to count, once to pick the offset row -- rather than through window
// functions (ROW_NUMBER+COUNT OVER, which this method used at first):
// measured against a 292k-event production snapshot, the double reference is
// consistently faster, because SQLite auto-materializes a CTE referenced more
// than once (a query planner detail, not a language feature this relies on)
// so the GROUP BY runs once regardless, and a plain LIMIT/OFFSET avoids the
// extra sort-with-frame bookkeeping ROW_NUMBER needs. OFFSET N/2 (integer
// division) after ordering ascending is the same index (the upper of the two
// middle values on an even population) findings.runaway() used when it
// derived the median from its own sorted slice, so any caller with the full
// population already in hand computes byte-for-byte the same number either
// way.
func (s *Store) SessionTokenMedian(f Filter) (int64, error) {
	where, args, err := f.where("hour")
	if err != nil {
		return 0, err
	}
	q := fmt.Sprintf(`
		WITH per_session AS (
			SELECT SUM%s AS tokens
			FROM usage_hourly %s AND session_id != ''
			GROUP BY session_id
			HAVING SUM(events) >= 2
		)
		SELECT tokens FROM per_session ORDER BY tokens ASC
		LIMIT 1 OFFSET (SELECT COUNT(*) / 2 FROM per_session)`, hourlyTokens, where)
	var median int64
	switch err := s.db.QueryRow(q, args...).Scan(&median); {
	case err == sql.ErrNoRows:
		return 0, nil
	case err != nil:
		return 0, fmt.Errorf("session token median: %w", err)
	}
	return median, nil
}

// fillSessionModels sets Model/Models for a page of sessions in one query.
func (s *Store) fillSessionModels(account string, rows []SessionRow, ids []string) error {
	if len(ids) == 0 {
		return nil
	}
	ph := strings.TrimRight(strings.Repeat("?,", len(ids)), ",")
	args := make([]any, 0, len(ids)+1)
	where := "WHERE session_id IN (" + ph + ")"
	if account != AllAccounts {
		where = "WHERE account_uuid = ? AND session_id IN (" + ph + ")"
		args = append(args, account)
	}
	for _, id := range ids {
		args = append(args, id)
	}
	res, err := s.db.Query(fmt.Sprintf(`SELECT session_id, model, SUM%s AS t FROM usage_hourly %s
		GROUP BY session_id, model ORDER BY session_id, t DESC`, hourlyTokens, where), args...)
	if err != nil {
		return fmt.Errorf("session models: %w", err)
	}
	defer res.Close()
	models := map[string][]string{}
	for res.Next() {
		var id, m string
		var t int64
		if err := res.Scan(&id, &m, &t); err != nil {
			return err
		}
		models[id] = append(models[id], m)
	}
	for i := range rows {
		rows[i].Models = models[rows[i].SessionID]
		if len(rows[i].Models) > 0 {
			rows[i].Model = rows[i].Models[0]
		}
	}
	return res.Err()
}

func (s *Store) labelSessionEndpoints(rows []SessionRow) {
	eps, err := s.ListEndpoints("")
	if err != nil {
		return
	}
	byID := map[string]string{}
	for _, e := range eps {
		label := e.Label
		if label == "" {
			label = e.Hostname
		}
		byID[e.ID] = label
	}
	for i := range rows {
		rows[i].Endpoint = byID[rows[i].EndpointID]
	}
}

// Session returns one session's header row, or nil when unknown.
func (s *Store) Session(account, id string) (*SessionRow, error) {
	f := Filter{Account: account, Session: id,
		Start: time.Date(2000, 1, 1, 0, 0, 0, 0, time.UTC), End: time.Date(2100, 1, 1, 0, 0, 0, 0, time.UTC)}
	rows, err := s.Sessions(f, "tokens", 1, 0)
	if err != nil || len(rows) == 0 {
		return nil, err
	}
	return &rows[0], nil
}

// Turn is one API call inside a session, from the raw events.
type Turn struct {
	TS                time.Time `json:"ts"`
	Model             string    `json:"model"`
	Effort            string    `json:"effort"`
	InputTokens       int64     `json:"input_tokens"`
	OutputTokens      int64     `json:"output_tokens"`
	CacheReadTokens   int64     `json:"cache_read_tokens"`
	CacheCreateTokens int64     `json:"cache_create_tokens"`
	ThinkingTokens    int64     `json:"thinking_tokens"`
	CostUSD           *float64  `json:"cost_usd"`
	IsSidechain       bool      `json:"is_sidechain"`
}

// SessionTurns lists a session's turns oldest first. Empty when the raw events
// were pruned; the caller reports that rather than showing an empty chart.
func (s *Store) SessionTurns(account, id string) ([]Turn, error) {
	if account == "" {
		return nil, fmt.Errorf("account is required")
	}
	where, args := "WHERE session_id = ?", []any{id}
	if account != AllAccounts {
		where, args = "WHERE account_uuid = ? AND session_id = ?", []any{account, id}
	}
	rows, err := s.db.Query(`SELECT ts, model, effort, input_tokens, output_tokens, cache_read_tokens,
		cache_create_5m_tokens + cache_create_1h_tokens, thinking_tokens, cost_usd, is_sidechain
		FROM usage_events `+where+` ORDER BY ts`, args...)
	if err != nil {
		return nil, fmt.Errorf("session turns: %w", err)
	}
	defer rows.Close()
	var out []Turn
	for rows.Next() {
		var t Turn
		var ts string
		var cost sql.NullFloat64
		var side int
		if err := rows.Scan(&ts, &t.Model, &t.Effort, &t.InputTokens, &t.OutputTokens, &t.CacheReadTokens,
			&t.CacheCreateTokens, &t.ThinkingTokens, &cost, &side); err != nil {
			return nil, err
		}
		t.TS, _ = time.Parse(rfc, ts)
		if cost.Valid {
			c := cost.Float64
			t.CostUSD = &c
		}
		t.IsSidechain = side == 1
		out = append(out, t)
	}
	return out, rows.Err()
}
