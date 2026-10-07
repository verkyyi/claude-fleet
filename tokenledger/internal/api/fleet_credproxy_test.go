package api

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/credproxy"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/credvault"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/fleetid"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// The cluster credential proxy against the real hub (claude-fleet#1973,
// EPIC #1967 C6): passes issued by the hub (C2), credentials in its vault,
// bindings in its store, and a fake upstream standing in for the relay.

const cpToken = "credproxy-secret"

// two sessions' fleet ids
const (
	fidA = "aaaaaaaa-0000-4000-8000-00000000000a"
	fidB = "bbbbbbbb-0000-4000-8000-00000000000b"
)

type cpRig struct {
	h        *harness
	tok5, f5 string
	tok4, f4 string
	proxy    *httptest.Server
	mu       sync.Mutex
	upAuth   []string
	upAcct   []string
	audit    []string
	// full is Authorization → the 429 body it answers (claude-fleet#2115)
	full     map[string]string
	skew     atomic.Int64 // the proxy's clock runs this far ahead (pastCache)
}

// cpCacheTTL is the rig proxy's verdict cache. It runs on the rig's clock and
// is long on purpose: a test steps past it with pastCache, never a sleep. It
// was 1 ms of wall clock, and a live call plus a revoke can both finish inside
// one millisecond — the next call was then answered from the cache, 5 times in
// 12 (claude-fleet#2072). Long, a forgotten step fails every run, not 1 in 3.
const cpCacheTTL = 10 * time.Second

// pastCache moves the proxy's clock beyond every verdict it holds, so its
// next request asks the hub — what CacheTTL promises of a revocation or a
// rebind in production.
func (r *cpRig) pastCache() { r.skew.Add(int64(cpCacheTTL + time.Millisecond)) }

func newCPRig(t *testing.T) *cpRig {
	t.Helper()
	h, tok5, tok4, f5, f4 := sessHarness(t)
	h.srv.CredProxyToken = cpToken
	for _, acct := range []string{"acct1", "acct2"} {
		if err := h.srv.Vault.Put("gh:1005", credvault.Claude, acct, credvault.Secret{RefreshToken: "rt-" + acct}); err != nil {
			t.Fatal(err)
		}
	}
	if err := h.srv.Vault.Put(store.PoolPrincipal, credvault.Codex, "poolcx", credvault.Secret{RefreshToken: "rt-cx", AccountID: "aid-pool"}); err != nil {
		t.Fatal(err)
	}
	r := &cpRig{h: h, tok5: tok5, f5: f5, tok4: tok4, f4: f4}
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		_, _ = io.Copy(io.Discard, req.Body)
		r.mu.Lock()
		r.upAuth = append(r.upAuth, req.Header.Get("Authorization"))
		r.upAcct = append(r.upAcct, req.Header.Get("Chatgpt-Account-Id"))
		full, isFull := r.full[req.Header.Get("Authorization")]
		r.mu.Unlock()
		if isFull {
			if strings.Contains(full, "weekly limit") { // a quota 429, not a request rate
				w.Header().Set("Anthropic-Ratelimit-Unified-Status", "rejected")
			}
			w.WriteHeader(http.StatusTooManyRequests)
			_, _ = io.WriteString(w, full)
			return
		}
		// usage: 150 counted tokens a request (claude-fleet#1977)
		_, _ = io.WriteString(w, `{"content":[{"type":"text","text":"PONG"}],"usage":{"input_tokens":100,"cache_read_input_tokens":9000,"output_tokens":50}}`)
	}))
	t.Cleanup(up.Close)
	p, err := credproxy.New(credproxy.Config{
		Resolver: &credproxy.HubResolver{URL: h.http.URL, Token: cpToken},
		Direct:   true, AnthropicURL: up.URL, CodexURL: up.URL,
		CacheTTL: cpCacheTTL, StaleFor: time.Minute,
		Now:   func() time.Time { return time.Now().Add(time.Duration(r.skew.Load())) },
		Audit: func(l string) { r.mu.Lock(); r.audit = append(r.audit, l); r.mu.Unlock() },
	})
	if err != nil {
		t.Fatal(err)
	}
	r.proxy = httptest.NewServer(p.Handler())
	t.Cleanup(r.proxy.Close)
	return r
}

// issue a pass for session fid on m5.
func (r *cpRig) issue(t *testing.T, fid string) (cred, workerID string) {
	t.Helper()
	c := assertClaims(r.f5, time.Now())
	c.Fid, c.WorkerID, c.Key = fid, fleetid.WorkerID(r.f5, fid), "issue-"+fid[:4]
	a := signWorkerAssertion(c, HashToken(r.tok5))
	st, out := sessDo(t, r.h, http.MethodPost, "/v1/fleet/session-cred", r.tok5, a, nil)
	if st != 200 {
		t.Fatalf("issue: %d %v", st, out)
	}
	return out["cred"].(string), out["worker_id"].(string)
}

