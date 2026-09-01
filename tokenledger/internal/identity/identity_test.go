package identity

import (
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"testing"
	"time"
)

func writeHome(t *testing.T, claudeJSON string) string {
	t.Helper()
	home := t.TempDir()
	if err := os.WriteFile(filepath.Join(home, ".claude.json"), []byte(claudeJSON), 0o600); err != nil {
		t.Fatal(err)
	}
	return home
}

const goodConfig = `{
  "machineID": "9dadb2c4751d265d",
  "userID": "0257dc8642cc73c2",
  "lastReleaseNotesSeen": "2.1.252",
  "oauthAccount": {
    "accountUuid": "e69154ac-3200-4019-b346-03384c7ddafb",
    "emailAddress": "someone@example.com",
    "organizationUuid": "ddf204b4-5f0e-44b6-8613-625b2b228bfc",
    "organizationName": "Example Org",
    "displayName": "Someone"
  }
}`

func TestDetect(t *testing.T) {
	id, err := Detect(writeHome(t, goodConfig))
	if err != nil {
		t.Fatal(err)
	}
	if id.AccountUUID != "e69154ac-3200-4019-b346-03384c7ddafb" {
		t.Errorf("AccountUUID = %q", id.AccountUUID)
	}
	if id.Email != "someone@example.com" || id.OrgName != "Example Org" {
		t.Errorf("email/org = %q/%q", id.Email, id.OrgName)
	}
	if id.MachineID != "9dadb2c4751d265d" {
		t.Errorf("MachineID = %q", id.MachineID)
	}
	if id.CCVersion != "2.1.252" {
		t.Errorf("CCVersion = %q", id.CCVersion)
	}
	if id.Hostname == "" || id.OS == "" || id.Arch == "" {
		t.Errorf("machine fields incomplete: %+v", id)
	}
}

// Without an account uuid every event would be attributed to the empty
// subscription and silently pooled with other machines' data. Refusing is the
// only safe answer.
func TestDetect_NoAccountIsAnError(t *testing.T) {
	for name, cfg := range map[string]string{
		"no oauthAccount": `{"machineID":"m"}`,
		"empty uuid":      `{"machineID":"m","oauthAccount":{"accountUuid":""}}`,
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := Detect(writeHome(t, cfg)); err == nil {
				t.Fatal("expected an error when the account cannot be identified")
			}
		})
	}
}

func TestDetect_MissingFile(t *testing.T) {
	if _, err := Detect(t.TempDir()); err == nil {
		t.Fatal("expected an error for a home with no .claude.json")
	}
}

func TestDetect_IgnoresNonSemverReleaseNotes(t *testing.T) {
	id, err := Detect(writeHome(t, `{"machineID":"m","lastReleaseNotesSeen":"unknown","oauthAccount":{"accountUuid":"a"}}`))
	if err != nil {
		t.Fatal(err)
	}
	if id.CCVersion != "" {
		t.Errorf("CCVersion = %q, want empty for a non-version string", id.CCVersion)
	}
}

// noKeychain isolates a test from the machine's real login keychain. Without
// it, credential tests on a Mac silently read the developer's own live token
// and assert against that instead of their fixture.
func noKeychain(t *testing.T) {
	t.Helper()
	prev := readKeychain
	readKeychain = func() (*Credentials, error) { return nil, ErrNoCredentials }
	t.Cleanup(func() { readKeychain = prev })
}

func writeCreds(t *testing.T, home, body string) {
	t.Helper()
	dir := filepath.Join(home, ".claude")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, ".credentials.json"), []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
}

func TestLoadCredentials_FromFile(t *testing.T) {
	noKeychain(t)
	home := t.TempDir()
	future := time.Now().Add(time.Hour).UnixMilli()
	writeCreds(t, home, `{"claudeAiOauth":{"accessToken":"sk-ant-oat01-x","expiresAt":`+
		itoa(future)+`,"subscriptionType":"max","rateLimitTier":"default_claude_max_20x"}}`)

	c, err := LoadCredentials(home)
	if err != nil {
		t.Fatal(err)
	}
	if c.AccessToken != "sk-ant-oat01-x" {
		t.Errorf("AccessToken = %q", c.AccessToken)
	}
	if c.SubscriptionType != "max" || c.RateLimitTier != "default_claude_max_20x" {
		t.Errorf("tier = %q/%q", c.SubscriptionType, c.RateLimitTier)
	}
}

// Expiry is reported, never repaired. Refreshing would race Claude Code's own
// refresh and could invalidate the user's live session.
func TestLoadCredentials_ExpiredIsReportedNotRefreshed(t *testing.T) {
	noKeychain(t)
	home := t.TempDir()
	past := time.Now().Add(-time.Hour).UnixMilli()
	writeCreds(t, home, `{"claudeAiOauth":{"accessToken":"stale","expiresAt":`+itoa(past)+`}}`)

	c, err := LoadCredentials(home)
	if !errors.Is(err, ErrTokenExpired) {
		t.Fatalf("err = %v, want ErrTokenExpired", err)
	}
	// The token is still returned so a caller can log which account is stale.
	if c == nil || c.AccessToken != "stale" {
		t.Errorf("credentials should still be returned alongside the expiry error, got %+v", c)
	}
}

