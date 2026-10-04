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
)

// The providers' public OAuth clients — the same ones the Claude Code and
// Codex CLIs refresh with, so a token the hub refreshes is indistinguishable
// from one the CLI refreshed itself.
const (
	ClaudeTokenURL = "https://platform.claude.com/v1/oauth/token"
	ClaudeClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
	CodexTokenURL  = "https://auth.openai.com/oauth/token"
	CodexClientID  = "app_EMoamEEZ73f0CkXaXp7hrann"
)

// HTTPRefresher refreshes against the providers' token endpoints.
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

type tokenResponse struct {
	AccessToken  string `json:"access_token"`
	RefreshToken string `json:"refresh_token"`
	IDToken      string `json:"id_token"`
	ExpiresIn    int64  `json:"expires_in"`
	Scope        string `json:"scope"`
}

func (r *HTTPRefresher) post(ctx context.Context, url string, body map[string]string) (tokenResponse, error) {
	var tr tokenResponse
	b, _ := json.Marshal(body)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(b))
	if err != nil {
		return tr, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")
	resp, err := r.client().Do(req)
	if err != nil {
		return tr, err
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if resp.StatusCode != http.StatusOK {
		// The body names the reason (invalid_grant = the refresh token was
		// revoked or already used) and never echoes the token back.
		return tr, fmt.Errorf("token endpoint answered %d: %s", resp.StatusCode, truncate(strings.TrimSpace(string(raw)), 200))
	}
	if err := json.Unmarshal(raw, &tr); err != nil {
		return tr, fmt.Errorf("token endpoint answered unparseable JSON: %w", err)
	}
	if tr.AccessToken == "" {
		return tr, errors.New("token endpoint answered without an access_token")
	}
	return tr, nil
}

// Refresh implements Refresher.
func (r *HTTPRefresher) Refresh(ctx context.Context, provider string, s Secret) (Access, Secret, error) {
	switch provider {
	case Claude:
		url := r.ClaudeTokenURL
		if url == "" {
			url = ClaudeTokenURL
		}
		tr, err := r.post(ctx, url, map[string]string{
			"grant_type": "refresh_token", "refresh_token": s.RefreshToken, "client_id": ClaudeClientID,
		})
		if err != nil {
			return Access{}, s, err
		}
		next := s
		if tr.RefreshToken != "" {
			next.RefreshToken = tr.RefreshToken
		}
		if tr.Scope != "" {
			next.Scopes = strings.Fields(tr.Scope)
		}
		acc := Access{AccessToken: tr.AccessToken, Scopes: next.Scopes, SubscriptionType: next.SubscriptionType}
		if tr.ExpiresIn > 0 {
			t := r.now().Add(time.Duration(tr.ExpiresIn) * time.Second).UTC()
			acc.ExpiresAt = &t
		}
		if acc.ExpiresAt == nil {
			return Access{}, next, errors.New("claude token endpoint answered without expires_in")
		}
		return acc, next, nil

	case Codex:
		url := r.CodexTokenURL
		if url == "" {
			url = CodexTokenURL
		}
		tr, err := r.post(ctx, url, map[string]string{
			"client_id": CodexClientID, "grant_type": "refresh_token", "refresh_token": s.RefreshToken,
			"scope": "openid profile email",
		})
		if err != nil {
			return Access{}, s, err
		}
		next := s
		if tr.RefreshToken != "" {
			next.RefreshToken = tr.RefreshToken
		}
		if tr.IDToken != "" {
			next.IDToken = tr.IDToken
		}
		acc := Access{AccessToken: tr.AccessToken, IDToken: next.IDToken, AccountID: next.AccountID}
		if exp := JWTExpiry(tr.AccessToken); exp != nil {
			acc.ExpiresAt = exp
		} else if tr.ExpiresIn > 0 {
			t := r.now().Add(time.Duration(tr.ExpiresIn) * time.Second).UTC()
			acc.ExpiresAt = &t
		}
		if acc.ExpiresAt == nil {
			return Access{}, next, errors.New("codex access token carries no expiry")
		}
		return acc, next, nil
	}
	return Access{}, s, fmt.Errorf("provider %q has no refresh", provider)
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
