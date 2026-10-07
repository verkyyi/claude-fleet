// Package credproxy is the cluster credential proxy — 中心代理
// (claude-fleet#1973, EPIC #1967 C6).
//
// A session on an untrusted machine holds no subscription credential, only a
// hub-signed session pass (fcp-h1., C2). Its machine's own proxy (C3) sends
// its requests here, pass in Authorization; this proxy asks the hub what the
// pass is worth — still valid? whose session? bound to which account? — and
// gets the account's short-lived access token from the hub's vault lease. It
// then sends the request on with that token in place of the pass, always
// through the Singapore relay (C7), and streams the answer back. The
// credential never leaves the cluster: not to the machine, not to the relay
// (the relay sees the pass in X-Fleet-Relay and checks it with the hub).
//
//	/v1/proxy/anthropic/<path>  → <relay>/anthropic/<path>      (api.anthropic.com)
//	/v1/proxy/codex/<path>      → <relay>/chatgpt/codex/<path>  (chatgpt.com/backend-api/codex)
//
// It is stateless: no database, no vault key, nothing on disk. Each answer
// from the hub is cached ≤ CacheTTL (30 s at most) by the pass, so a
// revocation, a rebind or an account's refreshed token reaches it within
// that. When the hub cannot answer (a restart, a rollout), an answer already
// held keeps serving for up to StaleFor as long as its access token has not
// run out — a hub restart does not stop the sessions already running.
//
// Behaviour kept from the local proxy (EPIC #1967 共同约定 5): only the
// authentication is rewritten (Claude: Authorization + the oauth beta,
// x-api-key dropped; Codex: Authorization + chatgpt-account-id overwritten);
// the body passes byte for byte; the response streams chunk by chunk; a
// refusal reads the request body first; a permanent refusal (a forged /
// expired / revoked pass, no account) is a 403, which neither client retries;
// only a hub that cannot answer is a 503. Every request is one audit line —
// principal, worker_id, account, status, bytes — never a header or a body.
package credproxy

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"
)

// Providers, as the hub names them.
const (
	Claude = "claude"
	Codex  = "codex"
)

// PassPrefix marks a hub-issued session pass.
const PassPrefix = "fcp-h1."

// ResolvePath is the hub route the proxy asks (api.CredProxyResolvePath).
const ResolvePath = "/v1/fleet/credproxy/resolve"

// MaxCacheTTL bounds CacheTTL: the issue's "≤ 30 s" verify cache.
const MaxCacheTTL = 30 * time.Second

// oauthBeta is the beta Anthropic requires with an OAuth access token.
const oauthBeta = "oauth-2025-04-20"

// maxBody bounds one request body (a long conversation with images).
const maxBody = 64 << 20

// Resolution is the hub's answer for one pass + provider (api.CredProxyResolve).
type Resolution struct {
	Valid       bool       `json:"valid"`
	Reason      string     `json:"reason,omitempty"`
	Error       string     `json:"error,omitempty"`
	ID          string     `json:"id,omitempty"`
	Principal   string     `json:"principal,omitempty"`
	WorkerID    string     `json:"worker_id,omitempty"`
	Machine     string     `json:"machine,omitempty"`
	Exp         int64      `json:"exp,omitempty"`
	Provider    string     `json:"provider,omitempty"`
	Owner       string     `json:"owner,omitempty"`
	Account     string     `json:"account,omitempty"`
	BindRev     int64      `json:"bind_rev,omitempty"`
	AccessToken string     `json:"access_token,omitempty"`
	AccountID   string     `json:"account_id,omitempty"`
	ExpiresAt   *time.Time `json:"expires_at,omitempty"`
}

// ErrHubUnavailable is a resolve the hub could not answer — the proxy rides
// it out on its cache.
var ErrHubUnavailable = errors.New("hub unavailable")

// Resolver asks the hub about a pass.
type Resolver interface {
	Resolve(ctx context.Context, pass, provider string) (Resolution, error)
}

