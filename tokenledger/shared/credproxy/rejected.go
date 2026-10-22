package credproxy

import (
	"bytes"
	"compress/gzip"
	"compress/zlib"
	"context"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"

	"github.com/verkyyi/claude-fleet/tokenledger/shared/codex"
)

type AccessRejection struct {
	Owner       string `json:"owner"`
	Account     string `json:"account"`
	Fingerprint string `json:"fingerprint"`
	Code        string `json:"code"`
}

func (rejection AccessRejection) Valid() bool {
	fingerprint, err := hex.DecodeString(rejection.Fingerprint)
	return err == nil && len(fingerprint) == 32 && rejection.Owner != "" && rejection.Account != "" && accessRejectedCode(rejection.Code)
}

type ResolveRequest struct {
	// Set only before a NEW request is sent, never by an auth-error refresh.
	RequestBoundary bool             `json:"request_boundary,omitempty"`
	Cred            string           `json:"cred"`
	Provider        string           `json:"provider"`
	Rejected        *AccessRejection `json:"rejected,omitempty"`
}

type AccessRejecter interface {
	RejectAccess(context.Context, string, string, Resolution, string) (Resolution, error)
}

func (h *HubResolver) RejectAccess(ctx context.Context, pass, provider string, previous Resolution, code string) (Resolution, error) {
	return h.resolveRequest(ctx, ResolveRequest{Cred: pass, Provider: provider, Rejected: &AccessRejection{
		Owner: previous.Owner, Account: previous.Account, Fingerprint: codex.AccessFingerprint(previous.AccessToken), Code: code,
	}})
}

func accessRejectedCode(code string) bool {
	switch code {
	case "token_expired", "token_revoked", "token_invalidated", "invalid_token":
		return true
	}
	return false
}

func (p *Proxy) forgetAccess(provider string, previous Resolution) {
	p.mu.Lock()
	entries := make([]*entry, 0, len(p.cache))
	for _, cached := range p.cache {
		entries = append(entries, cached)
	}
	p.mu.Unlock()
	for _, cached := range entries {
		cached.mu.Lock()
		if cached.res.Provider == provider && cached.res.Owner == previous.Owner && cached.res.Account == previous.Account && cached.res.AccessToken == previous.AccessToken {
			cached.ok = false
		}
		cached.mu.Unlock()
	}
}

func (p *Proxy) refreshRejected(ctx context.Context, response *http.Response, pass, provider string, resolved *Resolution,
	send func(Resolution) (*http.Response, error)) *http.Response {
	rejecter, supported := p.cfg.Resolver.(AccessRejecter)
	if !supported {
		return response
	}
	original := response.Body
	body, err := io.ReadAll(io.LimitReader(original, 64<<10))
	response.Body = struct {
		io.Reader
		io.Closer
	}{io.MultiReader(bytes.NewReader(body), original), original}
	if err != nil {
		return response
	}
	var decoded io.ReadCloser
	switch response.Header.Get("Content-Encoding") {
	case "", "identity":
	case "gzip":
		decoded, err = gzip.NewReader(bytes.NewReader(body))
	case "deflate":
		decoded, err = zlib.NewReader(bytes.NewReader(body))
	default:
		return response
	}
	if err != nil {
		return response
	}
	if decoded != nil {
		body, err = io.ReadAll(io.LimitReader(decoded, 64<<10))
		_ = decoded.Close()
	}
	var refusal struct {
		Error struct {
			Code string `json:"code"`
		} `json:"error"`
	}
	if err != nil || json.Unmarshal(body, &refusal) != nil || !accessRejectedCode(refusal.Error.Code) {
		return response
	}
	p.forgetAccess(provider, *resolved)
	refreshed, err := rejecter.RejectAccess(ctx, pass, provider, *resolved, refusal.Error.Code)
	if err != nil || !refreshed.Valid || refreshed.AccessToken == "" || refreshed.AccessToken == resolved.AccessToken {
		return response
	}
	p.remember(pass, provider, refreshed)
	if refreshed.Owner != resolved.Owner || refreshed.Account != resolved.Account {
		// An authorization change may have replaced the binding while the
		// refusal was handled. Never replay this body on another account.
		return response
	}
	again, err := send(refreshed)
	if err != nil {
		return response
	}
	_ = original.Close()
	*resolved = refreshed
	return again
}
