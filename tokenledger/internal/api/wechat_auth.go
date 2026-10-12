package api

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"html/template"
	"io"
	"log"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/i18n"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// Sign in with WeChat (claude-fleet#3604, EPIC #3570 C11 · 共同约定 11).
//
// # Two roads, one person
//
// On a computer the browser goes to WeChat's open platform "website app"
// (qrconnect, scope snsapi_login): a QR code the person scans with their
// phone. Inside WeChat's own browser there is nothing to scan: the company
// service account's web authorisation (oauth2/authorize, snsapi_userinfo)
// asks them to allow it and comes straight back. /auth/wechat/start picks
// the road by the browser (inWeChat). Both come back to /auth/wechat/callback,
// which trades the code for the person's unionid — the same for both roads
// only because the website app and the service account are bound under one
// open-platform account — and the unionid is who they are: identity kind
// wechat, subject the unionid, hung on a principal (hub_identities). The
// trade goes straight to api.weixin.qq.com from the hub's own egress, never
// through the Singapore relay GitHub's needs.
//
// # The first scan opens no account
//
// A unionid nobody's account carries yet does not sign anyone in and does
// not make a new person: the browser goes to the binding page
// (/auth/wechat/bind), which offers exactly one thing — hang this WeChat on
// the account this browser is signed in to, or come in on the invite this
// browser carries — and does it only when the person presses the button.
// With neither, it says to ask an admin for an invite. BREAK-IT
// wechat-first-scan-autocreate.
//
// # What is kept
//
// The access token is used for two calls and dropped. The state is one use
// across both replicas (hub_signin_spent); the binding cookie is signed, ten
// minutes, one use. Enterprise WeChat is not a way in: it signs in only an
// enterprise's own members, and a customer's people could not come in.

// WeChatAuth is the WeChat sign-in's configuration: the website app
// (CCQUOTA_WECHAT_WEB_APPID / _SECRET), the service account
// (CCQUOTA_WECHAT_MP_APPID / _SECRET), either or both. The secrets live in the
// hub's environment only.
type WeChatAuth struct {
	WebAppID, WebSecret string
	MPAppID, MPSecret   string

	// WeChat's endpoints; empty means the real ones. Tests point them at a
	// fake.
	AuthorizeBase string // https://open.weixin.qq.com
	APIBase       string // https://api.weixin.qq.com
	// HTTP is the client for the code trade; nil means one with a 10-second
	// timeout.
	HTTP *http.Client
}

const (
	wechatAuthorizeBase = "https://open.weixin.qq.com"
	wechatAPIBase       = "https://api.weixin.qq.com"

	wechatFlowCookie = "ccq_wx_flow"
	wechatBindCookie = "ccq_wx_bind"
	wechatFlowPath   = "/auth/wechat/"
	wechatFlowTTL    = 10 * time.Minute

	wechatRoadWeb = "web" // the website app's QR code
	wechatRoadMP  = "mp"  // the service account, inside WeChat
)

func (x *WeChatAuth) webReady() bool { return x != nil && x.WebAppID != "" && x.WebSecret != "" }
func (x *WeChatAuth) mpReady() bool  { return x != nil && x.MPAppID != "" && x.MPSecret != "" }
func (x *WeChatAuth) ready() bool    { return x.webReady() || x.mpReady() }

func (x *WeChatAuth) authorizeBase() string {
	return strings.TrimRight(orDefault(x.AuthorizeBase, wechatAuthorizeBase), "/")
}
func (x *WeChatAuth) apiBase() string {
	return strings.TrimRight(orDefault(x.APIBase, wechatAPIBase), "/")
}

func (x *WeChatAuth) client() *http.Client {
	if x.HTTP != nil {
		return x.HTTP
	}
	return &http.Client{Timeout: 10 * time.Second}
}

// app is the app id and secret of a road.
func (x *WeChatAuth) app(road string) (id, secret string) {
	if road == wechatRoadMP {
		return x.MPAppID, x.MPSecret
	}
	return x.WebAppID, x.WebSecret
}

