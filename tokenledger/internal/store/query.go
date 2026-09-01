package store

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"time"

	"github.com/verkyyi/ccquota/internal/model"
)

// Account is a subscription tracked by this hub.
type Account struct {
	AccountUUID      string    `json:"account_uuid"`
	Email            string    `json:"email"`
	OrgUUID          string    `json:"org_uuid"`
	OrgName          string    `json:"org_name"`
	SubscriptionType string    `json:"subscription_type"`
	RateLimitTier    string    `json:"rate_limit_tier"`
	DisplayName      string    `json:"display_name"`
	FirstSeen        time.Time `json:"first_seen"`
	LastSeen         time.Time `json:"last_seen"`
	EndpointCount    int       `json:"endpoint_count"`
}

// ListAccounts returns every subscription on this hub.
func (s *Store) ListAccounts() ([]Account, error) {
	rows, err := s.db.Query(`
		SELECT a.account_uuid, a.email, a.org_uuid, a.org_name,
		       a.subscription_type, a.rate_limit_tier, a.display_name,
		       a.first_seen, a.last_seen,
		       (SELECT COUNT(*) FROM endpoints e WHERE e.account_uuid = a.account_uuid)
		FROM accounts a
		ORDER BY a.last_seen DESC`)
	if err != nil {
		return nil, fmt.Errorf("list accounts: %w", err)
	}
	defer rows.Close()

	var out []Account
	for rows.Next() {
		var a Account
		var first, last string
		if err := rows.Scan(&a.AccountUUID, &a.Email, &a.OrgUUID, &a.OrgName,
			&a.SubscriptionType, &a.RateLimitTier, &a.DisplayName,
			&first, &last, &a.EndpointCount); err != nil {
			return nil, err
		}
		a.FirstSeen, _ = time.Parse(rfc, first)
		a.LastSeen, _ = time.Parse(rfc, last)
		out = append(out, a)
	}
	return out, rows.Err()
}

// ListEndpoints returns the endpoints for one account, or all when account is
// empty.
func (s *Store) ListEndpoints(account string) ([]Endpoint, error) {
	q := `SELECT endpoint_id, account_uuid, label, hostname, os, arch, machine_id,
	             cc_version, agent_version, enrolled_at, last_seen
	      FROM endpoints`
	var args []any
	if account != "" {
		q += ` WHERE account_uuid = ?`
		args = append(args, account)
	}
	q += ` ORDER BY last_seen DESC NULLS LAST, label`

	rows, err := s.db.Query(q, args...)
	if err != nil {
		return nil, fmt.Errorf("list endpoints: %w", err)
	}
	defer rows.Close()

	var out []Endpoint
	for rows.Next() {
		e, err := scanEndpoint(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *e)
	}
	return out, rows.Err()
}

// LatestLimits returns the freshest snapshot for an account.
//
// A nil snapshot with a nil error means no endpoint has ever managed to read
// this account's limits. Callers must render that as "unavailable", never as
// zero utilization.
func (s *Store) LatestLimits(account string) (*model.LimitsSnapshot, error) {
	row := s.db.QueryRow(`
		SELECT account_uuid, endpoint_id, observed_at,
		       five_hour_pct, five_hour_resets_at,
		       seven_day_pct, seven_day_resets_at,
		       scoped_json, extra_usage_json, spend_json
		FROM limit_snapshots
		WHERE account_uuid = ?
		ORDER BY observed_at DESC LIMIT 1`, account)

	var snap model.LimitsSnapshot
	var observed string
	var fiveReset, sevenReset sql.NullString
	var scoped string
	err := row.Scan(&snap.AccountUUID, &snap.EndpointID, &observed,
		&snap.FiveHour.Utilization, &fiveReset,
		&snap.SevenDay.Utilization, &sevenReset,
		&scoped, &snap.ExtraUsageJSON, &snap.SpendJSON)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("latest limits: %w", err)
	}

	snap.ObservedAt, _ = time.Parse(rfc, observed)
	snap.FiveHour.ResetsAt = parseNullTime(fiveReset)
	snap.SevenDay.ResetsAt = parseNullTime(sevenReset)
	if scoped != "" {
		_ = json.Unmarshal([]byte(scoped), &snap.Scoped)
	}
	return &snap, nil
}

