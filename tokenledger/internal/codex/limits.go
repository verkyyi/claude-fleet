package codex

import (
	"encoding/json"
	"errors"
	"sort"
	"strings"
	"time"

	"github.com/verkyyi/ccquota/internal/model"
)

// normalizeKeys accepts the RPC camelCase and transcript snake_case contracts.
func normalizeKeys(v any) any {
	switch x := v.(type) {
	case map[string]any:
		m := map[string]any{}
		for k, v := range x {
			key := strings.ToLower(strings.ReplaceAll(k, "_", ""))
			if key == "ratelimitsbylimitid" {
				if buckets, ok := v.(map[string]any); ok {
					b := map[string]any{}
					for id, value := range buckets {
						b[id] = normalizeKeys(value)
					}
					m[key] = b
					continue
				}
			}
			m[key] = normalizeKeys(v)
		}
		return m
	case []any:
		for i := range x {
			x[i] = normalizeKeys(x[i])
		}
		return x
	default:
		return v
	}
}

func ParseLimits(raw []byte, observed time.Time) (*model.QuotaSnapshot, error) {
	var doc any
	if err := json.Unmarshal(raw, &doc); err != nil {
		return nil, errors.New("invalid Codex quota JSON")
	}
	m, ok := normalizeKeys(doc).(map[string]any)
	if !ok {
		return nil, errors.New("Codex quota unavailable")
	}
	buckets, _ := m["ratelimitsbylimitid"].(map[string]any)
	if len(buckets) == 0 {
		if nested, ok := m["ratelimits"].(map[string]any); ok {
			m = nested
		}
		id := str(m["limitid"])
		if id == "" {
			id = "codex"
		}
		buckets = map[string]any{id: m}
	}
	q := &model.QuotaSnapshot{Source: model.SourceCodex, ObservedAt: observed, Observation: "transcript"}
	ids := make([]string, 0, len(buckets))
	for k := range buckets {
		ids = append(ids, k)
	}
	sort.Strings(ids)
	for _, id := range ids {
		b, ok := buckets[id].(map[string]any)
		if !ok {
			continue
		}
		pool := model.QuotaPool{LimitID: id}
		if p := str(b["plantype"]); p != "" {
			q.Plan = p
		}
		label := str(b["limitname"])
		if label == "" {
			label = id
		}
		for _, kind := range []string{"primary", "secondary"} {
			w, ok := b[kind].(map[string]any)
			if !ok {
				continue
			}
			pct, ok := w["usedpercent"].(float64)
			if !ok || pct < 0 || pct > 100 {
				continue
			}
			win := model.QuotaWindow{ID: id + ":" + kind, LimitID: id, Label: label + " · " + kind, UsedPercent: pct}
			if mins, ok := w["windowdurationmins"].(float64); ok && mins > 0 {
				win.Minutes = int64(mins)
			}
			if reset, ok := w["resetsat"].(float64); ok && reset > 0 {
				t := time.Unix(int64(reset), 0).UTC()
				win.ResetsAt = &t
			}
			q.Windows = append(q.Windows, win)
		}
		if reason := str(b["ratelimitreachedtype"]); reason != "" {
			q.Blocked = true
			q.Reason = reason
			pool.Blocked, pool.Reason = true, reason
		}
		if reached, _ := b["spendcontrolreached"].(bool); reached {
			q.Blocked = true
			q.Reason = "spend_control_reached"
			pool.Blocked, pool.Reason = true, q.Reason
		}
		if c, ok := b["credits"].(map[string]any); ok {
			cr := model.QuotaCredits{LimitID: id}
			cr.HasCredits, _ = c["hascredits"].(bool)
			cr.Unlimited, _ = c["unlimited"].(bool)
			if balance, ok := c["balance"].(string); ok {
				cr.Balance = &balance
			}
			q.Credits = append(q.Credits, cr)
		}
		q.Pools = append(q.Pools, pool)
	}
	if len(q.Windows) == 0 && len(q.Credits) == 0 && !q.Blocked {
		return nil, errors.New("Codex returned no quota windows or credits")
	}
	return q, nil
}
