package api

import (
	"context"
	"crypto/rand"
	"encoding/binary"
	"errors"
	"fmt"
	"html/template"
	"log"
	"net/http"
	"strconv"
	"strings"
	"time"

	"rsc.io/qr"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/i18n"
)

// Sign in by following the service account (claude-fleet#4054, EPIC #4048
// C6). The sign-in page draws one of the service account's temporary QR
// codes, numbered inside ClaudeFleet's own range (共同约定 4); scanning it
// follows 「二四网络科技」 — or, for a follower, just scans — and the company's
// workbench, which receives the account's events, keeps who scanned it for
// ten minutes under our range. The page polls; once someone has scanned, the
// browser that drew the code (and only it) trades the code for a session,
// once:
//
//	POST /auth/wechat/qr     draw a code for this browser ({purpose:"login"})
//	GET  /auth/wechat/poll?s= JSON for the page's script: wait | ready |
//	                          expired | down; as a page (the script's own
//	                          navigation, or <meta refresh> with no script)
//	                          it finishes: user/info, who it is, a session
//
// Who it is (共同约定 5): identity wechat, subject the unionid — the same
// person #3604's two roads sign in — or, when WeChat sends no unionid,
// wechat-mp with the openid, joined to the unionid once one arrives. Someone
// the list names comes straight in; anyone else goes to /apply as an
// applicant (C2 / C3), with no principal and no session. The openid is kept
// as where to reach them (hub_reach) for the notices C5 sends.
//
// Off — CCQUOTA_WX_INTERNAL_URL / _TOKEN unset — the routes 404 and /signin
// is byte for byte what it was. wxScene / wxScenePoll are the one way a code
// is drawn and read; C3's reach code and C9's binding draw theirs through
// them with their own purpose.

const (
	wxQRPath   = "/auth/wechat/qr"
	wxPollPath = "/auth/wechat/poll"
	// signinPollScriptPath is the sign-in page's one script (共同约定 10).
	signinPollScriptPath = AppPrefix + "/assets/signin-poll.js"

	// wxBrowserCookie is this browser's nonce: a code finishes only in the
	// browser it was drawn for.
	wxBrowserCookie = "ccq_wx_browser"
	wxBrowserTTL    = time.Hour

	wxPurposeLogin = "login"
	wxPurposeBind  = "bind"
	wxPurposeReach = "reach"
)

var (
	// wxSceneTTL is a code's life: what WeChat is asked for, and what the
	// page says (「二维码 10 分钟内有效」).
	wxSceneTTL = 10 * time.Minute
	// wxScenesPerMinute bounds the codes asked of WeChat hub-wide.
	wxScenesPerMinute = 120
)

// errWxBusy: the hub-wide bound on new codes is reached.
var errWxBusy = errors.New("too many codes asked for this minute")

// wxScanOn: the service account's road is configured.
func (s *Server) wxScanOn() bool { return s.WxGW.ready() && s.Store != nil }

// wxBrowserHash is this browser's nonce, hashed; set (or refreshed) on w.
func (s *Server) wxBrowserHash(w http.ResponseWriter, r *http.Request) string {
	nonce := ""
	if c, err := r.Cookie(wxBrowserCookie); err == nil && len(c.Value) >= 32 && len(c.Value) <= 64 {
		nonce = c.Value
	}
	if nonce == "" {
		nonce, _ = randomToken(24)
	}
	http.SetCookie(w, &http.Cookie{
		Name: wxBrowserCookie, Value: nonce, Path: "/",
		HttpOnly: true, SameSite: http.SameSiteLaxMode, Secure: isHTTPS(r),
		MaxAge: int(wxBrowserTTL.Seconds()),
	})
	return spentHash("wx-browser", nonce)
}

// wxBrowserHashOf is the nonce r carries, hashed; "" for none. Read-only:
// polling never mints one.
func wxBrowserHashOf(r *http.Request) string {
	c, err := r.Cookie(wxBrowserCookie)
	if err != nil || len(c.Value) < 32 || len(c.Value) > 64 {
		return ""
	}
	return spentHash("wx-browser", c.Value)
}

// randomScene is a scene number inside ClaudeFleet's range, at random.
func randomScene() int64 {
	var b [8]byte
	_, _ = rand.Read(b[:])
	return wxSceneMin + int64(binary.BigEndian.Uint64(b[:])%uint64(wxSceneMax-wxSceneMin))
}

