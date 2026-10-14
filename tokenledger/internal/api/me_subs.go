package api

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"sort"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/codex"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/credvault"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// 我自己的订阅 (EPIC #3923 C21, claude-fleet#4035): a member connects a
// Claude or ChatGPT subscription of their OWN, signed in in their own browser,
// and it is theirs alone. Before it the site said 「接上你们自己的订阅」 and a
// person had to book a time for an admin to run `fleet account add` on a node.
//
// Only the caller's own rows, ever: every route reads principalOf(ctx) and no
// argument names a person, so another member's subscription is a 404 the same
// as one that does not exist. The credential is stored under the member's
// principal — the lease (fleet_creds.go) and the central proxy
// (sessionBindChoices) read only «own + pool» rows, so no one else's session
// can be handed it; in strict mode its ID joins the member's allowlist and
// their own machines' (it is only ever leased to them there).
//
// The sign-in is the providers' own PKCE flow, the one their CLIs run: the hub
// mints the verifier and the official authorize URL, the person signs in on
// the provider's page in their own browser (the password never reaches us) and
// pastes back what it hands them — Claude shows a code, ChatGPT redirects to a
// localhost page that does not load, whose address carries the code. The
// verifier rides the browser sealed to the person (Vault.SealNote), so any
// replica can finish and no table holds a half-done login. The exchange goes
// out the way refreshes do (Server.OAuthExchange): through an admin node's
// relay when the hub's own egress is refused (decided on #4035 — the node still
// posts only to the provider's token endpoint it picks itself).

// The routes.
const (
	MeSubsPath       = "/v1/me/subscriptions"
	MeSubsLoginPath  = "/v1/me/subscriptions/login"
	MeSubsFinishPath = "/v1/me/subscriptions/login/finish"
	MeSubsPausePath  = "/v1/me/subscriptions/pause"
	MeSubsDeletePath = "/v1/me/subscriptions/delete"
)

// OwnPausedPrefix makes own.paused.<principal>/<provider>/<account>: a
// member's own subscription they paused — "on", or no row. Leased flagged
// paused like a paused pool row (a node starts no new session on it) and never
// chosen by the central proxy.
const OwnPausedPrefix = "own.paused."

func ownPausedKey(principal, provider, account string) string {
	return OwnPausedPrefix + principal + "/" + provider + "/" + account
}

// ownPaused says whether c is a member's own row its owner paused.
func ownPaused(settings map[string]string, c store.Credential) bool {
	return c.PrincipalID != store.PoolPrincipal && strings.EqualFold(settings[ownPausedKey(c.PrincipalID, c.Provider, c.Account)], "on")
}

// The providers' own sign-in, as their CLIs run it: Claude Code's
// claude.ai login (its manual-code redirect), Codex's ChatGPT login.
const (
	claudeAuthorizeURL = "https://claude.ai/oauth/authorize"
	claudeCodeRedirect = "https://platform.claude.com/oauth/code/callback"
	claudeLoginScope   = "user:profile user:inference user:sessions:claude_code"
	codexAuthorizeURL  = "https://auth.openai.com/oauth/authorize"
	codexRedirect      = "http://localhost:1455/auth/callback"
	codexLoginScope    = "openid profile email offline_access"

	meSubLoginTTL  = 10 * time.Minute
	meSubLoginNote = "me-sub-login"
	// meSubNear is 「快满」 on the member's card: a window at or past it.
	meSubNear = 80
)

// OAuthExchangeFunc posts one sign-in's token request (an
// authorization_code exchange) for provider and returns the provider's status
// and body. encoding is control.OAuthRefresh.Encoding.
type OAuthExchangeFunc func(ctx context.Context, provider string, form map[string]string, encoding string) (int, []byte, error)