func (r *cpRig) call(t *testing.T, provider, cred string) (int, string) {
	t.Helper()
	path := "/v1/proxy/anthropic/v1/messages"
	if provider == credvault.Codex {
		path = "/v1/proxy/codex/responses"
	}
	req, _ := http.NewRequest(http.MethodPost, r.proxy.URL+path, strings.NewReader(`{"PING":1}`))
	req.Header.Set("Authorization", "Bearer "+cred)
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	b, _ := io.ReadAll(res.Body)
	return res.StatusCode, string(b)
}

func (r *cpRig) lastAuth() string {
	r.mu.Lock()
	defer r.mu.Unlock()
	if len(r.upAuth) == 0 {
		return ""
	}
	return r.upAuth[len(r.upAuth)-1]
}

// leased is the access token the vault holds for one account.
func (r *cpRig) leased(t *testing.T, owner, provider, acct string) string {
	t.Helper()
	acc, err := r.h.srv.Vault.Lease(context.Background(), owner, provider, acct)
	if err != nil {
		t.Fatal(err)
	}
	return "Bearer " + acc.AccessToken
}

// A pass the hub issued reaches the provider as the bound account's token —
// the vault's lease, nothing else — Claude to the person's own account,
// Codex to the shared pool's with its account id. The first use binds; the
// binding is listed for the node that issued the pass.
func TestCredProxyEndToEnd(t *testing.T) {
	r := newCPRig(t)
	cred, wid := r.issue(t, fidA)
	if st, body := r.call(t, credvault.Claude, cred); st != 200 || !strings.Contains(body, "PONG") {
		t.Fatalf("claude → %d %s", st, body)
	}
	if got, want := r.lastAuth(), r.leased(t, "gh:1005", credvault.Claude, "acct1"); got != want {
		t.Fatalf("upstream Authorization = %q; want acct1's lease %q", got, want)
	}
	if st, _ := r.call(t, credvault.Codex, cred); st != 200 {
		t.Fatalf("codex → %d", st)
	}
	r.mu.Lock()
	acct := r.upAcct[len(r.upAcct)-1]
	r.mu.Unlock()
	if got, want := r.lastAuth(), r.leased(t, store.PoolPrincipal, credvault.Codex, "poolcx"); got != want || acct != "aid-pool" {
		t.Fatalf("codex upstream = %q / %q; want the pool's lease + aid-pool", got, acct)
	}
	st, out := sessDo(t, r.h, http.MethodGet, "/v1/fleet/session-cred/bind?worker_id="+wid, r.tok5, "", nil)
	if st != 200 || !strings.Contains(strings.Join(fmtAny(out["binds"]), " "), "acct1") {
		t.Fatalf("bind list: %d %v", st, out)
	}
	// The audit names the session and the account, never the pass.
	r.mu.Lock()
	defer r.mu.Unlock()
	for _, l := range r.audit {
		if strings.Contains(l, "fcp-h1.") || strings.Contains(l, "Bearer") || !strings.Contains(l, wid) {
			t.Fatalf("audit line: %s", l)
		}
	}
}

func fmtAny(v any) []string {
	var out []string
	if l, ok := v.([]any); ok {
		for _, x := range l {
			if m, ok := x.(map[string]any); ok {
				out = append(out, m["provider"].(string)+"="+m["account"].(string))
			}
		}
	}
	return out
}

// Forged, expired and revoked passes are refused (403) and reach nothing.
func TestCredProxyRefusesBadPasses(t *testing.T) {
	r := newCPRig(t)
	cred, _ := r.issue(t, fidA)
	parts := strings.Split(cred, ".")
	forged := parts[0] + "." + parts[1] + ".AAAA" + parts[2][4:]
	if st, _ := r.call(t, credvault.Claude, forged); st != http.StatusForbidden {
		t.Fatalf("forged → %d", st)
	}
	// expired: signed by the hub's key, exp in the past
	c, _ := parseSessionCred(cred, r.h.srv.SessionCredKey, time.Now())
	old := *c
	old.Exp = time.Now().Add(-time.Minute).Unix()
	if st, _ := r.call(t, credvault.Claude, signSessionCred(old, r.h.srv.SessionCredKey)); st != http.StatusForbidden {
		t.Fatalf("expired → %d", st)
	}
	if st, _ := r.call(t, credvault.Claude, cred); st != 200 {
		t.Fatalf("live → %d", st)
	}
	if st, out := sessDo(t, r.h, http.MethodDelete, "/v1/fleet/session-cred/"+c.ID, r.tok5, "", nil); st != 200 {
		t.Fatalf("revoke: %d %v", st, out)
	}
	r.pastCache()
	if st, body := r.call(t, credvault.Claude, cred); st != http.StatusForbidden || !strings.Contains(body, "revoked") {
		t.Fatalf("revoked → %d %s", st, body)
	}
	r.mu.Lock()
	n := len(r.upAuth)
	r.mu.Unlock()
	if n != 1 {
		t.Fatalf("upstream saw %d requests; want only the live one", n)
	}
}

