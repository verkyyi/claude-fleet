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
}

// AccountKeyFor derives the stable, non-secret identifier for a token.
//
// The token itself is never written anywhere: a monitoring tool that leaves
// credentials on disk is a worse problem than the one it solves.
func AccountKeyFor(token string) string {
	if token == "" {
		return ""
	}
	sum := sha256.Sum256([]byte(token))
	return "tok_" + hex.EncodeToString(sum[:])[:16]
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
		if s.AccountKey == "" {
			continue
		}
		if s.Label != "" || out[s.AccountKey] == "" {
			out[s.AccountKey] = s.Label
		}
	}
	return out
}
