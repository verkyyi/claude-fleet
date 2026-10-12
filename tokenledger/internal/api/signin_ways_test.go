package api

import (
	"context"
	"io"
	"net/http"
	"net/http/cookiejar"
	"net/http/httptest"
	"net/url"
	"regexp"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/authz"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/i18n"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// claude-fleet#3604 (EPIC #3570 C11): WeChat first, a mail as the spare,
// GitHub kept.

// fakeWeChat stands in for api.weixin.qq.com: a code is good once, for the
// app it was issued to, and says which unionid it belongs to.
type fakeWeChat struct {
	mu     sync.Mutex
	srv    *httptest.Server
	codes  map[string]fakeWXGrant // code → grant
	tokens map[string]fakeWXGrant // access token → grant
	traded int
}

type fakeWXGrant struct {
	appid, union, nick string
}

func newFakeWeChat(t *testing.T) *fakeWeChat {
	f := &fakeWeChat{codes: map[string]fakeWXGrant{}, tokens: map[string]fakeWXGrant{}}
	mux := http.NewServeMux()
	mux.HandleFunc("/sns/oauth2/access_token", func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query()
		f.mu.Lock()
		defer f.mu.Unlock()
		f.traded++
		g, ok := f.codes[q.Get("code")]
		secretOK := q.Get("secret") == "sec-"+q.Get("appid")
		if !ok || g.appid != q.Get("appid") || !secretOK || q.Get("grant_type") != "authorization_code" {
			writeJSON(w, http.StatusOK, map[string]any{"errcode": 40029, "errmsg": "invalid code"})
			return
		}
		delete(f.codes, q.Get("code"))
		tok := "tok-" + q.Get("code")
		f.tokens[tok] = g
		// The website app's answer carries the unionid; the service
		// account's (snsapi_userinfo) leaves it to userinfo.
		out := map[string]any{"access_token": tok, "openid": "open-" + g.appid + "-" + g.union, "scope": "x"}
		if g.appid == "web-app" {
			out["unionid"] = g.union
		}
		writeJSON(w, http.StatusOK, out)
	})
	mux.HandleFunc("/sns/userinfo", func(w http.ResponseWriter, r *http.Request) {
		f.mu.Lock()
		defer f.mu.Unlock()
		g, ok := f.tokens[r.URL.Query().Get("access_token")]
		if !ok {
			writeJSON(w, http.StatusOK, map[string]any{"errcode": 40001})
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"nickname": g.nick, "unionid": g.union, "openid": "x"})
	})
	f.srv = httptest.NewServer(mux)
	t.Cleanup(f.srv.Close)
	return f
}

func (f *fakeWeChat) grant(code, appid, union, nick string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.codes[code] = fakeWXGrant{appid, union, nick}
}

// sentMail is one mail the fake sender took.
type sentMail struct{ to, subject, body string }

type waysHarness struct {
	*ghHarness
	wx    *fakeWeChat
	mails chan sentMail
}

// newWaysHarness: a hub with GitHub, WeChat (both apps) and mail on.
func newWaysHarness(t *testing.T) *waysHarness {
	t.Helper()
	wx := newFakeWeChat(t)
	mails := make(chan sentMail, 16)
	gh := newGitHubHarnessWith(t, func(s *Server) {
		s.WeChat = &WeChatAuth{WebAppID: "web-app", WebSecret: "sec-web-app", MPAppID: "mp-app", MPSecret: "sec-mp-app",
			AuthorizeBase: "https://open.example", APIBase: wx.srv.URL}
		s.Email = &EmailAuth{Send: func(_ context.Context, to, subject, body string) error {
			mails <- sentMail{to, subject, body}
			return nil
		}}
	})
	return &waysHarness{ghHarness: gh, wx: wx, mails: mails}
}

// browser is one browser: its own cookie jar, never following a redirect.
type browser struct {
	t  *testing.T
	c  *http.Client
	ua string
}

func newBrowser(t *testing.T, ua string) *browser {
	jar, _ := cookiejar.New(nil)
	return &browser{t: t, ua: ua, c: &http.Client{Jar: jar, CheckRedirect: func(*http.Request, []*http.Request) error {
		return http.ErrUseLastResponse
	}}}
}