// wxScene draws a code for this browser and purpose (owner: who a bind /
// reach code is for) — the one it already holds while that is good for
// another minute, else a new one: a number reserved first, then WeChat asked
// for its code, so two live codes never share a number.
func (s *Server) wxScene(ctx context.Context, w http.ResponseWriter, r *http.Request, purpose, owner string, now time.Time) (*store.WxScene, error) {
	bh := s.wxBrowserHash(w, r)
	if c, err := s.Store.LiveWxSceneFor(bh, purpose, owner, now.Add(time.Minute)); err != nil || c != nil {
		return c, err
	}
	if n, err := s.Store.WxScenesSince(now.Add(-time.Minute)); err != nil {
		return nil, err
	} else if n >= wxScenesPerMinute {
		return nil, errWxBusy
	}
	for try := 0; try < 5; try++ {
		c := store.WxScene{Scene: randomScene(), BrowserHash: bh, Purpose: purpose, Owner: owner,
			CreatedAt: now, ExpiresAt: now.Add(wxSceneTTL)}
		err := s.Store.CreateWxScene(c)
		if errors.Is(err, store.ErrWxSceneTaken) {
			continue
		}
		if err != nil {
			return nil, err
		}
		if c.QRURL, err = s.WxGW.qrCreate(ctx, c.Scene, wxSceneTTL); err != nil {
			return nil, err
		}
		if err := s.Store.SetWxSceneQR(c.Scene, c.QRURL); err != nil {
			return nil, err
		}
		return &c, nil
	}
	return nil, errors.New("no free scene number")
}

// The states of a code, as the page's script reads them.
const (
	wxWait    = "wait"
	wxReady   = "ready"
	wxExpired = "expired"
	wxDown    = "down"
)

// wxScenePoll says where code n stands for the browser asking: expired for a
// code this hub never drew, one drawn for another browser or purpose, one
// already traded or past its ten minutes; else who scanned it (ready +
// openid), nobody yet (wait), or workbench not answering (down).
func (s *Server) wxScenePoll(ctx context.Context, r *http.Request, n int64, purpose string, now time.Time) (string, *store.WxScene, string) {
	bh := wxBrowserHashOf(r)
	if !wxSceneInRange(n) || bh == "" {
		return wxExpired, nil, ""
	}
	c, err := s.Store.WxSceneOf(n)
	if err != nil {
		return wxDown, nil, ""
	}
	if c == nil || c.Purpose != purpose || c.QRURL == "" || !c.ConsumedAt.IsZero() || !now.Before(c.ExpiresAt) ||
		!constantTimeEqual(c.BrowserHash, bh) {
		return wxExpired, nil, ""
	}
	openid, err := s.WxGW.scanOpenid(ctx, n)
	switch {
	case err != nil:
		return wxDown, c, ""
	case openid == "":
		return wxWait, c, ""
	}
	return wxReady, c, openid
}

// handleWxQR draws a sign-in code for this browser: {s, qr (an SVG), expires_at}.
func (s *Server) handleWxQR(w http.ResponseWriter, r *http.Request) {
	if !s.wxScanOn() {
		http.NotFound(w, r)
		return
	}
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", "POST")
		httpError(w, http.StatusMethodNotAllowed, "POST only")
		return
	}
	if !sameOrigin(r) {
		httpError(w, http.StatusForbidden, "cross-site request refused")
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	purpose := orDefault(strings.TrimSpace(r.FormValue("purpose")), wxPurposeLogin)
	if purpose != wxPurposeLogin && (purpose != wxPurposeTrial || !s.trialOn()) {
		// bind / reach draw theirs from their own pages, through wxScene.
		httpError(w, http.StatusBadRequest, "purpose must be login (or trial, with the trial on)")
		return
	}
	if purpose == wxPurposeTrial {
		if code := s.siteTrialCode(time.Now()); code != nil {
			// The website's channel code (claude-fleet C2): scanned, it is
			// MRGB's road — followed, the trial opens and the chat is in
			// WeChat — so there is no scene for this browser to poll.
			writeJSON(w, http.StatusOK, map[string]any{"qr": string(qrSVG(code.URL)), "channel": code.Channel})
			return
		}
	}
	c, err := s.wxScene(r.Context(), w, r, purpose, "", time.Now())
	if err != nil {
		if !errors.Is(err, errWxBusy) {
			log.Printf("wechat scan: no code: %v", err)
		}
		httpError(w, http.StatusServiceUnavailable, "WeChat sign-in is not available right now")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"s": c.Scene, "qr": string(qrSVG(c.QRURL)), "expires_at": c.ExpiresAt.Unix()})
}

// siteTrialChannel names the 试用二维码 (MRGB) the website shows: an admin
// draws one with this channel, and the front page's scan card hands it out.
const siteTrialChannel = "site"