// DirectOAuthExchange posts from the hub's own network to the provider's token
// endpoint (urls overrides one, for a fake provider) — the exchange when
// refreshes are direct too.
func DirectOAuthExchange(urls map[string]string) OAuthExchangeFunc {
	client := &http.Client{Timeout: 20 * time.Second}
	return func(ctx context.Context, provider string, form map[string]string, encoding string) (int, []byte, error) {
		endpoint := urls[provider]
		if endpoint == "" {
			endpoint = control.OAuthTokenURL(provider)
		}
		if endpoint == "" {
			return 0, nil, fmt.Errorf("no token endpoint for %q", provider)
		}
		var body []byte
		ctype := "application/json"
		if encoding == control.OAuthEncodingForm {
			v := url.Values{}
			for k, x := range form {
				v.Set(k, x)
			}
			body, ctype = []byte(v.Encode()), "application/x-www-form-urlencoded"
		} else {
			body, _ = json.Marshal(form)
		}
		req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(body))
		if err != nil {
			return 0, nil, err
		}
		req.Header.Set("Content-Type", ctype)
		req.Header.Set("Accept", "application/json")
		resp, err := client.Do(req)
		if err != nil {
			return 0, nil, err
		}
		defer resp.Body.Close()
		raw, _ := io.ReadAll(io.LimitReader(resp.Body, control.MaxOAuthRefreshBody))
		return resp.StatusCode, raw, nil
	}
}

// NodeOAuthExchangeFunc is the exchange through an admin node's relay.
func (s *Server) NodeOAuthExchangeFunc() OAuthExchangeFunc {
	return func(ctx context.Context, provider string, form map[string]string, encoding string) (int, []byte, error) {
		ans, err := s.NodeOAuthExchange(ctx, provider, form, encoding)
		return ans.Status, ans.Body, err
	}
}

// MySub is one row of GET /v1/me/subscriptions: the member's own vault row
// and its two windows. Nothing secret, no e-mail.
type MySub struct {
	Provider    string     `json:"provider"`
	Account     string     `json:"account"`
	AccountUUID string     `json:"account_uuid,omitempty"`
	Plan        string     `json:"plan,omitempty"`
	State       string     `json:"state"` // ok · near · limited · paused · reauth · unread
	Paused      bool       `json:"paused"`
	FiveHour    *MySubWin  `json:"five_hour,omitempty"`
	SevenDay    *MySubWin  `json:"seven_day,omitempty"`
	ObservedAt  *time.Time `json:"observed_at,omitempty"`
	CreatedAt   time.Time  `json:"created_at"`
}

// MySubWin is one window: how much is used (0–100, null = no reading) and when it resets.
type MySubWin struct {
	UsedPct  *float64   `json:"used_pct"`
	ResetsAt *time.Time `json:"resets_at,omitempty"`
}

// meSubPerson is the caller, or a refusal: these routes are a person's own,
// the operator's door (no principal) has none.
func meSubPerson(w http.ResponseWriter, r *http.Request, methods ...string) (string, bool) {
	ok := false
	for _, m := range methods {
		ok = ok || r.Method == m
	}
	if !ok {
		w.Header().Set("Allow", strings.Join(methods, ", "))
		httpError(w, http.StatusMethodNotAllowed, strings.Join(methods, " or ")+" only")
		return "", false
	}
	pid := principalOf(r.Context())
	if pid == "" {
		httpError(w, http.StatusForbidden, "your own subscriptions need a signed-in person")
		return "", false
	}
	return pid, true
}

func (s *Server) handleMeSubs(w http.ResponseWriter, r *http.Request) {
	pid, ok := meSubPerson(w, r, http.MethodGet)
	if !ok || s.vaultOff(w) {
		return
	}
	rows, err := s.mySubs(pid)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, map[string]any{"subscriptions": rows, "login": s.OAuthExchange != nil})
}

// mySubs is pid's own rows, Claude first, then by name.
func (s *Server) mySubs(pid string) ([]MySub, error) {
	creds, err := s.Store.Credentials(pid)
	if err != nil {
		return nil, err
	}
	settings, err := s.Store.FleetSettings()
	if err != nil {
		return nil, err
	}
	out := []MySub{}
	for _, c := range creds {
		if c.PrincipalID != pid || c.Provider == credvault.GitHub {
			continue
		}
		out = append(out, s.mySub(c, settings))
	}
	sort.SliceStable(out, func(i, j int) bool {
		if out[i].Provider != out[j].Provider {
			return out[i].Provider == credvault.Claude
		}
		return out[i].Account < out[j].Account
	})
	return out, nil
}