// wechatFlow is the flow cookie's body.
type wechatFlow struct {
	State string `json:"s"`
	Road  string `json:"r"`
	Exp   int64  `json:"e"`
	// Link is the person a ?link=1 start was made by (登录方式 · 加微信).
	Link string `json:"l,omitempty"`
}

// wechatBind is the binding cookie's body: a WeChat nobody's account
// carries yet, waiting for the person to say whose it is.
type wechatBind struct {
	Union string `json:"u"`
	Name  string `json:"n"`
	Nonce string `json:"o"`
	Exp   int64  `json:"e"`
}

func spentHash(kind, v string) string {
	sum := sha256.Sum256([]byte(kind + ":" + v))
	return hex.EncodeToString(sum[:])
}

func (s *Server) wechatCallbackURL(r *http.Request) string {
	return s.hubURL(r) + "/auth/wechat/callback"
}

// handleWeChatStart sends the browser to WeChat: the service account inside
// WeChat, the website app's QR code anywhere else.
func (s *Server) handleWeChatStart(w http.ResponseWriter, r *http.Request) {
	if !s.WeChat.ready() {
		http.NotFound(w, r)
		return
	}
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Allow", "GET")
		httpError(w, http.StatusMethodNotAllowed, "GET only")
		return
	}
	road := wechatRoadWeb
	switch {
	case inWeChat(r) && s.WeChat.mpReady():
		road = wechatRoadMP
	case !s.WeChat.webReady():
		// Only the service account is set up (the website app is still
		// under WeChat's review): it works inside WeChat only.
		http.Redirect(w, r, appURL("/signin")+"?e=wechat-app", http.StatusFound)
		return
	}
	state, err := randomToken(24)
	if err != nil {
		httpError(w, http.StatusInternalServerError, "could not start sign-in")
		return
	}
	f := wechatFlow{State: state, Road: road, Exp: time.Now().Add(wechatFlowTTL).Unix()}
	if r.URL.Query().Get("link") == "1" {
		if _, pid, ok := s.personSession(r); ok {
			f.Link = pid
		}
	}
	flow, _ := json.Marshal(f)
	http.SetCookie(w, &http.Cookie{
		Name: wechatFlowCookie, Value: signBlob(flow, s.sessionKey()), Path: wechatFlowPath,
		HttpOnly: true, SameSite: http.SameSiteLaxMode, Secure: isHTTPS(r),
		MaxAge: int(wechatFlowTTL.Seconds()),
	})
	appid, _ := s.WeChat.app(road)
	q := url.Values{
		"appid":         {appid},
		"redirect_uri":  {s.wechatCallbackURL(r)},
		"response_type": {"code"},
		"state":         {state},
	}
	path := "/connect/qrconnect"
	q.Set("scope", "snsapi_login")
	if road == wechatRoadMP {
		path = "/connect/oauth2/authorize"
		q.Set("scope", "snsapi_userinfo")
	}
	w.Header().Set("Cache-Control", "no-store")
	// WeChat wants its parameters in this order and the fragment last.
	http.Redirect(w, r, s.WeChat.authorizeBase()+path+"?appid="+url.QueryEscape(appid)+
		"&redirect_uri="+url.QueryEscape(q.Get("redirect_uri"))+"&response_type=code&scope="+q.Get("scope")+
		"&state="+url.QueryEscape(state)+"#wechat_redirect", http.StatusFound)
}

