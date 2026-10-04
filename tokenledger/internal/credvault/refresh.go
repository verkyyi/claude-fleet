package credvault

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
)

// The providers' public OAuth clients — the same ones the Claude Code and
// Codex CLIs refresh with, so a token the hub refreshes is indistinguishable
// from one the CLI refreshed itself. The endpoints live in control, because a
// relaying node picks them itself (claude-fleet#1490).
const (
	ClaudeTokenURL = control.ClaudeTokenURL
	ClaudeClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
	CodexTokenURL  = control.CodexTokenURL
	CodexClientID  = "app_EMoamEEZ73f0CkXaXp7hrann"
)

// refreshForm is the token request for provider from s: the JSON body the hub
// posts itself (HTTPRefresher) or hands an admin node to post for it
// (ProxyRefresher). One function, so the two paths can never drift.
func refreshForm(provider string, s Secret) (map[string]string, error) {
	switch provider {
	case Claude:
		return map[string]string{
			"grant_type": "refresh_token", "refresh_token": s.RefreshToken, "client_id": ClaudeClientID,
		}, nil
	case Codex:
		return map[string]string{
			"client_id": CodexClientID, "grant_type": "refresh_token", "refresh_token": s.RefreshToken,
			"scope": "openid profile email",
		}, nil
	}
	return nil, fmt.Errorf("provider %q has no refresh", provider)
}

type tokenResponse struct {
	AccessToken  string `json:"access_token"`
	RefreshToken string `json:"refresh_token"`
	IDToken      string `json:"id_token"`
	ExpiresIn    int64  `json:"expires_in"`
	Scope        string `json:"scope"`
}

// parseRefresh turns a token endpoint's answer (status + body, however it
// travelled) into the Access to issue and the Secret to keep from now on.
func parseRefresh(provider string, s Secret, status int, raw []byte, now time.Time) (Access, Secret, error) {
	if status != http.StatusOK {
		// The body names the reason (invalid_grant = the refresh token was
		// revoked or already used) and never echoes the token back.
		return Access{}, s, fmt.Errorf("token endpoint answered %d: %s", status, truncate(strings.TrimSpace(string(raw)), 200))
	}
	var tr tokenResponse
	if err := json.Unmarshal(raw, &tr); err != nil {
		return Access{}, s, fmt.Errorf("token endpoint answered unparseable JSON: %w", err)
	}
	if tr.AccessToken == "" {
		return Access{}, s, errors.New("token endpoint answered without an access_token")
	}
	next := s
	if tr.RefreshToken != "" {
		next.RefreshToken = tr.RefreshToken
	}
	switch provider {
	case Claude:
		if tr.Scope != "" {
			next.Scopes = strings.Fields(tr.Scope)
		}
		acc := Access{AccessToken: tr.AccessToken, Scopes: next.Scopes, SubscriptionType: next.SubscriptionType}
		if tr.ExpiresIn > 0 {
			t := now.Add(time.Duration(tr.ExpiresIn) * time.Second).UTC()
			acc.ExpiresAt = &t
		}
		if acc.ExpiresAt == nil {
			return Access{}, next, errors.New("claude token endpoint answered without expires_in")
		}
		return acc, next, nil
	case Codex:
		if tr.IDToken != "" {
			next.IDToken = tr.IDToken
		}
		acc := Access{AccessToken: tr.AccessToken, IDToken: next.IDToken, AccountID: next.AccountID}
		if exp := JWTExpiry(tr.AccessToken); exp != nil {
			acc.ExpiresAt = exp
		} else if tr.ExpiresIn > 0 {
			t := now.Add(time.Duration(tr.ExpiresIn) * time.Second).UTC()
			acc.ExpiresAt = &t
		}
		if acc.ExpiresAt == nil {
			return Access{}, next, errors.New("codex access token carries no expiry")
		}
		return acc, next, nil
	}
	return Access{}, s, fmt.Errorf("provider %q has no refresh", provider)
}

// HTTPRefresher refreshes against the providers' token endpoints from the
// hub's own network.
type HTTPRefresher struct {
	Client         *http.Client
	ClaudeTokenURL string // "" = ClaudeTokenURL
	CodexTokenURL  string // "" = CodexTokenURL
	Now            func() time.Time
}

func (r *HTTPRefresher) now() time.Time {
	if r.Now != nil {
		return r.Now()
	}
	return time.Now()
}

func (r *HTTPRefresher) client() *http.Client {
	if r.Client != nil {
		return r.Client
	}
	return &http.Client{Timeout: 30 * time.Second}
}

func (r *HTTPRefresher) url(provider string) string {
	switch provider {
	case Claude:
		if r.ClaudeTokenURL != "" {
			return r.ClaudeTokenURL
		}
	case Codex:
		if r.CodexTokenURL != "" {
			return r.CodexTokenURL
		}
	}
	return control.OAuthTokenURL(provider)
}

