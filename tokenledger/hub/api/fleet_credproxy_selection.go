package api

import (
	"crypto/sha256"
	"encoding/binary"
	"encoding/json"
	"log"
	"math"
	"sort"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/model"
)

// These are policy reserves, not subscription sizes or plan multipliers.
// /wham/usage supplies no absolute capacity. Only an explicitly registered,
// sourced plan profile establishes comparable estimated work units.
const codexQuotaFresh = 10 * time.Minute
const codexStickyHold = 10 * time.Minute
const codexReservePercent = 20.0

type codexWindowInput struct {
	Minutes        int64      `json:"minutes"`
	Remaining      *float64   `json:"remaining_percent,omitempty"`
	Reset          *time.Time `json:"reset_at,omitempty"`
	Age            int64      `json:"age_seconds"`
	State          string     `json:"state"`
	EstimatedUnits *float64   `json:"estimated_remaining_units,omitempty"`
}

type codexQuotaInput struct {
	RefreshHealthy   bool               `json:"refresh_healthy"`
	Account          string             `json:"account"`
	Owner            string             `json:"owner"`
	State            string             `json:"state"`
	Reason           string             `json:"reason"`
	Age              int64              `json:"age_seconds"`
	Comparability    string             `json:"comparability"`
	Opportunity      bool               `json:"reset_opportunity"`
	Windows          []codexWindowInput `json:"windows,omitempty"`
	Capacity         codexCapacityInput `json:"capacity"`
	LivePassBindings *int               `json:"live_pass_bindings,omitempty"`
	Score            *float64           `json:"score,omitempty"`
	Tie              uint64             `json:"-"`
}