func (b *browser) do(method, u string, form url.Values) (*http.Response, string) {
	b.t.Helper()
	var body io.Reader
	if form != nil {
		body = strings.NewReader(form.Encode())
	}
	req, _ := http.NewRequest(method, u, body)
	if form != nil {
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	}
	req.Header.Set("Accept", "text/html")
	if b.ua != "" {
		req.Header.Set("User-Agent", b.ua)
	}
	resp, err := b.c.Do(req)
	if err != nil {
		b.t.Fatal(err)
	}
	defer resp.Body.Close()
	out, _ := io.ReadAll(resp.Body)
	return resp, string(out)
}

// session is the person this browser is signed in as ("" for none) and how.
func (b *browser) session(h *waysHarness) (pid, via string) {
	u, _ := url.Parse(h.http.URL + "/")
	for _, c := range b.c.Jar.Cookies(u) {
		if c.Name == authz.CookieName {
			s, err := authz.VerifySession(c.Value, h.srv.sessionKey(), time.Now())
			if err == nil {
				return s.UID, s.Sub
			}
		}
	}
	return "", ""
}

const wechatUA = "Mozilla/5.0 (iPhone) AppleWebKit/605.1.15 Mobile/15E148 MicroMessenger/8.0.50(0x1800322d) NetType/WIFI"

// scan walks one WeChat sign-in in b: start, WeChat's consent (the fake
// grants code to the app the start chose), callback. Returns the callback's
// answer and which app the start sent the browser to.
func (h *waysHarness) scan(t *testing.T, b *browser, code, union, nick string) (*http.Response, string) {
	t.Helper()
	resp, _ := b.do(http.MethodGet, h.http.URL+"/auth/wechat/start", nil)
	if resp.StatusCode != http.StatusFound {
		t.Fatalf("start = %d", resp.StatusCode)
	}
	to, _ := url.Parse(resp.Header.Get("Location"))
	app := to.Query().Get("appid")
	if to.Fragment != "wechat_redirect" || to.Query().Get("redirect_uri") != h.http.URL+"/auth/wechat/callback" {
		t.Fatalf("start sent the browser to %s", resp.Header.Get("Location"))
	}
	h.wx.grant(code, app, union, nick)
	cb, _ := b.do(http.MethodGet, h.http.URL+"/auth/wechat/callback?code="+code+"&state="+url.QueryEscape(to.Query().Get("state")), nil)
	return cb, to.Path + " " + app + " " + to.Query().Get("scope")
}

// A person's WeChat signs them in by either road — the computer's scan and
// WeChat's own browser — as the one person its unionid is hung on.
func TestWeChatTwoRoadsOnePerson(t *testing.T) {
	h := newWaysHarness(t)
	pid, _ := newPersonPrincipal()
	if err := h.srv.Store.UpsertHubUser(store.HubUser{PrincipalID: pid, Login: "Xiaolin", Role: store.RoleUser, AddedBy: "test", AddedAt: time.Now()}); err != nil {
		t.Fatal(err)
	}
	if err := h.srv.Store.AddHubIdentity(store.HubIdentity{Kind: store.IdentityWeChat, Subject: "union-xl", PrincipalID: pid, VerifiedAt: time.Now()}); err != nil {
		t.Fatal(err)
	}

	pc := newBrowser(t, "Mozilla/5.0 (Macintosh)")
	cb, road := h.scan(t, pc, "c-web", "union-xl", "小林")
	if road != "/connect/qrconnect web-app snsapi_login" {
		t.Fatalf("a computer went %q; want the website app's QR code", road)
	}
	if cb.StatusCode != http.StatusFound || cb.Header.Get("Location") != AppPrefix {
		t.Fatalf("scan callback = %d → %q", cb.StatusCode, cb.Header.Get("Location"))
	}
	if got, via := pc.session(h); got != pid || via != store.IdentityWeChat {
		t.Fatalf("the scan signed in %q via %q; want %s via wechat", got, via, pid)
	}

	phone := newBrowser(t, wechatUA)
	// Inside WeChat, /signin goes straight to the authorisation: no scan.
	if resp, _ := phone.do(http.MethodGet, h.http.URL+AppPrefix+"/signin", nil); resp.StatusCode != http.StatusFound ||
		resp.Header.Get("Location") != "/auth/wechat/start" {
		t.Fatalf("/signin inside WeChat = %d → %q", resp.StatusCode, resp.Header.Get("Location"))
	}
	cb, road = h.scan(t, phone, "c-mp", "union-xl", "小林")
	if road != "/connect/oauth2/authorize mp-app snsapi_userinfo" {
		t.Fatalf("WeChat's browser went %q; want the service account", road)
	}
	if got, _ := phone.session(h); cb.StatusCode != http.StatusFound || got != pid {
		t.Fatalf("the service account signed in %q (%d); want the same person %s", got, cb.StatusCode, pid)
	}
	// /v1/me says how.
	resp, body := phone.do(http.MethodGet, h.http.URL+"/v1/me", nil)
	if resp.StatusCode != 200 || !strings.Contains(body, `"via":"wechat"`) {
		t.Fatalf("/v1/me = %d %s", resp.StatusCode, body)
	}
}

