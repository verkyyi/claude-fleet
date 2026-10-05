package agent

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/codex"
	"io/fs"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// fakeVaultHub answers /v1/node/credentials with the given status and body.
func fakeVaultHub(t *testing.T, status int, body string) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/node/credentials" || r.Method != http.MethodPost || r.Header.Get("Authorization") != "Bearer tok" {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		w.WriteHeader(status)
		fmt.Fprint(w, body)
	}))
	t.Cleanup(srv.Close)
	return srv
}

func credAgent(srv *httptest.Server, home string) *Agent {
	return &Agent{cfg: Config{HubURL: srv.URL, Token: "tok", Home: home}, http: srv.Client()}
}

// hubTestJWT shapes a short-lived Codex access token the way the provider
// does, so the codex package can read the written home as a login.
func hubTestJWT(v any) string {
	b, _ := json.Marshal(v)
	return "e30." + base64.RawURLEncoding.EncodeToString(b) + ".signature"
}

func TestCredCycleWritesEachCLIsFile(t *testing.T) {
	home := t.TempDir()
	exp := time.Now().Add(8 * time.Hour).UTC().Truncate(time.Second)
	cxShort := hubTestJWT(map[string]any{"exp": exp.Unix(), "https://api.openai.com/auth": map[string]any{"chatgpt_account_id": "acct-1", "chatgpt_user_id": "member"}})
	body := fmt.Sprintf(`{"principal_id":"p","credentials":[
	 {"provider":"claude","account":"main","expires_at":%q,"access":{"access_token":"sk-ant-oat01-short","scopes":["user:inference","user:profile"],"subscription_type":"max"}},
	 {"provider":"codex","account":"work","expires_at":%q,"access":{"access_token":%q,"id_token":"idt","account_id":"acct-1"}},
	 {"provider":"github","account":"alice","access":{"token":"ghp_short","user":"alice"}}]}`,
		exp.Format(time.RFC3339), exp.Format(time.RFC3339), cxShort)
	a := credAgent(fakeVaultHub(t, 200, body), home)

	// A pre-existing long-lived token for the same label, and a codex config
	// with a table: both must survive correctly.
	acct := filepath.Join(home, ".config", "claude-fleet", "accounts")
	_ = os.MkdirAll(acct, 0o700)
	_ = os.WriteFile(filepath.Join(acct, "main"), []byte("sk-ant-oat01-LONGLIVED\n"), 0o600)
	cxHome := filepath.Join(home, ".codex-accounts", "work")
	_ = os.MkdirAll(cxHome, 0o700)
	_ = os.WriteFile(filepath.Join(cxHome, "config.toml"), []byte("model = \"gpt-5.5\"\n[mcp_servers.x]\ncommand = \"y\"\n"), 0o600)

	wait, err := a.credCycle(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if want := time.Until(exp.Add(-credRenewLead)); wait < want-time.Minute || wait > want+time.Minute {
		t.Fatalf("next lease in %s, want ~%s (2h before expiry)", wait, want)
	}

	// Claude: the file Claude Code reads via CLAUDE_SECURESTORAGE_CONFIG_DIR.
	var cc struct {
		ClaudeAiOauth struct {
			AccessToken      string   `json:"accessToken"`
			RefreshToken     *string  `json:"refreshToken"`
			ExpiresAt        int64    `json:"expiresAt"`
			Scopes           []string `json:"scopes"`
			SubscriptionType string   `json:"subscriptionType"`
		} `json:"claudeAiOauth"`
	}
	readJSON(t, filepath.Join(acct, "main.hub", ".credentials.json"), &cc)
	o := cc.ClaudeAiOauth
	if o.AccessToken != "sk-ant-oat01-short" || o.RefreshToken != nil || o.ExpiresAt != exp.UnixMilli() ||
		len(o.Scopes) != 2 || o.SubscriptionType != "max" {
		t.Fatalf("claude credentials = %+v", o)
	}
	if b, _ := os.ReadFile(filepath.Join(acct, "main")); string(b) != "hub:main\n" {
		t.Fatalf("label file = %q, want the hub marker in place of the long-lived token", b)
	}
	mode(t, filepath.Join(acct, "main.hub", ".credentials.json"), 0o600)

	// Codex: auth.json with the placeholder, and file storage switched on
	// ABOVE the existing table.
	var cx struct {
		AuthMode string `json:"auth_mode"`
		Tokens   map[string]string
	}
	readJSON(t, filepath.Join(cxHome, "auth.json"), &cx)
	if cx.AuthMode != "chatgpt" || cx.Tokens["access_token"] != cxShort || cx.Tokens["refresh_token"] != CodexRefreshPlaceholder ||
		cx.Tokens["account_id"] != "acct-1" || cx.Tokens["id_token"] != "idt" {
		t.Fatalf("codex auth.json = %+v", cx)
	}
	// The home the lease wrote is one `ccquota codex` reads as hub-managed
	// (claude-fleet#1666): a valid login refreshed by the hub, and a local
	// refresh — the agent's auto-refresh or `ccquota codex refresh` — refused
	// before the official CLI is started.
	leased, err := codex.ReadAuth(cxHome)
	if err != nil {
		t.Fatalf("the leased home does not read as a Codex login: %v", err)
	}
	if !leased.HubManaged || leased.HasRefreshToken || !leased.ExpiresAt.Equal(exp) {
		t.Fatalf("leased home = hub:%v refresh:%v exp:%s", leased.HubManaged, leased.HasRefreshToken, leased.ExpiresAt)
	}
	if h := codex.LoginHealth(cxHome, leased, true); h.State != "valid" || h.Source != "hub" || h.AutoRefresh {
		t.Fatalf("leased home health = %+v, want valid · source hub · auto_refresh false", h)
	}
	if _, err := codex.Maintain(context.Background(), filepath.Join(home, "no-such-codex"), cxHome, true); !errors.Is(err, codex.ErrHubManaged) {
		t.Fatalf("local refresh of the leased home: err = %v, want ErrHubManaged", err)
	}
	cfg, _ := os.ReadFile(filepath.Join(cxHome, "config.toml"))
	if !strings.HasPrefix(string(cfg), "cli_auth_credentials_store = \"file\"\nmodel = \"gpt-5.5\"\n[mcp_servers.x]") {
		t.Fatalf("config.toml = %q", cfg)
	}

	// GitHub phase one.
	gh, _ := os.ReadFile(filepath.Join(home, ".config", "gh", "hosts.yml"))
	if !strings.Contains(string(gh), "oauth_token: ghp_short") || !strings.Contains(string(gh), "user: alice") {
		t.Fatalf("hosts.yml = %q", gh)
	}

	// The node holds no refresh token and no long-lived Claude token anywhere.
	_ = filepath.WalkDir(home, func(p string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return err
		}
		b, _ := os.ReadFile(p)
		for _, bad := range []string{"LONGLIVED", "sk-ant-ort01", "rt-"} {
			if strings.Contains(string(b), bad) {
				t.Errorf("%s holds %q", p, bad)
			}
		}
		return nil
	})

	// A second cycle leaves config.toml alone (no second prepend).
	if _, err := a.credCycle(context.Background()); err != nil {
		t.Fatal(err)
	}
	if cfg2, _ := os.ReadFile(filepath.Join(cxHome, "config.toml")); string(cfg2) != string(cfg) {
		t.Fatalf("config.toml changed on the second write: %q", cfg2)
	}
}