// post sends one token request and returns the status and body, whatever they
// are; the caller reads them with parseRefresh.
func (r *HTTPRefresher) post(ctx context.Context, url string, form map[string]string) (int, []byte, error) {
	b, _ := json.Marshal(form)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(b))
	if err != nil {
		return 0, nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")
	resp, err := r.client().Do(req)
	if err != nil {
		return 0, nil, err
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	return resp.StatusCode, raw, nil
}

// Refresh implements Refresher.
func (r *HTTPRefresher) Refresh(ctx context.Context, provider string, s Secret) (Access, Secret, error) {
	form, err := refreshForm(provider, s)
	if err != nil {
		return Access{}, s, err
	}
	status, raw, err := r.post(ctx, r.url(provider), form)
	if err != nil {
		return Access{}, s, err
	}
	return parseRefresh(provider, s, status, raw, r.now())
}

// --- refresh by an admin node (claude-fleet#1490) -----------------------------

// ErrRefreshUnavailable means the refresh could not be ASKED: no admin node
// was online to carry it, or the one asked never reached the token endpoint.
// It is never a provider's refusal — that comes back as its own status and
// reason — so a leasing node can tell "the relay is down" from "the account
// is dead". The leading word is what the node's log shows, by design.
var ErrRefreshUnavailable = errors.New("refresh_unavailable")

// ProxyAnswer is what a relaying node brought back from the token endpoint,
// and which node it was (for the audit row).
type ProxyAnswer struct {
	Status int
	Body   []byte
	// Via names the node, "<login>@<hostname>"; set whenever a node was
	// picked, even when the request then failed.
	Via string
}

// RefresherVia is a Refresher that can also say WHERE a refresh ran. The
// vault prefers it when its Refresher implements it, and writes the answer
// into the refresh audit row as refresh_via=<node>.
type RefresherVia interface {
	Refresher
	RefreshVia(ctx context.Context, provider string, s Secret) (Access, Secret, string, error)
}

// ProxyRefresher refreshes by handing the one token request to an admin node
// whose network the provider accepts, instead of posting it from the hub's
// own (which auth.openai.com refuses from a mainland IP, claude-fleet#1490).
// The hub still builds the request and reads the answer — the node only
// carries bytes — so what is stored and issued is exactly what HTTPRefresher
// would have stored and issued.
type ProxyRefresher struct {
	// Via posts form to provider's token endpoint from a node and returns
	// the provider's answer verbatim; an error means it could not be asked
	// (no node, timeout, the node's own network) and is reported as
	// ErrRefreshUnavailable.
	Via func(ctx context.Context, provider string, form map[string]string) (ProxyAnswer, error)
	Now func() time.Time
}

func (p *ProxyRefresher) now() time.Time {
	if p.Now != nil {
		return p.Now()
	}
	return time.Now()
}

// Refresh implements Refresher.
func (p *ProxyRefresher) Refresh(ctx context.Context, provider string, s Secret) (Access, Secret, error) {
	acc, next, _, err := p.RefreshVia(ctx, provider, s)
	return acc, next, err
}

// RefreshVia implements RefresherVia.
func (p *ProxyRefresher) RefreshVia(ctx context.Context, provider string, s Secret) (Access, Secret, string, error) {
	form, err := refreshForm(provider, s)
	if err != nil {
		return Access{}, s, "", err
	}
	if p.Via == nil {
		return Access{}, s, "", fmt.Errorf("%w: no node relay is wired to this vault", ErrRefreshUnavailable)
	}
	ans, err := p.Via(ctx, provider, form)
	if err != nil {
		if !errors.Is(err, ErrRefreshUnavailable) {
			err = fmt.Errorf("%w: %v", ErrRefreshUnavailable, err)
		}
		return Access{}, s, ans.Via, err
	}
	acc, next, err := parseRefresh(provider, s, ans.Status, ans.Body, p.now())
	return acc, next, ans.Via, err
}

// JWTExpiry reads the exp claim of a JWT without verifying it (the hub just
// received it from the issuer over TLS; it only needs the date).
func JWTExpiry(tok string) *time.Time {
	parts := strings.Split(tok, ".")
	if len(parts) != 3 {
		return nil
	}
	raw, err := base64.RawURLEncoding.DecodeString(strings.TrimRight(parts[1], "="))
	if err != nil {
		return nil
	}
	var c struct {
		Exp float64 `json:"exp"`
	}
	if json.Unmarshal(raw, &c) != nil || c.Exp <= 0 {
		return nil
	}
	t := time.Unix(int64(c.Exp), 0).UTC()
	return &t
}
