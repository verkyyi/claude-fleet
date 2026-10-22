package api

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/credvault"
	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/codex"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/limits"
)

const (
	AdminSubsLoginPath   = "/v1/admin/subscriptions/login"
	AdminSubsFinishPath  = "/v1/admin/subscriptions/login/finish"
	AdminSubsTokenPath   = "/v1/admin/subscriptions/token"
	AdminSubsRefreshPath = "/v1/admin/subscriptions/refresh"
	adminSubPurpose      = "admin-pool-login"
)

// All mounts are viewerOnly + adminOnly. The actor seals the flow; its owner
// is always pool. No request argument can select another owner or purpose.
func (s *Server) adminSubRequest(w http.ResponseWriter, r *http.Request, dst any) bool {
	w.Header().Set("Cache-Control", "no-store")
	if r.Method != http.MethodPost {
		httpError(w, 405, "POST only")
		return false
	}
	if s.vaultOff(w) || s.vaultLocked(w) {
		return false
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 32<<10)).Decode(dst); err != nil {
		httpError(w, 400, "请求格式不正确")
		return false
	}
	return true
}

func validAdminSub(provider, account string) bool {
	return (provider == credvault.Claude || provider == credvault.Codex) && validAccountLabel(account)
}

func (s *Server) handleAdminSubsLogin(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Provider string `json:"provider"`
		Account  string `json:"account"`
		Again    bool   `json:"again"`
	}
	if !s.adminSubRequest(w, r, &req) {
		return
	}
	if !validAdminSub(req.Provider, req.Account) {
		httpError(w, 400, "请选择服务并填写有效名称")
		return
	}
	if s.OAuthExchange == nil {
		httpError(w, 503, "授权服务暂不可用，请稍后重试")
		return
	}
	_, err := s.Store.Credential(store.PoolPrincipal, req.Provider, req.Account)
	if err != nil && !errors.Is(err, store.ErrNoCredential) {
		httpError(w, 500, "无法读取订阅")
		return
	}
	if err == nil && !req.Again {
		httpError(w, 409, "同名订阅已存在，请从详情选择更新凭据")
		return
	}
	if err != nil && req.Again {
		httpError(w, 404, "待更新订阅不存在")
		return
	}
	note := meSubLogin{Provider: req.Provider, Account: req.Account, Again: req.Again, Verifier: randURL(32), State: randURL(16), Expires: time.Now().Add(meSubLoginTTL).UTC()}
	blob, err := s.Vault.SealNote(note, actorOf(r), adminSubPurpose)
	if err != nil {
		httpError(w, 503, "暂时无法开始授权，请重试")
		return
	}
	auth, paste := subAuthorizeURL(note)
	writeJSON(w, 200, map[string]any{"flow": base64.RawURLEncoding.EncodeToString(blob), "authorize_url": auth, "paste": paste, "expires_at": note.Expires})
}

