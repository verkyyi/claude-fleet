package credproxy

import (
	"encoding/json"
	"fmt"
	"math"
	"os"
	"testing"
	"time"
)

func claudeFixture(now time.Time) ClaudeCapacityEvidence {
	zero := 0.0
	five, week := now.Add(time.Hour), now.Add(24*time.Hour)
	return ClaudeCapacityEvidence{RefreshHealthy: true, Complete: true, MetadataStatus: "observed_metadata_stale_or_missing", Windows: []ClaudeWindow{
		{ID: "five_hour", Minutes: 300, Used: &zero, Reset: &five, ObservedAt: now},
		{ID: "seven_day", Minutes: 10080, Used: &zero, Reset: &week, ObservedAt: now},
	}}
}
func TestClaudeHardLimitsBeforeMetadata(t *testing.T) {
	now := time.Now()
	full := 100.0
	for _, status := range []string{"metadata_unknown", "observed_metadata_stale_or_missing", "metadata_conflict", "valid"} {
		e := claudeFixture(now)
		e.MetadataStatus = status
		e.Windows[1].Used = &full
		for _, model := range []string{"claude-sonnet-4-5", "unknown"} {
			got := ClaudeEvaluate(e, model, now, 0)
			if got.State != "limited" || got.Score != nil {
				t.Fatalf("%s %s: %+v", status, model, got)
			}
		}
	}
}
func TestClaudeUnknownWindowsAndModel(t *testing.T) {
	now := time.Now()
	cases := []struct {
		name, reason string
		change       func(*ClaudeCapacityEvidence)
	}{
		{"unknown id", "unexpected_window", func(e *ClaudeCapacityEvidence) {
			w := e.Windows[0]
			w.ID = "new_limit"
			e.Windows = append(e.Windows, w)
		}},
		{"unknown scope", "unknown_model_scope", func(e *ClaudeCapacityEvidence) {
			w := e.Windows[0]
			w.UnknownScope = true
			e.Windows = append(e.Windows, w)
		}},
		{"duplicate", "duplicate_window", func(e *ClaudeCapacityEvidence) { e.Windows = append(e.Windows, e.Windows[0]) }},
		{"past reset", "awaiting_reset_reading", func(e *ClaudeCapacityEvidence) { past := now.Add(-time.Second); e.Windows[1].Reset = &past }},
		{"future", "invalid_observation", func(e *ClaudeCapacityEvidence) { e.Windows[1].ObservedAt = now.Add(time.Second) }},
		{"missing percentage", "invalid_percentage", func(e *ClaudeCapacityEvidence) { e.Windows[1].Used = nil }},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			e := claudeFixture(now)
			c.change(&e)
			got := ClaudeEvaluate(e, "claude-sonnet-4-5", now, 0)
			if got.State != "unknown" || got.Reason != c.reason {
				t.Fatalf("%+v", got)
			}
		})
	}
	e := claudeFixture(now)
	full := 100.0
	w := e.Windows[1]
	w.ID = "seven_day_opus"
	w.Model = "family:opus"
	w.Used = &full
	e.Windows = append(e.Windows, w)
	if ClaudeEvaluate(e, "claude-opus-4-1", now, 0).State != "limited" || ClaudeEvaluate(e, "claude-sonnet-4-5", now, 0).State != "usable" {
		t.Fatal("model scope crossed")
	}
}
func TestClaudeFiveHourOnly(t *testing.T) {
	now := time.Now()
	e := claudeFixture(now)
	e.Plan = "max"
	e.Tier = "max20"
	e.MetadataStatus = "valid"
	e.Profile = &ClaudeBaseline{Plan: e.Plan, Tier: e.Tier, Pool: "claude", FiveHour: 20, Unit: "pro-session", Basis: "5h", Source: "official", Confidence: "verified", EffectiveFrom: now.Add(-time.Hour)}
	q := ClaudeEvaluate(e, "claude-sonnet-4-5", now, 0)
	if q.Score == nil || *q.EstimatedFiveHour != 20 || q.EstimatedWeekly != nil || q.WeeklyCapacity != "unknown" || q.CapacityStatus != "five_hour_only_estimate" {
		t.Fatalf("%+v", q)
	}
}