func (s *Server) mySub(c store.Credential, settings map[string]string) MySub {
	m := MySub{Provider: c.Provider, Account: c.Account, CreatedAt: c.CreatedAt, State: "unread", Paused: ownPaused(settings, c)}
	if s.Vault != nil {
		m.AccountUUID = s.Vault.AccountUUID(c)
	}
	if s.Vault != nil {
		if v, err := s.credentialLimits(c); err == nil && v != nil {
			m.Plan, m.ObservedAt = v.Plan, v.ObservedAt
			h5, h7 := limitWindows(v)
			win := func(w *WindowView) *MySubWin {
				if w == nil {
					return nil
				}
				p := w.Utilization
				return &MySubWin{UsedPct: &p, ResetsAt: w.ResetsAt}
			}
			m.FiveHour, m.SevenDay = win(h5), win(h7)
			var q MyQuota
			fillQuota(&q, v)
			switch {
			case q.State == QuotaLimited:
				m.State = "limited"
			case q.State == QuotaOK:
				m.State = "ok"
				for _, w := range []*WindowView{h5, h7} {
					if w != nil && w.Utilization >= meSubNear {
						m.State = "near"
					}
				}
			}
		}
	}
	switch {
	case c.ReauthRequired:
		m.State = "reauth"
	case m.Paused:
		m.State = "paused"
	}
	return m
}

// meSubLogin is the sealed half of one sign-in, carried by the browser.
type meSubLogin struct {
	Provider string    `json:"p"`
	Account  string    `json:"a"`
	Verifier string    `json:"v"`
	State    string    `json:"s"`
	Expires  time.Time `json:"e"`
	Again    bool      `json:"g,omitempty"`
}

func randURL(n int) string {
	b := make([]byte, n)
	_, _ = rand.Read(b)
	return base64.RawURLEncoding.EncodeToString(b)
}