func (s *Server) handleAdminSubsFinish(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Flow  string `json:"flow"`
		Paste string `json:"paste"`
	}
	if !s.adminSubRequest(w, r, &req) {
		return
	}
	blob, err := base64.RawURLEncoding.DecodeString(req.Flow)
	var note meSubLogin
	if err != nil || s.Vault.OpenNote(blob, &note, actorOf(r), adminSubPurpose) != nil || time.Now().After(note.Expires) || !validAdminSub(note.Provider, note.Account) {
		httpError(w, 410, "授权已过期或不属于本次登录，请重新授权")
		return
	}
	code, err := pastedCode(note.Provider, req.Paste, note.State)
	if err != nil {
		httpError(w, 422, "授权码不匹配，请使用本次授权页面给出的完整代码")
		return
	}
	if s.OAuthExchange == nil {
		httpError(w, 503, "授权服务暂不可用，请重试")
		return
	}
	// Atomic in the shared DB, so a flow cannot be replayed on another replica.
	used, err := s.Store.SpendPoolLogin(note.State, note.Expires, time.Now())
	if err != nil {
		httpError(w, 503, "无法校验授权状态，请重试")
		return
	}
	if !used {
		httpError(w, 410, "本次授权已使用，请重新授权")
		return
	}
	form := map[string]string{"grant_type": "authorization_code", "code": code, "code_verifier": note.Verifier}
	enc := ""
	if note.Provider == credvault.Claude {
		form["client_id"], form["redirect_uri"], form["state"] = credvault.ClaudeClientID, claudeCodeRedirect, note.State
	} else {
		form["client_id"], form["redirect_uri"], enc = credvault.CodexClientID, codexRedirect, control.OAuthEncodingForm
	}
	status, raw, err := s.OAuthExchange(r.Context(), note.Provider, form, enc)
	if err != nil || status >= 500 {
		httpError(w, 502, "授权服务连接中断，请重新授权后重试")
		return
	}
	var ans tokenAnswer
	if status != 200 || json.Unmarshal(raw, &ans) != nil || ans.AccessToken == "" || ans.RefreshToken == "" {
		httpError(w, 422, "授权码无效或过期，请重新授权")
		return
	}
	sec := credvault.Secret{RefreshToken: ans.RefreshToken, Scopes: strings.Fields(ans.Scope)}
	acc := credvault.Access{AccessToken: ans.AccessToken, Scopes: sec.Scopes}
	if ans.ExpiresIn > 0 {
		exp := time.Now().Add(time.Duration(ans.ExpiresIn) * time.Second).UTC()
		acc.ExpiresAt = &exp
	}
	if note.Provider == credvault.Claude {
		sec.AccountUUID = ans.Account.UUID
	} else {
		sec.IDToken, sec.AccountID, sec.SubscriptionType = ans.IDToken, codex.AccountIDFromIDToken(ans.IDToken), codex.PlanFromIDToken(ans.IDToken)
		acc.IDToken, acc.AccountID, acc.SubscriptionType = sec.IDToken, sec.AccountID, sec.SubscriptionType
		if acc.ExpiresAt == nil {
			acc.ExpiresAt = credvault.JWTExpiry(ans.AccessToken)
		}
	}
	c, duplicate, err := s.Vault.ImportBrowser(r.Context(), store.PoolPrincipal, note.Provider, note.Account, ans.RefreshToken, note.Again,
		func() (credvault.Secret, credvault.Access, error) { return sec, acc, sec.Validate(note.Provider) })
	s.adminSubSaved(w, r, c, duplicate, err)
}

var errAdminTokenInvalid = errors.New("invalid OAuth token")
var errAdminTokenNetwork = errors.New("OAuth validation unavailable")

// statusTransport observes only HTTP status, never the request's bearer or body.
type subStatusTransport struct {
	base         http.RoundTripper
	status       int
	relayRefused bool
}

func (t *subStatusTransport) RoundTrip(r *http.Request) (*http.Response, error) {
	resp, err := t.base.RoundTrip(r)
	if resp != nil {
		t.status = resp.StatusCode
		if resp.StatusCode == 403 {
			body, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
			resp.Body.Close()
			resp.Body = io.NopCloser(bytes.NewReader(body))
			t.relayRefused = bytes.Contains(body, []byte("relay_refused"))
		}
	}
	return resp, err
}

func (s *Server) validateAdminToken(ctx context.Context, provider, token string) (credvault.Secret, credvault.Access, error) {
	if provider == credvault.Codex {
		if s.Vault.Refresher == nil {
			return credvault.Secret{}, credvault.Access{}, errAdminTokenNetwork
		}
		acc, sec, err := s.Vault.Refresher.Refresh(ctx, provider, credvault.Secret{RefreshToken: token})
		if err != nil {
			var refusal *credvault.ProviderRefusal
			if errors.As(err, &refusal) && refusal.Status < 500 {
				return sec, acc, errAdminTokenInvalid
			}
			return sec, acc, errAdminTokenNetwork
		}
		if sec.AccountID == "" {
			sec.AccountID = codex.AccountIDFromIDToken(sec.IDToken)
		}
		if sec.SubscriptionType == "" {
			sec.SubscriptionType = codex.PlanFromIDToken(sec.IDToken)
		}
		acc.AccountID, acc.SubscriptionType = sec.AccountID, sec.SubscriptionType
		if acc.AccessToken == "" || sec.AccountID == "" {
			return sec, acc, errAdminTokenInvalid
		}
		return sec, acc, nil
	}
	sec := credvault.Secret{SetupToken: token}
	if sec.Validate(provider) != nil {
		return sec, credvault.Access{}, errAdminTokenInvalid
	}
	if s.HubQuota == nil {
		return sec, credvault.Access{}, errAdminTokenNetwork
	}
	client := *s.HubQuota.client()
	transport := client.Transport
	if transport == nil {
		transport = http.DefaultTransport
	}
	capture := &subStatusTransport{base: transport}
	client.Transport = capture
	probe := &limits.Client{HTTP: &client, MessagesURL: strings.TrimRight(s.HubQuota.RelayURL, "/") + hubQuotaClaudePath, Decorate: s.hubQuotaDecorate}
	_, _ = probe.FetchViaInference(ctx, token)
	switch capture.status {
	case 200, 429:
		return sec, credvault.Access{}, nil // valid even when quota headers are absent
	case 403:
		if capture.relayRefused {
			return sec, credvault.Access{}, errAdminTokenNetwork
		}
		return sec, credvault.Access{}, errAdminTokenInvalid
	case 401:
		return sec, credvault.Access{}, errAdminTokenInvalid
	default:
		return sec, credvault.Access{}, errAdminTokenNetwork // includes relay refusal; never label it an invalid token
	}
}

