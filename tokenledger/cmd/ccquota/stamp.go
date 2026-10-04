package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/verkyyi/ccquota/internal/sessions"
)

// statusLinePayload is the subset of Claude Code's statusLine JSON that
// identifies a session and its subscription.
//
// Field names verified against a live payload on Claude Code 2.1.252.
type statusLinePayload struct {
	SessionID      string `json:"session_id"`
	TranscriptPath string `json:"transcript_path"`
	CWD            string `json:"cwd"`
	Version        string `json:"version"`
	Model          struct {
		ID          string `json:"id"`
		DisplayName string `json:"display_name"`
	} `json:"model"`
	Effort struct {
		Level string `json:"level"`
	} `json:"effort"`
	Workspace struct {
		GitWorktree string `json:"git_worktree"`
	} `json:"workspace"`
	Cost struct {
		TotalCostUSD       float64 `json:"total_cost_usd"`
		TotalDurationMS    int64   `json:"total_duration_ms"`
		TotalAPIDurationMS int64   `json:"total_api_duration_ms"`
		TotalLinesAdded    int64   `json:"total_lines_added"`
		TotalLinesRemoved  int64   `json:"total_lines_removed"`
	} `json:"cost"`
	ContextWindow struct {
		TotalInputTokens  int64   `json:"total_input_tokens"`
		TotalOutputTokens int64   `json:"total_output_tokens"`
		ContextWindowSize int64   `json:"context_window_size"`
		UsedPercentage    float64 `json:"used_percentage"`
	} `json:"context_window"`
	PromptCache struct {
		Warm     bool    `json:"warm"`
		HitRatio float64 `json:"hit_ratio"`
	} `json:"prompt_cache"`
	Thinking struct {
		Enabled bool `json:"enabled"`
	} `json:"thinking"`
	FastMode   bool `json:"fast_mode"`
	RateLimits *struct {
		FiveHour *struct {
			UsedPercentage *float64 `json:"used_percentage"`
			ResetsAt       *int64   `json:"resets_at"` // unix seconds
		} `json:"five_hour"`
		SevenDay *struct {
			UsedPercentage *float64 `json:"used_percentage"`
			ResetsAt       *int64   `json:"resets_at"`
		} `json:"seven_day"`
	} `json:"rate_limits"`
}

// runStamp records which subscription the calling session is signed in to.
//
// It is meant to be installed as Claude Code's statusLine, because that hook is
// the only thing that runs INSIDE a session's own process — which is where the
// per-session CLAUDE_CODE_OAUTH_TOKEN lives. Nothing outside can see it: an
// agent inspecting the machine sees only ~/.claude.json, which records the last
// interactive login and says nothing about what each running session is using.
//
// It writes a stamp and then optionally execs the operator's real statusLine
// with the same payload, so adopting it costs nobody their existing status bar.
func runStamp(args []string) error {
	fs := flag.NewFlagSet("stamp", flag.ExitOnError)
	state := fs.String("state", "", "state directory (default: <home>/.ccquota)")
	label := fs.String("label", "", "human name for this session's subscription (e.g. an email)")
	then := fs.String("then", "", "run this command with the same payload and pass its output through")
	quiet := fs.Bool("quiet", false, "never write to stderr, even on failure")
	if err := fs.Parse(args); err != nil {
		return err
	}

	payload, err := io.ReadAll(io.LimitReader(os.Stdin, 1<<20))
	if err != nil {
		return chain(*then, payload, fmt.Errorf("read statusline payload: %w", err), *quiet)
	}

	// Everything below is best-effort. A monitoring stamp must never be the
	// reason someone's status bar goes blank.
	if err := stampFrom(payload, *state, *label); err != nil && !*quiet {
		fmt.Fprintln(os.Stderr, "ccquota stamp:", err)
	}
	return chain(*then, payload, nil, *quiet)
}