// BREAK-IT wechat-first-scan-autocreate: a WeChat nobody's account carries
// opens no account by itself. It waits on the binding page, which binds it
// to the signed-in person or lets it in on an invite — only when pressed.
func TestWeChatFirstScanOpensNoAccount(t *testing.T) {
	h := newWaysHarness(t)
	people := func() int {
		u, err := h.srv.Store.HubUsers()
		if err != nil {
			t.Fatal(err)
		}
		return len(u)
	}
	before := people()

	// Nobody, no invite: the binding page, no account, no session.
	stranger := newBrowser(t, "")
	cb, _ := h.scan(t, stranger, "c1", "union-new", "陌生人")
	if cb.StatusCode != http.StatusFound || cb.Header.Get("Location") != "/auth/wechat/bind" {
		t.Fatalf("first scan = %d → %q; want the binding page", cb.StatusCode, cb.Header.Get("Location"))
	}
	if pid, _ := stranger.session(h); pid != "" {
		t.Fatalf("a first scan signed someone in: %s", pid)
	}
	if n := people(); n != before {
		t.Fatalf("a first scan put someone on the list (%d → %d)", before, n)
	}
	if pid, _ := h.srv.Store.IdentityPrincipal(store.IdentityWeChat, "union-new"); pid != "" {
		t.Fatalf("a first scan hung the WeChat on %s", pid)
	}
	resp, body := stranger.do(http.MethodGet, h.http.URL+"/auth/wechat/bind", nil)
	if resp.StatusCode != 200 || !strings.Contains(body, pageT(i18n.EN, "wxbind.none")) || strings.Contains(body, `name="action"`) {
		t.Fatalf("binding page with nothing to bind to = %d, offers a button or no advice", resp.StatusCode)
	}
	// Forcing it anyway opens nothing.
	resp, _ = stranger.do(http.MethodPost, h.http.URL+"/auth/wechat/bind", url.Values{"action": {"invite"}})
	if pid, _ := stranger.session(h); pid != "" || people() != before {
		t.Fatalf("a forced bind opened an account (%d)", resp.StatusCode)
	}

	// Signed in another way: the page offers this account, and binds on the press.
	alice := newBrowser(t, "")
	pid, _ := newPersonPrincipal()
	_ = h.srv.Store.UpsertHubUser(store.HubUser{PrincipalID: pid, Login: "Alice", Role: store.RoleUser, AddedBy: "test", AddedAt: time.Now()})
	_ = h.srv.Store.AddHubIdentity(store.HubIdentity{Kind: store.IdentityEmail, Subject: "alice@example.com", PrincipalID: pid, VerifiedAt: time.Now()})
	u, _ := url.Parse(h.http.URL + "/")
	alice.c.Jar.SetCookies(u, []*http.Cookie{{Name: authz.CookieName, Path: "/",
		Value: authz.SignRole(store.IdentityEmail, pid, "Alice", roleUser, h.srv.sessionKey(), time.Now(), time.Hour)}})
	if cb, _ := h.scan(t, alice, "c2", "union-alice", "爱丽丝"); cb.Header.Get("Location") != "/auth/wechat/bind" {
		t.Fatalf("alice's first scan → %q", cb.Header.Get("Location"))
	}
	if got, _ := h.srv.Store.IdentityPrincipal(store.IdentityWeChat, "union-alice"); got != "" {
		t.Fatal("bound before the press")
	}
	_, body = alice.do(http.MethodGet, h.http.URL+"/auth/wechat/bind", nil)
	if !strings.Contains(body, `value="link"`) || !strings.Contains(body, "<b>Alice</b>") {
		t.Fatalf("the binding page does not offer Alice's account")
	}
	resp, _ = alice.do(http.MethodPost, h.http.URL+"/auth/wechat/bind", url.Values{"action": {"link"}})
	if got, _ := h.srv.Store.IdentityPrincipal(store.IdentityWeChat, "union-alice"); resp.StatusCode != http.StatusFound || got != pid {
		t.Fatalf("link = %d, WeChat now %q's", resp.StatusCode, got)
	}
	// One use: the same binding cannot be pressed again.
	if resp, _ = alice.do(http.MethodPost, h.http.URL+"/auth/wechat/bind", url.Values{"action": {"link"}}); !strings.Contains(resp.Header.Get("Location"), "e=expired") {
		t.Fatalf("a second press = %q", resp.Header.Get("Location"))
	}
	// From now on a scan signs her straight in.
	again := newBrowser(t, "")
	if cb, _ := h.scan(t, again, "c3", "union-alice", "爱丽丝"); cb.Header.Get("Location") != AppPrefix {
		t.Fatalf("second scan → %q", cb.Header.Get("Location"))
	}
	if got, via := again.session(h); got != pid || via != store.IdentityWeChat {
		t.Fatalf("second scan signed in %q via %q", got, via)
	}

	// An invite: a new person, with this WeChat, only on the press.
	now := time.Now()
	const code = "wxinvitewxinvitewxinv"
	if err := h.srv.Store.CreateInvite(store.Invite{ID: "inv_wx", CodeHash: inviteHash(code), CreatedBy: "admin",
		CreatedAt: now, ExpiresAt: now.Add(store.InviteTTL)}); err != nil {
		t.Fatal(err)
	}
	newbie := newBrowser(t, "")
	if resp, _ := newbie.do(http.MethodGet, h.http.URL+InvitePath+code, nil); resp.StatusCode != http.StatusFound {
		t.Fatalf("invite link = %d", resp.StatusCode)
	}
	if c := newbie.c.Jar.Cookies(mustURL(h.http.URL + "/auth/wechat/bind")); !hasCookie(c, inviteCookie) {
		t.Fatal("the invite does not ride to the WeChat sign-in")
	}
	before = people()
	if cb, _ := h.scan(t, newbie, "c4", "union-newbie", "新人"); cb.Header.Get("Location") != "/auth/wechat/bind" {
		t.Fatalf("an invited first scan → %q; want the binding page", cb.Header.Get("Location"))
	}
	if people() != before {
		t.Fatal("an invited first scan opened an account before the press")
	}
	_, body = newbie.do(http.MethodGet, h.http.URL+"/auth/wechat/bind", nil)
	if !strings.Contains(body, `value="invite"`) {
		t.Fatal("the binding page does not offer the invite")
	}
	resp, _ = newbie.do(http.MethodPost, h.http.URL+"/auth/wechat/bind", url.Values{"action": {"invite"}})
	got, via := newbie.session(h)
	if resp.StatusCode != http.StatusFound || !strings.HasPrefix(got, personPrincipalPrefix) || via != store.IdentityWeChat {
		t.Fatalf("invite press = %d, signed in %q via %q", resp.StatusCode, got, via)
	}
	if owner, _ := h.srv.Store.IdentityPrincipal(store.IdentityWeChat, "union-newbie"); owner != got || people() != before+1 {
		t.Fatalf("the invited WeChat is %q's; people %d", owner, people())
	}
}

