// Package sessions maps a Claude Code session to the subscription it actually
// ran on.
//
// The problem it solves: an account is NOT a property of a machine. Claude Code
// reads CLAUDE_CODE_OAUTH_TOKEN from the environment, which is per process, so
// several sessions on one machine can be signed in to different subscriptions
// at the same instant. Measured on a real laptop running a fleet supervisor:
// three accounts live at once, two of them invisible to a hub that assumed one
// account per machine.
//
// Transcripts record nothing about the account, so the mapping has to come from
// inside each session. Claude Code's statusLine hook runs in that session's own
// process, and its payload carries `session_id` and `transcript_path`. That is
// enough: `ccquota stamp`, installed as (or chained into) the statusLine,
// writes one small file per session, and the agent reads them at scan time.
//
// Without the hook the agent falls back to the machine-wide login and SAYS SO.
// A wrong number presented confidently is the thing this package exists to
// prevent.
package sessions

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// Stamp is what one session reports about itself.
type Stamp struct {
	SessionID      string    `json:"session_id"`
	TranscriptPath string    `json:"transcript_path"`
	StampedAt      time.Time `json:"stamped_at"`

	// AccountKey identifies the subscription WITHOUT storing the token.
	//
	// It is a hash of the session's OAuth token, so two sessions on the same
	// subscription agree and two on different ones do not. Empty means the
	// session had no per-session token and therefore used the machine-wide
	// login.
	AccountKey string `json:"account_key,omitempty"`

	// Label is a human name for the subscription when something knows it — a
	// supervisor that manages the accounts, or an operator passing --label.
	// The hash alone is correct but unreadable.
	Label string `json:"label,omitempty"`

	// FiveHourPct and SevenDayPct come from the statusLine payload's
	// rate_limits, which Claude Code reports for THAT SESSION's account. It is
	// a second, free source of the exact utilization — valuable on a machine
	// whose credential file is stale or whose keychain is unreadable.
	FiveHourPct *float64   `json:"five_hour_pct,omitempty"`
	SevenDayPct *float64   `json:"seven_day_pct,omitempty"`
	FiveHourAt  *time.Time `json:"five_hour_resets_at,omitempty"`
	SevenDayAt  *time.Time `json:"seven_day_resets_at,omitempty"`
	CWD         string     `json:"cwd,omitempty"`
	Model       string     `json:"model,omitempty"`
	CCVersion   string     `json:"cc_version,omitempty"`

	// Billing distinguishes a subscription session from an API-key one.
	//
	// Claude Code reports rate_limits ONLY for plan-based auth: an API-key
	// session has no 5-hour or 7-day window to report, it is billed per token.
	// Both kinds appear in the same transcripts and cost the same to run, but
	// only one of them consumes a subscription — counting API spend against a
	// plan's quota would misattribute it entirely.
	Billing string `json:"billing,omitempty"` // "subscription" | "api" | ""

	// Live is what this session looks like RIGHT NOW.
	//
	// Claude Code recomputes the statusLine on every turn, so these are a
	// few-seconds-old view of a running session — far fresher than the
	// transcript scan, which is a minute behind by design. It is also Claude
	// Code's own arithmetic rather than ours.
	Live *LiveSnapshot `json:"live,omitempty"`
}

// LiveSnapshot is one session's current state, straight from the statusLine
// payload.
//
// These are per-session running totals, NOT deltas: two consecutive stamps
// give a rate. They are also NOT the same quantity as the transcript scan's
// events — this is Claude Code's own accounting of the session it is in, which
// is why the dashboard shows it as a live indicator and never adds it to the
// stored totals.
type LiveSnapshot struct {
	CostUSD       float64 `json:"cost_usd"`
	InputTokens   int64   `json:"input_tokens"`
	OutputTokens  int64   `json:"output_tokens"`
	DurationMS    int64   `json:"duration_ms"`
	APIDurationMS int64   `json:"api_duration_ms"`
	LinesAdded    int64   `json:"lines_added"`
	LinesRemoved  int64   `json:"lines_removed"`

	ContextUsedPct  float64 `json:"context_used_pct"`
	ContextWindow   int64   `json:"context_window"`
	CacheHitRatio   float64 `json:"cache_hit_ratio"`
	CacheWarm       bool    `json:"cache_warm"`
	ModelDisplay    string  `json:"model_display,omitempty"`
	Effort          string  `json:"effort,omitempty"`
	Worktree        string  `json:"worktree,omitempty"`
	ThinkingEnabled bool    `json:"thinking_enabled"`
	FastMode        bool    `json:"fast_mode"`
}

