package api

import (
	"errors"
	"net/http"
	"sort"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/credvault"
	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/credproxy"
)

var errClaudeCapacity = errors.New("claude subscription capacity unavailable")

func (s *Server) claudeEvidence(c store.Credential, cat store.ProviderCapacityCatalog, now time.Time) credproxy.ClaudeCapacityEvidence {
	e := credproxy.ClaudeCapacityEvidence{Account: c.Account, Owner: c.PrincipalID, CredentialID: s.Vault.CredentialID(c), RefreshHealthy: c.RefreshError == "" && !c.ReauthRequired, MetadataStatus: "metadata_unknown"}
	if c.Source() == store.SourceAPI {
		e.IneligibleReason = "paid_api_not_subscription"
	}
	e.RegisteredPlan, e.RegisteredTier = s.Vault.PlanRegistration(c)
	registration := s.Vault.RegisteredPlanEvidence(c)
	e.RegisteredSource, e.RegisteredConfidence = registration.Source, registration.Confidence
	if !registration.ObservedAt.IsZero() {
		e.RegisteredAt = &registration.ObservedAt
		age := int64(now.Sub(registration.ObservedAt).Seconds())
		e.RegisteredAgeSeconds = &age
	}
	identity := s.Vault.AccountUUID(c)
	accounts, err := s.Store.ListAccounts()
	if err != nil {
		e.MetadataStatus = "metadata_read_failed"
	}
	for _, a := range accounts {
		if identity == "" || a.AccountUUID != identity || a.Source != "claude" {
			continue
		}
		e.ObservedPlan, e.ObservedTier = a.SubscriptionType, a.RateLimitTier
		at := a.LastSeen
		e.ObservedAt = &at
		e.ObservedSource = "provider_account_identity:last_seen"
		age := int64(now.Sub(at).Seconds())
		e.ObservedAgeSeconds = &age
		if !at.IsZero() && !at.After(now) && now.Sub(at) <= 24*time.Hour && a.SubscriptionType != "" && a.RateLimitTier != "" {
			e.Plan, e.Tier, e.MetadataStatus, e.MetadataSource, e.MetadataAt = a.SubscriptionType, a.RateLimitTier, "valid", "provider_account_identity:last_seen", &at
		} else {
			e.MetadataStatus = "observed_metadata_stale_or_missing"
		}
	}
	if e.RegisteredPlan != "" && e.RegisteredTier != "" {
		e.Plan, e.Tier = e.RegisteredPlan, e.RegisteredTier
		e.MetadataStatus = "registration_evidence_missing"
		if registration.Source != "" && (registration.Confidence == "verified" || registration.Confidence == "provisional") && !registration.ObservedAt.IsZero() && !registration.ObservedAt.After(now) && now.Sub(registration.ObservedAt) <= 30*24*time.Hour {
			e.MetadataStatus, e.MetadataSource = "valid", "registration:"+registration.Source
			e.MetadataAt = &registration.ObservedAt
		}
		if e.ObservedPlan != "" && e.ObservedPlan != e.Plan || e.ObservedTier != "" && e.ObservedTier != e.Tier {
			e.MetadataStatus = "metadata_conflict"
		}
	}
	for _, p := range cat.Profiles {
		if p.Pool != "claude" || p.Plan != e.Plan || p.Tier != e.Tier {
			continue
		}
		profile := credproxy.ClaudeBaseline{Plan: p.Plan, Tier: p.Tier, Pool: p.Pool, Unit: p.Unit, Basis: p.Basis, Source: p.Source, Version: p.Version, Confidence: p.Confidence, EffectiveFrom: p.EffectiveFrom, EffectiveTo: p.EffectiveTo}
		for _, w := range p.Windows {
			if w.Minutes == 300 {
				profile.FiveHour = w.Units
			}
			if w.Minutes == 10080 {
				units := w.Units
				profile.Weekly = &units
			}
		}
		e.Profile = &profile
	}
	e.ObservationStatus = "invalid_or_missing_account_schema"
	raw, at, err := s.Store.ClaudeCapacityRaw(e.CredentialID)
	if err != nil {
		e.ReadFailed = true
	} else {
		if windows, model, header := credproxy.ClaudeHeaderWindows(raw, at); header {
			e.Windows = windows
			e.ObservationStatus = "request_model_headers"
			e.ObservedModel = model
		} else {
			e.Windows, e.Complete = credproxy.ClaudeUsageWindows(raw, at)
			if e.Complete {
				e.ObservationStatus = "account_api"
			}
		}
		if len(raw) == 0 {
			e.ObservationStatus = "legacy_negative_only"
			// Old header snapshots have no completeness/presence proof. Their known
			// full windows still forbid fallback; no positive capacity is invented.
			snap, readErr := s.Store.LatestLimits(e.CredentialID)
			if readErr != nil {
				e.ReadFailed = true
			} else if snap != nil {
				for _, w := range []struct {
					id      string
					minutes int64
					used    float64
					reset   *time.Time
				}{{"five_hour", 300, snap.FiveHour.Utilization, snap.FiveHour.ResetsAt}, {"seven_day", 10080, snap.SevenDay.Utilization, snap.SevenDay.ResetsAt}} {
					if w.used == 100 {
						used := w.used
						e.Windows = append(e.Windows, credproxy.ClaudeWindow{ID: w.id, Minutes: w.minutes, Used: &used, Reset: w.reset, ObservedAt: snap.ObservedAt})
					}
				}
			}
		}
	}
	read, err := s.Store.CredentialQuotaRead(e.CredentialID)
	if err != nil || read != nil && read.Error != "" && !read.At.Before(at) {
		e.ReadFailed = true
	}
	claims, err := s.Store.LatestModelClaims(e.CredentialID)
	if err != nil {
		e.ReadFailed = true
	}
	for _, c := range claims {
		used := c.Utilization
		if c.Status == "rejected" {
			used = 100
		}
		minutes := int64(0)
		if strings.HasPrefix(c.Claim, "7d_") {
			minutes = 10080
		}
		if strings.HasPrefix(c.Claim, "5h_") {
			minutes = 300
		}
		duplicate := false
		for _, w := range e.Windows {
			if w.Model == c.Model && w.ID == c.Claim && w.ObservedAt.Equal(c.ObservedAt) {
				duplicate = true
			}
		}
		if duplicate {
			continue
		}
		e.Windows = append(e.Windows, credproxy.ClaudeWindow{ID: "claim:" + c.Claim, Model: c.Model, Minutes: minutes, Used: &used, Reset: c.ResetsAt, ObservedAt: c.ObservedAt, UnknownScope: c.Model == ""})
	}
	if e.ReadFailed {
		e.ObservationStatus = "quota_read_failed_or_conflicting"
	}
	e.Limited = s.limits.limited(credvault.Claude, c.PrincipalID, e.CredentialID, now)
	return e
}