func mustURL(s string) *url.URL { u, _ := url.Parse(s); return u }

func hasCookie(cs []*http.Cookie, name string) bool {
	for _, c := range cs {
		if c.Name == name {
			return true
		}
	}
	return false
}

// A WeChat callback replayed — same browser, same state, the flow cookie
// put back — is refused before WeChat is asked anything.
func TestWeChatStateReplayRefused(t *testing.T) {
	h := newWaysHarness(t)
	pid, _ := newPersonPrincipal()
	_ = h.srv.Store.UpsertHubUser(store.HubUser{PrincipalID: pid, Login: "R", Role: store.RoleUser, AddedBy: "test", AddedAt: time.Now()})
	_ = h.srv.Store.AddHubIdentity(store.HubIdentity{Kind: store.IdentityWeChat, Subject: "union-r", PrincipalID: pid, VerifiedAt: time.Now()})

	b := newBrowser(t, "")
	resp, _ := b.do(http.MethodGet, h.http.URL+"/auth/wechat/start", nil)
	flow := cookieNamed(resp, wechatFlowCookie)
	to, _ := url.Parse(resp.Header.Get("Location"))
	cbURL := h.http.URL + "/auth/wechat/callback?code=c-r&state=" + url.QueryEscape(to.Query().Get("state"))
	h.wx.grant("c-r", "web-app", "union-r", "R")
	h.wx.grant("c-r2", "web-app", "union-r", "R")
	if cb, _ := b.do(http.MethodGet, cbURL, nil); cb.Header.Get("Location") != AppPrefix {
		t.Fatalf("first callback → %q", cb.Header.Get("Location"))
	}
	traded := h.wx.traded
	// The attacker's copy: a fresh browser with the flow cookie and the URL.
	other := newBrowser(t, "")
	other.c.Jar.SetCookies(mustURL(h.http.URL+wechatFlowPath), []*http.Cookie{{Name: flow.Name, Value: flow.Value, Path: wechatFlowPath}})
	cb, _ := other.do(http.MethodGet, strings.Replace(cbURL, "code=c-r", "code=c-r2", 1), nil)
	if !strings.Contains(cb.Header.Get("Location"), "e=expired") {
		t.Fatalf("a replayed state → %q; want refused", cb.Header.Get("Location"))
	}
	if pid, _ := other.session(h); pid != "" || h.wx.traded != traded {
		t.Fatalf("a replayed state signed in %q / asked WeChat again (%d → %d)", pid, traded, h.wx.traded)
	}
	// A forged state: refused the same way.
	if cb, _ := newBrowser(t, "").do(http.MethodGet, h.http.URL+"/auth/wechat/callback?code=x&state=forged", nil); !strings.Contains(cb.Header.Get("Location"), "e=expired") {
		t.Fatalf("a callback with no flow → %q", cb.Header.Get("Location"))
	}
}