// HubResolver is the Resolver over HTTP.
type HubResolver struct {
	URL    string // the hub's base URL (in the cluster: its Service)
	Token  string // CCQUOTA_FLEET_CREDPROXY_TOKEN
	Client *http.Client
}

// Resolve posts {cred, provider} to the hub. A transport error or a 5xx is
// ErrHubUnavailable; any other non-200 is a configuration error.
func (h *HubResolver) Resolve(ctx context.Context, pass, provider string) (Resolution, error) {
	c := h.Client
	if c == nil {
		c = &http.Client{Timeout: 5 * time.Second}
	}
	body, _ := json.Marshal(map[string]string{"cred": pass, "provider": provider})
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, strings.TrimRight(h.URL, "/")+ResolvePath, bytes.NewReader(body))
	if err != nil {
		return Resolution{}, err
	}
	req.Header.Set("Authorization", "Bearer "+h.Token)
	req.Header.Set("Content-Type", "application/json")
	res, err := c.Do(req)
	if err != nil {
		return Resolution{}, fmt.Errorf("%w: %v", ErrHubUnavailable, err)
	}
	defer res.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(res.Body, 1<<20))
	if res.StatusCode >= 500 {
		return Resolution{}, fmt.Errorf("%w: %d %s", ErrHubUnavailable, res.StatusCode, firstLine(raw))
	}
	if res.StatusCode != http.StatusOK {
		return Resolution{}, fmt.Errorf("hub refused the proxy: %d %s", res.StatusCode, firstLine(raw))
	}
	var r Resolution
	if err := json.Unmarshal(raw, &r); err != nil {
		return Resolution{}, fmt.Errorf("%w: unreadable answer: %v", ErrHubUnavailable, err)
	}
	return r, nil
}

func firstLine(b []byte) string {
	s := strings.TrimSpace(string(b))
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		s = s[:i]
	}
	if len(s) > 200 {
		s = s[:200]
	}
	return s
}

// Config is a proxy.
type Config struct {
	Resolver Resolver
	// RelayURL is the Singapore relay (C7). Every request goes through it.
	RelayURL string
	// Direct sends to AnthropicURL / CodexURL instead of the relay — a test
	// seam and an operator's explicit choice, never a fallback.
	Direct       bool
	AnthropicURL string // default https://api.anthropic.com
	CodexURL     string // default https://chatgpt.com/backend-api/codex
	// CacheTTL is how long one hub answer is used (default and max 30 s).
	CacheTTL time.Duration
	// StaleFor is how long an answer may outlive CacheTTL while the hub
	// cannot answer (default 15 min; never past the access token's expiry).
	StaleFor time.Duration
	// Upstream sends the requests (default: a transport with no timeout on
	// the body — a stream lasts as long as it lasts).
	Upstream *http.Client
	// Audit receives one line per request (default: log.Print).
	Audit func(line string)
	Now   func() time.Time
}

// Proxy is the handler.
type Proxy struct {
	cfg Config

	mu    sync.Mutex
	cache map[string]*entry
}

type entry struct {
	mu  sync.Mutex // one resolve at a time per pass
	res Resolution
	at  time.Time
	ok  bool
}

// New checks cfg and returns the proxy.
func New(cfg Config) (*Proxy, error) {
	if cfg.Resolver == nil {
		return nil, errors.New("credproxy: no resolver (the hub URL and token)")
	}
	if !cfg.Direct && cfg.RelayURL == "" {
		return nil, errors.New("credproxy: no relay URL — every request goes through the Singapore relay (or say --direct)")
	}
	for _, u := range []*string{&cfg.RelayURL, &cfg.AnthropicURL, &cfg.CodexURL} {
		*u = strings.TrimRight(*u, "/")
	}
	if cfg.AnthropicURL == "" {
		cfg.AnthropicURL = "https://api.anthropic.com"
	}
	if cfg.CodexURL == "" {
		cfg.CodexURL = "https://chatgpt.com/backend-api/codex"
	}
	if cfg.CacheTTL <= 0 || cfg.CacheTTL > MaxCacheTTL {
		cfg.CacheTTL = MaxCacheTTL
	}
	if cfg.StaleFor <= 0 {
		cfg.StaleFor = 15 * time.Minute
	}
	if cfg.Upstream == nil {
		cfg.Upstream = &http.Client{Transport: &http.Transport{
			Proxy:                 nil,
			DialContext:           (&net.Dialer{Timeout: 10 * time.Second, KeepAlive: 30 * time.Second}).DialContext,
			TLSHandshakeTimeout:   10 * time.Second,
			ResponseHeaderTimeout: 10 * time.Minute,
			MaxIdleConnsPerHost:   32,
			IdleConnTimeout:       90 * time.Second,
			ForceAttemptHTTP2:     true,
			DisableCompression:    true, // bytes pass as the upstream sent them
		}}
	}
	if cfg.Audit == nil {
		cfg.Audit = func(l string) { log.Print(l) }
	}
	if cfg.Now == nil {
		cfg.Now = time.Now
	}
	return &Proxy{cfg: cfg, cache: map[string]*entry{}}, nil
}