func stampFrom(payload []byte, stateOverride, label string) error {
	var p statusLinePayload
	if err := json.Unmarshal(payload, &p); err != nil {
		return fmt.Errorf("parse statusline payload: %w", err)
	}
	if p.SessionID == "" {
		return fmt.Errorf("payload has no session_id")
	}

	stateDir := stateOverride
	if stateDir == "" {
		h, err := os.UserHomeDir()
		if err != nil {
			return err
		}
		stateDir = filepath.Join(h, ".ccquota")
	}

	s := sessions.Stamp{
		SessionID:      p.SessionID,
		TranscriptPath: p.TranscriptPath,
		StampedAt:      time.Now().UTC(),
		// The token is hashed, never stored: a usage monitor that leaves
		// credentials on disk is a worse problem than the one it solves.
		AccountKey: sessions.AccountKeyFor(os.Getenv("CLAUDE_CODE_OAUTH_TOKEN")),
		Label:      resolveLabel(label),
		CWD:        p.CWD,
		Model:      p.Model.ID,
		CCVersion:  p.Version,
	}

	// Claude Code recomputes this on every turn, so it is a few-seconds-old
	// view of a running session — the freshest signal ccquota has by far.
	s.Live = &sessions.LiveSnapshot{
		CostUSD:         p.Cost.TotalCostUSD,
		InputTokens:     p.ContextWindow.TotalInputTokens,
		OutputTokens:    p.ContextWindow.TotalOutputTokens,
		DurationMS:      p.Cost.TotalDurationMS,
		APIDurationMS:   p.Cost.TotalAPIDurationMS,
		LinesAdded:      p.Cost.TotalLinesAdded,
		LinesRemoved:    p.Cost.TotalLinesRemoved,
		ContextUsedPct:  p.ContextWindow.UsedPercentage,
		ContextWindow:   p.ContextWindow.ContextWindowSize,
		CacheHitRatio:   p.PromptCache.HitRatio,
		CacheWarm:       p.PromptCache.Warm,
		ModelDisplay:    p.Model.DisplayName,
		Effort:          p.Effort.Level,
		Worktree:        p.Workspace.GitWorktree,
		ThinkingEnabled: p.Thinking.Enabled,
		FastMode:        p.FastMode,
	}

	// Claude Code reports rate limits for THIS session's account, which is a
	// free second source of the exact utilization — and the only one available
	// when the machine's credential file is stale.
	// A session with no rate-limit window is not on a plan — it is API-key
	// billed, and its spend must not be counted against a subscription's quota.
	hadLimits := p.RateLimits != nil &&
		(p.RateLimits.FiveHour != nil || p.RateLimits.SevenDay != nil)
	s.Billing = sessions.InferBilling(hadLimits)

	if rl := p.RateLimits; rl != nil {
		if rl.FiveHour != nil {
			s.FiveHourPct = rl.FiveHour.UsedPercentage
			s.FiveHourAt = unixPtr(rl.FiveHour.ResetsAt)
		}
		if rl.SevenDay != nil {
			s.SevenDayPct = rl.SevenDay.UsedPercentage
			s.SevenDayAt = unixPtr(rl.SevenDay.ResetsAt)
		}
	}

	return sessions.Write(stateDir, s)
}

// resolveLabel finds a human name for this session's subscription.
//
// The statusLine command is one fixed string for every session, so a --label
// flag cannot vary per window. These sources can:
//
//   - $CCQUOTA_ACCOUNT_LABEL, for any supervisor that sets it per session
//   - the tmux window option @cc_account, which is where at least one fleet
//     manager already records the account it launched a window with
//
// Without either, the subscription is still identified correctly — by its
// rate-limit schedule — just not by name.
func resolveLabel(explicit string) string {
	if explicit != "" {
		return explicit
	}
	if v := os.Getenv("CCQUOTA_ACCOUNT_LABEL"); v != "" {
		return v
	}
	if pane := os.Getenv("TMUX_PANE"); pane != "" && os.Getenv("TMUX") != "" {
		out, err := exec.Command("tmux", "display-message", "-p", "-t", pane,
			"#{@cc_account}").Output()
		if err == nil {
			if v := strings.TrimSpace(string(out)); v != "" {
				return v
			}
		}
	}
	return ""
}

func unixPtr(sec *int64) *time.Time {
	if sec == nil || *sec <= 0 {
		return nil
	}
	t := time.Unix(*sec, 0).UTC()
	return &t
}

// chain runs the operator's original statusLine, if any, feeding it the same
// payload and forwarding its output verbatim.
func chain(then string, payload []byte, prior error, quiet bool) error {
	if then == "" {
		return prior
	}
	cmd := exec.Command("/bin/sh", "-c", then)
	cmd.Stdin = bytesReader(payload)
	cmd.Stdout = os.Stdout
	if !quiet {
		cmd.Stderr = os.Stderr
	}
	if err := cmd.Run(); err != nil && !quiet {
		fmt.Fprintln(os.Stderr, "ccquota stamp: chained statusline failed:", err)
	}
	return prior
}

func bytesReader(b []byte) io.Reader { return &sliceReader{b: b} }

type sliceReader struct {
	b []byte
	i int
}

func (r *sliceReader) Read(p []byte) (int, error) {
	if r.i >= len(r.b) {
		return 0, io.EOF
	}
	n := copy(p, r.b[r.i:])
	r.i += n
	return n, nil
}