func (s *Server) claudeInputs(choices []store.Credential, b store.SessionBind, cat store.ProviderCapacityCatalog, model string, now time.Time) []credproxy.ClaudeCapacityInput {
	loads, err := s.Store.ClaudeLiveBindLoads(b.WorkerID, now)
	settings, settingsErr := s.Store.FleetSettings()
	paused := map[string]bool{}
	for _, a := range pausedAccounts(settings) {
		paused[a] = true
	}
	out := make([]credproxy.ClaudeCapacityInput, 0, len(choices))
	for _, c := range choices {
		e := s.claudeEvidence(c, cat, now)
		e.Paused = settingsErr != nil || c.PrincipalID == store.PoolPrincipal && paused[c.Account]
		row := credproxy.ClaudeEvaluate(e, model, now, loads[c.PrincipalID+"\x00"+c.Account])
		if err != nil {
			row.Score = nil
			row.CapacityStatus = "load_unknown"
		}
		out = append(out, row)
	}
	return out
}

func claudeEligible(q credproxy.ClaudeCapacityInput) bool {
	return q.State == "usable" || q.State == "tight"
}
func claudeComparable(a, b credproxy.ClaudeCapacityInput) bool {
	return a.Score != nil && b.Score != nil && a.Profile != nil && b.Profile != nil && a.Profile.Pool == b.Profile.Pool && a.Profile.Unit == b.Profile.Unit && a.Profile.Basis == b.Profile.Basis
}

