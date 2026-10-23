package api

import (
	"math"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/model"
)

type codexCapacityInput struct {
	Plan                  string                     `json:"plan,omitempty"`
	PlanSource            string                     `json:"plan_source,omitempty"`
	RegisteredPlan        string                     `json:"registered_plan,omitempty"`
	Tier                  string                     `json:"tier,omitempty"`
	Status                string                     `json:"status"`
	Profile               *store.PlanCapacityProfile `json:"profile,omitempty"`
	EstimatedRemaining    *float64                   `json:"estimated_remaining_units,omitempty"`
	Calibration           float64                    `json:"calibration_factor"`
	CalibrationConfidence string                     `json:"calibration_confidence"`
	CalibrationSamples    int                        `json:"calibration_samples"`
	CalibrationStatus     string                     `json:"calibration_status"`
}

func (s *Server) codexCapacityProfile(c store.Credential, q *model.QuotaSnapshot, cat store.PlanCapacityCatalog, now time.Time) (codexCapacityInput, *store.PlanCapacityProfile) {
	plan, source := s.Vault.PlanMetadata(c)
	registered, tier := s.Vault.PlanRegistration(c)
	meta := codexCapacityInput{Plan: plan, PlanSource: source, RegisteredPlan: registered, Tier: tier, Status: "baseline_unknown", Calibration: 1, CalibrationStatus: "pending_matched_observations", CalibrationConfidence: "none"}
	if registered != "" && registered != plan || q != nil && q.Plan != "" && q.Plan != plan {
		meta.Status = "plan_mismatch"
		return meta, nil
	}
	for _, p := range cat.Profiles {
		if p.Plan != plan || p.Tier != tier {
			continue
		}
		meta.Profile = &p
		if p.Confidence != "verified" {
			meta.Status = "baseline_unverified"
			return meta, nil
		}
		if now.Before(p.EffectiveFrom) || p.EffectiveTo != nil && !now.Before(*p.EffectiveTo) {
			meta.Status = "baseline_outside_effective_period"
			return meta, nil
		}
		meta.Status = "quota_unknown"
		return meta, &p
	}
	return meta, nil
}

// All configured windows constrain the same declared work unit. The bottleneck
// wins; a fast-reset window cannot mask an exhausted weekly window. A bounded
// 0..23.75% horizon bonus prefers use before reset without a 1/time singularity.
func applyCodexCapacity(out *codexQuotaInput, p store.PlanCapacityProfile, now time.Time) {
	if out.State != "usable" && out.State != "tight" {
		return
	}
	remaining, score := math.Inf(1), math.Inf(1)
	for _, w := range p.Windows {
		for i := range out.Windows {
			in := &out.Windows[i]
			if in.Minutes != w.Minutes || in.State != "valid" || in.Remaining == nil || in.Reset == nil {
				continue
			}
			units := w.Units * *in.Remaining / 100 // calibration is explicitly neutral until evidence exists
			in.EstimatedUnits = &units
			remaining = math.Min(remaining, units)
			horizon := math.Max(0.05, math.Min(1, in.Reset.Sub(now).Minutes()/float64(w.Minutes)))
			score = math.Min(score, units*(1+0.25*(1-horizon)))
		}
	}
	if math.IsInf(score, 0) || math.IsNaN(score) {
		return
	}
	out.Comparability = p.Unit + "/" + p.Basis
	out.Score = &score
	out.Capacity.EstimatedRemaining = &remaining
}

func codexComparable(a, b codexQuotaInput) bool {
	return a.Score != nil && b.Score != nil && a.Capacity.Profile != nil && b.Capacity.Profile != nil && a.Capacity.Profile.Pool == b.Capacity.Profile.Pool && a.Capacity.Profile.Unit == b.Capacity.Profile.Unit && a.Capacity.Profile.Basis == b.Capacity.Profile.Basis
}