// codexQuota evaluates actual windows independently. A reset passing does not
// refill a bucket: only a new observation can make it usable. Negative evidence
// (a full, unreset window) survives staleness; positive evidence does not.
func codexQuota(q *model.QuotaSnapshot, read *store.CredentialQuotaRead, now time.Time, profiles ...*store.PlanCapacityProfile) codexQuotaInput {
	out := codexQuotaInput{State: "unknown", Reason: "missing_reading", Comparability: "no_absolute_capacity", Age: -1}
	expected := map[int64]bool{300: true, 10080: true}
	missingReason, reserveReason := "missing_dual_window", "dual_window_reserve"
	if len(profiles) > 0 && profiles[0] != nil {
		expected = map[int64]bool{}
		missingReason, reserveReason = "missing_expected_window", "configured_window_reserve"
		for _, w := range profiles[0].Windows {
			expected[w.Minutes] = true
		}
	}
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
	// A subset of transcript/response headers cannot establish that an absent
	// window does not exist. account_api is a complete account usage response.
	if len(expected) == 1 && q.Observation != "account_api" {
		valid = false
		out.Reason = "incomplete_window_evidence"
	}
	seen := map[int64]bool{}
	for _, w := range q.Windows {
		// Model-specific pools cannot establish the general subscription's size.
		if w.LimitID != "codex" {
			continue
		}
		if !expected[w.Minutes] {
			valid = false
			out.Reason = "unexpected_window"
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
		case !expected[w.Minutes]:
			in.State = "unexpected_window"
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
	case len(seen) != len(expected):
		out.Reason = missingReason
	case !valid:
	case tight:
		out.State, out.Reason = "tight", reserveReason
	default:
		out.State, out.Reason, out.Opportunity = "usable", reserveReason, opportunity
	}
	return out
}

func (s *Server) codexQuotaFor(c store.Credential, now time.Time) codexQuotaInput {
	cat, err := s.Store.PlanCapacities()
	if err != nil {
		cat.Catalog.Mode = "off"
	}
	if cat.Catalog.Mode != "active" {
		cat.Catalog.Profiles = nil
	}
	return s.codexQuotaForCatalog(c, now, cat.Catalog)
}

func (s *Server) codexQuotaForCatalog(c store.Credential, now time.Time, cat store.PlanCapacityCatalog) codexQuotaInput {
	out := codexQuota(nil, nil, now)
	if s.Vault != nil {
		id := s.Vault.CredentialID(c)
		q, err := s.Store.LatestQuota(id)
		read, rerr := s.Store.CredentialQuotaRead(id)
		meta, profile := s.codexCapacityProfile(c, q, cat, now)
		if err == nil && rerr == nil {
			out = codexQuota(q, read, now, profile)
			out.Capacity = meta
			if profile != nil {
				applyCodexCapacity(&out, *profile, now)
			}
		} else {
			out.Reason = "read_error"
		}
		if out.Capacity.Status == "" {
			out.Capacity = meta
		}
		if profile != nil && out.Score != nil {
			out.Capacity.Status = "estimated"
		}
		if s.limits.limited(c.Provider, c.PrincipalID, id, now) {
			out.State, out.Reason, out.Opportunity = "limited", "429_cooldown", false
			out.Score = nil
		}
	}
	out.Account, out.Owner = c.Account, c.PrincipalID
	out.RefreshHealthy = c.RefreshError == ""
	return out
}

func codexCohortBand(q codexQuotaInput) int {
	if q.State == "tight" {
		return 0
	}
	return codexBand(q)
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
		if (choices[i].PrincipalID == store.PoolPrincipal) != (choices[j].PrincipalID == store.PoolPrincipal) {
			return choices[i].PrincipalID != store.PoolPrincipal
		}
		if (choices[i].RefreshError == "") != (choices[j].RefreshError == "") {
			return choices[i].RefreshError == ""
		}
		return codexCohortBand(inputs[i]) < codexCohortBand(inputs[j])
	})
	// Rank capacity only within a complete comparable policy cohort. Pairwise
	// comparisons across different bases would make the sort non-transitive.
	for from := 0; from < len(order); {
		to := from + 1
		first := order[from]
		for to < len(order) {
			j := order[to]
			if choices[first].PrincipalID != choices[j].PrincipalID || (choices[first].RefreshError == "") != (choices[j].RefreshError == "") || codexCohortBand(inputs[first]) != codexCohortBand(inputs[j]) {
				break
			}
			to++
		}
		comparable := inputs[first].Score != nil
		for _, i := range order[from:to] {
			comparable = comparable && codexComparable(inputs[first], inputs[i])
		}
		maxScore := 0.0
		if comparable {
			for _, i := range order[from:to] {
				maxScore = math.Max(maxScore, *inputs[i].Score)
			}
		}
		sort.SliceStable(order[from:to], func(a, b int) bool {
			i, j := order[from+a], order[from+b]
			if comparable {
				topI, topJ := *inputs[i].Score >= maxScore*0.99, *inputs[j].Score >= maxScore*0.99
				if topI != topJ {
					return topI
				}
				if !topI && *inputs[i].Score != *inputs[j].Score {
					return *inputs[i].Score > *inputs[j].Score
				}
			}
			if !comparable && codexBand(inputs[i]) != codexBand(inputs[j]) {
				return codexBand(inputs[i]) < codexBand(inputs[j])
			}
			if !comparable && inputs[i].Opportunity != inputs[j].Opportunity {
				return inputs[i].Opportunity
			}
			return inputs[i].Tie > inputs[j].Tie
		})
		from = to
	}
	return order
}

func (s *Server) codexSelectionInputs(choices []store.Credential, b store.SessionBind, now time.Time, cat store.PlanCapacityCatalog) []codexQuotaInput {
	inputs := make([]codexQuotaInput, len(choices))
	loads, loadErr := s.Store.CodexLiveBindLoads(b.WorkerID, now)
	for i, c := range choices {
		inputs[i] = s.codexQuotaForCatalog(c, now, cat)
		if cat.Mode != "off" {
			h := sha256.Sum256([]byte(b.WorkerID + "\x00" + c.PrincipalID + "\x00" + s.Vault.CredentialID(c)))
			inputs[i].Tie = binary.BigEndian.Uint64(h[:8])
		}
		if loadErr == nil {
			n := loads[c.PrincipalID+"\x00"+c.Account]
			inputs[i].LivePassBindings = &n
			if inputs[i].Score != nil {
				*inputs[i].Score /= 1 + float64(n)
			}
		} else {
			inputs[i].Score = nil
			inputs[i].Capacity.Status = "load_unknown"
		}
	}
	return inputs
}