func (s *Server) handleAdminSubsToken(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Provider string `json:"provider"`
		Account  string `json:"account"`
		Token    string `json:"token"`
		Again    bool   `json:"again"`
	}
	if !s.adminSubRequest(w, r, &req) {
		return
	}
	req.Token = strings.TrimSpace(req.Token)
	if !validAdminSub(req.Provider, req.Account) || req.Token == "" {
		httpError(w, 400, "请选择服务、填写名称与 OAuth Token")
		return
	}
	c, duplicate, err := s.Vault.ImportBrowser(r.Context(), store.PoolPrincipal, req.Provider, req.Account, req.Token, req.Again,
		func() (credvault.Secret, credvault.Access, error) {
			return s.validateAdminToken(r.Context(), req.Provider, req.Token)
		})
	s.adminSubSaved(w, r, c, duplicate, err)
}

func (s *Server) adminSubSaved(w http.ResponseWriter, r *http.Request, c *store.Credential, duplicate bool, err error) {
	switch {
	case errors.Is(err, credvault.ErrImportExists):
		httpError(w, 409, "同名或相同凭据订阅已存在，请从详情选择更新凭据")
		return
	case errors.Is(err, credvault.ErrImportMissing):
		httpError(w, 404, "待更新订阅不存在")
		return
	case errors.Is(err, errAdminTokenInvalid):
		httpError(w, 422, "OAuth Token 无效或已失效")
		return
	case err != nil:
		httpError(w, 502, "暂时无法验证或保存凭据，请稍后重试")
		return
	}
	if !duplicate {
		_ = s.Store.AddCredAudit(store.CredAudit{Action: store.CredPut, PrincipalID: store.PoolPrincipal, Provider: c.Provider, Account: c.Account, Detail: "admin browser connection · by " + actorOf(r)})
		s.BroadcastCreds("pool subscription connected")
	}
	s.adminSubAnswer(w, r, *c, duplicate)
}

func (s *Server) adminSubAnswer(w http.ResponseWriter, r *http.Request, c store.Credential, duplicate bool) {
	quota := "pending"
	if s.HubQuota != nil {
		ctx, cancel := context.WithTimeout(r.Context(), 45*time.Second)
		read := s.readHubQuotaOne(ctx, c)
		cancel()
		s.HubQuota.record(read)
		s.hubQuotaOutcome(read, s.HubQuota.now())
		if read.OK {
			quota = "ready"
		}
	}
	writeJSON(w, 200, map[string]any{"provider": c.Provider, "account": c.Account, "owner": store.PoolPrincipal, "quota": quota, "duplicate": duplicate})
}

func (s *Server) handleAdminSubsRefresh(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Provider string `json:"provider"`
		Account  string `json:"account"`
	}
	if !s.adminSubRequest(w, r, &req) {
		return
	}
	if !validAdminSub(req.Provider, req.Account) {
		httpError(w, 400, "无效订阅")
		return
	}
	c, err := s.Store.Credential(store.PoolPrincipal, req.Provider, req.Account)
	if err != nil {
		httpError(w, 404, "订阅不存在")
		return
	}
	s.adminSubAnswer(w, r, *c, false)
}
