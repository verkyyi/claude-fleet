package agent

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/codex"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"io"
	"io/fs"
	"log"
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
	a, stored := storeAgent(t, fakeVaultHub(t, 200, body), home)

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

	// Claude: the file Claude Code reads via CLAUDE_SECURESTORAGE_CONFIG_DIR,
	// held by the store (claude-fleet#4675: never in the home).
	var cc struct {
		ClaudeAiOauth struct {
			AccessToken      string   `json:"accessToken"`
			RefreshToken     *string  `json:"refreshToken"`
			ExpiresAt        int64    `json:"expiresAt"`
			Scopes           []string `json:"scopes"`
			SubscriptionType string   `json:"subscriptionType"`
		} `json:"claudeAiOauth"`
	}
	if err := json.Unmarshal(stored("claude", "main"), &cc); err != nil {
		t.Fatalf("stored claude credential: %v", err)
	}
	o := cc.ClaudeAiOauth
	if o.AccessToken != "sk-ant-oat01-short" || o.RefreshToken != nil || o.ExpiresAt != exp.UnixMilli() ||
		len(o.Scopes) != 2 || o.SubscriptionType != "max" {
		t.Fatalf("claude credentials = %+v", o)
	}
	if b, _ := os.ReadFile(filepath.Join(acct, "main")); string(b) != "hub:main\n" {
		t.Fatalf("label file = %q, want the hub marker in place of the long-lived token", b)
	}
	for _, p := range []string{filepath.Join(acct, "main.hub"), filepath.Join(cxHome, "auth.json")} {
		if _, err := os.Lstat(p); err == nil {
			t.Fatalf("%s written into the home", p)
		}
	}

	// Codex: auth.json with the placeholder (in the store), and file storage
	// switched on ABOVE the existing table.
	var cx struct {
		AuthMode string `json:"auth_mode"`
		Tokens   map[string]string
	}
	if err := json.Unmarshal(stored("codex", "work"), &cx); err != nil {
		t.Fatalf("stored codex auth: %v", err)
	}
	if cx.AuthMode != "chatgpt" || cx.Tokens["access_token"] != cxShort || cx.Tokens["refresh_token"] != CodexRefreshPlaceholder ||
		cx.Tokens["account_id"] != "acct-1" || cx.Tokens["id_token"] != "idt" {
		t.Fatalf("codex auth.json = %+v", cx)
	}
	// The auth.json the lease made is one `ccquota codex` reads as hub-managed
	// (claude-fleet#1666): a valid login refreshed by the hub, and a local
	// refresh — the agent's auto-refresh or `ccquota codex refresh` — refused
	// before the official CLI is started.
	leasedHome := filepath.Join(t.TempDir(), "work")
	_ = os.MkdirAll(leasedHome, 0o700)
	if err := os.WriteFile(filepath.Join(leasedHome, "auth.json"), stored("codex", "work"), 0o600); err != nil {
		t.Fatal(err)
	}
	leased, err := codex.ReadAuth(leasedHome)
	if err != nil {
		t.Fatalf("the leased home does not read as a Codex login: %v", err)
	}
	if !leased.HubManaged || leased.HasRefreshToken || !leased.ExpiresAt.Equal(exp) {
		t.Fatalf("leased home = hub:%v refresh:%v exp:%s", leased.HubManaged, leased.HasRefreshToken, leased.ExpiresAt)
	}
	if h := codex.LoginHealth(leasedHome, leased, true); h.State != "valid" || h.Source != "hub" || h.AutoRefresh {
		t.Fatalf("leased home health = %+v, want valid · source hub · auto_refresh false", h)
	}
	if _, err := codex.Maintain(context.Background(), filepath.Join(home, "no-such-codex"), leasedHome, true); !errors.Is(err, codex.ErrHubManaged) {
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
	a, _ := storeAgent(t, fakeVaultHub(t, 200, fmt.Sprintf(`{"credentials":[{"provider":"claude","account":"../../evil","expires_at":%q,"access":{"access_token":"x"}}]}`, exp)), home)
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
	leaseFile(t, dir, "main", "sk-ant-oat01-live", exp)
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
	leaseFile(t, dir, "main", "sk-ant-oat01-stale", past)
	_, err = hubAccountToken(dir, "main", "hub:main")
	check("expired lease", err, "lease expired", "not renewed")
}

