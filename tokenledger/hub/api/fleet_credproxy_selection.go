package api

import (
	"encoding/json"
	"log"
	"math"
	"sort"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/model"
)

// These are policy reserves, not subscription sizes or plan multipliers.
// /wham/usage supplies no absolute capacity. Even equal plan names do not
// establish comparable token capacity; never sort accounts by a percentage.
const codexQuotaFresh = 10 * time.Minute
const codexStickyHold = 10 * time.Minute
const codexReservePercent = 20.0

type codexWindowInput struct {
	Minutes   int64      `json:"minutes"`
	Remaining *float64   `json:"remaining_percent,omitempty"`
	Reset     *time.Time `json:"reset_at,omitempty"`
	Age       int64      `json:"age_seconds"`
	State     string     `json:"state"`
}

type codexQuotaInput struct {
	RefreshHealthy bool               `json:"refresh_healthy"`
	Account        string             `json:"account"`
	Owner          string             `json:"owner"`
	State          string             `json:"state"`
	Reason         string             `json:"reason"`
	Age            int64              `json:"age_seconds"`
	Comparability  string             `json:"comparability"`
	Opportunity    bool               `json:"reset_opportunity"`
	Windows        []codexWindowInput `json:"windows,omitempty"`
}

// codexQuota evaluates actual windows independently. A reset passing does not
// refill a bucket: only a new observation can make it usable. Negative evidence
// (a full, unreset window) survives staleness; positive evidence does not.
func codexQuota(q *model.QuotaSnapshot, read *store.CredentialQuotaRead, now time.Time) codexQuotaInput {
	out := codexQuotaInput{State: "unknown", Reason: "missing_reading", Comparability: "no_absolute_capacity", Age: -1}
	if q == nil {
		return out
	}
	out.Age = int64(now.Sub(q.ObservedAt).Seconds())
	fresh := !q.ObservedAt.IsZero() && !q.ObservedAt.After(now) && now.Sub(q.ObservedAt) <= codexQuotaFresh
	if !fresh {
		out.Reason = "stale_or_future_reading"
	}
	if read != nil && read.Error != "" && !read.At.Before(q.ObservedAt) {
		fresh = false
		out.Reason = "read_failed"
	}
	full := fresh && q.Blocked
	valid, tight, opportunity := fresh, false, false
	seen := map[int64]bool{}
	for _, w := range q.Windows {
		// Model-specific pools cannot establish the general subscription's size.
		if w.LimitID != "codex" {
			continue
		}
		if w.Minutes != 300 && w.Minutes != 10080 {
			valid = false
			out.Reason = "unsupported_window"
			continue
		}
		observed := q.ObservedAt
		if w.ObservedAt != nil {
			observed = *w.ObservedAt
		}
		remaining := 100 - w.UsedPercent
		in := codexWindowInput{Minutes: w.Minutes, Remaining: &remaining, Reset: w.ResetsAt, Age: int64(now.Sub(observed).Seconds()), State: "valid"}
		pctOK := !math.IsNaN(w.UsedPercent) && !math.IsInf(w.UsedPercent, 0) && w.UsedPercent >= 0 && w.UsedPercent <= 100
		if !pctOK {
			in.Remaining = nil // Invalid evidence is omitted, never measured zero.
		}
		duration := time.Duration(w.Minutes) * time.Minute
		switch {
		case seen[w.Minutes]:
			in.State = "duplicate_window"
		case !pctOK:
			in.State = "invalid_percentage"
		case observed.IsZero() || observed.After(now) || observed.After(q.ObservedAt):
			in.State = "invalid_observation"
		case w.ResetsAt == nil:
			in.State = "missing_reset"
		case !w.ResetsAt.After(now):
			in.State = "awaiting_reset_reading"
		case w.ResetsAt.After(observed.Add(duration)):
			in.State = "reset_outside_window"
		case now.Sub(observed) > codexQuotaFresh:
			in.State = "stale_window"
		}
		seen[w.Minutes] = true
		if pctOK && w.UsedPercent == 100 && !observed.After(now) && (w.ResetsAt == nil || w.ResetsAt.After(now)) {
			full = true
		}
		if in.State != "valid" {
			valid = false
			out.Reason = in.State
		}
		if in.State == "valid" {
			if *in.Remaining < codexReservePercent {
				tight = true
			}
			horizon := 30 * time.Minute
			if w.Minutes == 10080 {
				horizon = 12 * time.Hour
			}
			if w.ResetsAt.Sub(now) <= horizon {
				opportunity = true
			}
		}
		out.Windows = append(out.Windows, in)
	}
	switch {
	case full:
		out.State, out.Reason = "limited", "blocked_or_full_window"
	case !seen[300] || !seen[10080]:
		out.Reason = "missing_dual_window"
	case !valid:
	case tight:
		out.State, out.Reason = "tight", "dual_window_reserve"
	default:
		out.State, out.Reason, out.Opportunity = "usable", "dual_window_reserve", opportunity
	}
	return out
}

