package codex

import (
	"encoding/json"
	"errors"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/model"
)

// The account API read over HTTP (claude-fleet#2169).
//
// A node asks `codex app-server` (account/rateLimits/read); the hub has no
// Codex binary and reads the same numbers where the CLI itself reads them —
// chatgpt.com's backend-api /wham/usage, through the Singapore relay's
// /chatgpt/ route. Its body is the backend's own snake_case shape:
//
//	{"plan_type":"plus",
//	 "rate_limit":{"allowed":true,"limit_reached":false,
//	   "primary_window":{"used_percent":12,"limit_window_seconds":18000,"reset_after_seconds":60,"reset_at":1730000000},
//	   "secondary_window":{…}},
//	 "credits":{"has_credits":false,"unlimited":false,"balance":"0"},
//	 "additional_rate_limits":[{"limit_name":"…","metered_feature":"…","rate_limit":{…}}]}
//
// ParseUsage turns it into the app-server's rateLimitsByLimitId shape and
// hands that to ParseLimits, so both reads name their pools and windows the
// same way ("codex:primary", …) and the subscriptions page cannot tell them
// apart except by Observation.

// UsagePath is the backend-api route under chatgpt.com's /backend-api.
const UsagePath = "/wham/usage"

// ObservationAccountAPI marks a complete account read made over HTTP — the
// same completeness as an app_server read (store.LatestQuota).
const ObservationAccountAPI = "account_api"

type usageWindow struct {
	UsedPercent        *float64 `json:"used_percent"`
	LimitWindowSeconds float64  `json:"limit_window_seconds"`
	ResetAt            float64  `json:"reset_at"`
}

type usageLimit struct {
	Allowed         *bool        `json:"allowed"`
	LimitReached    bool         `json:"limit_reached"`
	PrimaryWindow   *usageWindow `json:"primary_window"`
	SecondaryWindow *usageWindow `json:"secondary_window"`
}

type usageDoc struct {
	PlanType  string      `json:"plan_type"`
	RateLimit *usageLimit `json:"rate_limit"`
	Credits   *struct {
		HasCredits bool    `json:"has_credits"`
		Unlimited  bool    `json:"unlimited"`
		Balance    *string `json:"balance"`
	} `json:"credits"`
	Additional []struct {
		LimitName      string      `json:"limit_name"`
		MeteredFeature string      `json:"metered_feature"`
		RateLimit      *usageLimit `json:"rate_limit"`
	} `json:"additional_rate_limits"`
}

func usageBucket(l *usageLimit, plan, name string) map[string]any {
	b := map[string]any{}
	if plan != "" {
		b["planType"] = plan
	}
	if name != "" {
		b["limitName"] = name
	}
	for kind, w := range map[string]*usageWindow{"primary": l.PrimaryWindow, "secondary": l.SecondaryWindow} {
		if w == nil || w.UsedPercent == nil {
			continue
		}
		win := map[string]any{"usedPercent": *w.UsedPercent}
		if w.LimitWindowSeconds > 0 {
			win["windowDurationMins"] = w.LimitWindowSeconds / 60
		}
		if w.ResetAt > 0 {
			win["resetsAt"] = w.ResetAt
		}
		b[kind] = win
	}
	if l.LimitReached || (l.Allowed != nil && !*l.Allowed) {
		b["rateLimitReachedType"] = "limit_reached"
	}
	return b
}

// ParseUsage reads a /wham/usage body. It carries measurements only — the
// body names no credential.
func ParseUsage(raw []byte, observed time.Time) (*model.QuotaSnapshot, error) {
	var d usageDoc
	if err := json.Unmarshal(raw, &d); err != nil {
		return nil, errors.New("invalid Codex usage JSON")
	}
	buckets := map[string]any{}
	if d.RateLimit != nil {
		b := usageBucket(d.RateLimit, d.PlanType, "")
		if d.Credits != nil {
			c := map[string]any{"hasCredits": d.Credits.HasCredits, "unlimited": d.Credits.Unlimited}
			if d.Credits.Balance != nil {
				c["balance"] = *d.Credits.Balance
			}
			b["credits"] = c
		}
		buckets["codex"] = b
	}
	for _, a := range d.Additional {
		id := a.MeteredFeature
		if id == "" {
			id = a.LimitName
		}
		if id == "" || a.RateLimit == nil || buckets[id] != nil {
			continue
		}
		buckets[id] = usageBucket(a.RateLimit, d.PlanType, a.LimitName)
	}
	if len(buckets) == 0 {
		return nil, errors.New("Codex usage carried no rate limit")
	}
	b, err := json.Marshal(map[string]any{"rateLimitsByLimitId": buckets})
	if err != nil {
		return nil, err
	}
	q, err := ParseLimits(b, observed)
	if err != nil {
		return nil, err
	}
	if q.Plan == "" {
		q.Plan = d.PlanType
	}
	q.Observation = ObservationAccountAPI
	return q, nil
}
