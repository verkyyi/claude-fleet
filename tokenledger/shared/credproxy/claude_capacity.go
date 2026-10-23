package credproxy

// Claude capacity has two distinct questions: are ALL applicable observed
// windows usable, and how much evidenced five-hour allowance remains? Weekly
// percentages never become five-hour work units. Keep the Python evaluator and
// testdata/claude_capacity.json contract aligned.
import (
	"math"
	"strings"
	"time"
)

type ClaudeWindow struct {
	ID           string     `json:"id"`
	Model        string     `json:"model,omitempty"` // exact request model, or family:sonnet/opus
	Minutes      int64      `json:"minutes"`
	Used         *float64   `json:"used_percent"`
	Reset        *time.Time `json:"reset_at"`
	ObservedAt   time.Time  `json:"observed_at"`
	UnknownScope bool       `json:"unknown_scope,omitempty"`
}
type ClaudeBaseline struct {
	Plan          string     `json:"plan"`
	Tier          string     `json:"tier"`
	Pool          string     `json:"pool"`
	Unit          string     `json:"unit"`
	Basis         string     `json:"basis"`
	Source        string     `json:"source"`
	Confidence    string     `json:"confidence"`
	Version       string     `json:"version"`
	FiveHour      float64    `json:"five_hour_units"`
	Weekly        *float64   `json:"weekly_units,omitempty"` // separately evidenced, never the scoring minimum
	EffectiveFrom time.Time  `json:"effective_from"`
	EffectiveTo   *time.Time `json:"effective_to,omitempty"`
}
type ClaudeCapacityEvidence struct {
	IneligibleReason     string          `json:"ineligible_reason,omitempty"`
	Account              string          `json:"account"`
	Owner                string          `json:"owner"`
	LeaseKey             string          `json:"lease_key,omitempty"`
	CredentialID         string          `json:"credential_id"`
	Plan                 string          `json:"plan,omitempty"`
	Tier                 string          `json:"tier,omitempty"`
	MetadataStatus       string          `json:"metadata_status"`
	MetadataSource       string          `json:"metadata_source,omitempty"`
	MetadataAt           *time.Time      `json:"metadata_at,omitempty"`
	ObservedPlan         string          `json:"observed_plan,omitempty"`
	ObservedTier         string          `json:"observed_tier,omitempty"`
	ObservedAt           *time.Time      `json:"metadata_observed_at,omitempty"`
	ObservedSource       string          `json:"observed_source,omitempty"`
	ObservedAgeSeconds   *int64          `json:"observed_age_seconds,omitempty"`
	RegisteredSource     string          `json:"registered_source,omitempty"`
	RegisteredConfidence string          `json:"registered_confidence,omitempty"`
	RegisteredAt         *time.Time      `json:"registered_at,omitempty"`
	RegisteredAgeSeconds *int64          `json:"registered_age_seconds,omitempty"`
	RegisteredPlan       string          `json:"registered_plan,omitempty"`
	RegisteredTier       string          `json:"registered_tier,omitempty"`
	Profile              *ClaudeBaseline `json:"profile,omitempty"`
	Windows              []ClaudeWindow  `json:"windows"`
	ObservationStatus    string          `json:"observation_status,omitempty"`
	ReadFailed           bool            `json:"read_failed"`
	RefreshHealthy       bool            `json:"refresh_healthy"`
	Paused               bool            `json:"paused"`
	Limited              bool            `json:"limited"`
	ObservedModel        string          `json:"observed_model,omitempty"`
	Complete             bool            `json:"complete"` // complete account API observation, including absence of model buckets
}
type ClaudeCapacityInput struct {
	ClaudeCapacityEvidence
	Issues            []string `json:"issues,omitempty"`
	Model             string   `json:"model"`
	State             string   `json:"state"`
	Reason            string   `json:"reason"`
	CapacityStatus    string   `json:"capacity_status"`
	Score             *float64 `json:"score,omitempty"`
	EstimatedFiveHour *float64 `json:"estimated_five_hour_units,omitempty"`
	EstimatedWeekly   *float64 `json:"estimated_weekly_units,omitempty"`
	WeeklyRemaining   *float64 `json:"weekly_remaining_percent,omitempty"`
	WeeklyCapacity    string   `json:"weekly_capacity"`
	Reservations      int      `json:"reservations"`
}