// Eligibility is decided before ranking. Unknown weekly/model observations
// cannot become an unlimited fallback, including for an explicit binding.
func claudeChoose(inputs []credproxy.ClaudeCapacityInput, b store.SessionBind, now time.Time, boundary bool) (int, string) {
	current := -1
	eligible := []int{}
	for i, q := range inputs {
		if q.Owner == b.Owner && q.Account == b.Account {
			current = i
		}
		if claudeEligible(q) {
			eligible = append(eligible, i)
		}
	}
	auto := b.SetBy == "" || b.SetBy == "auto" || b.SetBy == "claude:capacity" || b.SetBy == "credproxy:quota" || b.SetBy == "credproxy:429"
	if current >= 0 && !auto {
		if claudeEligible(inputs[current]) {
			return current, "explicit_binding"
		}
		return -1, "explicit_binding_unavailable"
	}
	if len(eligible) == 0 {
		return -1, "no_observed_eligible_subscription"
	}
	// Preserve own-before-pool. The comparable cohort must be complete, so a
	// single unknown baseline cannot make pairwise ordering non-transitive.
	own := inputs[eligible[0]].Owner
	for _, i := range eligible {
		if inputs[i].Owner != store.PoolPrincipal {
			own = inputs[i].Owner
			break
		}
	}
	cohort := []int{}
	for _, i := range eligible {
		if inputs[i].Owner == own {
			cohort = append(cohort, i)
		}
	}
	comparable := true
	for _, i := range cohort {
		comparable = comparable && claudeComparable(inputs[cohort[0]], inputs[i])
	}
	sort.SliceStable(cohort, func(a, b int) bool {
		x, y := inputs[cohort[a]], inputs[cohort[b]]
		if comparable && *x.Score != *y.Score {
			return *x.Score > *y.Score
		}
		if x.WeeklyRemaining != nil && y.WeeklyRemaining != nil && *x.WeeklyRemaining != *y.WeeklyRemaining {
			return *x.WeeklyRemaining > *y.WeeklyRemaining
		}
		return x.Account < y.Account
	})
	pick := cohort[0]
	reason := "conservative_weekly_fraction"
	if comparable {
		reason = "five_hour_capacity"
	}
	if current >= 0 && claudeEligible(inputs[current]) {
		if !boundary {
			return current, "continuation_binding"
		}
		if now.Sub(b.UpdatedAt) < 10*time.Minute {
			return current, "minimum_hold"
		}
		if inputs[current].Owner == inputs[pick].Owner {
			if !claudeComparable(inputs[current], inputs[pick]) || !comparable {
				return current, "incomparable_keep"
			}
			if *inputs[pick].Score <= *inputs[current].Score*1.25 {
				return current, "no_material_gain"
			}
		}
	}
	return pick, reason
}

func (s *Server) claudePreview(w http.ResponseWriter, worker, principal, endpoint, model string, newSession, authorized bool, now time.Time) {
	if !authorized {
		httpError(w, 403, "worker pass does not authorize Claude")
		return
	}
	choices, err := s.sessionBindChoices(principal, endpoint, credvault.Claude)
	if err != nil {
		httpError(w, 500, "policy read failed")
		return
	}
	if isSvcPrincipal(principal) {
		choices = s.svcYield(principal, choices, now)
	}
	b, err := s.Store.SessionBindFor(worker, credvault.Claude)
	if err != nil && !errors.Is(err, store.ErrNoSessionBind) {
		httpError(w, 500, "binding read failed")
		return
	}
	if newSession || errors.Is(err, store.ErrNoSessionBind) {
		b = store.SessionBind{WorkerID: worker, Provider: credvault.Claude}
	}
	cat, err := s.Store.PlanCapacities()
	if err != nil {
		httpError(w, 500, "catalog read failed")
		return
	}
	cfg := cat.Catalog.Provider("claude")
	inputs := s.claudeInputs(choices, b, cfg, model, now)
	pick, reason := claudeChoose(inputs, b, now, !isSvcPrincipal(principal))
	proposed := map[string]any{"reason": reason, "refused": pick < 0}
	if pick >= 0 {
		proposed["owner"] = inputs[pick].Owner
		proposed["account"] = inputs[pick].Account
	}
	current := map[string]any{"owner": b.Owner, "account": b.Account, "reason": "legacy_sticky"}
	if cfg.Mode == "active" {
		current = proposed
	}
	writeJSON(w, 200, map[string]any{"policy": "claude-capacity-v1", "catalog_revision": cat.Revision, "mode": cfg.Mode, "worker_id": worker, "model": model, "binding": b, "new_session": newSession, "inputs": inputs, "proposed": proposed, "current_policy": current, "mutates_bindings": false, "weekly_capacity": "unknown unless separately evidenced", "estimate_scope": "five_hour_only"})
}