// Handler mounts the proxy routes and /healthz (which never asks the hub).
func (p *Proxy) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) { _, _ = io.WriteString(w, "ok\n") })
	mux.HandleFunc("/v1/proxy/anthropic/", func(w http.ResponseWriter, r *http.Request) { p.serve(w, r, Claude) })
	mux.HandleFunc("/v1/proxy/codex/", func(w http.ResponseWriter, r *http.Request) { p.serve(w, r, Codex) })
	return mux
}

// resolve answers from the cache, the hub, or — when the hub cannot answer —
// a stale answer still worth using. stale says which.
func (p *Proxy) resolve(ctx context.Context, pass, provider string) (res Resolution, stale bool, err error) {
	sum := sha256.Sum256([]byte(provider + "\x00" + pass))
	key := hex.EncodeToString(sum[:])
	now := p.cfg.Now()
	p.mu.Lock()
	e := p.cache[key]
	if e == nil {
		e = &entry{}
		p.cache[key] = e
	}
	p.mu.Unlock()

	e.mu.Lock()
	defer e.mu.Unlock()
	if e.ok && now.Sub(e.at) < p.cfg.CacheTTL && !now.Before(e.at) {
		return e.res, false, nil
	}
	r, err := p.cfg.Resolver.Resolve(ctx, pass, provider)
	if err == nil {
		e.res, e.at, e.ok = r, now, true
		p.sweep(now)
		return r, false, nil
	}
	if errors.Is(err, ErrHubUnavailable) && e.ok && e.res.Valid && now.Sub(e.at) < p.cfg.CacheTTL+p.cfg.StaleFor &&
		(e.res.ExpiresAt == nil || e.res.ExpiresAt.After(now)) && (e.res.Exp == 0 || time.Unix(e.res.Exp, 0).After(now)) {
		return e.res, true, nil
	}
	if !e.ok {
		p.mu.Lock()
		delete(p.cache, key)
		p.mu.Unlock()
	}
	return Resolution{}, false, err
}

// sweep drops answers too old to serve even stale.
func (p *Proxy) sweep(now time.Time) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if len(p.cache) < 256 {
		return
	}
	for k, e := range p.cache {
		if e.mu.TryLock() {
			if e.ok && now.Sub(e.at) > p.cfg.CacheTTL+p.cfg.StaleFor {
				delete(p.cache, k)
			}
			e.mu.Unlock()
		}
	}
}

// hop-by-hop headers, and what a hop through the cluster's front door adds.
var dropAlways = map[string]bool{
	"connection": true, "keep-alive": true, "proxy-connection": true, "transfer-encoding": true,
	"te": true, "trailer": true, "upgrade": true, "host": true, "content-length": true,
	"proxy-authorization": true, "authorization": true, "x-api-key": true, "cookie": true,
	"x-fleet-relay": true, "x-forwarded-for": true, "x-forwarded-host": true, "x-forwarded-proto": true,
	"x-forwarded-port": true, "x-forwarded-scheme": true, "x-real-ip": true, "x-original-forwarded-for": true,
	"x-scheme": true, "x-request-id": true, "forwarded": true,
}