// siteTrialCode is the newest code of the website's channel that gives a
// trial with no approval right now; nil ⇒ the page draws its own code.
func (s *Server) siteTrialCode(now time.Time) *store.TrialCode {
	codes, err := s.Store.TrialCodes()
	if err != nil {
		log.Printf("wechat scan: trial codes: %v", err)
		return nil
	}
	for _, c := range codes {
		if strings.EqualFold(c.Channel, siteTrialChannel) && c.State == store.TrialCodeLive && !c.Approval &&
			c.URL != "" && (c.Until.IsZero() || now.Before(c.Until)) {
			return &c
		}
	}
	return nil
}

// handleWxPoll answers the page's script with a code's state, and finishes a
// scanned login code when asked as a page.
func (s *Server) handleWxPoll(w http.ResponseWriter, r *http.Request) {
	if !s.wxScanOn() {
		http.NotFound(w, r)
		return
	}
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", "GET")
		httpError(w, http.StatusMethodNotAllowed, "GET only")
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	now := time.Now()
	n, _ := strconv.ParseInt(r.URL.Query().Get("s"), 10, 64)
	purpose := wxPurposeLogin
	if r.URL.Query().Get("p") == wxPurposeTrial && s.trialOn() {
		purpose = wxPurposeTrial // a code drawn on the way to a trial (claude-fleet#4058)
	}
	state, c, openid := s.wxScenePoll(r.Context(), r, n, purpose, now)
	if !wantsHTML(r) {
		writeJSON(w, http.StatusOK, map[string]string{"s": state})
		return
	}
	switch state {
	case wxWait:
		http.Redirect(w, r, appURL("/signin")+"?s="+strconv.FormatInt(n, 10), http.StatusFound)
	case wxDown:
		http.Redirect(w, r, appURL("/signin")+"?e=wechat-down", http.StatusFound)
	case wxReady:
		s.wxFinishLogin(w, r, c, openid, purpose == wxPurposeTrial, now)
	default:
		http.Redirect(w, r, appURL("/signin")+"?e=wechat-expired", http.StatusFound)
	}
}

// wxFinishLogin trades a scanned login code, once, for whoever scanned it.
// trial: the code was drawn on the way to a trial (claude-fleet#4058).
func (s *Server) wxFinishLogin(w http.ResponseWriter, r *http.Request, c *store.WxScene, openid string, trial bool, now time.Time) {
	u, err := s.WxGW.userInfo(r.Context(), openid)
	if err != nil {
		log.Printf("wechat scan: user/info: %v", err)
		http.Redirect(w, r, appURL("/signin")+"?e=wechat-down", http.StatusFound)
		return
	}
	if ok, err := s.Store.ConsumeWxScene(c.Scene, c.BrowserHash, now); err != nil || !ok {
		if err != nil {
			log.Printf("wechat scan: %v", err)
		}
		http.Redirect(w, r, appURL("/signin")+"?e=wechat-expired", http.StatusFound)
		return
	}
	s.wxLand(w, r, u, trial, now)
}

// wxLand signs in whoever the service account says u is — the scan's road
// and the web-authorisation relay's (wx_relay.go) alike: someone on the list
// comes in, someone not on it goes to /apply as an applicant, and the openid
// is kept as where to reach them. trial: the sign-in is on its way to a
// trial (claude-fleet#4058) — a trial code, or the ccq_try note.
func (s *Server) wxLand(w http.ResponseWriter, r *http.Request, u wxUser, trial bool, now time.Time) {
	openid := u.OpenID
	kind, subject, err := s.wxIdentity(u, now)
	if err != nil {
		log.Printf("wechat scan: %v", err)
		httpError(w, http.StatusInternalServerError, "could not read the people list")
		return
	}
	name := u.Nickname
	if name == "" {
		name = pageT(s.pageLocale(w, r), "wx.user") + "·" + openid[max(0, len(openid)-4):]
	}
	invite := s.takeInviteCookie(w, r)
	pid, role, refusal, err := s.admitPerson(kind, subject, name, invite, now)
	if err != nil {
		log.Printf("wechat scan: %v", err)
		httpError(w, http.StatusInternalServerError, "could not read the people list")
		return
	}
	owner := pid
	if role == "" && refusal == denyNotListed {
		owner = store.ApplicantReachOwner(kind, subject)
	}
	if owner != "" {
		if err := s.Store.SetHubReach(store.HubReach{Owner: owner, Channel: store.ReachWeChatMP, Addr: openid,
			Followed: u.Followed, UpdatedAt: now}); err != nil {
			log.Printf("wechat scan: reach: %v", err)
		}
	}
	if role == "" && refusal == denyNotListed && s.trialSignIn(w, r, trial || s.trialAsked(r), kind, subject, name, "", now) {
		if pid, err := s.Store.IdentityPrincipal(kind, subject); err == nil && pid != "" {
			// Reach the trial person where they scanned: their turn, their
			// result (C5).
			_ = s.Store.SetHubReach(store.HubReach{Owner: pid, Channel: store.ReachWeChatMP, Addr: openid,
				Followed: u.Followed, UpdatedAt: now})
		}
		return
	}
	if trial && role != "" && role != roleTrial {
		// On the list already: the console is theirs, no trial
		// (claude-fleet#4058).
		clearCookie(w, r, tryCookie, "/")
		http.SetCookie(w, s.personCookie(r, kind, pid, name, role, now))
		s.onPrincipalSignIn(pid, name)
		http.Redirect(w, r, AppPrefix, http.StatusFound)
		return
	}
	if role == "" {
		if refusal == denyNotListed {
			s.notListedSignIn(w, r, kind, subject, name, now)
			return
		}
		s.waySignedOut(w, r, kind, refusal, subject, name, now)
		return
	}
	s.signInAs(w, r, kind, pid, name, role, now)
}