// handleWeChatCallback finishes it: state, code trade, who it is, then a
// session — or, for a WeChat no account carries, the binding page.
func (s *Server) handleWeChatCallback(w http.ResponseWriter, r *http.Request) {
	if !s.WeChat.ready() {
		http.NotFound(w, r)
		return
	}
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", "GET")
		httpError(w, http.StatusMethodNotAllowed, "GET only")
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	var flow wechatFlow
	if c, err := r.Cookie(wechatFlowCookie); err == nil {
		if raw, ok := verifyBlob(c.Value, s.sessionKey()); ok {
			_ = json.Unmarshal(raw, &flow)
		}
	}
	clearCookie(w, r, wechatFlowCookie, wechatFlowPath)
	now := time.Now()
	q := r.URL.Query()
	state, code := q.Get("state"), q.Get("code")
	if code == "" && state != "" && flow.State != "" {
		// The person said no on their phone: WeChat comes back without a code.
		http.Redirect(w, r, appURL("/signin")+"?e=wechat-cancelled", http.StatusFound)
		return
	}
	if flow.State == "" || flow.Exp < now.Unix() || state == "" || code == "" || !constantTimeEqual(state, flow.State) {
		http.Redirect(w, r, appURL("/signin")+"?e=expired", http.StatusFound)
		return
	}
	// One use, on either replica: a replayed callback is refused here, before
	// WeChat is asked anything.
	if ok, err := s.Store.SpendSigninValue(spentHash("wx-state", state), time.Unix(flow.Exp, 0), now); err != nil || !ok {
		if err != nil {
			log.Printf("wechat sign-in: %v", err)
		}
		http.Redirect(w, r, appURL("/signin")+"?e=expired", http.StatusFound)
		return
	}
	union, name, err := s.wechatWho(r.Context(), flow.Road, code)
	if err != nil {
		log.Printf("wechat sign-in: %v", err)
		http.Redirect(w, r, appURL("/signin")+"?e=wechat", http.StatusFound)
		return
	}
	target := orDefault(name, "?") + " (wechat)"
	if flow.Link != "" {
		// 登录方式 · 加微信, started from the settings page by this person.
		if _, pid, ok := s.personSession(r); ok && pid == flow.Link {
			if role, err := s.personRole(pid); err == nil && role != "" {
				http.Redirect(w, r, s.wechatLink(pid, union, name, now), http.StatusFound)
				return
			}
		}
	}
	pid, err := s.Store.IdentityPrincipal(store.IdentityWeChat, union)
	if err != nil {
		httpError(w, http.StatusInternalServerError, "could not read the people list")
		return
	}
	if pid == "" {
		// The first scan: nobody's yet. Ask, never make an account.
		_ = s.Store.HubAudit("wechat:?", "signin", target, "held", "first scan: waiting to be bound", now)
		s.setWeChatBind(w, r, union, name, now)
		http.Redirect(w, r, "/auth/wechat/bind", http.StatusFound)
		return
	}
	role, err := s.personRole(pid)
	if err != nil {
		httpError(w, http.StatusInternalServerError, "could not read the people list")
		return
	}
	if role == "" {
		_ = s.Store.HubAudit(pid, "signin", target, "refused", "no longer on the list", now)
		s.waySignedOut(w, r, store.IdentityWeChat, denyRemoved, name, now)
		return
	}
	_ = s.Store.TouchHubPrincipal(pid, "", now)
	_ = s.Store.HubAudit(pid, "signin", target, "ok", "as "+role, now)
	s.signInAs(w, r, store.IdentityWeChat, pid, orDefault(name, s.personLogin(pid)), role, now)
}

// signInAs sets the session for a person signed in by kind and sends the
// browser on: back to a waiting `fleet login`, else the console.
func (s *Server) signInAs(w http.ResponseWriter, r *http.Request, kind, pid, name, role string, now time.Time) {
	if name == "" {
		name = s.personLogin(pid)
	}
	http.SetCookie(w, s.personCookie(r, kind, pid, name, role, now))
	s.onPrincipalSignIn(pid, name)
	http.Redirect(w, r, loginReturn(w, r), http.StatusFound)
}

