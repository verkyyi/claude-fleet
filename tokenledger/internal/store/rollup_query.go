// internal/store/rollup_query.go
package store

import (
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/verkyyi/ccquota/internal/model"
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
		SELECT %s AS k, SUM(events), SUM%s,
		       SUM(CASE WHEN is_sidechain = 1 THEN %s ELSE 0 END),
		       SUM(input_tokens), SUM(output_tokens), SUM(cache_read_tokens),
		       SUM(cache_create_5m_tokens + cache_create_1h_tokens), SUM(thinking_tokens),
		       %s
		FROM usage_hourly %s
		GROUP BY k ORDER BY 3 DESC, k LIMIT ?`, col, hourlyTokens, hourlyTokens, hourlyCostSplit.sel, where)
	rows, err := s.read.Query(q, append(args, limit)...)
	if err != nil {
		return nil, fmt.Errorf("usage by %s (rollup): %w", d, err)
	}
	defer rows.Close()
	var out []Bucket
	for rows.Next() {
		var b Bucket
		cs := hourlyCostSplit.scan()
		if err := rows.Scan(append([]any{&b.Key, &b.Events, &b.Tokens, &b.Sidechain,
			&b.InputTokens, &b.OutputTokens, &b.CacheReadTokens, &b.CacheCreateTokens, &b.ThinkingTokens},
			cs.dest()...)...); err != nil {
			return nil, err
		}
		b.Cost = cs.costs()
		b.Unpriced = b.Cost.Unpriced()
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
	Hour      string       `json:"hour"`
	Model     string       `json:"model"`
	Events    int64        `json:"events"`
	Tokens    int64        `json:"tokens"`
	Cost      CostBySource `json:"cost"`
	Unpriced  int64        `json:"unpriced_events"`
	Sidechain int64        `json:"sidechain_tokens"`
}

// HourlyByModel returns the rollup grouped by hour and model, oldest first.
// Callers fold it into coarser buckets; hours are the finest the store knows.
func (s *Store) HourlyByModel(f Filter) ([]HourRow, error) {
	where, args, err := f.where("hour")
	if err != nil {
		return nil, err
	}
	rows, err := s.read.Query(fmt.Sprintf(`
		SELECT hour, model, SUM(events), SUM%s,
		       SUM(CASE WHEN is_sidechain = 1 THEN %s ELSE 0 END),
		       %s
		FROM usage_hourly %s GROUP BY hour, model ORDER BY hour, model`,
		hourlyTokens, hourlyTokens, hourlyCostSplit.sel, where), args...)
	if err != nil {
		return nil, fmt.Errorf("hourly by model: %w", err)
	}
	defer rows.Close()
	var out []HourRow
	for rows.Next() {
		var r HourRow
		cs := hourlyCostSplit.scan()
		if err := rows.Scan(append([]any{&r.Hour, &r.Model, &r.Events, &r.Tokens, &r.Sidechain}, cs.dest()...)...); err != nil {
			return nil, err
		}
		r.Cost = cs.costs()
		r.Unpriced = r.Cost.Unpriced()
		out = append(out, r)
	}
	return out, rows.Err()
}

// Summary is the KPI strip's data: everything additive over a Filter.
type Summary struct {
	CacheWriteTokens      int64 `json:"cache_write_tokens"`
	CacheWriteKnownEvents int64 `json:"cache_write_known_events"`
	Events                int64 `json:"events"`
	Tokens                int64 `json:"tokens"`
	Sessions              int64 `json:"sessions"`

	// Cost is the KPI strip's money, split by source and with no blended
	// member. The strip shows one column per source; a "total spend" tile, if
	// the page shows one, adds Cost.Billed() to subscription spend and leaves
	// Cost.Notional() out of it.
	Cost CostBySource `json:"cost"`

	Unpriced          int64 `json:"unpriced_events"`
	InputTokens       int64 `json:"input_tokens"`
	OutputTokens      int64 `json:"output_tokens"`
	CacheReadTokens   int64 `json:"cache_read_tokens"`
	CacheCreateTokens int64 `json:"cache_create_tokens"`
	ThinkingTokens    int64 `json:"thinking_tokens"`
	SidechainTokens   int64 `json:"sidechain_tokens"`
	SidechainEvents   int64 `json:"sidechain_events"`
}

func (s *Store) Summary(f Filter) (*Summary, error) { return readSummary(s.read, f) }

func readSummary(db interface{ QueryRow(string, ...any) *sql.Row }, f Filter) (*Summary, error) {
	where, args, err := f.where("hour")
	if err != nil {
		return nil, err
	}
	var sum Summary
	cs := hourlyCostSplit.scan()
	dest := append([]any{
		&sum.Events, &sum.Tokens, &sum.Sessions,
		&sum.InputTokens, &sum.OutputTokens, &sum.CacheReadTokens, &sum.CacheCreateTokens, &sum.ThinkingTokens,
		&sum.SidechainTokens, &sum.SidechainEvents, &sum.CacheWriteTokens, &sum.CacheWriteKnownEvents,
	}, cs.dest()...)
	err = db.QueryRow(fmt.Sprintf(`
		SELECT COALESCE(SUM(events),0), COALESCE(SUM%s,0), COUNT(DISTINCT session_id),
		       COALESCE(SUM(input_tokens),0), COALESCE(SUM(output_tokens),0), COALESCE(SUM(cache_read_tokens),0),
		       COALESCE(SUM(cache_create_5m_tokens + cache_create_1h_tokens),0), COALESCE(SUM(thinking_tokens),0),
		       COALESCE(SUM(CASE WHEN is_sidechain = 1 THEN %s ELSE 0 END),0),
		       COALESCE(SUM(CASE WHEN is_sidechain = 1 THEN events ELSE 0 END),0),COALESCE(SUM(cache_write_tokens),0),COALESCE(SUM(cache_write_known_events),0),
		       %s
		FROM usage_hourly %s`, hourlyTokens, hourlyTokens, hourlyCostSplit.sel, where), args...).Scan(dest...)
	if err != nil {
		return nil, fmt.Errorf("summary: %w", err)
	}
	sum.Cost = cs.costs()
	sum.Unpriced = sum.Cost.Unpriced()
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

	// Source, CostKind and CostUSD travel together, and the row is scoped to
	// ONE source (see Sessions' grouping) rather than carrying a split. That
	// is the other half of the rule Bucket.Cost keeps: an aggregate either
	// groups by source or is filtered to one, and a session is the natural
	// place to filter — session ids come out of a single source's transcript,
	// so a row spanning two would be a collision, not a session.
	//
	// CostKind is what stops the number being read as one currency of money:
	// "billed" is an invoice, "notional" is an estimate for work billed by
	// subscription. It is also why the cost SORT is safe to offer without
	// being safe to add up — see sessionSorts.
	Source   string  `json:"source"`
	CostKind string  `json:"cost_kind"`
	CostUSD  float64 `json:"cost_usd"`
	Unpriced int64   `json:"unpriced_events"`

	OutputTokens      int64 `json:"output_tokens"`
	InputTokens       int64 `json:"input_tokens"`
	CacheReadTokens   int64 `json:"cache_read_tokens"`
	CacheCreateTokens int64 `json:"cache_create_tokens"`
	SidechainTokens   int64 `json:"sidechain_tokens"`

	CacheHit       float64 `json:"cache_hit"`       // cache_read / (cache_read + input + cache_create)
	SidechainShare float64 `json:"sidechain_share"` // sidechain_tokens / tokens
}

// sessionSorts ranks; it never totals. "cost" orders rows that are each scoped
// to one source, so no row's figure is a blend — but two rows of different
// CostKind next to each other are still two kinds of money, which is why every
// row carries its kind and why nothing downstream adds this column up.
var sessionSorts = map[string]string{
	"tokens":   "tokens DESC",
	"cost":     "cost_usd DESC",
	"started":  "started DESC",
	"duration": "(julianday(ended) - julianday(started)) DESC",
	"turns":    "turns DESC",
}

// ErrUnknownSort is returned by Sessions when sortBy is non-empty and not one
// of sessionSorts -- a bad client-supplied value, distinct from a database
// failure, so callers (handleSessions) can tell the two apart and answer 400
// only for this one.
var ErrUnknownSort = errors.New("unknown sort")

// Sessions lists sessions under a Filter, from the rollup. The Filter's
// Session field narrows to one session (used by Session).
//
// Grouped by (account_uuid, source, session_id), not session_id alone: the
// rollup's dedup key is (account_uuid, message_uuid), so one session_id can
// legitimately carry rows under two accounts (a session resumed under a
// different login -- account_switches records exactly this seam). Grouping
// by session_id alone would blend those into one row labelled with whichever
// account_uuid happened to sort higher.
//
// source joined that key for the same reason and one more: it is what makes
// this row's cost_usd a single kind of money. Session ids come from one
// source's transcript, so in practice the extra term splits nothing; when it
// does split a row, two ids from different sources collided and showing them
// apart is the honest answer either way.
func (s *Store) Sessions(f Filter, sortBy string, limit, offset int) ([]SessionRow, error) {
	order, ok := sessionSorts[sortBy]
	if sortBy == "" {
		order, ok = sessionSorts["tokens"], true
	}
	if !ok {
		return nil, fmt.Errorf("%w %q", ErrUnknownSort, sortBy)
	}
	where, args, err := f.where("hour")
	if err != nil {
		return nil, err
	}
	switch {
	case limit <= 0:
		limit = 50
	case limit > 500:
		limit = 500
	}
	q := fmt.Sprintf(`
		SELECT * FROM (
		  SELECT session_id, account_uuid, %s AS source, MAX(endpoint_id) AS endpoint_id,
		         MAX(os_user) AS os_user, MAX(cwd) AS cwd,
		         MIN(min_ts) AS started, MAX(max_ts) AS ended,
		         SUM(events) AS turns, SUM%s AS tokens,
		         COALESCE(SUM(cost_usd), 0) AS cost_usd, /* cost-split-exempt: this GROUP BY includes source, so the row is one kind of money */
		         SUM(unpriced_events) AS unpriced,
		         SUM(output_tokens) AS output_tokens, SUM(input_tokens) AS input_tokens,
		         SUM(cache_read_tokens) AS cache_read, SUM(cache_create_5m_tokens + cache_create_1h_tokens) AS cache_create,
		         SUM(CASE WHEN is_sidechain = 1 THEN %s ELSE 0 END) AS sidechain
		  FROM usage_hourly %s AND session_id != ''
		  GROUP BY account_uuid, source, session_id
		) ORDER BY %s LIMIT ? OFFSET ?`, sourceExpr, hourlyTokens, hourlyTokens, where, order)
	rows, err := s.read.Query(q, append(args, limit, offset)...)
	if err != nil {
		return nil, fmt.Errorf("sessions: %w", err)
	}
	defer rows.Close()
	var out []SessionRow
	var ids []string
	for rows.Next() {
		var r SessionRow
		var started, ended string
		if err := rows.Scan(&r.SessionID, &r.AccountUUID, &r.Source, &r.EndpointID, &r.OSUser, &r.CWD, &started, &ended,
			&r.Turns, &r.Tokens, &r.CostUSD, &r.Unpriced, &r.OutputTokens, &r.InputTokens,
			&r.CacheReadTokens, &r.CacheCreateTokens, &r.SidechainTokens); err != nil {
			return nil, err
		}
		r.CostKind = model.CostKind(r.Source)
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
	if err := s.fillSessionModels(f, out, ids); err != nil {
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
	// Grouped by (account_uuid, session_id), same reason as Sessions above: a
	// session_id can legitimately carry rows under two accounts, and grouping
	// by session_id alone would compute the median over that blended
	// population instead of over the real one session per (account, id).
	q := fmt.Sprintf(`
		WITH per_session AS (
			SELECT SUM%s AS tokens
			FROM usage_hourly %s AND session_id != ''
			GROUP BY account_uuid, session_id
			HAVING SUM(events) >= 2
		)
		SELECT tokens FROM per_session ORDER BY tokens ASC
		LIMIT 1 OFFSET (SELECT COUNT(*) / 2 FROM per_session)`, hourlyTokens, where)
	var median int64
	switch err := s.read.QueryRow(q, args...).Scan(&median); {
	case err == sql.ErrNoRows:
		return 0, nil
	case err != nil:
		return 0, fmt.Errorf("session token median: %w", err)
	}
	return median, nil
}

// fillSessionModels sets Model/Models for a page of sessions in one query,
// scoped by the SAME Filter (time range plus every drill-down chip) the
// outer Sessions query used, narrowed further to this page's ids.
//
// It used to scope by account_uuid and session_id IN (…) only -- no hour
// bound, no drill-down predicates -- so a session's Model/Models were
// computed over all of history and every model while its Tokens were the
// filtered subset: with a model chip active, the sessions table could show
// model: X on a row whose displayed tokens were entirely model Y's.
//
// Keyed by (account_uuid, session_id), matching Sessions' grouping: a
// session_id alone is not a unique row once one can legitimately carry rows
// under two accounts (see Sessions' doc comment).
func (s *Store) fillSessionModels(f Filter, rows []SessionRow, ids []string) error {
	if len(ids) == 0 {
		return nil
	}
	where, args, err := f.where("hour")
	if err != nil {
		return err
	}
	ph := strings.TrimRight(strings.Repeat("?,", len(ids)), ",")
	where += " AND session_id IN (" + ph + ")"
	for _, id := range ids {
		args = append(args, id)
	}
	res, err := s.read.Query(fmt.Sprintf(`SELECT account_uuid, session_id, model, SUM%s AS t FROM usage_hourly %s
		GROUP BY account_uuid, session_id, model ORDER BY account_uuid, session_id, t DESC`, hourlyTokens, where), args...)
	if err != nil {
		return fmt.Errorf("session models: %w", err)
	}
	defer res.Close()
	models := map[string][]string{}
	key := func(account, session string) string { return account + "\x00" + session }
	for res.Next() {
		var acct, id, m string
		var t int64
		if err := res.Scan(&acct, &id, &m, &t); err != nil {
			return err
		}
		k := key(acct, id)
		models[k] = append(models[k], m)
	}
	for i := range rows {
		k := key(rows[i].AccountUUID, rows[i].SessionID)
		rows[i].Models = models[k]
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
func (s *Store) Session(account, id string, sources ...string) (*SessionRow, error) {
	f := Filter{Account: account, Session: id,
		Start: time.Date(2000, 1, 1, 0, 0, 0, 0, time.UTC), End: time.Date(2100, 1, 1, 0, 0, 0, 0, time.UTC)}
	if len(sources) > 0 {
		f.Source = sources[0]
	}
	rows, err := s.Sessions(f, "tokens", 1, 0)
	if err != nil || len(rows) == 0 {
		return nil, err
	}
	return &rows[0], nil
}

// Turn is one API call inside a session, from the raw events.
type Turn struct {
	RequestID         string              `json:"request_id"`
	Source            string              `json:"source"`
	Details           *model.UsageDetails `json:"details,omitempty"`
	TS                time.Time           `json:"ts"`
	Model             string              `json:"model"`
	Effort            string              `json:"effort"`
	InputTokens       int64               `json:"input_tokens"`
	OutputTokens      int64               `json:"output_tokens"`
	CacheReadTokens   int64               `json:"cache_read_tokens"`
	CacheCreateTokens int64               `json:"cache_create_tokens"`
	ThinkingTokens    int64               `json:"thinking_tokens"`
	CostUSD           *float64            `json:"cost_usd"`
	IsSidechain       bool                `json:"is_sidechain"`
}

// SessionTurns lists a session's turns oldest first. Empty when the raw events
// were pruned; the caller reports that rather than showing an empty chart.
func (s *Store) SessionTurns(account, id string, sources ...string) ([]Turn, error) {
	if account == "" {
		return nil, fmt.Errorf("account is required")
	}
	where, args := "WHERE session_id = ?", []any{id}
	if account != AllAccounts {
		where, args = "WHERE account_uuid = ? AND session_id = ?", []any{account, id}
	}
	if len(sources) > 0 && sources[0] != "" {
		where += ` AND source=?`
		args = append(args, sources[0])
	}
	rows, err := s.read.Query(`SELECT ts, model, effort, input_tokens, output_tokens, cache_read_tokens,
		cache_create_5m_tokens + cache_create_1h_tokens, thinking_tokens, cost_usd, is_sidechain,request_id,source,details_json
		FROM usage_events `+where+` ORDER BY ts`, args...)
	if err != nil {
		return nil, fmt.Errorf("session turns: %w", err)
	}
	defer rows.Close()
	var out []Turn
	for rows.Next() {
		var t Turn
		var ts string
		var details string
		var cost sql.NullFloat64
		var side int
		if err := rows.Scan(&ts, &t.Model, &t.Effort, &t.InputTokens, &t.OutputTokens, &t.CacheReadTokens,
			&t.CacheCreateTokens, &t.ThinkingTokens, &cost, &side, &t.RequestID, &t.Source, &details); err != nil {
			return nil, err
		}
		t.TS, _ = time.Parse(rfc, ts)
		if cost.Valid {
			c := cost.Float64
			t.CostUSD = &c
		}
		t.IsSidechain = side == 1
		_ = json.Unmarshal([]byte(details), &t.Details)
		out = append(out, t)
	}
	return out, rows.Err()
}
