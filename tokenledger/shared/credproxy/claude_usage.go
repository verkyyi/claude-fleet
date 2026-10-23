package credproxy

import (
	"encoding/json"
	"sort"
	"strconv"
	"strings"
	"time"
)

// Preserve absent utilization and model scope. No price, extra_usage or spend
// field participates. Unknown non-null weekly scopes remain conservative.
func ClaudeUsageWindows(raw []byte, at time.Time) ([]ClaudeWindow, bool) {
	var root map[string]json.RawMessage
	if !uniqueCodexJSON(raw) || json.Unmarshal(raw, &root) != nil || root == nil {
		return nil, false
	}
	var windows []ClaudeWindow
	window := func(id, model string, minutes int64, raw json.RawMessage, unknown bool) {
		var value struct {
			Used  *float64   `json:"utilization"`
			Reset *time.Time `json:"resets_at"`
		}
		if json.Unmarshal(raw, &value) != nil {
			windows = append(windows, ClaudeWindow{ID: id, UnknownScope: true})
			return
		}
		windows = append(windows, ClaudeWindow{ID: id, Model: model, Minutes: minutes, Used: value.Used, Reset: value.Reset, ObservedAt: at, UnknownScope: unknown})
	}
	for _, name := range []string{"five_hour", "seven_day"} {
		if v, ok := root[name]; ok && string(v) != "null" {
			minutes := int64(300)
			if name == "seven_day" {
				minutes = 10080
			}
			window(name, "", minutes, v, false)
		}
	}
	names := []string{}
	for name := range root {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		value := root[name]
		if name != "five_hour" && name != "seven_day" && !strings.HasPrefix(name, "seven_day_") && name != "extra_usage" && name != "spend" && name != "limits" && string(value) != "null" {
			var obj map[string]json.RawMessage
			if json.Unmarshal(value, &obj) == nil && obj["utilization"] != nil {
				window(name, "", 0, value, true)
			}
		}
		if !strings.HasPrefix(name, "seven_day_") || string(value) == "null" {
			continue
		}
		model := ""
		unknown := true
		for _, family := range []string{"sonnet", "opus", "haiku"} {
			if name == "seven_day_"+family {
				model = "family:" + family
				unknown = false
			}
		}
		window(name, model, 10080, value, unknown)
	}
	var scoped []struct {
		Kind    string     `json:"kind"`
		Percent *float64   `json:"percent"`
		Reset   *time.Time `json:"resets_at"`
		Scope   *struct {
			Model *struct {
				ID   string `json:"id"`
				Name string `json:"display_name"`
			} `json:"model"`
			Surface string `json:"surface"`
		} `json:"scope"`
	}
	if value, ok := root["limits"]; ok {
		if json.Unmarshal(value, &scoped) != nil {
			return windows, false
		}
		for _, w := range scoped {
			if w.Kind == "session" || w.Kind == "weekly_all" {
				id, minutes := "five_hour", int64(300)
				if w.Kind == "weekly_all" {
					id, minutes = "seven_day", 10080
				}
				candidate := ClaudeWindow{ID: id, Minutes: minutes, Used: w.Percent, Reset: w.Reset, ObservedAt: at, UnknownScope: w.Scope != nil}
				identical := false
				for _, old := range windows {
					if old.ID == id && old.Model == "" && !candidate.UnknownScope && old.Used != nil && candidate.Used != nil && *old.Used == *candidate.Used && old.Reset != nil && candidate.Reset != nil && old.Reset.Equal(*candidate.Reset) {
						identical = true
					}
				}
				if !identical {
					windows = append(windows, candidate)
				}
				continue
			}
			model := ""
			unknown := w.Kind != "weekly_scoped" || w.Scope != nil && w.Scope.Surface != ""
			if w.Scope != nil && w.Scope.Model != nil {
				model = w.Scope.Model.ID
				if model == "" {
					for _, family := range []string{"sonnet", "opus", "haiku"} {
						if strings.EqualFold(w.Scope.Model.Name, family) {
							model = "family:" + family
						}
					}
				}
			}
			if model == "" {
				unknown = true
			}
			windows = append(windows, ClaudeWindow{ID: "weekly_scoped", Model: model, Minutes: 10080, Used: w.Percent, Reset: w.Reset, ObservedAt: at, UnknownScope: unknown})
		}
	}
	return windows, true
}

// Header observations establish only the exact requested model's applicable
// windows. An absent claim for Haiku never proves that Opus is uncapped.
func ClaudeHeaderWindows(raw []byte, at time.Time) ([]ClaudeWindow, string, bool) {
	var v struct {
		Headers map[string][]string `json:"fleet_claude_headers_v1"`
		Model   string              `json:"request_model"`
	}
	if !uniqueCodexJSON(raw) || json.Unmarshal(raw, &v) != nil || v.Headers == nil {
		return nil, "", false
	}
	windows := []ClaudeWindow{}
	names := []string{}
	seen := map[string]bool{}
	for k := range v.Headers {
		for _, suffix := range []string{"-utilization", "-reset", "-status"} {
			if strings.HasPrefix(k, "anthropic-ratelimit-unified-") && strings.HasSuffix(k, suffix) {
				stem := strings.TrimSuffix(k, suffix)
				if stem != "anthropic-ratelimit-unified" && !seen[stem] {
					seen[stem] = true
					names = append(names, stem+"-utilization")
				}
			}
		}
	}
	sort.Strings(names)
	for _, k := range names {
		claim := strings.TrimSuffix(strings.TrimPrefix(k, "anthropic-ratelimit-unified-"), "-utilization")
		id, model, minutes := claim, v.Model, int64(0)
		if claim == "5h" {
			id, model, minutes = "five_hour", "", 300
		}
		if claim == "7d" {
			id, model, minutes = "seven_day", "", 10080
		}
		if strings.HasPrefix(claim, "7d_") {
			minutes = 10080
		}
		if strings.HasPrefix(claim, "5h_") {
			minutes = 300
		}
		w := ClaudeWindow{ID: id, Model: model, Minutes: minutes, ObservedAt: at, UnknownScope: model == "" && id != "five_hour" && id != "seven_day"}
		if values := v.Headers[k]; len(values) == 1 {
			if used, err := strconv.ParseFloat(values[0], 64); err == nil {
				used *= 100
				w.Used = &used
			}
		}
		prefix := "anthropic-ratelimit-unified-" + claim
		if values := v.Headers[prefix+"-reset"]; len(values) == 1 {
			if sec, err := strconv.ParseInt(values[0], 10, 64); err == nil && sec > 0 {
				reset := time.Unix(sec, 0).UTC()
				w.Reset = &reset
			}
		}
		if values := v.Headers[prefix+"-status"]; len(values) == 1 && values[0] == "rejected" {
			full := 100.0
			w.Used = &full
		}
		windows = append(windows, w)
	}
	if values := v.Headers["anthropic-ratelimit-unified-status"]; len(values) == 1 && values[0] == "rejected" {
		full := 100.0
		windows = append(windows, ClaudeWindow{ID: "unified_rejected", Model: v.Model, Minutes: 0, Used: &full, ObservedAt: at, UnknownScope: v.Model == ""})
	}
	return windows, v.Model, true
}
