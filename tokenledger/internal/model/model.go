// Package model holds the types that cross package boundaries in ccquota.
//
// Everything here is plain data with JSON tags: the agent serialises these to
// push to the hub, the hub stores them, and the query API hands them back. No
// behaviour lives here beyond trivial derivations.
package model

import "time"

// UsageEvent is one billable assistant turn, parsed from a single line of a
// Claude Code transcript.
//
// The token counters come from the transcript's top-level `message.usage`
// object. They are ALREADY the total for the turn — `usage.iterations[]` is a
// per-iteration breakdown of the same spend and must never be added on top.
type UsageEvent struct {
	AccountUUID string    `json:"account_uuid"`
	EndpointID  string    `json:"endpoint_id"`
	SessionID   string    `json:"session_id"`
	MessageUUID string    `json:"message_uuid"` // transcript entry `uuid` — the dedup key
	RequestID   string    `json:"request_id"`   // diagnostic only
	TS          time.Time `json:"ts"`
	Model       string    `json:"model"`

	InputTokens   int64 `json:"input_tokens"`
	OutputTokens  int64 `json:"output_tokens"`
	CacheCreate5m int64 `json:"cache_create_5m_tokens"`
	CacheCreate1h int64 `json:"cache_create_1h_tokens"`
	CacheRead     int64 `json:"cache_read_tokens"`
	Thinking      int64 `json:"thinking_tokens"`

	WebSearchRequests int64 `json:"web_search_requests"`
	WebFetchRequests  int64 `json:"web_fetch_requests"`

	// CostUSD is notional: what this turn would have cost at API rates. It is
	// nil for models absent from the pricing table — never 0, because 0 is a
	// claim and nil is an admission.
	CostUSD *float64 `json:"cost_usd"`

	CWD         string `json:"cwd"`
	GitBranch   string `json:"git_branch"`
	Entrypoint  string `json:"entrypoint"`
	Effort      string `json:"effort"`
	IsSidechain bool   `json:"is_sidechain"` // true = subagent turn
}

// TotalTokens is the raw, unweighted sum. Useful for display; not the right
// basis for apportioning a rate limit (see internal/recon).
func (e UsageEvent) TotalTokens() int64 {
	return e.InputTokens + e.OutputTokens + e.CacheCreate5m + e.CacheCreate1h + e.CacheRead
}

// Identity is who and where a batch of events came from.
type Identity struct {
	AccountUUID      string `json:"account_uuid"`
	Email            string `json:"email"`
	OrgUUID          string `json:"org_uuid"`
	OrgName          string `json:"org_name"`
	SubscriptionType string `json:"subscription_type"` // "max", "pro", ...
	RateLimitTier    string `json:"rate_limit_tier"`   // "default_claude_max_20x", ...
	DisplayName      string `json:"display_name"`

	MachineID string `json:"machine_id"`
	Hostname  string `json:"hostname"`
	OS        string `json:"os"`
	Arch      string `json:"arch"`
	CCVersion string `json:"cc_version"`
}

// Window is one rate-limit bucket as Anthropic reports it.
type Window struct {
	// Utilization is a percentage, 0-100. Exact — it comes from Anthropic and
	// already covers every device on the account.
	Utilization float64    `json:"utilization"`
	ResetsAt    *time.Time `json:"resets_at"`
}

// ScopedWindow is a per-model or per-surface weekly limit.
type ScopedWindow struct {
	Kind        string     `json:"kind"`  // "weekly_scoped", ...
	Model       string     `json:"model"` // display name, may be empty
	Surface     string     `json:"surface"`
	Utilization float64    `json:"utilization"`
	ResetsAt    *time.Time `json:"resets_at"`
	IsActive    bool       `json:"is_active"`
}

// LimitsSnapshot is one observation of an account's true, account-wide quota
// state. This is the only exact number in the system; everything the scanner
// produces is an estimate by comparison.
type LimitsSnapshot struct {
	AccountUUID string    `json:"account_uuid"`
	EndpointID  string    `json:"endpoint_id"` // which endpoint observed it
	ObservedAt  time.Time `json:"observed_at"`

	FiveHour Window `json:"five_hour"`
	SevenDay Window `json:"seven_day"`

	Scoped []ScopedWindow `json:"scoped"`

	ExtraUsageJSON string `json:"extra_usage_json"`
	SpendJSON      string `json:"spend_json"`
	RawJSON        string `json:"raw_json"`
}

// Batch is the agent's push payload.
type Batch struct {
	AgentVersion string          `json:"agent_version"`
	Identity     Identity        `json:"identity"`
	Events       []UsageEvent    `json:"events"`
	Limits       *LimitsSnapshot `json:"limits,omitempty"`

	// LimitsUnavailable explains why Limits is nil, so the hub can render an
	// honest banner instead of a stale gauge. Empty when Limits is present.
	LimitsUnavailable string `json:"limits_unavailable,omitempty"`
}

// IngestResponse lets the hub steer the fleet centrally.
type IngestResponse struct {
	Accepted            int    `json:"accepted"`
	Deduped             int    `json:"deduped"`
	EndpointID          string `json:"endpoint_id"`
	LimitsPollIntervalS int    `json:"limits_poll_interval_s,omitempty"`
}