func TestCredCycleRevokedIsRefused(t *testing.T) {
	a := credAgent(fakeVaultHub(t, 403, `{"error":"revoked","message":"this machine was revoked"}`), t.TempDir())
	_, err := a.credCycle(context.Background())
	var refused errLeaseRefused
	if !errors.As(err, &refused) || refused.reason != "revoked" {
		t.Fatalf("err = %v, want errLeaseRefused(revoked)", err)
	}
}

func TestCredCycleRejectsUnsafeLabel(t *testing.T) {
	home := t.TempDir()
	exp := time.Now().Add(8 * time.Hour).UTC().Format(time.RFC3339)
	a := credAgent(fakeVaultHub(t, 200, fmt.Sprintf(`{"credentials":[{"provider":"claude","account":"../../evil","expires_at":%q,"access":{"access_token":"x"}}]}`, exp)), home)
	if _, err := a.credCycle(context.Background()); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(home, ".config", "evil.hub")); err == nil {
		t.Fatal("a path-like label escaped the accounts directory")
	}
}

func TestHubAccountTokenResolvesMarker(t *testing.T) {
	dir := t.TempDir()
	exp := time.Now().Add(time.Hour)
	if err := writeClaudeCred(dir, "main", "sk-ant-oat01-live", &exp, nil, ""); err != nil {
		t.Fatal(err)
	}
	if got, err := hubAccountToken(dir, "main", "hub:main"); err != nil || got != "sk-ant-oat01-live" {
		t.Fatalf("marker resolved to %q, %v", got, err)
	}
	if got, err := hubAccountToken(dir, "x", "sk-ant-oat01-plain"); err != nil || got != "sk-ant-oat01-plain" {
		t.Fatalf("a plain token was rewritten to %q, %v", got, err)
	}
}