// leaseFile lays down the files an older agent leased into a home — the
// credential under <label>.hub/ and the marker — which the probe still reads.
func leaseFile(t *testing.T, dir, label, token string, exp time.Time) {
	t.Helper()
	if err := os.MkdirAll(filepath.Join(dir, label+".hub"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, label+".hub", ".credentials.json"), claudeCredJSON(token, exp, nil, ""), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, label), []byte(HubMarkerPrefix+label+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
}

// codexLeaseFile lays down the auth.json an older agent leased into a home.
func codexLeaseFile(t *testing.T, home, access string) {
	t.Helper()
	if err := os.MkdirAll(home, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(home, "auth.json"), codexAuthJSON(access, "idt", "acct-1", time.Now()), 0o600); err != nil {
		t.Fatal(err)
	}
}

// A pool setup token (claude-fleet#1463) arrives like any lease — a year out,
// marked kind/pool — and goes to the store like a short-lived one: the label
// file is the hub marker, and the agent's next lease is the ordinary 6h cap.
func TestCredCycleSetupTokenIsWrittenLikeAnyLease(t *testing.T) {
	home := t.TempDir()
	exp := time.Now().Add(365 * 24 * time.Hour).UTC().Truncate(time.Second)
	body := fmt.Sprintf(`{"principal_id":"gh:1001","credentials":[
	 {"provider":"claude","account":"icloud","kind":"setup_token","pool":true,"expires_at":%q,
	  "access":{"access_token":"sk-ant-oat01-POOLTOKEN","scopes":["user:inference"],"expires_at":%q}}]}`,
		exp.Format(time.RFC3339), exp.Format(time.RFC3339))
	a, stored := storeAgent(t, fakeVaultHub(t, 200, body), home)
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
	if err := json.Unmarshal(stored("claude", "icloud"), &cc); err != nil {
		t.Fatalf("stored claude credential: %v", err)
	}
	if o := cc.ClaudeAiOauth; o.AccessToken != "sk-ant-oat01-POOLTOKEN" || o.RefreshToken != nil || o.ExpiresAt != exp.UnixMilli() {
		t.Fatalf("claude credentials = %+v", o)
	}
	if b, _ := os.ReadFile(filepath.Join(acct, "icloud")); string(b) != "hub:icloud\n" {
		t.Fatalf("label file = %q, want the hub marker", b)
	}
	if _, err := os.Lstat(filepath.Join(acct, "icloud.hub")); err == nil {
		t.Fatal("the setup token was written into the home")
	}
}

// claude-fleet#2007: a hub-leased Codex home whose current access the
// upstream refused (#1920's .ccquota-upstream.json) is reported on the next
// lease by fingerprint — never the token — and only once wakes the loop.
func TestCredLeaseReportsUpstreamRevoked(t *testing.T) {
	home := t.TempDir()
	exp := time.Now().Add(100 * time.Hour).UTC()
	access := hubTestJWT(map[string]any{"exp": exp.Unix(), "https://api.openai.com/auth": map[string]any{"chatgpt_account_id": "acct-1", "chatgpt_user_id": "member"}})
	cx := filepath.Join(home, ".codex-accounts", "work")
	codexLeaseFile(t, cx, access)
	// An unmanaged home with a refusal of its own is not the hub's business.
	own := filepath.Join(home, ".codex")
	_ = os.MkdirAll(own, 0o700)
	_ = os.WriteFile(filepath.Join(own, "auth.json"), []byte(`{"tokens":{"access_token":"x","refresh_token":"mine"}}`), 0o600)
	verdict := func(dir, tok, refresh string) {
		fp := fmt.Sprintf("%x", sha256.Sum256([]byte(tok+"\x00"+refresh)))
		_ = os.WriteFile(filepath.Join(dir, ".ccquota-upstream.json"),
			[]byte(`{"credential_version":"`+fp+`","state":"rejected","error":"token_revoked","at":"2026-10-07T00:00:00Z","by":"proxy"}`), 0o600)
	}
	verdict(cx, access, CodexRefreshPlaceholder)
	verdict(own, "x", "mine")

	var got []byte
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got, _ = io.ReadAll(r.Body)
		fmt.Fprint(w, `{"principal_id":"p","credentials":[]}`)
	}))
	t.Cleanup(srv.Close)
	a := credAgent(srv, home)
	if _, err := a.credCycle(context.Background()); err != nil {
		t.Fatal(err)
	}
	var body struct {
		UpstreamRejected []upstreamRejection `json:"upstream_rejected"`
	}
	if err := json.Unmarshal(got, &body); err != nil {
		t.Fatalf("lease body %q: %v", got, err)
	}
	want := fmt.Sprintf("%x", sha256.Sum256([]byte(access)))
	if len(body.UpstreamRejected) != 1 {
		t.Fatalf("upstream_rejected = %+v, want the one hub-managed home", body.UpstreamRejected)
	}
	rj := body.UpstreamRejected[0]
	if rj.Provider != "codex" || rj.Account != "work" || rj.Fingerprint != want || rj.Error != "token_revoked" {
		t.Fatalf("report %+v", rj)
	}
	if strings.Contains(string(got), access) {
		t.Fatal("the access token itself went to the hub")
	}
	if !a.credReported[want] {
		t.Fatal("a carried refusal is not remembered: the wait would wake on it again")
	}
	// A renewed token (a new auth.json) outdates the refusal: nothing to say.
	codexLeaseFile(t, cx, access+"2")
	if rs := a.upstreamRejections(); len(rs) != 0 {
		t.Fatalf("refusal of a replaced token still reported: %+v", rs)
	}
}