func parseNullTime(ns sql.NullString) *time.Time {
	if !ns.Valid || ns.String == "" {
		return nil
	}
	t, err := time.Parse(rfc, ns.String)
	if err != nil {
		return nil
	}
	return &t
}

// EventsInRange returns the raw events for an account within a period.
// Reconciliation needs the individual rows, not an aggregate.
func (s *Store) EventsInRange(account string, start, end time.Time) ([]model.UsageEvent, error) {
	rows, err := s.db.Query(`
		SELECT endpoint_id, session_id, message_uuid, ts, model,
		       input_tokens, output_tokens, cache_create_5m_tokens,
		       cache_create_1h_tokens, cache_read_tokens, thinking_tokens,
		       cost_usd, cwd, git_branch, is_sidechain
		FROM usage_events
		WHERE account_uuid = ? AND ts >= ? AND ts < ?`,
		account, fmtTime(start), fmtTime(end))
	if err != nil {
		return nil, fmt.Errorf("events in range: %w", err)
	}
	defer rows.Close()

	var out []model.UsageEvent
	for rows.Next() {
		var e model.UsageEvent
		var ts string
		var cost sql.NullFloat64
		if err := rows.Scan(&e.EndpointID, &e.SessionID, &e.MessageUUID, &ts, &e.Model,
			&e.InputTokens, &e.OutputTokens, &e.CacheCreate5m, &e.CacheCreate1h,
			&e.CacheRead, &e.Thinking, &cost, &e.CWD, &e.GitBranch, &e.IsSidechain); err != nil {
			return nil, err
		}
		e.AccountUUID = account
		e.TS, _ = time.Parse(rfc, ts)
		if cost.Valid {
			c := cost.Float64
			e.CostUSD = &c
		}
		out = append(out, e)
	}
	return out, rows.Err()
}

// Bucket is one row of a breakdown.
type Bucket struct {
	Key       string  `json:"key"`
	Label     string  `json:"label"`
	Events    int64   `json:"events"`
	Tokens    int64   `json:"tokens"`
	CostUSD   float64 `json:"cost_usd"`
	Unpriced  int64   `json:"unpriced_events"`
	Sidechain int64   `json:"sidechain_tokens"`
}

// Dimension names a breakdown axis.
type Dimension string

const (
	ByEndpoint Dimension = "endpoint"
	ByProject  Dimension = "project"
	BySession  Dimension = "session"
	ByModel    Dimension = "model"
	ByBranch   Dimension = "branch"
)

// column maps a dimension to its SQL expression. Whitelisting rather than
// interpolating the caller's string is what keeps this injection-proof.
func (d Dimension) column() (string, error) {
	switch d {
	case ByEndpoint:
		return "endpoint_id", nil
	case ByProject:
		return "cwd", nil
	case BySession:
		return "session_id", nil
	case ByModel:
		return "model", nil
	case ByBranch:
		return "git_branch", nil
	default:
		return "", fmt.Errorf("unknown dimension %q", d)
	}
}

