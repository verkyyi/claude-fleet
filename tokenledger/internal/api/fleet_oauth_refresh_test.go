package api

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/coder/websocket/wsjson"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/agent"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/credvault"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// The OAuth refresh relay (claude-fleet#1490): the hub's own egress is refused
// by the provider, so the one POST a refresh is travels by an admin node. The
// three outcomes the issue names — the node relays and the provider answers,
// no node is online, the provider refuses — plus the rail that a node which
// is not an admin is never handed a form.

const (
	codexRefreshSecret = "rt-SECRET-codex-0"
	codexRefreshNext   = "rt-SECRET-codex-1"
	codexIDToken       = "id-SECRET-token-1"
)

// codexJWT is an unsigned JWT whose exp is in h hours: what the provider hands
// back as the access token, and what the hub reads the expiry from.
func codexJWT(t *testing.T, in time.Duration) string {
	t.Helper()
	claims, _ := json.Marshal(map[string]any{"exp": time.Now().Add(in).Unix(), "sub": "u"})
	seg := func(b []byte) string { return base64.RawURLEncoding.EncodeToString(b) }
	return seg([]byte(`{"alg":"none"}`)) + "." + seg(claims) + ".sig"
}

// fakeProvider is auth.openai.com for the test: it counts hits, checks the
// form is the one the hub built, and answers with status + body.
type fakeProvider struct {
	srv    *httptest.Server
	hits   atomic.Int64
	status atomic.Int64
	body   atomic.Value // string
	lastRT atomic.Value // string
}

func newFakeProvider(t *testing.T, access string) *fakeProvider {
	t.Helper()
	p := &fakeProvider{}
	p.status.Store(http.StatusOK)
	b, _ := json.Marshal(map[string]any{"access_token": access, "refresh_token": codexRefreshNext, "id_token": codexIDToken})
	p.body.Store(string(b))
	p.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		p.hits.Add(1)
		var form map[string]string
		_ = json.NewDecoder(r.Body).Decode(&form)
		p.lastRT.Store(form["refresh_token"])
		if form["grant_type"] != "refresh_token" || form["client_id"] != credvault.CodexClientID {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		w.WriteHeader(int(p.status.Load()))
		_, _ = w.Write([]byte(p.body.Load().(string)))
	}))
	t.Cleanup(p.srv.Close)
	return p
}

func (p *fakeProvider) refuse(status int, body string) {
	p.status.Store(int64(status))
	p.body.Store(body)
}

// proxyVaultHarness is a hub whose vault refreshes through nodes, with alice's
// m4 login (the leasing node) and one pool codex refresh token stored.
func proxyVaultHarness(t *testing.T) (*harness, string) {
	t.Helper()
	h := newFleetHarness(t)
	sealer, err := credvault.NewSealer(bytes.Repeat([]byte{9}, 32))
	if err != nil {
		t.Fatal(err)
	}
	h.srv.Vault = &credvault.Vault{Store: h.srv.Store, Sealer: sealer, Refresher: &credvault.ProxyRefresher{Via: h.srv.NodeOAuthRefresh}}
	tok := enrollAs(t, h, "alice-m4", "m4", "alice")
	p, err := h.srv.Store.AdoptPrincipal("wecom-alice", "alice", "Alice", time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if err := h.srv.Store.AdoptAccount(p, "m4", time.Now()); err != nil {
		t.Fatal(err)
	}
	code, out := h.post(t, "/v1/fleet/credentials", FleetCredentialRequest{Action: "put", PrincipalID: store.PoolPrincipal,
		Provider: credvault.Codex, Account: "default", Secret: credvault.Secret{RefreshToken: codexRefreshSecret, AccountID: "acct-pool", IDToken: "id-SECRET-token-0"}})
	if code != http.StatusOK {
		t.Fatalf("put pool codex: %d %v", code, out)
	}
	return h, tok
}

// lockedBuf is a log sink the test may read while the agent still writes.
type lockedBuf struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *lockedBuf) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(p)
}

func (b *lockedBuf) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.String()
}

// startRefreshAgent runs a REAL admin agent against the harness hub, pointed
// at the fake provider, and returns the log it writes.
func startRefreshAgent(t *testing.T, h *harness, provider *fakeProvider) (logBuf *lockedBuf, stop func()) {
	t.Helper()
	const adminUser = "opadmin"
	h.srv.FleetAdmins = append(h.srv.FleetAdmins, adminUser)
	tok := enrollAs(t, h, "m5-admin", "m5", adminUser)
	home := t.TempDir()
	a, err := agent.New(agent.Config{
		HubURL: h.http.URL, Token: tok, Home: home,
		StateDir: filepath.Join(home, "state"), SessionsDir: filepath.Join(home, "sessions"),
		Sources: "claude", LiveInterval: 150 * time.Millisecond, ScanInterval: time.Hour, LimitsInterval: time.Hour,
		Fleet: true, FleetAdmin: true, FleetOAuthRefresh: true, Version: "it-refresh",
		OAuthTokenURLs: map[string]string{"codex": provider.srv.URL},
	})
	if err != nil {
		t.Fatal(err)
	}
	logBuf = &lockedBuf{}
	prev := log.Writer()
	log.SetOutput(logBuf)
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { a.Run(ctx); close(done) }()
	stopped := false
	stop = func() {
		if !stopped {
			stopped = true
			cancel()
			<-done
			log.SetOutput(prev)
		}
	}
	t.Cleanup(stop)
	waitFor(t, 10*time.Second, "an admin node online to relay refreshes", func() bool {
		_, _, err := h.srv.OAuthRefreshNode(time.Now())
		return err == nil
	})
	return logBuf, stop
}