// waySignedOut answers a refusal of a way that is not GitHub: a waiting
// terminal hears it too, a browser gets the refusal page in that way's words.
func (s *Server) waySignedOut(w http.ResponseWriter, r *http.Request, kind, why, name string, now time.Time) {
	if to := s.loginRefusedHop(w, r, why, name, now); to != "" {
		http.Redirect(w, r, to, http.StatusFound)
		return
	}
	if !wantsHTML(r) {
		httpError(w, http.StatusForbidden, "this sign-in is not on this hub's list")
		return
	}
	loc := s.pageLocale(w, r)
	page := denyPage{pageView: newPageView(r, loc), Why: why, Login: name,
		Heading: i18n.Interpolate(pageT(loc, "deny.h1.way"), map[string]string{"way": identityWord(loc, kind)})}
	writeAuthPage(w, http.StatusForbidden, denyTmpl, loc, page)
}

// wechatLink hangs a WeChat on pid (登录方式 · 加微信, or the binding page's
// first button); where the browser goes next.
func (s *Server) wechatLink(pid, union, name string, now time.Time) string {
	err := s.Store.AddHubIdentity(store.HubIdentity{Kind: store.IdentityWeChat, Subject: union,
		PrincipalID: pid, VerifiedAt: now, AddedBy: "link"})
	target := orDefault(name, "?") + " (wechat)"
	if errors.Is(err, store.ErrIdentityTaken) {
		_ = s.Store.HubAudit(pid, "identity.add", target, "refused", "another person signs in with it", now)
		return AppPrefix + "/config?e=wechat-taken#logins"
	}
	if err != nil {
		log.Printf("wechat link for %s: %v", pid, err)
		return AppPrefix + "/config?e=wechat#logins"
	}
	_ = s.Store.HubAudit(pid, "identity.add", target, "ok", "wechat, by scanning it", now)
	return AppPrefix + "/config#logins"
}

func (s *Server) setWeChatBind(w http.ResponseWriter, r *http.Request, union, name string, now time.Time) {
	nonce, _ := randomToken(16)
	body, _ := json.Marshal(wechatBind{Union: union, Name: name, Nonce: nonce, Exp: now.Add(wechatFlowTTL).Unix()})
	http.SetCookie(w, &http.Cookie{
		Name: wechatBindCookie, Value: signBlob(body, s.sessionKey()), Path: wechatFlowPath,
		HttpOnly: true, SameSite: http.SameSiteLaxMode, Secure: isHTTPS(r),
		MaxAge: int(wechatFlowTTL.Seconds()),
	})
}

// wechatBindOf is the WeChat waiting on this browser to be bound, nil for
// none (or one expired / forged).
func (s *Server) wechatBindOf(r *http.Request, now time.Time) *wechatBind {
	c, err := r.Cookie(wechatBindCookie)
	if err != nil {
		return nil
	}
	raw, ok := verifyBlob(c.Value, s.sessionKey())
	if !ok {
		return nil
	}
	var b wechatBind
	if json.Unmarshal(raw, &b) != nil || b.Union == "" || b.Nonce == "" || b.Exp < now.Unix() {
		return nil
	}
	return &b
}

// wechatBindView is the binding page.
type wechatBindView struct {
	pageView
	// Mode: "link" (this browser is signed in as Person), "invite" (it
	// carries an invite), "none" (ask an admin).
	Mode   string
	Person string
	WeName string
}

