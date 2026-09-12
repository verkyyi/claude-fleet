package model

import "time"

// CacheWrite is a subset of normalized InputTokens, not another additive
// counter. A nil pointer means the client did not provide that breakdown.
type UsageDetails struct {
	ProfileID       string `json:"profile_id,omitempty"`
	Provider        string `json:"model_provider,omitempty"`
	ClientVersion   string `json:"client_version,omitempty"`
	BillingMode     string `json:"billing_mode,omitempty"`
	AccountBasis    string `json:"account_basis,omitempty"`
	CacheWrite      *int64 `json:"cache_write_input_tokens,omitempty"`
	ServiceTier     string `json:"service_tier,omitempty"`
	TurnID          string `json:"turn_id,omitempty"`
	RootTurnID      string `json:"root_turn_id,omitempty"`
	ParentSessionID string `json:"parent_session_id,omitempty"`
	PriceVersion    string `json:"price_version,omitempty"`
	PriceBasis      string `json:"price_basis,omitempty"`
	PriceSource     string `json:"price_source,omitempty"`
}

// QuotaWindow preserves a provider's actual window; primary is not always 5h.
type QuotaWindow struct {
	ID          string     `json:"id"`
	Label       string     `json:"label"`
	LimitID     string     `json:"limit_id"`
	Minutes     int64      `json:"minutes,omitempty"`
	UsedPercent float64    `json:"used_percent"`
	ResetsAt    *time.Time `json:"resets_at,omitempty"`
	ObservedAt  *time.Time `json:"observed_at,omitempty"`
}

type QuotaCredits struct {
	LimitID    string  `json:"limit_id"`
	HasCredits bool    `json:"has_credits"`
	Unlimited  bool    `json:"unlimited"`
	Balance    *string `json:"balance,omitempty"`
}

// Pools records which buckets a snapshot actually observed, including a
// bucket with no windows. Transcript updates can cover only one bucket.
type QuotaPool struct {
	LimitID string `json:"limit_id"`
	Blocked bool   `json:"blocked"`
	Reason  string `json:"reason,omitempty"`
}

// QuotaSnapshot contains only measurements, never an upstream credential.
type QuotaSnapshot struct {
	Source      string         `json:"source"`
	AccountUUID string         `json:"account_uuid"`
	EndpointID  string         `json:"endpoint_id"`
	ProfileID   string         `json:"profile_id"`
	ObservedAt  time.Time      `json:"observed_at"`
	Observation string         `json:"observation"` // app_server or transcript
	Plan        string         `json:"plan,omitempty"`
	Windows     []QuotaWindow  `json:"windows"`
	Credits     []QuotaCredits `json:"credits,omitempty"`
	Pools       []QuotaPool    `json:"pools,omitempty"`
	Blocked     bool           `json:"blocked"`
	Reason      string         `json:"reason,omitempty"`
}

type CollectorStatus struct {
	ProfileManaged     bool         `json:"profile_managed,omitempty"`
	ProfileName        string       `json:"profile_name,omitempty"`
	ProfileDefault     bool         `json:"profile_default,omitempty"`
	Login              *LoginHealth `json:"login,omitempty"`
	Source             string       `json:"source"`
	ProfileID          string       `json:"profile_id"`
	EndpointID         string       `json:"endpoint_id"`
	AccountUUID        string       `json:"account_uuid,omitempty"`
	ObservedAt         time.Time    `json:"observed_at"`
	LastEventAt        *time.Time   `json:"last_event_at,omitempty"`
	LimitsCheckedAt    *time.Time   `json:"limits_checked_at,omitempty"`
	State              string       `json:"state"`
	Reason             string       `json:"reason,omitempty"`
	LimitsReason       string       `json:"limits_reason,omitempty"`
	ClientVersion      string       `json:"client_version,omitempty"`
	ClientVersionBasis string       `json:"client_version_basis,omitempty"`
	BillingMode        string       `json:"billing_mode,omitempty"`
	Capabilities       []string     `json:"capabilities"`
	Files              int          `json:"files"`
	QueueBytes         int64        `json:"queue_bytes"`
}

type LoginHealth struct {
	State            string     `json:"state"`
	Reason           string     `json:"reason,omitempty"`
	AutoRefresh      bool       `json:"auto_refresh"`
	HasRefreshToken  bool       `json:"has_refresh_token"`
	AccessExpiresAt  *time.Time `json:"access_expires_at,omitempty"`
	LastRefreshAt    *time.Time `json:"last_refresh_at,omitempty"`
	RefreshAttemptAt *time.Time `json:"refresh_attempt_at,omitempty"`
	RetryAt          *time.Time `json:"retry_at,omitempty"`
}

type DailyUsage struct {
	Date   string `json:"date"`
	Tokens int64  `json:"tokens"`
}

// AccountUsage is an independent account-wide observation, never an event.
type AccountUsage struct {
	Source          string       `json:"source"`
	AccountUUID     string       `json:"account_uuid"`
	EndpointID      string       `json:"endpoint_id"`
	ObservedAt      time.Time    `json:"observed_at"`
	LifetimeTokens  *int64       `json:"lifetime_tokens"`
	PeakDailyTokens *int64       `json:"peak_daily_tokens"`
	Daily           []DailyUsage `json:"daily"`
}
