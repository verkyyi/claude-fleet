package identity

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
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
//  1. $CCQUOTA_OAUTH_TOKEN — an escape hatch for environments where none of
//     the below is reachable (containers, locked-down CI). Wins outright.
//  2. $CLAUDE_SECURESTORAGE_CONFIG_DIR/.credentials.json — a hub-managed
//     account (claude-fleet#1415): the fleet points a session at the directory
//     the ccquota agent leases a short-lived token into, and Claude Code reads
//     its credential there. Only when the variable is set.
//  3. <home>/.claude/.credentials.json — the only local source on Linux and
//     Windows.
//  4. the macOS keychain, via /usr/bin/security.
//
// On macOS BOTH local sources may exist, and the file is often a stale
// leftover: Claude Code writes refreshed tokens to the keychain, so a machine
// that once used the file keeps an expired copy of it forever. Preferring the
// file — as this used to — makes the limits lookup fail permanently on such a
// machine, and report "token expired" while a perfectly valid token sits in the
// keychain. Measured on a real Mac: file expired 17:07, keychain valid until
// 07:54 the next day.
//
// So every source is read and the FRESHEST wins. That is correct on Linux and
// Windows too, where there is only one.
//
// When NOTHING usable is found, the error names EVERY source tried and why each
// failed (claude-fleet#1404). The old code kept the first failure only, and the
// file is always tried before the keychain — so on a headless macOS login,
// where the keychain is exactly what cannot be reached, four of six machines on
// one hub told their operator "<file> has no claudeAiOauth.accessToken": a true
// fact, not the reason, and a pointer to a place where fixing changes nothing.
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
	var failed []string // "<source>: <why>", in the order tried
	try := func(source string, c *Credentials, err error) {
		if err == nil {
			found = append(found, c)
			return
		}
		failed = append(failed, source+": "+err.Error())
	}

	if dir := os.Getenv("CLAUDE_SECURESTORAGE_CONFIG_DIR"); dir != "" {
		p := filepath.Join(dir, ".credentials.json")
		c, err := fromFile(p)
		if err != nil {
			err = fmt.Errorf("%w (leased by the ccquota agent — is it running, and does the hub hold a Claude account for this login?)", err)
		}
		try("hub-managed credentials "+p, c, err)
	}

	p := filepath.Join(home, ".claude", ".credentials.json")
	c, err := fromFile(p)
	try("credentials file "+p, c, err)

	if runtime.GOOS == "darwin" {
		// A locked or unreachable keychain is ordinary on a headless SSH
		// session; fall back to whatever the file had — and when the file has
		// nothing either, SAY that the keychain failed, and how.
		c, err := readKeychain()
		try("macOS keychain", c, err)
	}

	best := freshest(found)
	if best == nil {
		if len(failed) == 0 {
			return nil, ErrNoCredentials
		}
		return nil, fmt.Errorf("%w: %s", ErrNoCredentials, strings.Join(failed, "; "))
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
		// The caller names the path; keep the reason to the reason.
		if errors.Is(err, os.ErrNotExist) {
			return nil, errors.New("no such file")
		}
		var pe *os.PathError
		if errors.As(err, &pe) {
			return nil, pe.Err
		}
		return nil, err
	}
	return parseCreds(b)
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
// reporting token usage without true limits — and names this failure beside
// the file's, so the operator learns which one to fix.
func fromKeychain() (*Credentials, error) {
	cmd := exec.Command("/usr/bin/security", "find-generic-password", "-s", keychainService, "-w")
	out, err := cmd.Output()
	if err != nil {
		return nil, errors.New(keychainFailure(err))
	}
	return parseCreds(out)
}

// keychainFailure turns /usr/bin/security's failure into words an operator can
// act on.
//
// The tool exits with the low byte of the Security framework's OSStatus, and
// on a headless session it prints NOTHING on stderr for the one that matters
// (measured on a fleet login: exit 36, empty stderr). So the two codes that
// account for nearly every failure are spelled out, and whatever stderr there
// is comes along:
//
//	36 = errSecInteractionNotAllowed (-25308 & 0xff) — the login keychain is
//	     locked, or there is no interactive session to unlock it; the token
//	     may well be IN there.
//	44 = errSecItemNotFound          (-25300 & 0xff) — reachable, but Claude
//	     Code never stored a credential for this user.
func keychainFailure(err error) string {
	var ee *exec.ExitError
	if !errors.As(err, &ee) {
		return "security could not run: " + err.Error()
	}
	var msg string
	switch ee.ExitCode() {
	case 36:
		msg = "the login keychain is locked or unreachable from a non-interactive session (security exit 36 = errSecInteractionNotAllowed); unlock it, or log in with `claude` from an interactive session on this user"
	case 44:
		msg = "no \"" + keychainService + "\" item in the login keychain (security exit 44 = errSecItemNotFound); log in with `claude` on this user"
	default:
		msg = fmt.Sprintf("security exit %d", ee.ExitCode())
	}
	if s := strings.TrimSpace(string(ee.Stderr)); s != "" {
		if i := strings.IndexByte(s, '\n'); i >= 0 {
			s = s[:i]
		}
		msg += ": " + s
	}
	return msg
}

// parseCreds reads the shared JSON shape. Its errors carry the reason only;
// LoadCredentials prefixes the source, so one message can list several.
func parseCreds(b []byte) (*Credentials, error) {
	var f credsFile
	if err := json.Unmarshal(b, &f); err != nil {
		return nil, fmt.Errorf("not the credentials JSON: %w", err)
	}
	if f.ClaudeAiOauth == nil || f.ClaudeAiOauth.AccessToken == "" {
		return nil, errors.New("has no claudeAiOauth.accessToken")
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