// wxIdentity is who a scan is (共同约定 5): wechat + the unionid when WeChat
// sent one — and a person known so far only by this openid gets the unionid
// hung on them, so the two are one from now on — else wechat-mp + the openid.
func (s *Server) wxIdentity(u wxUser, now time.Time) (kind, subject string, err error) {
	if u.UnionID == "" {
		return store.IdentityWeChatMP, u.OpenID, nil
	}
	pid, err := s.Store.IdentityPrincipal(store.IdentityWeChat, u.UnionID)
	if err != nil || pid != "" {
		return store.IdentityWeChat, u.UnionID, err
	}
	mp, err := s.Store.IdentityPrincipal(store.IdentityWeChatMP, u.OpenID)
	if err != nil {
		return "", "", err
	}
	if mp != "" {
		err := s.Store.AddHubIdentity(store.HubIdentity{Kind: store.IdentityWeChat, Subject: u.UnionID,
			PrincipalID: mp, VerifiedAt: now, AddedBy: "follow"})
		if err != nil && !errors.Is(err, store.ErrIdentityTaken) {
			return "", "", err
		}
		if err == nil {
			_ = s.Store.HubAudit(mp, "identity.add", "(wechat)", "ok", "wechat unionid joined to the service account's openid", now)
		}
	}
	return store.IdentityWeChat, u.UnionID, nil
}

// ── the sign-in page with the code up front ───────────────────────────────

// signinScanPage is /signin with the service account's code as the way in;
// the other ways folded under 「其他方式登录」.
type signinScanPage struct {
	pageView
	Note string
	// Mode: qr (a computer), mobile (a phone's browser: open it in WeChat,
	// the code folded), down (no code could be drawn).
	Mode  string
	Scene int64
	QR    template.HTML
	// PageURL is what 「在微信里打开」 copies.
	PageURL string
	// Apply: the person came to apply (?next=/apply).
	Apply bool
	// Trial: on the way to a trial (claude-fleet#4058) — the code is drawn
	// for one, and the page says scanning starts it.
	Trial bool
	// TrialOn: fleet.trial is on — only then does the plain lead offer the
	// trial (claude-fleet#4269).
	TrialOn bool
	// The other ways; OtherOpen unfolds them (WeChat is not answering).
	Email, GitHub, OtherOpen bool
}

// mobileBrowser: a phone's browser — it cannot scan its own screen.
func mobileBrowser(r *http.Request) bool {
	ua := r.UserAgent()
	return !inWeChat(r) && (strings.Contains(ua, "Mobi") || strings.Contains(ua, "Android") ||
		strings.Contains(ua, "iPhone") || strings.Contains(ua, "iPad"))
}