func refreshAudit(t *testing.T, h *harness) []store.CredAudit {
	t.Helper()
	rows, err := h.srv.Store.CredAuditLog("", 100)
	if err != nil {
		t.Fatal(err)
	}
	var out []store.CredAudit
	for _, a := range rows {
		if a.Action == store.CredRefresh {
			out = append(out, a)
		}
	}
	return out
}

func TestOAuthRefreshViaNodeSucceeds(t *testing.T) {
	h, aliceTok := proxyVaultHarness(t)
	access := codexJWT(t, 8*time.Hour)
	provider := newFakeProvider(t, access)
	agentLog, stop := startRefreshAgent(t, h, provider)

	code, got, refusal := lease(t, h, aliceTok)
	if code != http.StatusOK {
		t.Fatalf("lease: %d %v", code, refusal)
	}
	if len(got.Credentials) != 1 {
		t.Fatalf("credentials = %+v", got.Credentials)
	}
	c := got.Credentials[0]
	if c.Error != "" || c.Access == nil || c.Access.AccessToken != access || c.Access.IDToken != codexIDToken || c.Access.AccountID != "acct-pool" || !c.Pool {
		t.Fatalf("leased codex = %+v (error %q)", c.Access, c.Error)
	}
	if n := provider.hits.Load(); n != 1 {
		t.Fatalf("provider hit %d times, want exactly 1 (the node's POST)", n)
	}
	if rt, _ := provider.lastRT.Load().(string); rt != codexRefreshSecret {
		t.Fatalf("the node posted refresh_token %q, want the vault's", rt)
	}

	// The audit row says which node carried it.
	_, name, err := h.srv.OAuthRefreshNode(time.Now())
	if err != nil {
		t.Fatal(err)
	}
	rows := refreshAudit(t, h)
	if len(rows) != 1 || !strings.HasPrefix(rows[0].Detail, "ok") || !strings.Contains(rows[0].Detail, "refresh_via="+name) {
		t.Fatalf("refresh audit = %+v, want ok · refresh_via=%s", rows, name)
	}
	if !strings.Contains(name, "@") {
		t.Fatalf("refresh_via %q should be login@host", name)
	}

	// Nothing of the tokens reached the node's log — only the status line.
	logText := agentLog.String()
	for _, secret := range []string{codexRefreshSecret, codexRefreshNext, codexIDToken, access} {
		if strings.Contains(logText, secret) {
			t.Fatalf("a token reached the agent log:\n%s", logText)
		}
	}
	if !strings.Contains(logText, "relayed a codex refresh for the hub: HTTP 200") {
		t.Fatalf("agent log lacks the one status line:\n%s", logText)
	}
	// Force a second refresh (MinTTL above the token's life) and check the
	// form carries the ROTATED token: the vault saved what the node brought.
	h.srv.Vault.MinTTL = 9 * time.Hour
	if code, _, refusal := lease(t, h, aliceTok); code != http.StatusOK {
		t.Fatalf("second lease: %d %v", code, refusal)
	}
	if rt, _ := provider.lastRT.Load().(string); rt != codexRefreshNext {
		t.Fatalf("second refresh posted %q, want the rotated token %q", rt, codexRefreshNext)
	}
	if provider.hits.Load() != 2 {
		t.Fatalf("provider hit %d times after two refreshes", provider.hits.Load())
	}
	stop()
}

func TestOAuthRefreshNoNodeIsUnavailable(t *testing.T) {
	h, aliceTok := proxyVaultHarness(t)
	provider := newFakeProvider(t, codexJWT(t, 8*time.Hour))

	code, got, refusal := lease(t, h, aliceTok)
	if code != http.StatusOK {
		t.Fatalf("lease: %d %v", code, refusal)
	}
	if len(got.Credentials) != 1 || got.Credentials[0].Access != nil {
		t.Fatalf("credentials = %+v, want one refused codex row", got.Credentials)
	}
	e := got.Credentials[0].Error
	if !strings.Contains(e, "refresh_unavailable") || strings.Contains(e, "403") || !strings.Contains(e, "no admin node is online") {
		t.Fatalf("error = %q, want refresh_unavailable (no admin node online), never a provider status", e)
	}
	if provider.hits.Load() != 0 {
		t.Fatal("the provider was hit with no node to relay through")
	}
	rows := refreshAudit(t, h)
	if len(rows) != 1 || !strings.Contains(rows[0].Detail, "refresh_unavailable") || strings.Contains(rows[0].Detail, "refresh_via=") {
		t.Fatalf("refresh audit = %+v, want failed: refresh_unavailable with no node named", rows)
	}

	// The node comes online: the same lease now succeeds.
	startRefreshAgent(t, h, provider)
	code, got, refusal = lease(t, h, aliceTok)
	if code != http.StatusOK || len(got.Credentials) != 1 || got.Credentials[0].Access == nil {
		t.Fatalf("lease with a node: %d %v %+v", code, refusal, got.Credentials)
	}
}