// AccountKeyFor derives a stable, non-secret identifier from a token.
//
// The token itself is never written anywhere: a monitoring tool that leaves
// credentials on disk is a worse problem than the one it solves.
//
// In practice this is usually empty. Claude Code does NOT pass
// CLAUDE_CODE_OAUTH_TOKEN down to hook processes — verified across 17 live
// sessions on a machine that definitely had per-session tokens — so the
// fingerprint below is what actually identifies an account. This remains as the
// stronger signal for any context where the token IS visible.
func AccountKeyFor(token string) string {
	if token == "" {
		return ""
	}
	sum := sha256.Sum256([]byte(token))
	return "tok_" + hex.EncodeToString(sum[:])[:16]
}

// sevenDayWindow is the only rate-limit window whose reset phase identifies an
// account.
const sevenDayWindow = 7 * 24 * time.Hour

// FingerprintFor identifies a subscription from its SEVEN-DAY reset schedule.
//
// The token is unreachable from a hook, but the statusLine payload reports the
// session's own rate_limits — and every session on one subscription shares that
// subscription's reset schedule, while different subscriptions almost never do.
//
// The PHASE is used, not the timestamp: a reset advances a whole window at a
// time, so the raw value would change identity every rollover. The offset
// within the window is the property of the account.
//
// The five-hour window is deliberately NOT used, and that is the correction
// this function exists in its current form for. It is a ROLLING window: its
// reset moves as old usage ages out, by whatever amount happens to age out.
// Measured on one subscription, its reset went 18:40 -> 22:49:59 — four hours
// ten minutes, not five — while its seven-day reset never moved. Feeding a
// sliding value into the phase does not merely add noise: it guarantees a NEW
// identity every time it slides. One subscription had split into three within a
// day, and both halves of that split were then treated as separate accounts.
//
// A missing seven-day reset returns "" rather than a fingerprint built from a
// sentinel. The old code mapped "absent" to phase -1, which is a perfectly good
// distinct value, so a session whose statusLine happened to omit the window
// became its own subscription. Refusing to answer is right here — the caller
// falls back to the machine's own login, which is at worst the wrong known
// account rather than an invented one.
//
// This is a heuristic and is labelled as one wherever it surfaces. Dropping the
// five-hour component costs collision resistance — two subscriptions now
// collide if their weekly resets land in the same minute, about 1 in 10,080 per
// pair, against the old pair-of-phases space. That trade is worth taking: the
// old space was larger but its coordinate moved, so it did not identify
// anything. A heuristic that is stable and occasionally collides beats one that
// is precise and never holds still.
func FingerprintFor(sevenDayResets *time.Time) string {
	if sevenDayResets == nil {
		return ""
	}
	// Quantise to the nearest minute before taking the phase.
	//
	// The same reset arrives with different precision depending on the source:
	// /api/oauth/usage reports 13:59:59.916, the statusLine reports 14:00:00.
	// That is 0.084s apart but straddles a minute boundary, so the raw phases
	// differed and one subscription looked like two. Resets land on clean
	// minute boundaries, so rounding is lossless for real data and absorbs the
	// discrepancy.
	const quantum = int64(60)
	secs := sevenDayResets.Unix()
	rounded := (secs + quantum/2) / quantum * quantum

	p := rounded % int64(sevenDayWindow/time.Second)
	if p < 0 {
		p += int64(sevenDayWindow / time.Second)
	}
	sum := sha256.Sum256([]byte(fmt.Sprintf("7d|%d", p)))
	return fingerprintPrefix + hex.EncodeToString(sum[:])[:16]
}

// fingerprintPrefix marks an account identifier that was GUESSED from a reset
// schedule rather than reported. Callers must say so wherever it surfaces.
const fingerprintPrefix = "win_"

// IsFingerprint reports whether an account identifier is inferred.
func IsFingerprint(accountKey string) bool {
	return strings.HasPrefix(accountKey, fingerprintPrefix)
}

// Billing values.
const (
	BillingSubscription = "subscription"
	BillingAPI          = "api"
)

// InferBilling decides how a session is paid for.
//
// The presence of a rate-limit window is the tell: plans have windows, API keys
// have invoices. It is an inference from an absence, so it is only made when
// the payload was otherwise complete — a truncated payload must not be read as
// "this is an API session".
func InferBilling(payloadHadRateLimits bool) string {
	if payloadHadRateLimits {
		return BillingSubscription
	}
	return BillingAPI
}