// renderSigninScan draws /signin with the code: this browser's live one when
// ?s= names it, else the one it holds, else a new one.
func (s *Server) renderSigninScan(w http.ResponseWriter, r *http.Request, loc, e string) {
	now := time.Now()
	page := signinScanPage{pageView: newPageView(r, loc), Mode: "qr", Apply: toApply(r), Trial: s.trialAsked(r), TrialOn: s.trialOn(),
		Email: s.Email.ready(), GitHub: s.GitHub.ready(), PageURL: s.nodeHubURL(r) + appURL("/signin")}
	purpose := wxPurposeLogin
	if page.Trial {
		purpose = wxPurposeTrial
	}
	if signinNotes[e] || signinWayNotes[e] {
		page.Note = pageT(loc, "signin.note."+e)
	}
	if mobileBrowser(r) {
		page.Mode = "mobile"
	}
	if r.Method == http.MethodHead {
		// Headers only: no code is asked of WeChat for nobody to see.
		entryHeaders(w, loc)
		w.Header().Set("Content-Security-Policy", signinScanCSP)
		return
	}
	var c *store.WxScene
	if n, err := strconv.ParseInt(r.URL.Query().Get("s"), 10, 64); err == nil && e == "" {
		if got, _ := s.Store.WxSceneOf(n); got != nil && got.Purpose == purpose && got.QRURL != "" &&
			got.ConsumedAt.IsZero() && now.Before(got.ExpiresAt) && constantTimeEqual(got.BrowserHash, wxBrowserHashOf(r)) {
			c = got
		}
	}
	if c == nil {
		var err error
		if c, err = s.wxScene(r.Context(), w, r, purpose, "", now); err != nil {
			if !errors.Is(err, errWxBusy) {
				log.Printf("wechat scan: no code: %v", err)
			}
			c = nil
		}
	}
	if c == nil {
		page.Mode, page.OtherOpen = "down", true
	} else {
		page.Scene, page.QR = c.Scene, qrSVG(c.QRURL)
	}
	if e == "wechat-down" {
		page.OtherOpen = true
	}
	entryHeaders(w, loc)
	w.Header().Set("Content-Security-Policy", signinScanCSP)
	w.Header().Add("Vary", "Accept-Language, Cookie, User-Agent")
	w.WriteHeader(http.StatusOK)
	if t, err := signinScanTmpl.Clone(); err == nil {
		_ = t.Funcs(pageFuncs(loc)).Execute(w, page)
	}
}

// signinScanCSP is entryCSP with the page's one same-origin script allowed.
const signinScanCSP = "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; connect-src 'self'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'"

// qrSVG draws text as a QR code: one path, a four-module quiet zone, the
// highest error correction — the WeChat mark sits on its middle.
func qrSVG(text string) template.HTML {
	c, err := qr.Encode(text, qr.H)
	if err != nil {
		return ""
	}
	rows := make([]string, c.Size)
	for y := range rows {
		var b strings.Builder
		for x := 0; x < c.Size; x++ {
			if c.Black(x, y) {
				b.WriteByte('#')
			} else {
				b.WriteByte('.')
			}
		}
		rows[y] = b.String()
	}
	n := len(rows) + 8
	var b strings.Builder
	fmt.Fprintf(&b, `<svg class="qr" viewBox="0 0 %d %d" shape-rendering="crispEdges" role="img" aria-label="QR"><path d="`, n, n)
	for y, row := range rows {
		for x := 0; x < len(row); {
			if row[x] != '#' {
				x++
				continue
			}
			run := strings.IndexByte(row[x:], '.')
			if run < 0 {
				run = len(row) - x
			}
			fmt.Fprintf(&b, "M%d %dh%dv1h-%dz", x+4, y+4, run, run)
			x += run
		}
	}
	b.WriteString(`"/></svg>`)
	return template.HTML(b.String())
}

const rotateIcon = `<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M3 12a9 9 0 1 0 9-9 9.75 9.75 0 0 0-6.74 2.74L3 8"/><path d="M3 3v5h5"/></svg>`