func TestOAuthRefreshProviderRefuses(t *testing.T) {
	h, aliceTok := proxyVaultHarness(t)
	provider := newFakeProvider(t, codexJWT(t, 8*time.Hour))
	provider.refuse(http.StatusForbidden, `{"error":{"code":"unsupported_country_region_territory","message":"Country, region, or territory not supported"}}`)
	agentLog, stop := startRefreshAgent(t, h, provider)

	code, got, refusal := lease(t, h, aliceTok)
	if code != http.StatusOK {
		t.Fatalf("lease: %d %v", code, refusal)
	}
	e := got.Credentials[0].Error
	if !strings.Contains(e, "token endpoint answered 403") || !strings.Contains(e, "unsupported_country_region_territory") || strings.Contains(e, "refresh_unavailable") {
		t.Fatalf("error = %q, want the provider's refusal, not refresh_unavailable", e)
	}
	if provider.hits.Load() != 1 {
		t.Fatalf("provider hit %d times, want 1 — a refused form is never re-sent", provider.hits.Load())
	}
	_, name, _ := h.srv.OAuthRefreshNode(time.Now())
	rows := refreshAudit(t, h)
	if len(rows) != 1 || !strings.HasPrefix(rows[0].Detail, "failed: token endpoint answered 403") || !strings.Contains(rows[0].Detail, "refresh_via="+name) {
		t.Fatalf("refresh audit = %+v", rows)
	}
	stop()
	if l := agentLog.String(); strings.Contains(l, codexRefreshSecret) || !strings.Contains(l, "HTTP 403") {
		t.Fatalf("agent log:\n%s", l)
	}
}

// A node that offers the capability without being an admin is never asked.
func TestOAuthRefreshNeverSentToNonAdmin(t *testing.T) {
	h, aliceTok := proxyVaultHarness(t)
	tok := enrollAs(t, h, "m6-user", "m6", "someone")
	c := dialNode(t, h, tok)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	m, _ := control.New(control.TypeHello, control.Hello{HeartbeatMS: 5000, Admin: true,
		Capabilities: []string{control.CapRead, control.CapOAuthRefresh}})
	if err := wsjson.Write(ctx, c, m); err != nil {
		t.Fatal(err)
	}
	var reply control.Message
	if err := wsjson.Read(ctx, c, &reply); err != nil || reply.Type != control.TypeWelcome {
		t.Fatalf("hello: %v %+v", err, reply)
	}
	beat(t, c, control.Proto, control.Heartbeat{Hostname: "m6", OSUser: "someone"})
	n := &tnode{c: c, in: make(chan control.Message, 16)}
	go func() {
		defer close(n.in)
		for {
			var m control.Message
			if err := wsjson.Read(context.Background(), c, &m); err != nil {
				return
			}
			n.in <- m
		}
	}()

	if _, _, err := h.srv.OAuthRefreshNode(time.Now()); !errors.Is(err, credvault.ErrRefreshUnavailable) {
		t.Fatalf("a non-admin node was picked to relay: %v", err)
	}
	_, got, _ := lease(t, h, aliceTok)
	if len(got.Credentials) != 1 || !strings.Contains(got.Credentials[0].Error, "refresh_unavailable") {
		t.Fatalf("credentials = %+v", got.Credentials)
	}
	if m, ok := readMsg(n, 300*time.Millisecond); ok && m.Type == control.TypeOAuthRefresh {
		t.Fatalf("the non-admin node received a refresh form: %+v", m)
	}
}

// The direct refresher is untouched by the relay: with no
// CCQUOTA_FLEET_OAUTH_REFRESH_VIA the hub posts from its own network.
func TestDirectRefreshStillPostsFromHub(t *testing.T) {
	provider := newFakeProvider(t, codexJWT(t, 8*time.Hour))
	r := &credvault.HTTPRefresher{CodexTokenURL: provider.srv.URL}
	acc, next, err := r.Refresh(context.Background(), credvault.Codex, credvault.Secret{RefreshToken: codexRefreshSecret, AccountID: "a"})
	if err != nil || acc.IDToken != codexIDToken || next.RefreshToken != codexRefreshNext || acc.ExpiresAt == nil {
		t.Fatalf("direct refresh: %+v %+v %v", acc, next, err)
	}
	if provider.hits.Load() != 1 {
		t.Fatal("direct refresh did not post once")
	}
}