func (p *Proxy) serve(w http.ResponseWriter, r *http.Request, provider string) {
	t0 := p.cfg.Now()
	a := audit{provider: provider, method: r.Method}
	defer func() {
		a.ms = p.cfg.Now().Sub(t0).Milliseconds()
		p.cfg.Audit(a.line())
	}()
	// Read the body FIRST: a refusal that leaves it unread on a keep-alive
	// connection gets it parsed as the next request (issue #1912).
	body, err := io.ReadAll(io.LimitReader(r.Body, maxBody+1))
	a.in = int64(len(body))
	if err != nil {
		a.status, a.why = refuse(w, provider, http.StatusBadRequest, "invalid_request_error", "could not read the request body")
		return
	}
	if len(body) > maxBody {
		a.status, a.why = refuse(w, provider, http.StatusRequestEntityTooLarge, "invalid_request_error", "request body too large")
		return
	}
	pass := ""
	if h := r.Header.Get("Authorization"); len(h) > 7 && strings.EqualFold(h[:7], "bearer ") {
		pass = strings.TrimSpace(h[7:])
	}
	if pass == "" {
		pass = strings.TrimSpace(r.Header.Get("X-Api-Key"))
	}
	if !strings.HasPrefix(pass, PassPrefix) {
		a.status, a.why = refuse(w, provider, http.StatusForbidden, "permission_error",
			"the cluster credential proxy takes a hub session pass (fcp-h1.) only")
		return
	}
	res, stale, err := p.resolve(r.Context(), pass, provider)
	a.stale = stale
	if err != nil {
		if errors.Is(err, ErrHubUnavailable) {
			a.status, a.why = refuse(w, provider, http.StatusServiceUnavailable, "api_error", "the hub cannot check this pass right now; retry")
		} else {
			a.status, a.why = refuse(w, provider, http.StatusBadGateway, "api_error", "the credential proxy is misconfigured")
			log.Printf("credproxy: resolve: %v", err)
		}
		return
	}
	a.principal, a.worker, a.pass = res.Principal, res.WorkerID, res.ID
	if !res.Valid {
		msg := "session pass refused: " + res.Reason
		if res.Error == "no_credential" {
			msg = "no subscription account for this session: " + res.Reason
		}
		a.status, _ = refuse(w, provider, http.StatusForbidden, "permission_error", msg)
		a.why = res.Reason
		return
	}
	a.account = res.Account
	if res.Owner != "" && res.Owner != res.Principal {
		a.account = res.Owner + "/" + res.Account
	}
	if res.AccessToken == "" {
		a.status, a.why = refuse(w, provider, http.StatusForbidden, "permission_error", "no access token for account "+res.Account)
		return
	}

	target, route := p.target(provider, r.URL)
	a.route = route
	out, err := http.NewRequestWithContext(r.Context(), r.Method, target, bytes.NewReader(body))
	if err != nil {
		a.status, a.why = refuse(w, provider, http.StatusBadRequest, "invalid_request_error", "bad request path")
		return
	}
	out.ContentLength = int64(len(body))
	if len(body) == 0 {
		out.Body = http.NoBody
	}
	var betas []string
	for k, vs := range r.Header {
		lk := strings.ToLower(k)
		if dropAlways[lk] || (provider == Codex && lk == "chatgpt-account-id") {
			continue
		}
		if provider == Claude && lk == "anthropic-beta" {
			for _, v := range vs {
				for _, b := range strings.Split(v, ",") {
					if b = strings.TrimSpace(b); b != "" {
						betas = append(betas, b)
					}
				}
			}
			continue
		}
		out.Header[k] = vs
	}
	out.Header.Set("Authorization", "Bearer "+res.AccessToken)
	if provider == Claude {
		if !contains(betas, oauthBeta) {
			betas = append(betas, oauthBeta)
		}
		out.Header.Set("Anthropic-Beta", strings.Join(betas, ","))
	}
	if provider == Codex && res.AccountID != "" {
		// ALWAYS the bound account's: a session never picks its workspace (#1912)
		out.Header.Set("Chatgpt-Account-Id", res.AccountID)
	}
	if route == "relay" {
		// the relay's forward_auth checks the pass with the hub (C7); it
		// never sees the credential, which rides inside TLS to the provider
		out.Header.Set("X-Fleet-Relay", pass)
	}
	resp, err := p.cfg.Upstream.Do(out)
	if err != nil {
		if r.Context().Err() != nil {
			a.status, a.why = 499, "client gone"
			return
		}
		a.status, _ = refuse(w, provider, http.StatusBadGateway, "api_error", "upstream ("+route+") unreachable")
		a.why = "upstream: " + errClass(err)
		return
	}
	defer resp.Body.Close()
	for k, vs := range resp.Header {
		lk := strings.ToLower(k)
		if lk == "connection" || lk == "keep-alive" || lk == "transfer-encoding" || lk == "trailer" ||
			lk == "upgrade" || lk == "proxy-connection" || lk == "te" {
			continue
		}
		w.Header()[k] = vs
	}
	w.WriteHeader(resp.StatusCode)
	a.status = resp.StatusCode
	a.out = stream(w, resp.Body)
}