// signinScanCSS is what the page adds to entryCSS, as the prototype draws it.
const signinScanCSS = `[hidden]{display:none!important}
.qrcard{padding:20px;border:1px solid var(--border);border-radius:calc(var(--radius) + 4px);background:var(--card);color:var(--card-foreground);text-align:center}
.qrbox{position:relative;width:184px;height:184px;margin:0 auto 14px;border-radius:10px;overflow:hidden;border:1px solid var(--border);background:#fff}
.qrbox svg{width:100%;height:100%;stroke:none}
.qrbox svg.qr{fill:#000}
.qrbox .mid{position:absolute;inset:0;display:grid;place-items:center}
.qrbox .mid b{display:grid;place-items:center;width:40px;height:40px;border-radius:10px;background:#07c160;color:#fff;border:3px solid #fff}
.qrbox .mid b svg{width:22px;height:22px;stroke:#fff}
.qrbox .veil{position:absolute;inset:0;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:8px;background:color-mix(in oklab,var(--card) 92%,transparent);color:var(--foreground);font-size:14px;font-weight:500}
.qrbox .veil svg{width:28px;height:28px;stroke:currentColor}
.qrbox .veil.ok svg{color:var(--fleet-ok)}
.qrbox .veil .btn{width:auto;height:32px;padding:0 14px;font-size:13px}
.qrbox .veil .btn svg{width:16px;height:16px}
.qrcard .t{font-size:15px;font-weight:500}
.qrcard .s{margin-top:2px;font-size:13px;color:var(--muted-foreground)}
.qrcard.off{opacity:.55}
details.other{margin-top:24px;font-size:13px;color:var(--muted-foreground)}
details.other>summary{list-style:none;cursor:pointer;text-align:center;text-decoration:underline;text-underline-offset:3px}
details.other>summary::-webkit-details-marker{display:none}
details.other .in{margin-top:14px;padding:14px;border:1px solid var(--border);border-radius:var(--radius);display:grid;gap:10px}
details.other .stack{gap:6px}
details.other .input{height:38px;font-size:14px}
details.other .btn{height:38px}
details.other .lk{display:flex;gap:16px;justify-content:center;font-size:13px}
details.other .lk a{color:var(--muted-foreground)}
details.more{margin-top:10px;font-size:13px;color:var(--muted-foreground);text-align:left}
details.more summary{cursor:pointer;text-align:center}
details.more ol{margin:8px 0 0;padding-left:20px}
details.more .qrbox{margin-top:12px}
`

// signinAgree is the line under the way in (T883): signing in is agreeing to
// the user agreement and the privacy policy, both a link to the site's page.
const signinAgree = `<p class="agree">{{t "signin.agree.pre"}}<a href="{{t "signin.agree.terms.href"}}">{{t "signin.agree.terms"}}</a>{{t "signin.agree.and"}}<a href="{{t "signin.agree.privacy.href"}}">{{t "signin.agree.privacy"}}</a>{{t "signin.agree.end"}}</p>`

var signinScanTmpl = template.Must(template.New("signin-scan").Funcs(pageFuncs(i18n.EN)).Parse(authPageHead + `<style>` + signinScanCSS + `</style>
<title>{{t "signin.title"}}</title>{{if .Scene}}<noscript><meta http-equiv="refresh" content="2;url=` + wxPollPath + `?s={{.Scene}}{{if .Trial}}&amp;p=trial{{end}}"></noscript>{{end}}</head><body><div class="page">` + entryTop + `
<main class="col" id="wx"{{if .Scene}} data-s="{{.Scene}}"{{end}}{{if .Trial}} data-p="trial"{{end}}>
` + limitedPill + `<h1>{{t "signin.h1"}}<span class="dot">.</span></h1>
<p class="lead">{{if .Trial}}{{t "signin.wx.lead.trial"}}{{else if .Apply}}{{t "signin.wx.lead.apply"}}{{else if .TrialOn}}{{t "signin.wx.lead"}}{{else}}{{t "signin.wx.lead.notrial"}}{{end}}</p>
{{if .Note}}<p class="alert" role="status">` + alertIcon + `<span>{{.Note}}</span></p>{{end}}
{{if eq .Mode "mobile"}}<button class="btn wx" type="button" id="wxcopy" data-url="{{.PageURL}}">` + wechatIcon + `{{t "signin.wx.open"}}</button>
<p class="alert" id="wxcopied" role="status" hidden>` + checkIcon + `<span>{{t "signin.wx.copied"}}</span></p>
{{if .Scene}}<details class="more"><summary>{{t "signin.wx.orqr"}}</summary><ol><li>{{t "signin.wx.qr1"}}</li><li>{{t "signin.wx.qr2"}}</li><li>{{t "signin.wx.qr3"}}</li></ol>
<div class="qrbox">{{.QR}}<div class="mid"><b>` + wechatIcon + `</b></div></div></details>{{end}}
{{else if eq .Mode "down"}}<p class="alert" role="status">` + alertIcon + `<span>{{t "signin.wx.down"}}</span></p>
<div class="qrcard off"><div class="qrbox"><div class="veil">` + alertIcon + `{{t "signin.wx.down.veil"}}</div></div><p class="t">{{t "signin.wx.down.t"}}</p><p class="s">{{t "signin.wx.down.s"}}</p></div>
{{else}}<div class="qrcard"><div class="qrbox">{{.QR}}<div class="mid"><b>` + wechatIcon + `</b></div>
<div class="veil ok" id="wxok" hidden>` + checkIcon + `{{t "signin.wx.scanned"}}</div>
<div class="veil" id="wxgone" hidden>{{t "signin.wx.expired"}}<a class="btn primary" href="/app/signin">` + rotateIcon + `{{t "signin.wx.again"}}</a></div></div>
<p class="t">{{t "signin.wx.t"}}</p><p class="s">{{t "signin.wx.s"}}</p></div>
<p class="alert" id="wxdown" role="status" hidden>` + alertIcon + `<span>{{t "signin.wx.down"}}</span></p>{{end}}
` + signinAgree + `
{{if or .Email .GitHub}}<details class="other" id="other"{{if .OtherOpen}} open{{end}}><summary>{{t "signin.wx.other"}}</summary><div class="in">
{{if .Email}}<form class="stack" method="post" action="/auth/email/start"><input class="input" type="email" name="email" autocomplete="email" required aria-label="{{t "signin.email.label"}}" placeholder="{{t "signin.wx.email.placeholder"}}">
<button class="btn outline" type="submit">{{t "signin.wx.email.button"}}</button></form>{{end}}
{{if .GitHub}}<div class="lk"><a href="/auth/github/start">{{t "signin.wx.github"}}</a></div>{{end}}
</div></details>{{end}}
<p class="fine">{{t "signin.ways.fine.wechat"}}</p>
</main></div><script src="` + signinPollScriptPath + `"></script></body></html>`))