// handleWeChatBind is the first scan's page: GET shows what may be done,
// POST does it — only when the person pressed the button.
func (s *Server) handleWeChatBind(w http.ResponseWriter, r *http.Request) {
	if !s.WeChat.ready() || s.Store == nil {
		http.NotFound(w, r)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	now := time.Now()
	b := s.wechatBindOf(r, now)
	if b == nil {
		http.Redirect(w, r, appURL("/signin")+"?e=expired", http.StatusFound)
		return
	}
	var signedIn string
	var signedName string
	if sess, pid, ok := s.personSession(r); ok {
		if role, err := s.personRole(pid); err == nil && role != "" {
			signedIn, signedName = pid, sess.Name
		}
	}
	hasInvite := false
	if c, err := r.Cookie(inviteCookie); err == nil && validInviteCode(c.Value) {
		hasInvite = true
	}
	switch r.Method {
	case http.MethodGet, http.MethodHead:
		loc := s.pageLocale(w, r)
		v := wechatBindView{pageView: newPageView(r, loc), Mode: "none", WeName: b.Name}
		switch {
		case signedIn != "":
			v.Mode, v.Person = "link", signedName
		case hasInvite:
			v.Mode = "invite"
		}
		writeAuthPage(w, http.StatusOK, wechatBindTmpl, loc, v)
		return
	case http.MethodPost:
	default:
		w.Header().Set("Allow", "GET, POST")
		httpError(w, http.StatusMethodNotAllowed, "GET or POST")
		return
	}
	if !sameOrigin(r) {
		httpError(w, http.StatusForbidden, "cross-site request refused")
		return
	}
	clearCookie(w, r, wechatBindCookie, wechatFlowPath)
	if ok, err := s.Store.SpendSigninValue(spentHash("wx-bind", b.Nonce), time.Unix(b.Exp, 0), now); err != nil || !ok {
		http.Redirect(w, r, appURL("/signin")+"?e=expired", http.StatusFound)
		return
	}
	switch r.FormValue("action") {
	case "link":
		if signedIn == "" {
			http.Redirect(w, r, appURL("/signin")+"?e=expired", http.StatusFound)
			return
		}
		to := s.wechatLink(signedIn, b.Union, b.Name, now)
		if !strings.Contains(to, "?e=") {
			to = loginReturn(w, r)
		}
		http.Redirect(w, r, to, http.StatusFound)
	case "invite":
		invite := s.takeInviteCookie(w, r)
		if invite == "" {
			http.Redirect(w, r, appURL("/signin")+"?e=expired", http.StatusFound)
			return
		}
		pid, role, refusal, err := s.admitPerson(store.IdentityWeChat, b.Union, b.Name, invite, now)
		if err != nil {
			log.Printf("wechat bind by invite: %v", err)
			httpError(w, http.StatusInternalServerError, "could not read the people list")
			return
		}
		if role == "" {
			s.waySignedOut(w, r, store.IdentityWeChat, refusal, b.Name, now)
			return
		}
		s.signInAs(w, r, store.IdentityWeChat, pid, b.Name, role, now)
	default:
		httpError(w, http.StatusBadRequest, "action must be link or invite")
	}
}

// wechatWho trades a code for the person's unionid and nickname, and lets
// the access token go. It is never stored or logged.
func (s *Server) wechatWho(ctx context.Context, road, code string) (union, name string, err error) {
	x := s.WeChat
	appid, secret := x.app(road)
	q := url.Values{"appid": {appid}, "secret": {secret}, "code": {code}, "grant_type": {"authorization_code"}}
	var tok struct {
		AccessToken string `json:"access_token"`
		OpenID      string `json:"openid"`
		UnionID     string `json:"unionid"`
		ErrCode     int    `json:"errcode"`
	}
	if err := x.get(ctx, "/sns/oauth2/access_token?"+q.Encode(), &tok); err != nil {
		return "", "", fmt.Errorf("code trade: %w", err)
	}
	if tok.ErrCode != 0 || tok.AccessToken == "" {
		// The code only: errmsg can echo the request.
		return "", "", fmt.Errorf("code trade: errcode %d", tok.ErrCode)
	}
	var who struct {
		Nickname string `json:"nickname"`
		UnionID  string `json:"unionid"`
		ErrCode  int    `json:"errcode"`
	}
	uq := url.Values{"access_token": {tok.AccessToken}, "openid": {tok.OpenID}, "lang": {"zh_CN"}}
	if err := x.get(ctx, "/sns/userinfo?"+uq.Encode(), &who); err != nil || who.ErrCode != 0 {
		log.Printf("wechat sign-in: no profile (%v, errcode %d) — signing in by the unionid alone", err, who.ErrCode)
	}
	union = orDefault(tok.UnionID, who.UnionID)
	if union == "" {
		return "", "", errors.New("WeChat sent no unionid: the " + road + " app is not bound to the open-platform account")
	}
	return union, strings.TrimSpace(who.Nickname), nil
}

func (x *WeChatAuth) get(ctx context.Context, path string, out any) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, x.apiBase()+path, nil)
	if err != nil {
		return err
	}
	resp, err := x.client().Do(req)
	if err != nil {
		return errors.New("api.weixin.qq.com did not answer")
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, 64<<10)).Decode(out); err != nil {
		return errors.New("unreadable answer")
	}
	return nil
}