func ClaudeModelFamily(model string) string {
	// Explicit provider model families, never a display label / price guess.
	for _, family := range []string{"sonnet", "opus", "haiku"} {
		if strings.HasPrefix(model, "claude-"+family+"-") || strings.HasPrefix(model, "claude-3-"+family+"-") || strings.HasPrefix(model, "claude-3-5-"+family+"-") || strings.HasPrefix(model, "claude-3-7-"+family+"-") {
			return family
		}
	}
	return ""
}
func ClaudeEvaluate(e ClaudeCapacityEvidence, model string, now time.Time, reservations int) ClaudeCapacityInput {
	out := ClaudeCapacityInput{ClaudeCapacityEvidence: e, Model: model, State: "unknown", Reason: "missing_windows", CapacityStatus: "baseline_unknown", WeeklyCapacity: "unknown", Reservations: reservations}
	if e.IneligibleReason != "" {
		out.State = "ineligible"
		out.Reason = e.IneligibleReason
		return out
	}
	if e.Paused || !e.RefreshHealthy {
		out.State = "ineligible"
		out.Reason = "paused_or_refresh_unhealthy"
		return out
	}
	if e.Limited {
		out.State = "limited"
		out.Reason = "429_cooldown"
		return out
	}
	family := ClaudeModelFamily(model)
	valid := (e.Complete || e.ObservedModel != "" && e.ObservedModel == model) && !e.ReadFailed && family != ""
	if family == "" {
		out.Reason = "unknown_model_pool"
	} else if e.ReadFailed {
		out.Reason = "read_failed"
	} else if !e.Complete && e.ObservedModel != model {
		out.Reason = "incomplete_account_observation"
	}
	full := false
	seen := map[string]bool{}
	five, weekly := false, false
	var fiveRemaining, weeklyRemaining float64
	var fiveReset time.Time
	for _, w := range e.Windows {
		if w.Model != "" && !w.UnknownScope && w.Model != model && w.Model != "family:"+family {
			continue
		}
		if w.UnknownScope {
			valid = false
			out.Reason = "unknown_model_scope"
			out.Issues = append(out.Issues, out.Reason)
			continue
		}
		key := w.Model + "\x00" + w.ID
		general := w.Model == ""
		if general && w.ID == "five_hour" && w.Minutes == 300 {
			five = true
		}
		if general && w.ID == "seven_day" && w.Minutes == 10080 {
			weekly = true
		}
		pctOK := w.Used != nil && !math.IsNaN(*w.Used) && !math.IsInf(*w.Used, 0) && *w.Used >= 0 && *w.Used <= 100
		// Negative evidence survives age, but a future observation proves nothing.
		if pctOK && *w.Used == 100 && !w.ObservedAt.IsZero() && !w.ObservedAt.After(now) && (w.Reset == nil || w.Reset.After(now)) {
			full = true
		}
		reason := ""
		switch {
		case seen[key]:
			reason = "duplicate_window"
		case general && !((w.ID == "five_hour" && w.Minutes == 300) || (w.ID == "seven_day" && w.Minutes == 10080)):
			reason = "unexpected_window"
		case w.Minutes != 300 && w.Minutes != 10080:
			reason = "unexpected_window"
		case !pctOK:
			reason = "invalid_percentage"
		case w.ObservedAt.IsZero() || w.ObservedAt.After(now):
			reason = "invalid_observation"
		case w.Reset == nil:
			reason = "missing_reset"
		case !w.Reset.After(now):
			reason = "awaiting_reset_reading"
		case w.Reset.After(w.ObservedAt.Add(time.Duration(w.Minutes) * time.Minute)):
			reason = "reset_outside_window"
		case now.Sub(w.ObservedAt) > 10*time.Minute:
			reason = "stale_window"
		}
		seen[key] = true
		if reason != "" {
			valid = false
			out.Reason = reason
			out.Issues = append(out.Issues, reason)
			continue
		}
		if general && w.ID == "five_hour" {
			fiveRemaining = 100 - *w.Used
			fiveReset = *w.Reset
		}
		if general && w.ID == "seven_day" {
			weeklyRemaining = 100 - *w.Used
			out.WeeklyRemaining = &weeklyRemaining
		}
	}
	if full {
		out.State = "limited"
		out.Reason = "blocked_or_full_window"
		return out
	}
	if !five || !weekly {
		out.Reason = "missing_dual_window"
		return out
	}
	if !valid {
		return out
	}
	out.State = "usable"
	out.Reason = "all_applicable_windows_valid"
	if fiveRemaining < 20 || weeklyRemaining < 20 {
		out.State = "tight"
	}
	p := e.Profile
	if p == nil || e.MetadataStatus != "valid" {
		out.CapacityStatus = e.MetadataStatus
		if out.CapacityStatus == "valid" {
			out.CapacityStatus = "baseline_unknown"
		}
		return out
	}
	if p.Plan != e.Plan || p.Tier != e.Tier || p.Pool != "claude" {
		out.CapacityStatus = "profile_mismatch"
		return out
	}
	if (p.Confidence != "verified" && p.Confidence != "provisional") || p.Source == "" || p.Unit == "" || p.Basis == "" {
		out.CapacityStatus = "baseline_unverified"
		return out
	}
	if p.EffectiveFrom.IsZero() || now.Before(p.EffectiveFrom) || p.EffectiveTo != nil && !now.Before(*p.EffectiveTo) {
		out.CapacityStatus = "baseline_outside_effective_period"
		return out
	}
	if math.IsNaN(p.FiveHour) || math.IsInf(p.FiveHour, 0) || p.FiveHour <= 0 {
		out.CapacityStatus = "invalid_baseline"
		return out
	}
	units := p.FiveHour * fiveRemaining / 100
	horizon := math.Max(.05, math.Min(1, fiveReset.Sub(now).Minutes()/300))
	score := units * (1 + .25*(1-horizon)) / float64(1+max(0, reservations))
	out.EstimatedFiveHour = &units
	out.Score = &score
	out.CapacityStatus = "five_hour_only_estimate"
	if p.Weekly != nil && *p.Weekly > 0 && !math.IsNaN(*p.Weekly) && !math.IsInf(*p.Weekly, 0) {
		weeklyUnits := *p.Weekly * weeklyRemaining / 100
		out.EstimatedWeekly = &weeklyUnits
		out.WeeklyCapacity = "separately_evidenced"
	}
	return out
}