// Account returns the best available identifier for this session's
// subscription, preferring the token-derived key when one exists.
func (s Stamp) Account() string {
	if s.AccountKey != "" {
		return s.AccountKey
	}
	return FingerprintFor(s.SevenDayAt)
}

// AccountIsInferred reports whether the identifier came from the reset-phase
// heuristic rather than from the token. Callers must say so.
func (s Stamp) AccountIsInferred() bool {
	return s.AccountKey == "" && s.Account() != ""
}

// Dir is where stamps live.
func Dir(stateDir string) string { return filepath.Join(stateDir, "sessions") }

// Write records one session's stamp.
//
// One file per session, named by session id: concurrent sessions stamp
// constantly and must never contend over a shared file.
func Write(stateDir string, s Stamp) error {
	if s.SessionID == "" {
		return fmt.Errorf("stamp has no session id")
	}
	dir := Dir(stateDir)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return fmt.Errorf("create session dir: %w", err)
	}
	b, err := json.Marshal(s)
	if err != nil {
		return err
	}
	path := filepath.Join(dir, safeName(s.SessionID)+".json")
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return fmt.Errorf("write stamp: %w", err)
	}
	if err := os.Rename(tmp, path); err != nil {
		os.Remove(tmp)
		return fmt.Errorf("commit stamp: %w", err)
	}
	return nil
}

// safeName keeps a session id from escaping the directory. Session ids are
// uuids in practice, but this reads untrusted input from a hook payload.
func safeName(id string) string {
	var b strings.Builder
	for _, r := range id {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9', r == '-', r == '_':
			b.WriteRune(r)
		default:
			b.WriteRune('_')
		}
	}
	name := b.String()
	if len(name) > 128 {
		name = name[:128]
	}
	if name == "" {
		name = "unnamed"
	}
	return name
}

// Index is the session-to-subscription map the agent consults.
type Index struct {
	// BySession maps a session id to its stamp.
	BySession map[string]Stamp

	// ByTranscript maps a transcript file path to its stamp, which is how the
	// scanner attributes events without needing the session id parsed out.
	ByTranscript map[string]Stamp
}

// Load reads every stamp under stateDir.
//
// Missing or unreadable stamps are not an error: the hook is optional, and the
// caller degrades to the machine-wide login.
func Load(stateDir string, maxAge time.Duration) (*Index, error) {
	idx := &Index{BySession: map[string]Stamp{}, ByTranscript: map[string]Stamp{}}
	dir := Dir(stateDir)

	entries, err := os.ReadDir(dir)
	if err != nil {
		if os.IsNotExist(err) {
			return idx, nil
		}
		return idx, fmt.Errorf("read session stamps: %w", err)
	}

	cutoff := time.Time{}
	if maxAge > 0 {
		cutoff = time.Now().Add(-maxAge)
	}

	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".json") {
			continue
		}
		b, err := os.ReadFile(filepath.Join(dir, e.Name()))
		if err != nil {
			continue
		}
		var s Stamp
		if err := json.Unmarshal(b, &s); err != nil {
			continue
		}
		// A stamp older than the window describes a session whose account may
		// since have changed; trusting it would reintroduce the very staleness
		// this package exists to remove.
		if !cutoff.IsZero() && s.StampedAt.Before(cutoff) {
			continue
		}
		if s.SessionID != "" {
			idx.BySession[s.SessionID] = s
		}
		if s.TranscriptPath != "" {
			idx.ByTranscript[s.TranscriptPath] = s
		}
	}
	return idx, nil
}

// Prune deletes stamps older than maxAge, so a long-lived agent does not
// accumulate a file per session forever.
func Prune(stateDir string, maxAge time.Duration) (int, error) {
	if maxAge <= 0 {
		return 0, nil
	}
	dir := Dir(stateDir)
	entries, err := os.ReadDir(dir)
	if err != nil {
		if os.IsNotExist(err) {
			return 0, nil
		}
		return 0, err
	}
	cutoff := time.Now().Add(-maxAge)
	removed := 0
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".json") {
			continue
		}
		info, err := e.Info()
		if err != nil || info.ModTime().After(cutoff) {
			continue
		}
		if os.Remove(filepath.Join(dir, e.Name())) == nil {
			removed++
		}
	}
	return removed, nil
}

// Accounts lists the distinct subscriptions seen across the stamps, with the
// best label known for each.
func (i *Index) Accounts() map[string]string {
	out := map[string]string{}
	for _, s := range i.BySession {
		k := s.Account()
		if k == "" {
			continue
		}
		if s.Label != "" || out[k] == "" {
			out[k] = s.Label
		}
	}
	return out
}