// With no WeChat and no mail configured, /signin is GitHub's page, byte for
// byte; with them, the ways are in the one order: WeChat · mail · GitHub.
func TestSigninPageWays(t *testing.T) {
	gh := newGitHubHarness(t)
	resp, body := newBrowser(t, "").do(http.MethodGet, gh.http.URL+AppPrefix+"/signin", nil)
	want := httptest.NewRecorder()
	writeAuthPage(want, http.StatusOK, signinTmpl, i18n.EN, signinPage{pageView: newPageView(httptest.NewRequest("GET", AppPrefix+"/signin", nil), i18n.EN)})
	if resp.StatusCode != 200 || body != want.Body.String() {
		t.Fatalf("GitHub-only /signin changed (%d):\n%s", resp.StatusCode, body)
	}
	for _, p := range []string{"/auth/wechat/start", "/auth/email/start", "/auth/wechat/bind", "/auth/email/link"} {
		if r, _ := newBrowser(t, "").do(http.MethodGet, gh.http.URL+p, nil); r.StatusCode != http.StatusNotFound {
			t.Errorf("%s with the way off = %d; want 404", p, r.StatusCode)
		}
	}

	h := newWaysHarness(t)
	_, body = newBrowser(t, "").do(http.MethodGet, h.http.URL+AppPrefix+"/signin", nil)
	iw, ie, ig := strings.Index(body, `href="/auth/wechat/start"`), strings.Index(body, `action="/auth/email/start"`), strings.Index(body, `href="/auth/github/start"`)
	if iw < 0 || ie < 0 || ig < 0 || !(iw < ie && ie < ig) {
		t.Fatalf("ways on /signin at wechat %d · email %d · github %d; want all three, in that order", iw, ie, ig)
	}
	// No GitHub at all: WeChat and mail alone still sign people in.
	h2 := newGitHubHarnessWith(t, func(s *Server) {
		s.GitHub = nil
		s.WeChat = &WeChatAuth{MPAppID: "mp-app", MPSecret: "sec-mp-app"}
		s.SessionSecret = "dev-only-session-secret"
	})
	resp, body = newBrowser(t, "").do(http.MethodGet, h2.http.URL+AppPrefix+"/signin", nil)
	if resp.StatusCode != 200 || strings.Contains(body, "/auth/github/start") {
		t.Fatalf("a hub with no GitHub: /signin = %d, offers GitHub: %v", resp.StatusCode, strings.Contains(body, "github"))
	}
	// Only the service account (the website app still in review): a computer
	// is told to open the page in WeChat, not sent to a QR code.
	if resp, _ = newBrowser(t, "").do(http.MethodGet, h2.http.URL+"/auth/wechat/start", nil); !strings.Contains(resp.Header.Get("Location"), "e=wechat-app") {
		t.Fatalf("start on a computer with no website app → %q", resp.Header.Get("Location"))
	}
}