func TestLoadCredentials_EnvOverride(t *testing.T) {
	t.Setenv("CCQUOTA_OAUTH_TOKEN", "injected")
	c, err := LoadCredentials(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if c.AccessToken != "injected" {
		t.Errorf("AccessToken = %q, want the env value", c.AccessToken)
	}
}

func TestLoadCredentials_MalformedFile(t *testing.T) {
	noKeychain(t)
	home := t.TempDir()
	writeCreds(t, home, `{"claudeAiOauth":{}}`)
	if _, err := LoadCredentials(home); err == nil {
		t.Fatal("expected an error when the credentials file has no token")
	}
}

func itoa(n int64) string {
	if n == 0 {
		return "0"
	}
	neg := n < 0
	if neg {
		n = -n
	}
	var b []byte
	for n > 0 {
		b = append([]byte{byte('0' + n%10)}, b...)
		n /= 10
	}
	if neg {
		return "-" + string(b)
	}
	return string(b)
}

// Regression: on macOS the file is often a stale leftover while the keychain
// holds the live token. Preferring the file made the limits lookup fail
// permanently and blame an expiry that had not happened.
// Measured on a real Mac: file expired 17:07, keychain valid until 07:54 next day.
func TestFreshest_PrefersTheLaterExpiry(t *testing.T) {
	stale := &Credentials{AccessToken: "stale", ExpiresAt: time.Now().Add(-2 * time.Hour)}
	live := &Credentials{AccessToken: "live", ExpiresAt: time.Now().Add(2 * time.Hour)}

	// Order must not matter — the file is read first in practice.
	if got := freshest([]*Credentials{stale, live}); got.AccessToken != "live" {
		t.Errorf("file-then-keychain picked %q, want the live one", got.AccessToken)
	}
	if got := freshest([]*Credentials{live, stale}); got.AccessToken != "live" {
		t.Errorf("keychain-then-file picked %q, want the live one", got.AccessToken)
	}
}

// An unknown expiry is not evidence of freshness and must not beat a known-good
// token.
func TestFreshest_UnknownExpiryLosesToKnownGood(t *testing.T) {
	unknown := &Credentials{AccessToken: "unknown"}
	live := &Credentials{AccessToken: "live", ExpiresAt: time.Now().Add(time.Hour)}

	if got := freshest([]*Credentials{unknown, live}); got.AccessToken != "live" {
		t.Errorf("picked %q over a token with a known-good expiry", got.AccessToken)
	}
	// ...but it is better than nothing.
	if got := freshest([]*Credentials{unknown}); got.AccessToken != "unknown" {
		t.Error("an unknown-expiry token should still be used when it is all there is")
	}
}

func TestFreshest_SkipsEmptyAndNil(t *testing.T) {
	if got := freshest([]*Credentials{nil, {AccessToken: ""}}); got != nil {
		t.Errorf("got %+v, want nil when nothing usable was found", got)
	}
}

// The single-source platforms (Linux, Windows) must be unaffected.
func TestLoadCredentials_SingleSourceStillWorks(t *testing.T) {
	noKeychain(t)
	home := t.TempDir()
	future := time.Now().Add(time.Hour).UnixMilli()
	writeCreds(t, home, `{"claudeAiOauth":{"accessToken":"only-one","expiresAt":`+itoa(future)+
		`,"subscriptionType":"pro"}}`)

	c, err := LoadCredentials(home)
	if err != nil {
		t.Fatal(err)
	}
	if c.AccessToken != "only-one" || c.SubscriptionType != "pro" {
		t.Errorf("got %+v", c)
	}
}

// The macOS two-source case, with the keychain stubbed so the assertion is
// about ccquota's logic rather than the developer's own login keychain.
func TestLoadCredentials_StaleFileLosesToLiveKeychain(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("the two-source case only arises on macOS")
	}
	home := t.TempDir()
	past := time.Now().Add(-2 * time.Hour).UnixMilli()
	writeCreds(t, home, `{"claudeAiOauth":{"accessToken":"stale-file","expiresAt":`+itoa(past)+`}}`)

	prev := readKeychain
	readKeychain = func() (*Credentials, error) {
		return &Credentials{AccessToken: "live-keychain",
			ExpiresAt: time.Now().Add(2 * time.Hour), SubscriptionType: "max"}, nil
	}
	t.Cleanup(func() { readKeychain = prev })

	c, err := LoadCredentials(home)
	if err != nil {
		t.Fatalf("a live keychain token must not report an expiry: %v", err)
	}
	if c.AccessToken != "live-keychain" {
		t.Fatalf("picked %q; the stale file beat the live keychain", c.AccessToken)
	}
}
