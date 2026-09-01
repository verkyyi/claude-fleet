// Package scan turns Claude Code transcript files into usage events.
//
// Transcripts live at ~/.claude/projects/<slugified-cwd>/<session-uuid>.jsonl,
// one JSON object per line, appended as a session progresses. Only assistant
// entries carrying a `message.usage` block represent billable spend.
package scan

import (
	"bytes"
	"encoding/json"
	"fmt"
	"time"

	"github.com/verkyyi/ccquota/internal/model"
)

// rawEntry mirrors the transcript schema as observed on Claude Code 2.1.252.
// Unlisted fields are ignored by encoding/json, which is what keeps this
// parser tolerant of Anthropic adding things.
type rawEntry struct {
	Type        string `json:"type"`
	UUID        string `json:"uuid"`
	RequestID   string `json:"requestId"`
	SessionID   string `json:"sessionId"`
	Timestamp   string `json:"timestamp"`
	CWD         string `json:"cwd"`
	GitBranch   string `json:"gitBranch"`
	Entrypoint  string `json:"entrypoint"`
	Effort      string `json:"effort"`
	IsSidechain bool   `json:"isSidechain"`

	Message *struct {
		Model string    `json:"model"`
		Usage *rawUsage `json:"usage"`
	} `json:"message"`
}

type rawUsage struct {
	InputTokens  int64 `json:"input_tokens"`
	OutputTokens int64 `json:"output_tokens"`

	// The flat counter. Present on every version; on newer ones it equals the
	// sum of the CacheCreation split below.
	CacheCreationInputTokens int64 `json:"cache_creation_input_tokens"`
	CacheReadInputTokens     int64 `json:"cache_read_input_tokens"`

	CacheCreation *struct {
		Ephemeral5m int64 `json:"ephemeral_5m_input_tokens"`
		Ephemeral1h int64 `json:"ephemeral_1h_input_tokens"`
	} `json:"cache_creation"`

	OutputTokensDetails *struct {
		ThinkingTokens int64 `json:"thinking_tokens"`
	} `json:"output_tokens_details"`

	ServerToolUse *struct {
		WebSearchRequests int64 `json:"web_search_requests"`
		WebFetchRequests  int64 `json:"web_fetch_requests"`
	} `json:"server_tool_use"`

	// Iterations is DELIBERATELY not parsed.
	//
	// It is a per-iteration breakdown of the very same spend the top-level
	// counters already report. Adding it produces roughly double the real
	// figure, and because both numbers look plausible the error is invisible
	// until someone reconciles against a bill. Leaving the field unbound makes
	// it impossible to sum by accident. See TestParseLine_DoesNotSumIterations.
}

// ParseLine converts one transcript line into a UsageEvent.
//
// ok is false for lines that carry no billable spend: user turns, summaries,
// assistant entries without a usage block, all-zero usage blocks, and blank
// lines. Those are ordinary and not errors. A non-nil error means the line was
// not valid JSON, which is worth surfacing because it usually means a partial
// write was read mid-append.
func ParseLine(line []byte) (*model.UsageEvent, bool, error) {
	line = bytes.TrimSpace(line)
	if len(line) == 0 {
		return nil, false, nil
	}

	var e rawEntry
	if err := json.Unmarshal(line, &e); err != nil {
		return nil, false, fmt.Errorf("parse transcript line: %w", err)
	}
	if e.Message == nil || e.Message.Usage == nil {
		return nil, false, nil
	}
	u := e.Message.Usage

	ev := &model.UsageEvent{
		SessionID:   e.SessionID,
		MessageUUID: e.UUID,
		RequestID:   e.RequestID,
		Model:       e.Message.Model,

		InputTokens:  u.InputTokens,
		OutputTokens: u.OutputTokens,
		CacheRead:    u.CacheReadInputTokens,

		CWD:         e.CWD,
		GitBranch:   e.GitBranch,
		Entrypoint:  e.Entrypoint,
		Effort:      e.Effort,
		IsSidechain: e.IsSidechain,
	}

	// Cache creation is billed at different rates per TTL, so prefer the split
	// when the transcript provides it. Older transcripts only have the flat
	// total; attribute those to the 5m bucket, which is the cheaper rate — an
	// unknown TTL should never inflate the notional cost.
	if u.CacheCreation != nil && (u.CacheCreation.Ephemeral5m > 0 || u.CacheCreation.Ephemeral1h > 0) {
		ev.CacheCreate5m = u.CacheCreation.Ephemeral5m
		ev.CacheCreate1h = u.CacheCreation.Ephemeral1h
	} else {
		ev.CacheCreate5m = u.CacheCreationInputTokens
	}

	if u.OutputTokensDetails != nil {
		ev.Thinking = u.OutputTokensDetails.ThinkingTokens
	}
	if u.ServerToolUse != nil {
		ev.WebSearchRequests = u.ServerToolUse.WebSearchRequests
		ev.WebFetchRequests = u.ServerToolUse.WebFetchRequests
	}

	if ev.TotalTokens() == 0 {
		return nil, false, nil
	}

	if e.Timestamp != "" {
		ts, err := time.Parse(time.RFC3339Nano, e.Timestamp)
		if err != nil {
			return nil, false, fmt.Errorf("parse timestamp %q: %w", e.Timestamp, err)
		}
		ev.TS = ts.UTC()
	}

	return ev, true, nil
}
