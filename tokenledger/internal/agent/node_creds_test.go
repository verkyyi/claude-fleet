package agent

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
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

func TestCredCycleWritesEachCLIsFile(t *testing.T) {
	home := t.TempDir()
	exp := time.Now().Add(8 * time.Hour).UTC().Truncate(time.Second)
	body := fmt.Sprintf(`{"principal_id":"p","credentials":[
	 {"provider":"claude","account":"main","expires_at":%q,"access":{"access_token":"sk-ant-oat01-short","scopes":["user:inference","user:profile"],"subscription_type":"max"}},
	 {"provider":"codex","account":"work","expires_at":%q,"access":{"access_token":"cx-short","id_token":"idt","account_id":"acct-1"}},
	 {"provider":"github","account":"alice","access":{"token":"ghp_short","user":"alice"}}]}`,
		exp.Format(time.RFC3339), exp.Format(time.RFC3339))
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
	if cx.AuthMode != "chatgpt" || cx.Tokens["access_token"] != "cx-short" || cx.Tokens["refresh_token"] != CodexRefreshPlaceholder ||
		cx.Tokens["account_id"] != "acct-1" || cx.Tokens["id_token"] != "idt" {
		t.Fatalf("codex auth.json = %+v", cx)
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
	if got := hubAccountToken(dir, "main", "hub:main"); got != "sk-ant-oat01-live" {
		t.Fatalf("marker resolved to %q", got)
	}
	if got := hubAccountToken(dir, "x", "sk-ant-oat01-plain"); got != "sk-ant-oat01-plain" {
		t.Fatalf("a plain token was rewritten to %q", got)
	}
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