// Two sessions of one person, bound to two accounts, never cross; a rebind
// by the issuing node moves the session's next request.
func TestCredProxyBindAndRebind(t *testing.T) {
	r := newCPRig(t)
	credA, widA := r.issue(t, fidA)
	credB, widB := r.issue(t, fidB)
	if st, out := sessDo(t, r.h, http.MethodPut, "/v1/fleet/session-cred/bind", r.tok5, "",
		map[string]any{"worker_id": widB, "provider": "claude", "account": "acct2"}); st != 200 || out["rev"] != float64(1) {
		t.Fatalf("bind B: %d %v", st, out)
	}
	a1, a2 := r.leased(t, "gh:1005", credvault.Claude, "acct1"), r.leased(t, "gh:1005", credvault.Claude, "acct2")
	for i := 0; i < 3; i++ {
		r.call(t, credvault.Claude, credA)
		if got := r.lastAuth(); got != a1 {
			t.Fatalf("A → %q; want acct1", got)
		}
		r.call(t, credvault.Claude, credB)
		if got := r.lastAuth(); got != a2 {
			t.Fatalf("B → %q; want acct2", got)
		}
	}
	if st, out := sessDo(t, r.h, http.MethodPut, "/v1/fleet/session-cred/bind", r.tok5, "",
		map[string]any{"worker_id": widA, "provider": "claude", "account": "acct2"}); st != 200 || out["rev"] != float64(2) {
		t.Fatalf("rebind A: %d %v", st, out)
	}
	r.pastCache()
	r.call(t, credvault.Claude, credA)
	if got := r.lastAuth(); got != a2 {
		t.Fatalf("A after rebind → %q; want acct2", got)
	}
	// Only the person's own or the pool's accounts; only the issuing node.
	if st, _ := sessDo(t, r.h, http.MethodPut, "/v1/fleet/session-cred/bind", r.tok5, "",
		map[string]any{"worker_id": widA, "provider": "claude", "account": "someone-elses"}); st != http.StatusNotFound {
		t.Fatalf("bind to an unknown account → %d", st)
	}
	tok4 := r.h.tokens["m4"]
	if st, _ := sessDo(t, r.h, http.MethodPut, "/v1/fleet/session-cred/bind", tok4, "",
		map[string]any{"worker_id": widA, "provider": "claude", "account": "acct1"}); st != http.StatusNotFound {
		t.Fatalf("another node's rebind → %d", st)
	}
}

// The hub goes away (a restart): sessions the proxy already serves keep
// working on what it holds; it never needed the hub's disk or key.
func TestCredProxyRidesOutHubRestart(t *testing.T) {
	r := newCPRig(t)
	cred, _ := r.issue(t, fidA)
	if st, _ := r.call(t, credvault.Claude, cred); st != 200 {
		t.Fatal(st)
	}
	want := r.lastAuth()
	r.h.http.Close()
	r.pastCache()
	for i := 0; i < 3; i++ {
		if st, body := r.call(t, credvault.Claude, cred); st != 200 {
			t.Fatalf("hub down, request %d → %d %s", i, st, body)
		}
	}
	if got := r.lastAuth(); got != want {
		t.Fatalf("hub down: %q; want the cached %q", got, want)
	}
}

// No CCQUOTA_FLEET_CREDPROXY_TOKEN: resolve answers 503 credproxy_off; a
// wrong token is a 401, which the proxy reports as misconfigured, never as a
// refused pass.
func TestCredProxyResolveGate(t *testing.T) {
	r := newCPRig(t)
	cred, _ := r.issue(t, fidA)
	if st, _ := sessDo(t, r.h, http.MethodPost, CredProxyResolvePath, "wrong", "", map[string]any{"cred": cred, "provider": "claude"}); st != 401 {
		t.Fatalf("wrong token → %d", st)
	}
	if st, _ := sessDo(t, r.h, http.MethodPost, CredProxyResolvePath, sessVerifier, "", map[string]any{"cred": cred, "provider": "claude"}); st != 401 {
		t.Fatalf("the verifier's token → %d; resolve hands out credentials, verify does not", st)
	}
	r.h.srv.CredProxyToken = ""
	if st, out := sessDo(t, r.h, http.MethodPost, CredProxyResolvePath, cpToken, "", map[string]any{"cred": cred, "provider": "claude"}); st != 503 || out["error"] != CredProxyOff {
		t.Fatalf("off → %d %v", st, out)
	}
}
