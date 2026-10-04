package scan

import (
	"bytes"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"time"

	"github.com/verkyyi/ccquota/internal/model"
)

// Codex writes metadata separately from usage. Persist both context and the
// cumulative baseline with the byte offset so appends and restarts agree.
type codexState struct {
	Version       int             `json:"version,omitempty"`
	Telemetry     *CodexTelemetry `json:"telemetry,omitempty"`
	SessionID     string          `json:"session_id,omitempty"`
	CWD           string          `json:"cwd,omitempty"`
	Branch        string          `json:"branch,omitempty"`
	Model         string          `json:"model,omitempty"`
	Effort        string          `json:"effort,omitempty"`
	Entrypoint    string          `json:"entrypoint,omitempty"`
	TurnID        string          `json:"turn_id,omitempty"`
	Sidechain     bool            `json:"sidechain,omitempty"`
	Previous      *codexUsage     `json:"previous,omitempty"`
	Records       bool            `json:"records,omitempty"`
	Provider      string          `json:"provider,omitempty"`
	ClientVersion string          `json:"client_version,omitempty"`
	ServiceTier   string          `json:"service_tier,omitempty"`
	ParentSession string          `json:"parent_session,omitempty"`
}

type codexUsage struct {
	Input     int64 `json:"input_tokens"`
	Cached    int64 `json:"cached_input_tokens"`
	Output    int64 `json:"output_tokens"`
	Reasoning int64 `json:"reasoning_output_tokens"`
	Total     int64 `json:"total_tokens"`
}

func (u codexUsage) valid() bool {
	return u.Input >= 0 && u.Cached >= 0 && u.Cached <= u.Input &&
		u.Output >= 0 && u.Reasoning >= 0 && u.Reasoning <= u.Output && u.Total >= 0
}