// handleMeSubsLogin starts one sign-in: {provider, account, again} →
// {flow, authorize_url, paste: code|url, expires_at}.
func (s *Server) handleMeSubsLogin(w http.ResponseWriter, r *http.Request) {
	pid, ok := meSubPerson(w, r, http.MethodPost)
	if !ok || s.vaultOff(w) {
		return
	}
	var req struct {
		Provider string `json:"provider"`
		Account  string `json:"account"`
		Again    bool   `json:"again"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4<<10)).Decode(&req); err != nil {
		httpError(w, http.StatusBadRequest, "malformed request: "+err.Error())
		return
	}
	if req.Provider != credvault.Claude && req.Provider != credvault.Codex {
		httpError(w, http.StatusBadRequest, "provider is claude or codex")
		return
	}
	if !validAccountLabel(req.Account) {
		httpError(w, http.StatusBadRequest, "名字用字母、数字、点、横线（name: 1-64 of [A-Za-z0-9._-])")
		return
	}
	if s.OAuthExchange == nil {
		httpError(w, http.StatusServiceUnavailable, "这个入口还不能在浏览器里接订阅（no token exchange configured on this hub）")
		return
	}
	_, err := s.Store.Credential(pid, req.Provider, req.Account)
	switch {
	case err != nil && !errors.Is(err, store.ErrNoCredential):
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	case req.Again && err != nil:
		httpError(w, http.StatusNotFound, "no such subscription of yours")
		return
	case !req.Again && err == nil:
		httpError(w, http.StatusConflict, "你已经有一份叫 "+req.Account+" 的订阅了")
		return
	}
	note := meSubLogin{Provider: req.Provider, Account: req.Account, Verifier: randURL(32), State: randURL(16),
		Expires: time.Now().Add(meSubLoginTTL).UTC(), Again: req.Again}
	blob, err := s.Vault.SealNote(note, pid, meSubLoginNote)
	if err != nil {
		code := http.StatusInternalServerError
		if errors.Is(err, credvault.ErrLocked) {
			code = http.StatusServiceUnavailable
		}
		httpError(w, code, err.Error())
		return
	}
	auth, paste := subAuthorizeURL(note)
	writeJSON(w, http.StatusOK, map[string]any{"flow": base64.RawURLEncoding.EncodeToString(blob),
		"authorize_url": auth, "paste": paste, "expires_at": note.Expires})
}

// pastedCode is the authorization code in what the person pasted — Claude's
// «code#state», ChatGPT's redirect address (or either bare code) — checked
// against the sign-in's state when it carries one.
func pastedCode(provider, paste, state string) (string, error) {
	paste = strings.TrimSpace(paste)
	code, got := paste, ""
	if u, err := url.Parse(paste); err == nil && u.Scheme != "" && u.RawQuery != "" {
		q := u.Query()
		if e := q.Get("error"); e != "" {
			return "", fmt.Errorf("登录页说：%s", e)
		}
		code, got = q.Get("code"), q.Get("state")
	} else if c, st, ok := strings.Cut(paste, "#"); ok {
		code, got = c, st
	}
	if code == "" || strings.ContainsAny(code, " \t\n") || len(code) > 2048 {
		return "", errors.New("没接上：贴的不像登录页给的代码。重新打开登录页，整串复制过来")
	}
	if got != "" && got != state {
		return "", errors.New("这串来自另一次登录：用这次打开的登录页再来一次")
	}
	return code, nil
}

// tokenAnswer is the providers' answer to a sign-in's exchange.
type tokenAnswer struct {
	AccessToken  string `json:"access_token"`
	RefreshToken string `json:"refresh_token"`
	IDToken      string `json:"id_token"`
	ExpiresIn    int64  `json:"expires_in"`
	Scope        string `json:"scope"`
	Account      struct {
		UUID string `json:"uuid"`
	} `json:"account"`
	Error string `json:"error"`
}

// handleMeSubsFinish finishes one: {flow, paste} → the stored row.
func (s *Server) handleMeSubsFinish(w http.ResponseWriter, r *http.Request) {
	pid, ok := meSubPerson(w, r, http.MethodPost)
	if !ok || s.vaultOff(w) {
		return
	}
	var req struct {
		Flow  string `json:"flow"`
		Paste string `json:"paste"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 16<<10)).Decode(&req); err != nil {
		httpError(w, http.StatusBadRequest, "malformed request: "+err.Error())
		return
	}
	gone := func() { httpError(w, http.StatusGone, "这次登录过期了，重新打开登录页再来一次") }
	blob, err := base64.RawURLEncoding.DecodeString(req.Flow)
	if err != nil {
		gone()
		return
	}
	var note meSubLogin
	// sealed to this person: another member's flow does not open, and reads as expired
	if err := s.Vault.OpenNote(blob, &note, pid, meSubLoginNote); err != nil || time.Now().After(note.Expires) {
		gone()
		return
	}
	if s.OAuthExchange == nil {
		httpError(w, http.StatusServiceUnavailable, "no token exchange configured on this hub")
		return
	}
	code, err := pastedCode(note.Provider, req.Paste, note.State)
	if err != nil {
		httpError(w, http.StatusUnprocessableEntity, err.Error())
		return
	}
	form, enc := map[string]string{"grant_type": "authorization_code", "code": code, "code_verifier": note.Verifier}, ""
	if note.Provider == credvault.Claude {
		form["client_id"], form["redirect_uri"], form["state"] = credvault.ClaudeClientID, claudeCodeRedirect, note.State
	} else {
		form["client_id"], form["redirect_uri"], enc = credvault.CodexClientID, codexRedirect, control.OAuthEncodingForm
	}
	status, raw, err := s.OAuthExchange(r.Context(), note.Provider, form, enc)
	if err != nil {
		log.Printf("me subscriptions: %s sign-in exchange for %s unavailable: %v", note.Provider, pid, err)
		httpError(w, http.StatusBadGateway, "现在换不到令牌（没有能连上登录服务的管理机器），过一会儿再试")
		return
	}
	var ans tokenAnswer
	_ = json.Unmarshal(raw, &ans)
	if status != http.StatusOK {
		why := ans.Error
		if why == "" {
			why = fmt.Sprintf("HTTP %d", status)
		}
		httpError(w, http.StatusUnprocessableEntity, "没接上：登录服务不认这串（"+why+"）。重新打开登录页再来一次")
		return
	}
	var sec credvault.Secret
	if note.Provider == credvault.Claude {
		sec = credvault.Secret{RefreshToken: ans.RefreshToken, AccountUUID: ans.Account.UUID, Scopes: strings.Fields(ans.Scope)}
	} else {
		sec = credvault.Secret{RefreshToken: ans.RefreshToken, IDToken: ans.IDToken, AccountID: codex.AccountIDFromIDToken(ans.IDToken),
			SubscriptionType: codex.PlanFromIDToken(ans.IDToken)}
	}
	if err := s.Vault.Put(pid, note.Provider, note.Account, sec); err != nil {
		code := http.StatusUnprocessableEntity
		if errors.Is(err, credvault.ErrLocked) {
			code = http.StatusServiceUnavailable
		}
		httpError(w, code, "没接上："+err.Error())
		return
	}
	cp, err := s.Store.Credential(pid, note.Provider, note.Account)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	c := *cp
	uuid := s.Vault.AccountUUID(c)
	allowed := s.ownAllow(pid, uuid, true, actorOf(r))
	_ = s.Store.AddCredAudit(store.CredAudit{Action: store.CredPut, PrincipalID: pid, Provider: note.Provider, Account: note.Account,
		Detail: "own · signed in in the browser" + optional(" · again", note.Again) + optional(" · allowlists +"+allowed, allowed != "") + " · by " + actorOf(r)})
	s.BroadcastCreds("own subscription connected")
	settings, _ := s.Store.FleetSettings()
	writeJSON(w, http.StatusOK, s.mySub(c, settings))
}

