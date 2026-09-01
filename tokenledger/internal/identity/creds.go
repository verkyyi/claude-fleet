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
// Sources, in order:
//  1. $CCQUOTA_OAUTH_TOKEN — an escape hatch for environments where neither
//     of the below is reachable (containers, locked-down CI).
//  2. <home>/.claude/.credentials.json — Linux and Windows.
//  3. the macOS keychain, via /usr/bin/security.
//
// A returned ErrNoCredentials or ErrTokenExpired is expected operational
// state, not a failure to report loudly.
func LoadCredentials(home string) (*Credentials, error) {
	if tok := os.Getenv("CCQUOTA_OAUTH_TOKEN"); tok != "" {
		// No expiry is knowable for an injected token; trust the operator and
		// let the API reject it if it is stale.
		return &Credentials{AccessToken: tok}, nil
	}

	if c, err := fromFile(filepath.Join(home, ".claude", ".credentials.json")); err == nil {
		return c, checkExpiry(c)
	} else if !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}

	if runtime.GOOS == "darwin" {
		c, err := fromKeychain()
		if err != nil {
			return nil, err
		}
		return c, checkExpiry(c)
	}

	return nil, ErrNoCredentials
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