var (
	mailLinkRE = regexp.MustCompile(`https?://\S+/auth/email/link\?t=[A-Za-z0-9_-]+`)
	mailCodeRE = regexp.MustCompile(`\b(\d{6})\b`)
)

func (h *waysHarness) mail(t *testing.T) sentMail {
	t.Helper()
	select {
	case m := <-h.mails:
		return m
	case <-time.After(5 * time.Second):
		t.Fatal("no mail was sent")
	}
	return sentMail{}
}

func (h *waysHarness) noMail(t *testing.T) {
	t.Helper()
	select {
	case m := <-h.mails:
		t.Fatalf("a mail was sent to %s", m.to)
	case <-time.After(200 * time.Millisecond):
	}
}

func (h *waysHarness) startMail(t *testing.T, b *browser, addr string) *http.Response {
	t.Helper()
	resp, _ := b.do(http.MethodPost, h.http.URL+"/auth/email/start", url.Values{"email": {addr}})
	return resp
}

// BREAK-IT email-link-replay: a mail's link signs in once, in the browser
// that asked; replayed — or opened on another device — it opens nothing.
// Unknown addresses are answered alike and mailed nothing; the limits hold.
func TestEmailSignIn(t *testing.T) {
	h := newWaysHarness(t)
	pid, _ := newPersonPrincipal()
	_ = h.srv.Store.UpsertHubUser(store.HubUser{PrincipalID: pid, Login: "Dana", Role: store.RoleUser, AddedBy: "test", AddedAt: time.Now()})
	_ = h.srv.Store.AddHubIdentity(store.HubIdentity{Kind: store.IdentityEmail, Subject: "dana@example.com", PrincipalID: pid, VerifiedAt: time.Now()})

	// Unknown and known answer the same; only the known one gets a mail.
	nobody := newBrowser(t, "")
	r1 := h.startMail(t, nobody, "nobody@example.com")
	h.noMail(t)
	pc := newBrowser(t, "")
	r2 := h.startMail(t, pc, "Dana@Example.com")
	if r1.StatusCode != r2.StatusCode || r1.Header.Get("Location") != r2.Header.Get("Location") || r2.StatusCode != http.StatusSeeOther {
		t.Fatalf("unknown %d → %q vs known %d → %q: they must read the same", r1.StatusCode, r1.Header.Get("Location"), r2.StatusCode, r2.Header.Get("Location"))
	}
	m := h.mail(t)
	link, code := mailLinkRE.FindString(m.body), mailCodeRE.FindStringSubmatch(m.body)
	if m.to != "dana@example.com" || link == "" || code == nil {
		t.Fatalf("mail to %q carries link %q code %v", m.to, link, code)
	}
	if n := countSigninCodes(t, h, "nobody@example.com"); n != 1 {
		t.Fatalf("the unknown address left %d rows; want 1, like any other", n)
	}

	// Another device: the link opens nothing and stays good.
	phone := newBrowser(t, "")
	if resp, _ := phone.do(http.MethodGet, link, nil); !strings.Contains(resp.Header.Get("Location"), "e=email-device") {
		t.Fatalf("link on another device → %q", resp.Header.Get("Location"))
	}
	if got, _ := phone.session(h); got != "" {
		t.Fatal("the link signed another device in")
	}
	// The browser that asked: signed in.
	asked := pc.c.Jar.Cookies(mustURL(h.http.URL + emailFlowPath))
	resp, _ := pc.do(http.MethodGet, link, nil)
	if got, via := pc.session(h); resp.StatusCode != http.StatusFound || got != pid || via != store.IdentityEmail {
		t.Fatalf("link = %d, signed in %q via %q", resp.StatusCode, got, via)
	}
	// Replayed: refused, even with the browser's cookie put back.
	replay := newBrowser(t, "")
	if !hasCookie(asked, emailFlowCookie) {
		t.Fatal("the asking browser had no flow cookie")
	}
	for _, c := range asked {
		replay.c.Jar.SetCookies(mustURL(h.http.URL+emailFlowPath), []*http.Cookie{{Name: c.Name, Value: c.Value, Path: emailFlowPath}})
	}
	if resp, _ := replay.do(http.MethodGet, link, nil); !strings.Contains(resp.Header.Get("Location"), "e=email-expired") {
		t.Fatalf("a replayed link → %q", resp.Header.Get("Location"))
	}
	if got, _ := replay.session(h); got != "" {
		t.Fatal("a replayed link signed someone in")
	}

	// The limits: a minute between mails, for an unknown address too.
	if resp := h.startMail(t, newBrowser(t, ""), "dana@example.com"); !strings.Contains(resp.Header.Get("Location"), "e=email-slow") {
		t.Fatalf("a second mail within the minute → %q", resp.Header.Get("Location"))
	}
	if resp := h.startMail(t, newBrowser(t, ""), "nobody@example.com"); !strings.Contains(resp.Header.Get("Location"), "e=email-slow") {
		t.Fatalf("an unknown address is not limited alike → %q", resp.Header.Get("Location"))
	}
	// …and five an hour.
	base := time.Now()
	for i := 1; i <= 6; i++ {
		rec := httptest.NewRecorder()
		err := h.srv.emailStart(rec, httptest.NewRequest(http.MethodPost, "/auth/email/start", nil), "hourly@example.com", base.Add(time.Duration(i)*2*time.Minute))
		if (i <= 5) != (err == nil) {
			t.Fatalf("mail %d of the hour: %v", i, err)
		}
	}
}