// serveSigninPollScript is the sign-in page's script.
func serveSigninPollScript(w http.ResponseWriter, r *http.Request) {
	h := w.Header()
	h.Set("Content-Type", "text/javascript; charset=utf-8")
	h.Set("Cache-Control", "public, max-age=300")
	h.Set("X-Content-Type-Options", "nosniff")
	if r.Method == http.MethodHead {
		return
	}
	_, _ = w.Write([]byte(signinPollScript))
}

// signinPollScript runs the page: 「在微信里打开」 copies the link; the code is
// asked about every two seconds, and once scanned the browser goes to finish
// it. No script: <meta refresh> does the asking.
const signinPollScript = `(function () {
  var m = document.getElementById("wx");
  if (!m) return;
  var $ = function (id) { return document.getElementById(id); };
  var copy = $("wxcopy");
  if (copy) copy.addEventListener("click", function () {
    var u = copy.getAttribute("data-url"), done = function () { $("wxcopied").hidden = false; };
    if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(u).then(done, function () { window.prompt("", u); });
    else window.prompt("", u);
  });
  var s = m.getAttribute("data-s");
  if (!s) return;
  var downs = 0, url = "` + wxPollPath + `?s=" + encodeURIComponent(s) + (m.getAttribute("data-p") === "trial" ? "&p=trial" : "");
  function tick() {
    fetch(url, { headers: { Accept: "application/json" }, credentials: "same-origin", cache: "no-store" })
      .then(function (r) { return r.ok ? r.json() : { s: "down" }; }, function () { return { s: "down" }; })
      .then(function (j) {
        if (j.s === "ready") { if ($("wxok")) $("wxok").hidden = false; location.assign(url); return; }
        if (j.s === "expired") { if ($("wxgone")) $("wxgone").hidden = false; return; }
        if (j.s === "down") {
          if (++downs >= 3) { if ($("wxdown")) $("wxdown").hidden = false; if ($("other")) $("other").open = true; }
        } else downs = 0;
        setTimeout(tick, 2000);
      });
  }
  setTimeout(tick, 2000);
})();
`

