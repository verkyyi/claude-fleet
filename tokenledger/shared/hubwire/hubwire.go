// Package hubwire holds the formats the hub serves that a node reads back:
// a quota reading (`GET /v1/limits`), the subscription list (`GET
// /v1/accounts`) and a place line's attempts tail. The hub (internal/api,
// internal/store) aliases these types; the node (agent/cli) decodes into them,
// so the two never drift (claude-fleet#4812, EPIC #4810).
package hubwire

import (
	"strconv"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/shared/model"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/recon"
)

// LimitsView is what the dashboard and MCP see for one account's quota.
//
// Available distinguishes "we know the numbers" from "we do not". When it is
// false the caller must render no gauge at all — a stale or inferred
// percentage shown with the same weight as a live one is the failure this
// whole project exists to avoid.
type LimitsView struct {
	Source      string               `json:"source,omitempty"`
	Plan        string               `json:"plan,omitempty"`
	Windows     []ProviderWindow     `json:"windows,omitempty"`
	Credits     []model.QuotaCredits `json:"credits,omitempty"`
	Blocked     bool                 `json:"blocked,omitempty"`
	AccountUUID string               `json:"account_uuid"`
	Available   bool                 `json:"available"`
	Reason      string               `json:"reason,omitempty"`

	// ReasonCode names WHICH reason, so the dashboard's handler can restate it
	// in the viewer's language without matching on the English sentence.
	// Unserialised for the same reason store.UnpricedReason.Code is: the wire
	// contract stays the prose.
	ReasonCode string `json:"-"`
	// ReasonEndpoint/ReasonDetail carry an endpoint's OWN reported reason, which
	// is relayed verbatim: only the frame around it is this hub's wording.
	ReasonEndpoint string `json:"-"`
	ReasonDetail   string `json:"-"`

	ObservedAt *time.Time `json:"observed_at,omitempty"`
	// StaleSeconds is how old the reading is. The UI greys out a reading older
	// than a few minutes rather than pretending it is current.
	StaleSeconds int64 `json:"stale_seconds,omitempty"`

	// ReadVia names who took the reading shown — "hub" (the hub's own read
	// through the relay) or "node" — and ReadNote why a node's is shown when
	// the hub's failed (claude-fleet#2169). Both stay empty unless the hub
	// reads quota itself (CCQUOTA_FLEET_HUB_QUOTA), so the view is unchanged
	// without it.
	ReadVia       string     `json:"read_via,omitempty"`
	ReadNote      string     `json:"read_note,omitempty"`
	ReadStatus    string     `json:"read_status,omitempty"`
	ReadAttemptAt *time.Time `json:"read_attempt_at,omitempty"`

	FiveHour *WindowView `json:"five_hour,omitempty"`
	SevenDay *WindowView `json:"seven_day,omitempty"`

	Scoped []ScopedView `json:"scoped,omitempty"`

	// ModelClaims are per-model caps (the weekly Fable cap) read by probing that
	// model. Each carries its own observed_at: they are refreshed by a different
	// source than the windows above, on a different cadence. They never feed
	// HighestUtilization — a model cap is not a subscription wall.
	ModelClaims []model.ModelClaim `json:"model_claims,omitempty"`

	// EndpointShares apportions the five-hour window across endpoints. The
	// account total is exact; these shares are estimates.
	EndpointShares []recon.Share `json:"endpoint_shares,omitempty"`

	Disclaimer string `json:"disclaimer"`
}

type ProviderWindow struct {
	ObservedAt *time.Time `json:"observed_at,omitempty"`
	WindowView
	ID      string `json:"id"`
	Label   string `json:"label"`
	LimitID string `json:"limit_id"`
	Minutes int64  `json:"minutes,omitempty"`
}

func (v *LimitsView) HighestUtilization() float64 {
	if v.Blocked {
		return 100
	}
	var n float64
	if v.FiveHour != nil {
		n = v.FiveHour.Utilization
	}
	for _, w := range v.Windows {
		if w.Utilization > n {
			n = w.Utilization
		}
	}
	return n
}

// WindowView is one rate-limit bucket plus its projection.
type WindowView struct {
	Utilization float64        `json:"utilization"`
	ResetsAt    *time.Time     `json:"resets_at,omitempty"`
	Burn        recon.BurnRate `json:"burn"`
}

// ScopedView is a per-model weekly limit.
type ScopedView struct {
	Model       string     `json:"model"`
	Surface     string     `json:"surface,omitempty"`
	Utilization float64    `json:"utilization"`
	ResetsAt    *time.Time `json:"resets_at,omitempty"`
	IsActive    bool       `json:"is_active"`
}

// LimitsAcross is the answer to "am I about to hit the wall" when more than one
// subscription is in view.
//
// It is a LIST, never a total. Two subscriptions at 4% and 19% are not 23% of
// anything — they are separate quota pools with separate resets, and adding
// them produces a number that means nothing while looking authoritative.
// Tokens and notional cost are additive; utilization is not, and the type
// enforces that rather than trusting a convention.
type LimitsAcross struct {
	// PerAccount holds one entry per subscription, each with its own exact
	// utilization. There is deliberately no aggregate field.
	PerAccount []AccountLimits `json:"per_account"`

	// Worst names the subscription closest to its limit — the only meaningful
	// single answer across several pools.
	Worst *AccountLimits `json:"worst,omitempty"`

	Note string `json:"note"`
}

// AccountLimits pairs a subscription with its own reading.
type AccountLimits struct {
	AccountUUID string      `json:"account_uuid"`
	Label       string      `json:"label"`
	Limits      *LimitsView `json:"limits"`
}

// Account is a subscription tracked by this hub.
type Account struct {
	Source           string     `json:"source"`
	AccountUUID      string     `json:"account_uuid"`
	Email            string     `json:"email"`
	OrgUUID          string     `json:"org_uuid"`
	OrgName          string     `json:"org_name"`
	SubscriptionType string     `json:"subscription_type"`
	RateLimitTier    string     `json:"rate_limit_tier"`
	DisplayName      string     `json:"display_name"`
	AccountCreatedAt *time.Time `json:"account_created_at,omitempty"`
	LabelLocked      bool       `json:"label_locked"`
	FirstSeen        time.Time  `json:"first_seen"`
	LastSeen         time.Time  `json:"last_seen"`
	EndpointCount    int        `json:"endpoint_count"`
}

// Label is THE display name for a subscription, everywhere.
//
// Every surface must resolve it the same way or the same account appears under
// two names on one page. Preference order: a name set by hand, then whatever
// the login reported, then the identifier itself — never blank, because a blank
// row is unclickable and unreadable.
func (a Account) Label() string {
	switch {
	case a.Email != "":
		return a.Email
	case a.DisplayName != "":
		return a.DisplayName
	default:
		return a.AccountUUID
	}
}

// Inferred reports whether this subscription was identified by its rate-limit
// schedule rather than by a login. The UI says so rather than presenting a
// heuristic as a fact.
func (a Account) Inferred() bool { return strings.HasPrefix(a.AccountUUID, "win_") }

// AttemptsTail is the optional last field of a place line (claude-fleet#1610):
// `after <machine>:<operation_id>:<exit>,…` for each machine that declined
// first ("-" for none), "" when the first try answered.
func AttemptsTail(machines, ops []string, exits []int) string {
	if len(machines) == 0 {
		return ""
	}
	parts := make([]string, len(machines))
	for i, m := range machines {
		op := ops[i]
		if op == "" {
			op = "-"
		}
		parts[i] = m + ":" + op + ":" + strconv.Itoa(exits[i])
	}
	return "after " + strings.Join(parts, ",")
}