// ownAllow keeps a member's own subscription usable by them in strict mode:
// add (or, gone, take away) its ID on their allowlist and their own machines'
// — only an explicit list is touched (no list, «all» and a malformed one are
// left as they are), and an ID still held by another vault row (the same
// subscription in the pool) is never taken away. Returns the keys changed.
func (s *Server) ownAllow(pid, uuid string, add bool, actor string) string {
	if uuid == "" || !validSubID(normSubID(uuid)) {
		return ""
	}
	id := normSubID(uuid)
	settings, err := s.Store.FleetSettings()
	if err != nil {
		return ""
	}
	if !add {
		all, err := s.Store.Credentials("")
		if err != nil {
			return ""
		}
		for _, c := range all {
			if c.Provider != credvault.GitHub && normSubID(s.Vault.AccountUUID(c)) == id {
				return "" // still someone's
			}
		}
	}
	keys := []string{credUserKey(pid)}
	if accts, err := s.Store.FleetAccounts(pid); err == nil {
		seen := map[string]bool{}
		for _, a := range accts {
			if k := credNodeKey(a.Hostname); a.Hostname != "" && !seen[k] {
				seen[k] = true
				keys = append(keys, k)
			}
		}
	}
	now := time.Now()
	var changed []string
	for _, key := range keys {
		raw, had := settings[key]
		a := credAllowOf(settings, key)
		if !had && !a.Set || a.All || a.Bad != "" {
			continue
		}
		if !had && key != credUserKey(pid) {
			continue // a machine with no list of its own is not given one
		}
		ids := map[string]bool{}
		for k := range a.IDs {
			ids[k] = true
		}
		if ids[id] == add {
			continue
		}
		if add {
			ids[id] = true
		} else {
			delete(ids, id)
		}
		list := make([]string, 0, len(ids))
		for k := range ids {
			list = append(list, k)
		}
		sort.Strings(list)
		b, _ := json.Marshal(list)
		if err := s.Store.SetFleetSetting(key, string(b), now); err != nil {
			log.Printf("me subscriptions: allowlist %s: %v", key, err)
			continue
		}
		s.settingAudit(actor, key, raw, string(b), now)
		changed = append(changed, key)
	}
	if len(changed) > 0 {
		s.sessCred.drop("")
	}
	return strings.Join(changed, ",")
}

// meSubTarget reads {provider, account} and the caller's own row by it — 404
// for anyone else's, the same as for none.
func (s *Server) meSubTarget(w http.ResponseWriter, r *http.Request, pid string, extra any) (store.Credential, bool) {
	var req struct {
		Provider string `json:"provider"`
		Account  string `json:"account"`
	}
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, 4<<10))
	if err == nil {
		err = json.Unmarshal(body, &req)
	}
	if err != nil {
		httpError(w, http.StatusBadRequest, "malformed request")
		return store.Credential{}, false
	}
	if extra != nil {
		_ = json.Unmarshal(body, extra)
	}
	c, err := s.Store.Credential(pid, req.Provider, req.Account)
	if err != nil || c == nil || c.PrincipalID != pid || c.Provider == credvault.GitHub {
		if err != nil && !errors.Is(err, store.ErrNoCredential) {
			httpError(w, http.StatusInternalServerError, err.Error())
		} else {
			httpError(w, http.StatusNotFound, "no such subscription of yours")
		}
		return store.Credential{}, false
	}
	return *c, true
}