// UsageBy aggregates an account's spend along one dimension.
//
// account is required. Every query path in this package filters by it: on a
// hub holding several subscriptions, an unfiltered aggregate would show one
// team's spend to another.
func (s *Store) UsageBy(account string, d Dimension, start, end time.Time, limit int) ([]Bucket, error) {
	if account == "" {
		return nil, fmt.Errorf("account is required: an unscoped aggregate would mix subscriptions")
	}
	col, err := d.column()
	if err != nil {
		return nil, err
	}
	if limit <= 0 {
		limit = 50
	}

	q := fmt.Sprintf(`
		SELECT %s AS k,
		       COUNT(*),
		       SUM(input_tokens + output_tokens + cache_create_5m_tokens
		           + cache_create_1h_tokens + cache_read_tokens),
		       COALESCE(SUM(cost_usd), 0),
		       SUM(CASE WHEN cost_usd IS NULL THEN 1 ELSE 0 END),
		       COALESCE(SUM(CASE WHEN is_sidechain = 1
		            THEN input_tokens + output_tokens + cache_create_5m_tokens
		                 + cache_create_1h_tokens + cache_read_tokens
		            ELSE 0 END), 0)
		FROM usage_events
		WHERE account_uuid = ? AND ts >= ? AND ts < ?
		GROUP BY k
		ORDER BY 3 DESC
		LIMIT ?`, col)

	rows, err := s.db.Query(q, account, fmtTime(start), fmtTime(end), limit)
	if err != nil {
		return nil, fmt.Errorf("usage by %s: %w", d, err)
	}
	defer rows.Close()

	var out []Bucket
	for rows.Next() {
		var b Bucket
		if err := rows.Scan(&b.Key, &b.Events, &b.Tokens, &b.CostUSD, &b.Unpriced, &b.Sidechain); err != nil {
			return nil, err
		}
		out = append(out, b)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	if d == ByEndpoint {
		s.labelEndpoints(out)
	}
	return out, nil
}

// labelEndpoints replaces opaque endpoint ids with their human labels.
func (s *Store) labelEndpoints(bs []Bucket) {
	eps, err := s.ListEndpoints("")
	if err != nil {
		return
	}
	byID := make(map[string]string, len(eps))
	for _, e := range eps {
		label := e.Label
		if label == "" {
			label = e.Hostname
		}
		byID[e.ID] = label
	}
	for i := range bs {
		if l := byID[bs[i].Key]; l != "" {
			bs[i].Label = l
		}
	}
}

// Granularity buckets a time series.
type Granularity string

const (
	Hourly Granularity = "hour"
	Daily  Granularity = "day"
)

// format maps a granularity to a strftime pattern.
func (g Granularity) format() (string, error) {
	switch g {
	case Hourly:
		return "%Y-%m-%dT%H:00", nil
	case Daily:
		return "%Y-%m-%d", nil
	default:
		return "", fmt.Errorf("unknown granularity %q", g)
	}
}

// History returns a time series of an account's spend.
func (s *Store) History(account string, g Granularity, start, end time.Time) ([]Bucket, error) {
	if account == "" {
		return nil, fmt.Errorf("account is required: an unscoped history would mix subscriptions")
	}
	f, err := g.format()
	if err != nil {
		return nil, err
	}

	rows, err := s.db.Query(`
		SELECT strftime(?, ts) AS k,
		       COUNT(*),
		       SUM(input_tokens + output_tokens + cache_create_5m_tokens
		           + cache_create_1h_tokens + cache_read_tokens),
		       COALESCE(SUM(cost_usd), 0),
		       SUM(CASE WHEN cost_usd IS NULL THEN 1 ELSE 0 END),
		       0
		FROM usage_events
		WHERE account_uuid = ? AND ts >= ? AND ts < ?
		GROUP BY k ORDER BY k`,
		f, account, fmtTime(start), fmtTime(end))
	if err != nil {
		return nil, fmt.Errorf("history: %w", err)
	}
	defer rows.Close()

	var out []Bucket
	for rows.Next() {
		var b Bucket
		if err := rows.Scan(&b.Key, &b.Events, &b.Tokens, &b.CostUSD, &b.Unpriced, &b.Sidechain); err != nil {
			return nil, err
		}
		out = append(out, b)
	}
	return out, rows.Err()
}

// ModelSplit breaks an account's spend down by model over a period.
func (s *Store) ModelSplit(account string, start, end time.Time) ([]Bucket, error) {
	return s.UsageBy(account, ByModel, start, end, 50)
}

// AccountSwitch is a recorded change of subscription on one endpoint.
type AccountSwitch struct {
	EndpointID  string    `json:"endpoint_id"`
	FromAccount string    `json:"from_account"`
	ToAccount   string    `json:"to_account"`
	ObservedAt  time.Time `json:"observed_at"`
}

// AccountSwitches lists login changes, newest first. The UI shows these
// alongside historical data because rows ingested before a switch keep their
// old attribution and cannot be corrected.
func (s *Store) AccountSwitches(limit int) ([]AccountSwitch, error) {
	if limit <= 0 {
		limit = 50
	}
	rows, err := s.db.Query(`
		SELECT endpoint_id, from_account, to_account, observed_at
		FROM account_switches ORDER BY observed_at DESC LIMIT ?`, limit)
	if err != nil {
		return nil, fmt.Errorf("account switches: %w", err)
	}
	defer rows.Close()

	var out []AccountSwitch
	for rows.Next() {
		var a AccountSwitch
		var at string
		if err := rows.Scan(&a.EndpointID, &a.FromAccount, &a.ToAccount, &at); err != nil {
			return nil, err
		}
		a.ObservedAt, _ = time.Parse(rfc, at)
		out = append(out, a)
	}
	return out, rows.Err()
}
