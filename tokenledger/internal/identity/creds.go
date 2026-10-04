package identity

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"time"
)

// ErrNoCredentials means no readable OAuth token was found. It is a normal,
// recoverable state: the agent keeps shipping token usage and simply reports
// that the true limits could not be read.
var ErrNoCredentials = errors.New("no readable Claude Code credentials")

// ErrTokenExpired means a token was found but has passed its expiry.
//
// ccquota deliberately does NOT refresh it. A refresh races Claude Code's own
// refresh and can invalidate the user's live session — a monitoring tool must
// never be able to log someone out of the thing it is monitoring. The token
// becomes usable again on its own the next time Claude Code runs.
var ErrTokenExpired = errors.New("Claude Code OAuth token expired; ccquota does not refresh tokens")

// Credentials is the read-only view ccquota needs.
type Credentials struct {
	AccessToken      string
	ExpiresAt        time.Time
	SubscriptionType string // "max", "pro", ...
	RateLimitTier    string // "default_claude_max_20x", ...
}

// credsFile is the on-disk shape of ~/.claude/.credentials.json and of the
// macOS keychain item's payload — they carry the same JSON.
type credsFile struct {
	ClaudeAiOauth *struct {
		AccessToken      string `json:"accessToken"`
		ExpiresAt        int64  `json:"expiresAt"` // unix milliseconds
		SubscriptionType string `json:"subscriptionType"`
		RateLimitTier    string `json:"rateLimitTier"`
	} `json:"claudeAiOauth"`
}

// keychainService is the macOS generic-password service Claude Code stores
// under.
const keychainService = "Claude Code-credentials"

// LoadCredentials finds the local OAuth token, read-only.
//
// Sources:
//  1. $CCQUOTA_OAUTH_TOKEN — an escape hatch for environments where neither
//     of the below is reachable (containers, locked-down CI). Wins outright.
//  2. <home>/.claude/.credentials.json — the only source on Linux and Windows.
//  3. the macOS keychain, via /usr/bin/security.
//
// On macOS BOTH may exist, and the file is often a stale leftover: Claude Code
// writes refreshed tokens to the keychain, so a machine that once used the file
// keeps an expired copy of it forever. Preferring the file — as this used to —
// makes the limits lookup fail permanently on such a machine, and report
// "token expired" while a perfectly valid token sits in the keychain.
// Measured on a real Mac: file expired 17:07, keychain valid until 07:54 the
// next day.
//
// So every source is read and the FRESHEST wins. That is correct on Linux and
// Windows too, where there is only one.
//
// A returned ErrNoCredentials or ErrTokenExpired is expected operational
// state, not a failure to report loudly.
func LoadCredentials(home string) (*Credentials, error) {
	if tok := os.Getenv("CCQUOTA_OAUTH_TOKEN"); tok != "" {
		// No expiry is knowable for an injected token; trust the operator and
		// let the API reject it if it is stale.
		return &Credentials{AccessToken: tok}, nil
	}

	var found []*Credentials
	var firstErr error

	if c, err := fromFile(filepath.Join(home, ".claude", ".credentials.json")); err == nil {
		found = append(found, c)
	} else if !errors.Is(err, os.ErrNotExist) && firstErr == nil {
		firstErr = err
	}

	if runtime.GOOS == "darwin" {
		// A locked or unreachable keychain is ordinary on a headless SSH
		// session; fall back to whatever the file had.
		if c, err := readKeychain(); err == nil {
			found = append(found, c)
		} else if firstErr == nil {
			firstErr = err
		}
	}

	best := freshest(found)
	if best == nil {
		if firstErr != nil {
			return nil, firstErr
		}
		return nil, ErrNoCredentials
	}
	return best, checkExpiry(best)
}

// freshest picks the credential with the latest expiry.
//
// A zero ExpiresAt means "unknown", which must never beat a known-good expiry;
// it is only chosen when nothing else is available.
func freshest(cs []*Credentials) *Credentials {
	var best *Credentials
	for _, c := range cs {
		if c == nil || c.AccessToken == "" {
			continue
		}
		switch {
		case best == nil:
			best = c
		case best.ExpiresAt.IsZero() && !c.ExpiresAt.IsZero():
			best = c
		case c.ExpiresAt.After(best.ExpiresAt):
			best = c
		}
	}
	return best
}

func checkExpiry(c *Credentials) error {
	if !c.ExpiresAt.IsZero() && time.Now().After(c.ExpiresAt) {
		return ErrTokenExpired
	}
	return nil
}

func fromFile(path string) (*Credentials, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	return parseCreds(b, path)
}

// readKeychain is a package variable so tests can isolate themselves from the
// developer's own login keychain, which otherwise leaks a real token into
// every credential test on a Mac.
var readKeychain = fromKeychain

// fromKeychain shells out to /usr/bin/security. The Go standard library has no
// keychain binding, and cgo is off by design so the binary stays trivially
// cross-compilable.
//
// This can fail on a machine where the keychain is locked or the item's ACL
// does not cover the security tool. That is not fatal: the caller degrades to
// reporting token usage without true limits.
func fromKeychain() (*Credentials, error) {
	cmd := exec.Command("/usr/bin/security", "find-generic-password", "-s", keychainService, "-w")
	out, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("%w: keychain read failed: %v", ErrNoCredentials, err)
	}
	return parseCreds(out, "macOS keychain")
}

func parseCreds(b []byte, source string) (*Credentials, error) {
	var f credsFile
	if err := json.Unmarshal(b, &f); err != nil {
		return nil, fmt.Errorf("parse credentials from %s: %w", source, err)
	}
	if f.ClaudeAiOauth == nil || f.ClaudeAiOauth.AccessToken == "" {
		return nil, fmt.Errorf("%w: %s has no claudeAiOauth.accessToken", ErrNoCredentials, source)
	}
	c := &Credentials{
		AccessToken:      f.ClaudeAiOauth.AccessToken,
		SubscriptionType: f.ClaudeAiOauth.SubscriptionType,
		RateLimitTier:    f.ClaudeAiOauth.RateLimitTier,
	}
	if ms := f.ClaudeAiOauth.ExpiresAt; ms > 0 {
		c.ExpiresAt = time.UnixMilli(ms)
	}
	return c, nil
}