// target is where a request goes, and by which road.
func (p *Proxy) target(provider string, u *url.URL) (string, string) {
	pfx := map[string]string{Claude: "/v1/proxy/anthropic", Codex: "/v1/proxy/codex"}[provider]
	rest := strings.TrimPrefix(u.EscapedPath(), pfx)
	base, route := "", "relay"
	switch {
	case p.cfg.Direct && provider == Claude:
		base, route = p.cfg.AnthropicURL, "direct"
	case p.cfg.Direct:
		base, route = p.cfg.CodexURL, "direct"
	case provider == Claude:
		base = p.cfg.RelayURL + "/anthropic"
	default:
		base = p.cfg.RelayURL + "/chatgpt/codex"
	}
	t := base + rest
	if u.RawQuery != "" {
		t += "?" + u.RawQuery
	}
	return t, route
}

// stream copies the response chunk by chunk, flushing each one.
func stream(w http.ResponseWriter, body io.Reader) int64 {
	f, _ := w.(http.Flusher)
	buf := make([]byte, 32<<10)
	var n int64
	for {
		k, err := body.Read(buf)
		if k > 0 {
			if _, werr := w.Write(buf[:k]); werr != nil {
				return n
			}
			n += int64(k)
			if f != nil {
				f.Flush()
			}
		}
		if err != nil {
			return n
		}
	}
}

// refuse answers in the provider's own error shape.
func refuse(w http.ResponseWriter, provider string, code int, typ, msg string) (int, string) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(code)
	var v any
	if provider == Codex {
		v = map[string]any{"error": map[string]string{"type": typ, "code": typ, "message": msg}}
	} else {
		v = map[string]any{"type": "error", "error": map[string]string{"type": typ, "message": msg}}
	}
	_ = json.NewEncoder(w).Encode(v)
	return code, msg
}

func contains(l []string, s string) bool {
	for _, x := range l {
		if x == s {
			return true
		}
	}
	return false
}

func errClass(err error) string {
	var ne net.Error
	switch {
	case errors.As(err, &ne) && ne.Timeout():
		return "timeout"
	case errors.Is(err, context.Canceled):
		return "canceled"
	}
	var oe *net.OpError
	if errors.As(err, &oe) {
		return oe.Op
	}
	return "error"
}

// audit is one request's line: who, which account, what happened — never a
// header, a pass, a token or a body.
type audit struct {
	provider, method, route string
	principal, worker, pass string
	account, why            string
	status                  int
	in, out, ms             int64
	stale                   bool
}

func (a audit) line() string {
	b, _ := json.Marshal(map[string]any{
		"ev": "credproxy", "provider": a.provider, "m": a.method, "route": a.route,
		"principal": a.principal, "worker_id": a.worker, "pass": a.pass, "account": a.account,
		"status": a.status, "bytes_in": a.in, "bytes_out": a.out, "ms": a.ms, "stale": a.stale,
		"why": a.why,
	})
	return string(b)
}