var wechatBindTmpl = template.Must(template.New("wechat-bind").Funcs(pageFuncs(i18n.EN)).Parse(authPageHead + signinWaysCSS + `
<title>{{t "wxbind.title"}}</title></head><body><div class="pub">` + authNav + `
<div class="center"><main class="card">
<div class="big" style="background:#07c160">` + wechatIcon + `</div>
<div style="display:grid;gap:6px"><h1>{{t "wxbind.h1"}}</h1><p class="lead">{{t "wxbind.lead"}}</p></div>
<div class="ways">
{{if eq .Mode "link"}}<form method="post" action="/auth/wechat/bind"><input type="hidden" name="action" value="link">
<button class="btn wx lg" type="submit">{{tb "wxbind.link" .Person}}</button></form>
{{else if eq .Mode "invite"}}<form method="post" action="/auth/wechat/bind"><input type="hidden" name="action" value="invite">
<button class="btn wx lg" type="submit">{{t "wxbind.invite"}}</button></form>
{{else}}<p class="note">{{t "wxbind.none"}}</p>
<a class="btn lg" href="/app/signin">{{t "wxbind.other"}}</a>{{end}}
</div>
<p class="fine">{{t "wxbind.fine"}}</p>
</main></div></div></body></html>`))

func init() {
	for k, v := range map[string]i18n.Text{
		"wxbind.title": {i18n.EN: "Link this WeChat · claudefleet", i18n.ZhCN: "挂上这个微信 · claudefleet"},
		"wxbind.h1":    {i18n.EN: "First time with this WeChat", i18n.ZhCN: "第一次用这个微信登录"},
		"wxbind.lead": {
			i18n.EN:   "This WeChat isn't on anyone's account here yet. So nobody can sign in as someone they are not, say whose it is first — after that, a scan signs you straight in.",
			i18n.ZhCN: "这个微信还没挂到任何账号上。为防冒用，先说清它是谁的；之后扫码直接进。",
		},
		"wxbind.link": {
			i18n.EN:   "Add it to {v}'s account",
			i18n.ZhCN: "挂到 {v} 的账号上",
		},
		"wxbind.invite": {i18n.EN: "Come in on my invite", i18n.ZhCN: "按邀请进入"},
		"wxbind.none": {
			i18n.EN:   "To come in, ask an admin for an invite link and open it, then scan again. Already have an account? Sign in another way first, then scan again to add this WeChat to it.",
			i18n.ZhCN: "要进来，请找管理员要一个邀请链接，打开后再扫一次。已经有账号？先用别的方式登录，再扫一次就能把这个微信挂上。",
		},
		"wxbind.other": {i18n.EN: "Sign in another way", i18n.ZhCN: "用别的方式登录"},
		"wxbind.fine": {
			i18n.EN:   "Nothing happens until you press the button. A WeChat never opens a new account by itself.",
			i18n.ZhCN: "不按按钮什么都不会发生。微信不会自己开出新账号。",
		},
		"deny.h1.way": {i18n.EN: "This {way} can't use this hub", i18n.ZhCN: "这个{way}不能使用本入口"},
	} {
		pageText[k] = v
	}
}