func codexAutoBinding(b store.SessionBind) bool {
	return b.SetBy == "auto" || b.SetBy == "credproxy:quota" || b.SetBy == "credproxy:429"
}

func codexComparableCohort(choices []store.Credential, inputs []codexQuotaInput, pick int) bool {
	for i, c := range choices {
		if c.PrincipalID == choices[pick].PrincipalID && (c.RefreshError == "") == (choices[pick].RefreshError == "") && codexCohortBand(inputs[i]) == codexCohortBand(inputs[pick]) && !codexComparable(inputs[pick], inputs[i]) {
			return false
		}
	}
	return inputs[pick].Score != nil
}

func codexChoose(choices []store.Credential, inputs []codexQuotaInput, b store.SessionBind, now time.Time, boundary bool) (int, string) {
	current := -1
	for i, c := range choices {
		if c.PrincipalID == b.Owner && c.Account == b.Account {
			current = i
		}
	}
	pick := codexOrder(choices, inputs)[0]
	why := "initial_conservative_order"
	if codexComparableCohort(choices, inputs, pick) {
		why = "estimated_capacity_reset_load"
	}
	if current >= 0 {
		why = "no_material_gain"
		switch {
		case !boundary:
			why = "not_request_boundary"
		case !codexAutoBinding(b):
			why = "explicit_binding"
		case pick == current:
			why = "best_current"
		case now.Before(b.UpdatedAt.Add(codexStickyHold)):
			why = "minimum_hold"
		case inputs[pick].State != "usable" && !(inputs[pick].State == "tight" && codexComparableCohort(choices, inputs, pick) && codexComparable(inputs[pick], inputs[current])):
			why = "no_known_safe_alternative"
		// Capacity does not cross ownership or refresh-health policy boundaries.
		case inputs[current].State != "limited" && (choices[pick].PrincipalID != choices[current].PrincipalID || choices[pick].RefreshError != ""):
			why = "policy_boundary"
		case inputs[current].State == "limited" || inputs[current].State == "tight" && !codexComparable(inputs[pick], inputs[current]):
			why = "restore_dual_window_reserve"
			if inputs[pick].Capacity.Profile != nil {
				why = "restore_configured_window_reserve"
			}
		case codexComparableCohort(choices, inputs, pick) && codexComparable(inputs[pick], inputs[current]) && *inputs[pick].Score > 1.25*(*inputs[current].Score):
			why = "material_capacity_advantage"
		case !codexComparable(inputs[pick], inputs[current]) && inputs[current].State == "usable" && inputs[pick].Opportunity && !inputs[current].Opportunity:
			why = "use_before_reset"
		}
		if why != "restore_dual_window_reserve" && why != "restore_configured_window_reserve" && why != "use_before_reset" && why != "material_capacity_advantage" {
			pick = current
		}
	}
	return pick, why
}

func (s *Server) codexSelect(choices []store.Credential, b store.SessionBind, now time.Time, boundary bool) (store.Credential, string) {
	cat, err := s.Store.PlanCapacities()
	catalogStatus := "ok"
	if err != nil {
		catalogStatus = "read_error"
		cat.Catalog = store.PlanCapacityCatalog{Mode: "off"}
	}
	// Shadow preview evaluates profiles, but real requests keep the old policy.
	runtimeCatalog := cat.Catalog
	if runtimeCatalog.Mode != "active" {
		runtimeCatalog = store.PlanCapacityCatalog{Mode: "off"}
	}
	inputs := s.codexSelectionInputs(choices, b, now, runtimeCatalog)
	pick, why := codexChoose(choices, inputs, b, now, boundary)
	line, _ := json.Marshal(struct {
		Policy        string            `json:"policy"`
		Revision      int64             `json:"catalog_revision"`
		Mode          string            `json:"mode"`
		CatalogStatus string            `json:"catalog_status"`
		Worker        string            `json:"worker_id"`
		Selected      string            `json:"selected"`
		Reason        string            `json:"reason"`
		Inputs        []codexQuotaInput `json:"inputs"`
	}{"codex-capacity-v2", cat.Revision, cat.Catalog.Mode, catalogStatus, b.WorkerID, choices[pick].Account, why, inputs})
	log.Printf("credproxy selection: %s", line)
	return choices[pick], why
}