func (s *Server) codexQuotaFor(c store.Credential, now time.Time) codexQuotaInput {
	out := codexQuota(nil, nil, now)
	if s.Vault != nil {
		id := s.Vault.CredentialID(c)
		q, err := s.Store.LatestQuota(id)
		read, rerr := s.Store.CredentialQuotaRead(id)
		if err == nil && rerr == nil {
			out = codexQuota(q, read, now)
		} else {
			out.Reason = "read_error"
		}
		if s.limits.limited(c.Provider, c.PrincipalID, id, now) {
			out.State, out.Reason, out.Opportunity = "limited", "429_cooldown", false
		}
	}
	out.Account, out.Owner = c.Account, c.PrincipalID
	out.RefreshHealthy = c.RefreshError == ""
	return out
}

func codexBand(q codexQuotaInput) int {
	switch q.State {
	case "usable":
		return 0
	case "tight":
		return 1
	case "unknown":
		return 2
	default:
		return 3
	}
}

// Keep the existing ownership/health tiers, except that a known full account
// yields to any authorized non-full account as it did before this policy.
func codexOrder(choices []store.Credential, inputs []codexQuotaInput) []int {
	order := make([]int, len(choices))
	for i := range order {
		order[i] = i
	}
	sort.SliceStable(order, func(a, b int) bool {
		i, j := order[a], order[b]
		if (inputs[i].State == "limited") != (inputs[j].State == "limited") {
			return inputs[i].State != "limited"
		}
		if choices[i].PrincipalID != choices[j].PrincipalID {
			return choices[i].PrincipalID != store.PoolPrincipal
		}
		if (choices[i].RefreshError == "") != (choices[j].RefreshError == "") {
			return choices[i].RefreshError == ""
		}
		if codexBand(inputs[i]) != codexBand(inputs[j]) {
			return codexBand(inputs[i]) < codexBand(inputs[j])
		}
		if inputs[i].Opportunity != inputs[j].Opportunity {
			return inputs[i].Opportunity
		}
		return false // no invented capacity, exact percentage ranking, or plan weights
	})
	return order
}

func (s *Server) codexSelect(choices []store.Credential, b store.SessionBind, now time.Time, boundary bool) (store.Credential, string) {
	inputs := make([]codexQuotaInput, len(choices))
	current := -1
	for i, c := range choices {
		inputs[i] = s.codexQuotaFor(c, now)
		if c.PrincipalID == b.Owner && c.Account == b.Account {
			current = i
		}
	}
	pick := codexOrder(choices, inputs)[0]
	why := "initial_conservative_order"
	if current >= 0 {
		why = "no_material_gain"
		switch {
		case !boundary:
			why = "not_request_boundary"
		case b.SetBy != "auto" && b.SetBy != "credproxy:quota" && b.SetBy != "credproxy:429":
			why = "explicit_binding"
		case pick == current:
			why = "best_current"
		case now.Before(b.UpdatedAt.Add(codexStickyHold)):
			why = "minimum_hold"
		case inputs[pick].State != "usable":
			why = "no_known_safe_alternative"
		case inputs[current].State == "limited" || inputs[current].State == "tight":
			why = "restore_dual_window_reserve"
		case inputs[current].State == "usable" && inputs[pick].Opportunity && !inputs[current].Opportunity:
			why = "use_before_reset"
		}
		if why != "restore_dual_window_reserve" && why != "use_before_reset" {
			pick = current
		}
	}
	// This deliberately contains no raw errors, plans, tokens, IDs from tokens,
	// request bodies or headers. Structured input explains conservative fallback.
	line, _ := json.Marshal(struct {
		Policy   string            `json:"policy"`
		Worker   string            `json:"worker_id"`
		Selected string            `json:"selected"`
		Reason   string            `json:"reason"`
		Inputs   []codexQuotaInput `json:"inputs"`
	}{"codex-dual-window-v1", b.WorkerID, choices[pick].Account, why, inputs})
	log.Printf("credproxy selection: %s", line)
	return choices[pick], why
}