func init() {
	for k, v := range map[string]i18n.Text{
		"wx.user":                   {i18n.EN: "WeChat user", i18n.ZhCN: "微信用户"},
		"signin.agree.pre":          {i18n.EN: "By signing in you agree to the ", i18n.ZhCN: "登录即表示你同意"},
		"signin.agree.terms":        {i18n.EN: "Terms of Service", i18n.ZhCN: "《用户协议》"},
		"signin.agree.and":          {i18n.EN: " and the ", i18n.ZhCN: "和"},
		"signin.agree.privacy":      {i18n.EN: "Privacy Policy", i18n.ZhCN: "《隐私政策》"},
		"signin.agree.end":          {i18n.EN: ".", i18n.ZhCN: "。"},
		"signin.agree.terms.href":   {i18n.EN: "/en/terms", i18n.ZhCN: "/terms"},
		"signin.agree.privacy.href": {i18n.EN: "/en/privacy", i18n.ZhCN: "/privacy"},
		"signin.wx.lead": {
			i18n.EN:   "Scan with WeChat and follow 二四网络科技 to sign in. Not on the list yet? Sign in, then try it and apply right there.",
			i18n.ZhCN: "用微信扫码关注「二四网络科技」登录。还不在名单上的，登录后可以先试用、当场申请。",
		},
		"signin.wx.lead.notrial": {
			i18n.EN:   "Scan with WeChat and follow 二四网络科技 to sign in. Not on the list yet? Sign in, then apply right there.",
			i18n.ZhCN: "用微信扫码关注「二四网络科技」登录。还不在名单上的，登录后当场申请。",
		},
		"signin.wx.lead.trial": {
			i18n.EN:   "Scan with WeChat and follow 二四网络科技 — your trial starts right away. One trial per account; email or GitHub work too, under other ways.",
			i18n.ZhCN: "用微信扫码关注「二四网络科技」，马上开始试用。一个账号试一次；也可以用下面的邮箱或 GitHub。",
		},
		"signin.wx.lead.apply": {
			i18n.EN:   "Scan to sign in first, then fill in the application; the answer comes to your WeChat.",
			i18n.ZhCN: "先扫码登录，再填申请；结果会发到你的微信。",
		},
		"signin.wx.t": {i18n.EN: "Scan with WeChat and follow 二四网络科技 to sign in", i18n.ZhCN: "微信扫一扫，关注「二四网络科技」即登录"},
		"signin.wx.s": {
			i18n.EN:   "Already following? Just scan · the code lasts 10 minutes",
			i18n.ZhCN: "已经关注过的直接扫 · 二维码 10 分钟内有效",
		},
		"signin.wx.scanned": {i18n.EN: "Scanned — signing you in…", i18n.ZhCN: "已扫码，正在登录…"},
		"signin.wx.expired": {i18n.EN: "This code has expired", i18n.ZhCN: "二维码已过期"},
		"signin.wx.again":   {i18n.EN: "Get a new one", i18n.ZhCN: "换一个"},
		"signin.wx.down": {
			i18n.EN:   "WeChat sign-in isn't available right now (the service account isn't answering). Sign in with email or GitHub for now — the list and applying work the same.",
			i18n.ZhCN: "微信登录暂时不可用（公众号那边没有回应）。先用邮箱或 GitHub 登录，名单和申请都一样。",
		},
		"signin.wx.down.veil": {i18n.EN: "Not available", i18n.ZhCN: "暂时不可用"},
		"signin.wx.down.t":    {i18n.EN: "Scan with WeChat", i18n.ZhCN: "微信扫码"},
		"signin.wx.down.s":    {i18n.EN: "Try again later", i18n.ZhCN: "稍后再试"},
		"signin.wx.open":      {i18n.EN: "Open in WeChat", i18n.ZhCN: "在微信里打开"},
		"signin.wx.copied": {
			i18n.EN:   "Link copied. Open WeChat, send it to File Transfer and tap it there — you'll be signed in without scanning.",
			i18n.ZhCN: "链接已复制。打开微信，发给「文件传输助手」再点开，就会直接登录，不用扫码。",
		},
		"signin.wx.orqr":  {i18n.EN: "Or use the QR code", i18n.ZhCN: "或者用二维码"},
		"signin.wx.qr1":   {i18n.EN: "Long-press the code below and save it to your photos", i18n.ZhCN: "长按下面的二维码存到相册"},
		"signin.wx.qr2":   {i18n.EN: "In WeChat, open Scan and pick Album at the top right", i18n.ZhCN: "打开微信「扫一扫」，右上角选「相册」"},
		"signin.wx.qr3":   {i18n.EN: "Choose the picture, follow, then come back here", i18n.ZhCN: "选这张图，关注后回到这里"},
		"signin.wx.other": {i18n.EN: "Other ways to sign in", i18n.ZhCN: "其他方式登录"},
		"signin.wx.email.placeholder": {
			i18n.EN: "Email you@example.com", i18n.ZhCN: "邮箱 you@example.cn",
		},
		"signin.wx.email.button": {i18n.EN: "Email me a code", i18n.ZhCN: "发验证码"},
		"signin.wx.github":       {i18n.EN: "Sign in with GitHub", i18n.ZhCN: "用 GitHub 登录"},
		"signin.note.wechat-expired": {
			i18n.EN:   "That code has expired or was already used. Here's a new one.",
			i18n.ZhCN: "那个二维码已过期或已用过，换了一个新的。",
		},
		"signin.note.wechat-down": {
			i18n.EN:   "WeChat isn't answering right now. Try again in a minute, or use another way below.",
			i18n.ZhCN: "微信那边暂时没有回应。过一分钟再试，或者用下面的其他方式。",
		},
	} {
		pageText[k] = v
	}
}