func countSigninCodes(t *testing.T, h *waysHarness, addr string) int {
	t.Helper()
	_, n, err := h.srv.Store.SigninCodeStats(store.IdentityEmail, addr, time.Now().Add(-time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	return n
}

// The six digits: typed in the browser that asked; five wrong ones void the
// mail; a right one after that opens nothing.
func TestEmailCode(t *testing.T) {
	h := newWaysHarness(t)
	pid, _ := newPersonPrincipal()
	_ = h.srv.Store.UpsertHubUser(store.HubUser{PrincipalID: pid, Login: "Eve", Role: store.RoleUser, AddedBy: "test", AddedAt: time.Now()})
	_ = h.srv.Store.AddHubIdentity(store.HubIdentity{Kind: store.IdentityEmail, Subject: "eve@example.com", PrincipalID: pid, VerifiedAt: time.Now()})

	pc := newBrowser(t, "")
	h.startMail(t, pc, "eve@example.com")
	code := mailCodeRE.FindStringSubmatch(h.mail(t).body)[1]
	wrong := "000000"
	if code == wrong {
		wrong = "111111"
	}
	// Another browser cannot use the right code.
	if resp, _ := newBrowser(t, "").do(http.MethodPost, h.http.URL+"/auth/email/code", url.Values{"code": {code}}); !strings.Contains(resp.Header.Get("Location"), "e=email-expired") {
		t.Fatalf("code from another browser → %q", resp.Header.Get("Location"))
	}
	for i := 1; i <= 5; i++ {
		resp, _ := pc.do(http.MethodPost, h.http.URL+"/auth/email/code", url.Values{"code": {wrong}})
		want := "e=email-wrong"
		if i == 5 {
			want = "e=email-void"
		}
		if !strings.Contains(resp.Header.Get("Location"), want) {
			t.Fatalf("wrong code %d → %q; want %s", i, resp.Header.Get("Location"), want)
		}
	}
	if resp, _ := pc.do(http.MethodPost, h.http.URL+"/auth/email/code", url.Values{"code": {code}}); !strings.Contains(resp.Header.Get("Location"), "e=email-expired") {
		t.Fatalf("the right code after five wrong → %q", resp.Header.Get("Location"))
	}
	if got, _ := pc.session(h); got != "" {
		t.Fatal("a voided mail signed someone in")
	}

	// A new mail (a minute later), the right code: in.
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/auth/email/start", nil)
	for _, c := range pc.c.Jar.Cookies(mustURL(h.http.URL + emailFlowPath)) {
		req.AddCookie(c)
	}
	if err := h.srv.emailStart(rec, req, "eve@example.com", time.Now().Add(2*time.Minute)); err != nil {
		t.Fatal(err)
	}
	code = mailCodeRE.FindStringSubmatch(h.mail(t).body)[1]
	resp, _ := pc.do(http.MethodPost, h.http.URL+"/auth/email/code", url.Values{"code": {code}})
	if got, via := pc.session(h); resp.StatusCode != http.StatusSeeOther && resp.StatusCode != http.StatusFound || got != pid || via != store.IdentityEmail {
		t.Fatalf("the right code = %d, signed in %q via %q", resp.StatusCode, got, via)
	}
}

// An address nobody has comes in only on the invite the browser carries; a
// signed-in person adds an address by proving its mail.
func TestEmailInviteAndAdd(t *testing.T) {
	h := newWaysHarness(t)
	now := time.Now()
	const code = "mailinvitemailinvitem"
	if err := h.srv.Store.CreateInvite(store.Invite{ID: "inv_mail", CodeHash: inviteHash(code), Email: "new@example.com",
		CreatedBy: "admin", CreatedAt: now, ExpiresAt: now.Add(store.InviteTTL)}); err != nil {
		t.Fatal(err)
	}
	b := newBrowser(t, "")
	b.do(http.MethodGet, h.http.URL+InvitePath+code, nil)
	h.startMail(t, b, "new@example.com")
	link := mailLinkRE.FindString(h.mail(t).body)
	b.do(http.MethodGet, link, nil)
	got, via := b.session(h)
	if !strings.HasPrefix(got, personPrincipalPrefix) || via != store.IdentityEmail {
		t.Fatalf("invited address signed in %q via %q", got, via)
	}

	// Signed in (by WeChat): add an address through its mail.
	b2 := newBrowser(t, "")
	pid, _ := newPersonPrincipal()
	_ = h.srv.Store.UpsertHubUser(store.HubUser{PrincipalID: pid, Login: "W", Role: store.RoleUser, AddedBy: "test", AddedAt: now})
	_ = h.srv.Store.AddHubIdentity(store.HubIdentity{Kind: store.IdentityWeChat, Subject: "union-w", PrincipalID: pid, VerifiedAt: now})
	sess := &http.Cookie{Name: authz.CookieName, Path: "/", Value: authz.SignRole(store.IdentityWeChat, pid, "W", roleUser, h.srv.sessionKey(), now, time.Hour)}
	b2.c.Jar.SetCookies(mustURL(h.http.URL+"/"), []*http.Cookie{sess})
	req, _ := http.NewRequest(http.MethodPost, h.http.URL+"/v1/me/identities", strings.NewReader(`{"kind":"email","subject":"w@example.com"}`))
	req.Header.Set("Content-Type", "application/json")
	resp, err := b2.c.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusAccepted {
		t.Fatalf("a user adding an address = %d; want 202 (a mail to prove it)", resp.StatusCode)
	}
	if owner, _ := h.srv.Store.IdentityPrincipal(store.IdentityEmail, "w@example.com"); owner != "" {
		t.Fatal("the address was added before its mail was opened")
	}
	link = mailLinkRE.FindString(h.mail(t).body)
	b2.do(http.MethodGet, link, nil)
	if owner, _ := h.srv.Store.IdentityPrincipal(store.IdentityEmail, "w@example.com"); owner != pid {
		t.Fatalf("the proven address is %q's; want %s", owner, pid)
	}
}

// The mail itself: a message any client reads, the subject encoded.
func TestBuildMailAndSMTPURL(t *testing.T) {
	c, err := parseSMTP("smtp://ses-smtp-user:pass@email-smtp.ap-southeast-1.amazonaws.com", "claudefleet <no-reply@example.com>")
	if err != nil || c.host != "email-smtp.ap-southeast-1.amazonaws.com:587" || c.implicit || c.user != "ses-smtp-user" {
		t.Fatalf("smtp URL = %+v %v", c, err)
	}
	if c, err = parseSMTP("smtps://u:p@mail.example.com?from=a@example.com", ""); err != nil || c.host != "mail.example.com:465" || !c.implicit || c.from.Address != "a@example.com" {
		t.Fatalf("smtps URL = %+v %v", c, err)
	}
	for _, bad := range []string{"http://x", "smtp://host"} {
		if _, err := parseSMTP(bad, ""); err == nil || strings.Contains(err.Error(), bad) {
			t.Errorf("parseSMTP(%q) = %v; want a refusal that does not quote it", bad, err)
		}
	}
	msg := string(buildMail(c.from, "x@example.com", "登录 claudefleet", "正文", time.Unix(0, 0)))
	if !strings.Contains(msg, "Subject: =?utf-8?b?") || !strings.Contains(msg, "Content-Transfer-Encoding: base64") || !strings.HasSuffix(msg, "\r\n") {
		t.Fatalf("mail:\n%s", msg)
	}
}