// handleMeSubsPause: {provider, account, paused} — the caller's own only.
func (s *Server) handleMeSubsPause(w http.ResponseWriter, r *http.Request) {
	pid, ok := meSubPerson(w, r, http.MethodPost)
	if !ok || s.vaultOff(w) {
		return
	}
	var p struct {
		Paused bool `json:"paused"`
	}
	c, ok := s.meSubTarget(w, r, pid, &p)
	if !ok {
		return
	}
	settings, err := s.Store.FleetSettings()
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	key, now := ownPausedKey(pid, c.Provider, c.Account), time.Now()
	stored := ""
	if p.Paused {
		stored = "on"
	}
	if settings[key] != stored {
		if err := s.Store.SetFleetSetting(key, stored, now); err != nil {
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
		s.settingAudit(actorOf(r), key, settings[key], stored, now)
		s.BroadcastCreds("own subscription pause")
		settings[key] = stored
		if stored == "" {
			delete(settings, key)
		}
	}
	writeJSON(w, http.StatusOK, s.mySub(c, settings))
}

// handleMeSubsDelete: {provider, account} — the caller's own only. The
// stored sign-in goes; the subscription itself is untouched.
func (s *Server) handleMeSubsDelete(w http.ResponseWriter, r *http.Request) {
	pid, ok := meSubPerson(w, r, http.MethodPost)
	if !ok || s.vaultOff(w) {
		return
	}
	c, ok := s.meSubTarget(w, r, pid, nil)
	if !ok {
		return
	}
	uuid := s.Vault.AccountUUID(c)
	if err := s.Store.DeleteCredential(pid, c.Provider, c.Account); err != nil {
		code := http.StatusInternalServerError
		if errors.Is(err, store.ErrNoCredential) {
			code = http.StatusNotFound
		}
		httpError(w, code, err.Error())
		return
	}
	now := time.Now()
	key := ownPausedKey(pid, c.Provider, c.Account)
	if settings, err := s.Store.FleetSettings(); err == nil && settings[key] != "" {
		if s.Store.SetFleetSetting(key, "", now) == nil {
			s.settingAudit(actorOf(r), key, settings[key], "", now)
		}
	}
	removed := s.ownAllow(pid, uuid, false, actorOf(r))
	_ = s.Store.AddCredAudit(store.CredAudit{Action: store.CredDelete, PrincipalID: pid, Provider: c.Provider, Account: c.Account,
		Detail: "own · disconnected" + optional(" · allowlists −"+removed, removed != "") + " · by " + actorOf(r)})
	s.BroadcastCreds("own subscription disconnected")
	writeJSON(w, http.StatusOK, map[string]any{"deleted": true})
}

// subAuthorizeURL is shared by personal and administrator flows; their sealed purposes stay separate.
func subAuthorizeURL(note meSubLogin) (string, string) {
	sum := sha256.Sum256([]byte(note.Verifier))
	q := url.Values{"response_type": {"code"}, "code_challenge": {base64.RawURLEncoding.EncodeToString(sum[:])},
		"code_challenge_method": {"S256"}, "state": {note.State}}
	auth, paste := "", "code"
	if note.Provider == credvault.Claude {
		q.Set("code", "true")
		q.Set("client_id", credvault.ClaudeClientID)
		q.Set("redirect_uri", claudeCodeRedirect)
		q.Set("scope", claudeLoginScope)
		auth = claudeAuthorizeURL + "?" + q.Encode()
	} else {
		q.Set("client_id", credvault.CodexClientID)
		q.Set("redirect_uri", codexRedirect)
		q.Set("scope", codexLoginScope)
		q.Set("id_token_add_organizations", "true")
		q.Set("codex_cli_simplified_flow", "true")
		auth, paste = codexAuthorizeURL+"?"+q.Encode(), "url"
	}
	return auth, paste
}