// A lease that withdraws an account (claude-fleet#3043) removes what the hub
// wrote for it — only that: a hand-stored Claude token and a person's own
// Codex login stay — and leases again within recheck_secs.
func TestCredCycleWithdrawsForbiddenAccounts(t *testing.T) {
	home := t.TempDir()
	acct := filepath.Join(home, ".config", "claude-fleet", "accounts")
	mk := func(p, body string) {
		t.Helper()
		_ = os.MkdirAll(filepath.Dir(p), 0o700)
		if err := os.WriteFile(p, []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	mk(filepath.Join(acct, "gone.hub", ".credentials.json"), `{"claudeAiOauth":{"accessToken":"sk-ant-oat01-x"}}`)
	mk(filepath.Join(acct, "gone"), "hub:gone\n")
	mk(filepath.Join(acct, "mine"), "sk-ant-oat01-HANDSTORED\n")
	hubCx := filepath.Join(home, ".codex-accounts", "work", "auth.json")
	mk(hubCx, `{"tokens":{"access_token":"a","refresh_token":"`+CodexRefreshPlaceholder+`"}}`)
	ownCx := filepath.Join(home, ".codex", "auth.json")
	mk(ownCx, `{"tokens":{"access_token":"a","refresh_token":"rt-own"}}`)

	body := `{"principal_id":"p","credentials":[],"recheck_secs":900,"withdrawn":[
	 {"provider":"claude","account":"gone","error":"not in machine mac-a's allowlist"},
	 {"provider":"claude","account":"mine","error":"x"},
	 {"provider":"codex","account":"work","error":"x"},
	 {"provider":"codex","account":"default","error":"x"},
	 {"provider":"claude","account":"../escape","error":"x"}]}`
	a := credAgent(fakeVaultHub(t, 200, body), home)
	wait, err := a.credCycle(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if wait > 15*time.Minute {
		t.Fatalf("next lease in %s; recheck_secs said 15m", wait)
	}
	for p, want := range map[string]bool{
		filepath.Join(acct, "gone.hub"): false, filepath.Join(acct, "gone"): false,
		filepath.Join(acct, "mine"): true, hubCx: false, ownCx: true,
	} {
		if _, err := os.Stat(p); (err == nil) != want {
			t.Errorf("%s exists=%v, want %v", p, err == nil, want)
		}
	}
}

// TestCredRefusedRetryNoPrincipal (claude-fleet#3397): a freshly opened
// login's no_principal is retried in seconds, doubling to the old 15-minute
// wait; any other refusal waits the 15 minutes at once.
func TestCredRefusedRetryNoPrincipal(t *testing.T) {
	// claude-fleet#3434: the first half hour stays on the 30-second clock — a
	// login asks from inside its own create, and the hub's word may come any
	// minute of it — then the doubling of #3397.
	for n := 0; n < credNoPrincipalHold; n++ {
		if got := credRefusedRetry("no_principal", n); got != 30*time.Second {
			t.Fatalf("no_principal #%d: wait %v, want 30s", n, got)
		}
	}
	want := []time.Duration{30 * time.Second, time.Minute, 2 * time.Minute, 4 * time.Minute, 8 * time.Minute, 15 * time.Minute, 15 * time.Minute}
	for i, w := range want {
		n := credNoPrincipalHold + i
		if got := credRefusedRetry("no_principal", n); got != w {
			t.Errorf("no_principal #%d: wait %v, want %v", n, got, w)
		}
	}
	if got := credRefusedRetry("revoked", 0); got != credRefusedWait {
		t.Errorf("revoked: wait %v, want %v", got, credRefusedWait)
	}
}

// claude-fleet#3440: a 200 lease with no subscription said nothing on the
// node — the count is logged (never a token), once per change.
func TestCredSummaryCountsAndLogsOnChange(t *testing.T) {
	if got := credSummary(map[string]int{"claude": 2, "github": 1}, 0, 0); got != "leased claude=2 codex=0 github=1" {
		t.Fatalf("summary: %q", got)
	}
	none := credSummary(map[string]int{}, 1, 3)
	if !strings.HasPrefix(none, "leased claude=0 codex=0 github=0 failed=1 withdrawn=3") || !strings.Contains(none, "not ready") {
		t.Fatalf("no-subscription summary: %q", none)
	}
	var buf bytes.Buffer
	log.SetOutput(&buf)
	defer log.SetOutput(os.Stderr)
	a := &Agent{}
	a.logCredSummary(none)
	a.logCredSummary(none)
	if n := strings.Count(buf.String(), "credentials: leased"); n != 1 {
		t.Fatalf("logged %d times, want once:\n%s", n, buf.String())
	}
	a.logCredSummary("leased claude=1 codex=0 github=0")
	if n := strings.Count(buf.String(), "credentials: leased"); n != 2 {
		t.Fatalf("a change is logged again:\n%s", buf.String())
	}
}

// TestCredCyclePrunesWhatTheHubDropped (claude-fleet#3744): a subscription the
// hub deleted is simply absent from the next lease — never in Withdrawn — and
// its copy goes; one the hub still names but could not lease this time stays,
// and so does a token the person stored by hand.
func TestCredCyclePrunesWhatTheHubDropped(t *testing.T) {
	home := t.TempDir()
	acct := filepath.Join(home, ".config", "claude-fleet", "accounts")
	mk := func(p, body string) {
		t.Helper()
		_ = os.MkdirAll(filepath.Dir(p), 0o700)
		if err := os.WriteFile(p, []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	for _, l := range []string{"icloud", "flaky", "kept"} {
		mk(filepath.Join(acct, l+".hub", ".credentials.json"), `{"claudeAiOauth":{"accessToken":"sk-ant-oat01-x"}}`)
		mk(filepath.Join(acct, l), "hub:"+l+"\n")
	}
	mk(filepath.Join(acct, "mine"), "sk-ant-oat01-HANDSTORED\n")
	hubCx := filepath.Join(home, ".codex-accounts", "gonecx", "auth.json")
	mk(hubCx, `{"tokens":{"access_token":"a","refresh_token":"`+CodexRefreshPlaceholder+`"}}`)
	ownCx := filepath.Join(home, ".codex", "auth.json")
	mk(ownCx, `{"tokens":{"access_token":"a","refresh_token":"rt-own"}}`)

	exp := time.Now().Add(8 * time.Hour).UTC().Format(time.RFC3339)
	body := `{"principal_id":"p","credentials":[
	 {"provider":"claude","account":"kept","pool":true,"expires_at":"` + exp + `","access":{"access_token":"sk-ant-oat01-new"}},
	 {"provider":"claude","account":"flaky","pool":true,"error":"refresh failed"}]}`
	a := credAgent(fakeVaultHub(t, 200, body), home)
	if _, err := a.credCycle(context.Background()); err != nil {
		t.Fatal(err)
	}
	for p, want := range map[string]bool{
		filepath.Join(acct, "icloud.hub"): false, filepath.Join(acct, "icloud"): false,
		filepath.Join(acct, "flaky.hub"): true, filepath.Join(acct, "flaky"): true,
		filepath.Join(acct, "kept.hub"): true, filepath.Join(acct, "kept"): true,
		filepath.Join(acct, "mine"): true, hubCx: false, ownCx: true,
	} {
		if _, err := os.Stat(p); (err == nil) != want {
			t.Errorf("%s exists=%v, want %v", p, err == nil, want)
		}
	}
}

// TestCredKickCutsTheWait (claude-fleet#3744): the hub's TypeCreds ends the
// lease loop's wait at once; a second push before the lease is the same one.
func TestCredKickCutsTheWait(t *testing.T) {
	a := &Agent{cfg: Config{FleetCreds: true}}
	m, _ := control.New(control.TypeCreds, control.Creds{Why: "credential delete"})
	a.handleCreds(m)
	a.handleCreds(m)
	done := make(chan bool, 1)
	go func() { done <- a.waitCredLease(context.Background(), time.Hour) }()
	select {
	case ok := <-done:
		if !ok {
			t.Fatal("waitCredLease said the context ended")
		}
	case <-time.After(5 * time.Second):
		t.Fatal("a TypeCreds push did not cut the wait")
	}
	select {
	case <-a.credKickCh():
		t.Fatal("two pushes queued two leases")
	default:
	}
}