func TestClaudeSharedCapacityVectors(t *testing.T) {
	raw, err := os.ReadFile("testdata/claude_capacity.json")
	if err != nil {
		t.Fatal(err)
	}
	var cases []struct {
		Name          string
		Now           time.Time
		Model         string
		Evidence      ClaudeCapacityEvidence
		State, Reason string
		Score         *float64
	}
	if err := json.Unmarshal(raw, &cases); err != nil {
		t.Fatal(err)
	}
	for _, v := range cases {
		t.Run(v.Name, func(t *testing.T) {
			q := ClaudeEvaluate(v.Evidence, v.Model, v.Now, 0)
			if q.State != v.State || v.Reason != "" && q.Reason != v.Reason {
				t.Fatalf("%+v", q)
			}
			if v.Score != nil && (q.Score == nil || math.Abs(*q.Score-*v.Score) > 1e-9) {
				t.Fatal(q.Score, v.Score)
			}
			if q.EstimatedWeekly != nil || q.WeeklyCapacity != "unknown" {
				t.Fatal("invented weekly units", q)
			}
		})
	}
}
func TestClaudeUsageHeaderAndUnknownSchema(t *testing.T) {
	now := time.Now()
	reset := now.Add(time.Hour).Format(time.RFC3339)
	raw := []byte(`{"five_hour":{"utilization":0,"resets_at":"` + reset + `"},"seven_day":{"utilization":100,"resets_at":"` + reset + `"},"nimbus_quill":{"utilization":0,"resets_at":null}}`)
	windows, complete := ClaudeUsageWindows(raw, now)
	q := ClaudeEvaluate(ClaudeCapacityEvidence{RefreshHealthy: true, Complete: complete, Windows: windows}, "claude-sonnet-4-6", now, 0)
	if q.State != "limited" || len(q.Issues) == 0 {
		t.Fatal("unknown schema or full evidence hidden", q)
	}
	windows, model, ok := ClaudeHeaderWindows([]byte(fmt.Sprintf(`{"fleet_claude_headers_v1":{"anthropic-ratelimit-unified-5h-utilization":["0"],"anthropic-ratelimit-unified-5h-reset":["%d"],"anthropic-ratelimit-unified-7d-utilization":["1"],"anthropic-ratelimit-unified-7d-reset":["%d"]},"request_model":"claude-haiku-4-5-20251001"}`, now.Add(time.Hour).Unix(), now.Add(24*time.Hour).Unix())), now)
	if !ok || model == "" {
		t.Fatal(windows, model, ok)
	}
	q = ClaudeEvaluate(ClaudeCapacityEvidence{RefreshHealthy: true, ObservedModel: model, Windows: windows}, "claude-sonnet-4-6", now, 0)
	if q.State != "limited" {
		t.Fatal("full general window lost across models", q)
	}
}

func TestClaudeConflictingAndStatusOnlyQuota(t *testing.T) {
	now := time.Now()
	reset := now.Add(time.Hour).Format(time.RFC3339)
	raw := []byte(`{"five_hour":{"utilization":0,"resets_at":"` + reset + `"},"seven_day":{"utilization":0,"resets_at":"` + reset + `"},"limits":[{"kind":"weekly_all","percent":100,"resets_at":"` + reset + `"}]}`)
	windows, complete := ClaudeUsageWindows(raw, now)
	q := ClaudeEvaluate(ClaudeCapacityEvidence{RefreshHealthy: true, Complete: complete, Windows: windows}, "claude-sonnet-4-6", now, 0)
	if q.State != "limited" {
		t.Fatal("ignored conflicting hard quota", q)
	}
	windows, model, ok := ClaudeHeaderWindows([]byte(`{"fleet_claude_headers_v1":{"anthropic-ratelimit-unified-7d_oi-status":["rejected"]},"request_model":"claude-opus-4-1"}`), now)
	if !ok {
		t.Fatal("not a header snapshot")
	}
	q = ClaudeEvaluate(ClaudeCapacityEvidence{RefreshHealthy: true, ObservedModel: model, Windows: windows}, model, now, 0)
	if q.State != "limited" {
		t.Fatal("missing utilization hid rejection", q)
	}
}
