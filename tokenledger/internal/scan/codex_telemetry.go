package scan

import (
	"encoding/json"
	"sort"
	"time"

	"github.com/verkyyi/ccquota/internal/codex"
	"github.com/verkyyi/ccquota/internal/model"
)

const codexParserVersion = 3

type CodexTelemetry struct {
	SessionID      string               `json:"session_id"`
	StartedAt      time.Time            `json:"started_at"`
	SeenAt         time.Time            `json:"seen_at"`
	UsageAt        time.Time            `json:"usage_at"`
	State          string               `json:"state"`
	Provider       string               `json:"provider"`
	ClientVersion  string               `json:"client_version"`
	ContextWindow  int64                `json:"context_window,omitempty"`
	ContextUsedPct *float64             `json:"context_used_pct,omitempty"`
	InputTokens    int64                `json:"input_tokens"`
	OutputTokens   int64                `json:"output_tokens"`
	CacheRead      int64                `json:"cache_read"`
	Model          string               `json:"model"`
	Effort         string               `json:"effort"`
	CWD            string               `json:"cwd"`
	Quota          *model.QuotaSnapshot `json:"quota,omitempty"`
}

type CodexQuotaObservation struct {
	SessionID string
	StartedAt time.Time
	Provider  string
	Snapshot  model.QuotaSnapshot
}

func (s *codexState) observe(kind, timestamp string, raw json.RawMessage) {
	s.Version = codexParserVersion
	if s.Telemetry == nil {
		s.Telemetry = &CodexTelemetry{}
	}
	t := s.Telemetry
	at, err := time.Parse(time.RFC3339Nano, timestamp)
	if err != nil {
		return
	}
	at = at.UTC()
	switch kind {
	case "session_meta":
		var m struct {
			ID        string          `json:"id"`
			Timestamp string          `json:"timestamp"`
			Provider  string          `json:"model_provider"`
			Version   string          `json:"cli_version"`
			CWD       string          `json:"cwd"`
			Context   json.RawMessage `json:"context_window"`
		}
		if json.Unmarshal(raw, &m) != nil {
			return
		}
		t.SessionID = "codex:" + m.ID
		t.StartedAt = at
		if started, err := time.Parse(time.RFC3339Nano, m.Timestamp); err == nil && !started.After(at) {
			t.StartedAt = started.UTC()
		}
		t.Provider = m.Provider
		t.ClientVersion = m.Version
		t.CWD = m.CWD
		// Recent clients use {window_id: ...} here for a context generation,
		// not its token capacity. It must not invalidate the other metadata.
		var capacity int64
		if json.Unmarshal(m.Context, &capacity) == nil && capacity > 0 {
			t.ContextWindow = capacity
		}
	case "turn_context":
		var m struct {
			Model  string `json:"model"`
			Effort string `json:"effort"`
			CWD    string `json:"cwd"`
		}
		if json.Unmarshal(raw, &m) == nil {
			t.Model = m.Model
			t.Effort = m.Effort
			if m.CWD != "" {
				t.CWD = m.CWD
			}
		}
	case "token_usage_record", "event_msg":
		var p struct {
			Type   string      `json:"type"`
			Usage  *codexUsage `json:"usage"`
			Thread *codexUsage `json:"thread_token_usage"`
			Info   *struct {
				Total   *codexUsage `json:"total_token_usage"`
				Last    *codexUsage `json:"last_token_usage"`
				Context int64       `json:"model_context_window"`
			} `json:"info"`
			Context int64           `json:"model_context_window"`
			Limits  json.RawMessage `json:"rate_limits"`
		}
		if json.Unmarshal(raw, &p) != nil {
			return
		}
		if len(p.Limits) > 0 && string(p.Limits) != "null" {
			if q, err := codex.ParseLimits(p.Limits, at); err == nil {
				t.Quota = q
			}
		}
		switch p.Type {
		case "task_started":
			t.State = "recent_activity"
			t.SeenAt = at
			if p.Context > 0 {
				t.ContextWindow = p.Context
			}
		case "task_complete", "task_completed":
			t.State = "completed"
			t.SeenAt = at
		case "turn_aborted":
			t.State = "interrupted"
			t.SeenAt = at
		}
		total, last := p.Thread, p.Usage
		if p.Info != nil {
			total, last = p.Info.Total, p.Info.Last
			if p.Info.Context > 0 {
				t.ContextWindow = p.Info.Context
			}
		}
		if total != nil && total.valid() && (total.Input != t.InputTokens || total.Output != t.OutputTokens) {
			t.InputTokens = total.Input
			t.OutputTokens = total.Output
			t.CacheRead = total.Cached
			t.UsageAt = at
			t.SeenAt = at
			t.State = "recent_activity"
		}
		if last != nil && last.valid() && t.ContextWindow > 0 {
			v := 100 * float64(last.Input+last.Output) / float64(t.ContextWindow)
			if v > 100 {
				v = 100
			}
			t.ContextUsedPct = &v
		}
	}
}

// CodexSessions is called on the scan goroutine and returns value snapshots.
func (s *Scanner) CodexSessions() []CodexTelemetry {
	states := s.pending
	if states == nil {
		states = s.cursor.Files
	}
	byID := map[string]CodexTelemetry{}
	for _, f := range states {
		if f.Codex == nil || f.Codex.Telemetry == nil {
			continue
		}
		t := *f.Codex.Telemetry
		if prev, ok := byID[t.SessionID]; !ok || t.SeenAt.After(prev.SeenAt) {
			byID[t.SessionID] = t
		}
	}
	out := make([]CodexTelemetry, 0, len(byID))
	for _, t := range byID {
		out = append(out, t)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].SessionID < out[j].SessionID })
	return out
}

func (s *Scanner) FileCount() int {
	if s.pending != nil {
		return len(s.pending)
	}
	return len(s.cursor.Files)
}