// claude-fleet#1404: a hub-managed account whose lease cannot be read used to
// vanish from the probe without a word. Every way it can fail now names the
// hub-managed source and the file, so the operator is sent to the lease — not
// to ~/.claude, and not to the keychain.
func TestHubAccountTokenNamesTheHubSourceWhenUnreadable(t *testing.T) {
	dir := t.TempDir()
	lease := filepath.Join(dir, "main.hub", ".credentials.json")
	check := func(stage string, err error, want ...string) {
		t.Helper()
		if err == nil {
			t.Fatalf("%s: expected an error", stage)
		}
		for _, w := range append([]string{"hub-managed account main", lease}, want...) {
			if !strings.Contains(err.Error(), w) {
				t.Errorf("%s: error does not name %q:\n  %v", stage, w, err)
			}
		}
	}
	_, err := hubAccountToken(dir, "main", "hub:main")
	check("nothing leased", err, "nothing leased yet")

	if err := os.MkdirAll(filepath.Dir(lease), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(lease, []byte("{not json"), 0o600); err != nil {
		t.Fatal(err)
	}
	_, err = hubAccountToken(dir, "main", "hub:main")
	check("malformed", err, "not the credentials JSON")

	if err := os.WriteFile(lease, []byte(`{"claudeAiOauth":{"accessToken":""}}`), 0o600); err != nil {
		t.Fatal(err)
	}
	_, err = hubAccountToken(dir, "main", "hub:main")
	check("empty token", err, "has no claudeAiOauth.accessToken")

	past := time.Now().Add(-3 * time.Hour)
	if err := writeClaudeCred(dir, "main", "sk-ant-oat01-stale", &past, nil, ""); err != nil {
		t.Fatal(err)
	}
	_, err = hubAccountToken(dir, "main", "hub:main")
	check("expired lease", err, "lease expired", "not renewed")
}

func readJSON(t *testing.T, path string, v any) {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(b, v); err != nil {
		t.Fatalf("%s: %v", path, err)
	}
}

func mode(t *testing.T, path string, want os.FileMode) {
	t.Helper()
	st, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if st.Mode().Perm() != want {
		t.Fatalf("%s mode %v, want %v", path, st.Mode().Perm(), want)
	}
}

// A pool setup token (claude-fleet#1463) arrives like any lease — a year out,
// marked kind/pool — and lands in the same files a short-lived one does: the
// session reads it through CLAUDE_SECURESTORAGE_CONFIG_DIR, the label file is
// the hub marker, and the agent's next lease is the ordinary 6h cap.
func TestCredCycleSetupTokenIsWrittenLikeAnyLease(t *testing.T) {
	home := t.TempDir()
	exp := time.Now().Add(365 * 24 * time.Hour).UTC().Truncate(time.Second)
	body := fmt.Sprintf(`{"principal_id":"wecom-alice","credentials":[
	 {"provider":"claude","account":"icloud","kind":"setup_token","pool":true,"expires_at":%q,
	  "access":{"access_token":"sk-ant-oat01-POOLTOKEN","scopes":["user:inference"],"expires_at":%q}}]}`,
		exp.Format(time.RFC3339), exp.Format(time.RFC3339))
	a := credAgent(fakeVaultHub(t, 200, body), home)
	acct := filepath.Join(home, ".config", "claude-fleet", "accounts")
	_ = os.MkdirAll(acct, 0o700)
	// The same token the operator kept here by hand before the import.
	_ = os.WriteFile(filepath.Join(acct, "icloud"), []byte("sk-ant-oat01-POOLTOKEN\n"), 0o600)

	wait, err := a.credCycle(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if wait != credMaxWait {
		t.Fatalf("next lease in %s, want the %s cap for a token a year out", wait, credMaxWait)
	}
	var cc struct {
		ClaudeAiOauth struct {
			AccessToken  string  `json:"accessToken"`
			RefreshToken *string `json:"refreshToken"`
			ExpiresAt    int64   `json:"expiresAt"`
		} `json:"claudeAiOauth"`
	}
	readJSON(t, filepath.Join(acct, "icloud.hub", ".credentials.json"), &cc)
	if o := cc.ClaudeAiOauth; o.AccessToken != "sk-ant-oat01-POOLTOKEN" || o.RefreshToken != nil || o.ExpiresAt != exp.UnixMilli() {
		t.Fatalf("claude credentials = %+v", o)
	}
	if b, _ := os.ReadFile(filepath.Join(acct, "icloud")); string(b) != "hub:icloud\n" {
		t.Fatalf("label file = %q, want the hub marker", b)
	}
	mode(t, filepath.Join(acct, "icloud.hub", ".credentials.json"), 0o600)
}