func (s *codexState) parseLine(line []byte) (*model.UsageEvent, bool, error) {
	if len(bytes.TrimSpace(line)) == 0 {
		return nil, false, nil
	}
	var entry struct {
		Type      string          `json:"type"`
		Timestamp string          `json:"timestamp"`
		Payload   json.RawMessage `json:"payload"`
	}
	if err := json.Unmarshal(line, &entry); err != nil {
		return nil, false, fmt.Errorf("parse Codex line: %w", err)
	}
	s.observe(entry.Type, entry.Timestamp, entry.Payload)
	switch entry.Type {
	case "session_meta":
		var meta struct {
			Provider string          `json:"model_provider"`
			Version  string          `json:"cli_version"`
			ID       string          `json:"id"`
			CWD      string          `json:"cwd"`
			Source   json.RawMessage `json:"source"`
			Git      struct {
				Branch string `json:"branch"`
			} `json:"git"`
		}
		if err := json.Unmarshal(entry.Payload, &meta); err != nil {
			return nil, false, err
		}
		s.SessionID, s.CWD, s.Branch = meta.ID, meta.CWD, meta.Git.Branch
		s.Provider, s.ClientVersion = meta.Provider, meta.Version
		var origin struct {
			Subagent struct {
				ThreadSpawn struct {
					Parent string `json:"parent_thread_id"`
				} `json:"thread_spawn"`
			} `json:"subagent"`
		}
		if json.Unmarshal(meta.Source, &origin) == nil {
			s.ParentSession = origin.Subagent.ThreadSpawn.Parent
		}
		if json.Unmarshal(meta.Source, &s.Entrypoint) != nil && bytes.Contains(meta.Source, []byte(`"subagent"`)) {
			s.Sidechain, s.Entrypoint = true, "subagent"
		}
		return nil, false, nil
	case "turn_context":
		var ctx struct {
			ServiceTier string `json:"service_tier"`
			CWD         string `json:"cwd"`
			Model       string `json:"model"`
			Effort      string `json:"effort"`
			TurnID      string `json:"turn_id"`
		}
		if err := json.Unmarshal(entry.Payload, &ctx); err != nil {
			return nil, false, err
		}
		s.Model, s.Effort, s.TurnID = ctx.Model, ctx.Effort, ctx.TurnID
		s.ServiceTier = ctx.ServiceTier
		if ctx.CWD != "" {
			s.CWD = ctx.CWD
		}
		return nil, false, nil
	case "token_usage_record", "event_msg":
	default:
		return nil, false, nil
	}

	var payload struct {
		Type        string      `json:"type"`
		ResponseID  string      `json:"response_id"`
		ThreadID    string      `json:"thread_id"`
		TurnID      string      `json:"turn_id"`
		Usage       *codexUsage `json:"usage"`
		ThreadUsage *codexUsage `json:"thread_token_usage"`
		Info        *struct {
			Total *codexUsage `json:"total_token_usage"`
			Last  *codexUsage `json:"last_token_usage"`
		} `json:"info"`
	}
	if err := json.Unmarshal(entry.Payload, &payload); err != nil {
		return nil, false, err
	}
	var usage codexUsage
	var next *codexUsage
	if entry.Type == "token_usage_record" {
		if payload.Usage == nil {
			return nil, false, nil
		}
		usage, next = *payload.Usage, payload.ThreadUsage
	} else {
		// New rollouts contain both records and token_count notifications. The
		// latter are echoes, including quota-only updates with unchanged usage.
		if s.Records || payload.Type != "token_count" || payload.Info == nil {
			return nil, false, nil
		}
		next = payload.Info.Total
		if next == nil {
			// Without a cumulative counter or a request id, a repeated last
			// reading is indistinguishable from a new request. Do not guess.
			return nil, false, nil
		}
		if !next.valid() {
			return nil, false, fmt.Errorf("invalid Codex cumulative usage")
		}
		if s.Previous != nil && *s.Previous == *next {
			return nil, false, nil
		}
		usage = *next
		if prev := s.Previous; prev != nil && next.Input >= prev.Input && next.Output >= prev.Output {
			usage = codexUsage{Input: next.Input - prev.Input, Cached: next.Cached - prev.Cached,
				Output: next.Output - prev.Output, Reasoning: next.Reasoning - prev.Reasoning,
				Total: next.Total - prev.Total}
		} else if payload.Info.Last != nil {
			// Resumed/forked histories can start with inherited totals; a
			// compaction can reset totals. Only the reported last request is new.
			usage = *payload.Info.Last
		} else if s.Previous != nil {
			s.Previous = next
			return nil, false, nil
		}
	}
	if !usage.valid() {
		return nil, false, fmt.Errorf("invalid Codex request usage")
	}
	ts, err := time.Parse(time.RFC3339Nano, entry.Timestamp)
	if err != nil {
		return nil, false, fmt.Errorf("parse Codex timestamp: %w", err)
	}
	if s.SessionID == "" && payload.ThreadID == "" {
		return nil, false, fmt.Errorf("Codex usage has no session id")
	}
	if next != nil {
		s.Previous = next
	}
	if entry.Type == "token_usage_record" {
		s.Records = true
	}
	if usage.Input+usage.Output == 0 {
		return nil, false, nil
	}

	session, turn := s.SessionID, s.TurnID
	if payload.ThreadID != "" {
		session = payload.ThreadID
	}
	if payload.TurnID != "" {
		turn = payload.TurnID
	}
	key := payload.ResponseID
	if key == "" {
		// Timestamp + original turn + counters survive copies and archiving.
		// Never use a filename/offset: those change when a rollout is moved.
		key = fmt.Sprintf("%x", sha256.Sum256([]byte(fmt.Sprintf("%s\x00%s\x00%v\x00%v", entry.Timestamp, turn, usage, next))))
	}
	details := &model.UsageDetails{Provider: s.Provider, ClientVersion: s.ClientVersion, ServiceTier: s.ServiceTier, TurnID: turn, ParentSessionID: s.ParentSession, AccountBasis: "unassigned", BillingMode: "unknown"}
	// Parse additions separately: codexUsage participates in legacy request
	// hashes, so adding fields to that struct would change historical IDs.
	if entry.Type == "token_usage_record" {
		var extra struct {
			Root  string `json:"root_turn_id"`
			Tier  string `json:"service_tier"`
			Usage struct {
				Write *int64 `json:"cache_write_input_tokens"`
			} `json:"usage"`
		}
		if json.Unmarshal(entry.Payload, &extra) == nil {
			details.RootTurnID = extra.Root
			if extra.Tier != "" {
				details.ServiceTier = extra.Tier
			}
			if extra.Usage.Write != nil && *extra.Usage.Write >= 0 && *extra.Usage.Write <= usage.Input-usage.Cached {
				details.CacheWrite = extra.Usage.Write
			}
		}
	}
	return &model.UsageEvent{
		Details: details,
		Source:  model.SourceCodex, SessionID: "codex:" + session, MessageUUID: "codex:" + key,
		RequestID: payload.ResponseID, TS: ts.UTC(), Model: s.Model,
		// Cached input is already included in Codex input; reasoning is
		// already included in output. Cache writes stay in non-read input
		// because rollouts do not specify the Claude-style cache TTL split.
		InputTokens: usage.Input - usage.Cached, CacheRead: usage.Cached,
		OutputTokens: usage.Output, Thinking: usage.Reasoning,
		CWD: s.CWD, GitBranch: s.Branch, Entrypoint: s.Entrypoint, Effort: s.Effort,
		IsSidechain: s.Sidechain,
	}, true, nil
}
