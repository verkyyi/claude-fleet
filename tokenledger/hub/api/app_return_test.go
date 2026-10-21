package api

import (
	"net/http"
	"net/http/httptest"
	"net/url"
	"testing"
	"testing/fstest"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

// claude-fleet T842: a session's link opened signed out — WeChat's own
// browser, a forwarded card — signs in and lands on that session, not the
// list; so does the mail's code, and every old console address.
func TestSignedOutSessionLinkSurvivesSignIn(t *testing.T) {
	h := newWaysHarness(t)
	h.srv.ConsoleFS = fstest.MapFS{"app/index.html": {Data: []byte("APP-ENTRY")}}
	pid, _ := newPersonPrincipal()
	_ = h.srv.Store.UpsertHubUser(store.HubUser{PrincipalID: pid, Login: "Xiaolin", Role: store.RoleUser, AddedBy: "test", AddedAt: time.Now()})
	_ = h.srv.Store.AddHubIdentity(store.HubIdentity{Kind: store.IdentityWeChat, Subject: "union-xl", PrincipalID: pid, VerifiedAt: time.Now()})
	_ = h.srv.Store.AddHubIdentity(store.HubIdentity{Kind: store.IdentityEmail, Subject: "xl@example.com", PrincipalID: pid, VerifiedAt: time.Now()})
	const want = "/app/s/D7KQ?view=term"

	// WeChat's own browser: the link → /app/signin → the service account → back.
	phone := newBrowser(t, wechatUA)
	resp, _ := phone.do(http.MethodGet, h.http.URL+want, nil)
	if resp.StatusCode != http.StatusFound || resp.Header.Get("Location") != "/app/signin" {
		t.Fatalf("signed out %s = %d → %q; want 302 /app/signin", want, resp.StatusCode, resp.Header.Get("Location"))
	}
	if c := cookieNamed(resp, entryReturnCookie); c == nil || c.Value != want || !c.HttpOnly {
		t.Fatalf("return cookie %+v; want %s, HttpOnly", c, want)
	}
	if resp, _ = phone.do(http.MethodGet, h.http.URL+"/app/signin", nil); resp.Header.Get("Location") != "/auth/wechat/start" {
		t.Fatalf("/app/signin in WeChat → %q", resp.Header.Get("Location"))
	}
	if cb, _ := h.scan(t, phone, "c-mp", "union-xl", "小林"); cb.StatusCode != http.StatusFound || cb.Header.Get("Location") != want {
		t.Fatalf("after WeChat sign-in: %d → %q; want %s", cb.StatusCode, cb.Header.Get("Location"), want)
	}
	if resp, body := phone.do(http.MethodGet, h.http.URL+want, nil); resp.StatusCode != http.StatusOK || body != "APP-ENTRY" {
		t.Fatalf("the session page signed in = %d %q", resp.StatusCode, body)
	}
	// Spent: the next sign-in lands on the list again.
	if cb, _ := h.scan(t, phone, "c-mp2", "union-xl", "小林"); cb.Header.Get("Location") != AppPrefix {
		t.Fatalf("a second sign-in → %q; want %s", cb.Header.Get("Location"), AppPrefix)
	}

	// The mail's code, on a computer.
	pc := newBrowser(t, "")
	pc.do(http.MethodGet, h.http.URL+"/app/s/K3F9", nil)
	h.startMail(t, pc, "xl@example.com")
	code := mailCodeRE.FindStringSubmatch(h.mail(t).body)[1]
	if resp, _ := pc.do(http.MethodPost, h.http.URL+"/auth/email/code", url.Values{"code": {code}}); resp.Header.Get("Location") != "/app/s/K3F9" {
		t.Fatalf("after the mail's code → %q; want /app/s/K3F9", resp.Header.Get("Location"))
	}

	// Every old address — moved on to where its page lives now, then asked to
	// sign in — is remembered as the last address the browser asked for.
	for _, p := range []string{"/app/usage", "/app/devices", "/app/settings", "/app/chat", "/app/terminal",
		"/app/tasks?q=x", "/app/sessions?q=x", "/app/me", "/app/me/usage"} {
		b, at := newBrowser(t, ""), p
		resp, _ := b.do(http.MethodGet, h.http.URL+at, nil)
		for hop := 0; hop < 4 && resp.StatusCode == http.StatusMovedPermanently; hop++ {
			at = resp.Header.Get("Location")
			resp, _ = b.do(http.MethodGet, h.http.URL+at, nil)
		}
		c := cookieNamed(resp, entryReturnCookie)
		if resp.Header.Get("Location") != "/app/signin" || c == nil || c.Value != at || !appReturnOK(at) {
			t.Errorf("%s signed out → %s → %q, cookie %+v; want /app/signin remembering %s", p, at, resp.Header.Get("Location"), c, at)
		}
	}
}

// Only a same-site console path is ever followed (no open redirect).
func TestAppReturnRefusesElsewhere(t *testing.T) {
	for _, v := range []string{"//evil.example/app/s/X", "https://evil.example/app/s/X", "/app", "/apps/x",
		`/app/\evil.example`, "/app/../admin/people", "/app/./s/X", "/app//evil.example", "/app/signin",
		"/app/logout", "/app/assets/x.js", "/fleet/login?code=AAAA", "/app/s/X\r\nSet-Cookie:x", "/app/s/中", "/app/%2e%2e/admin/people", "/app/%2F%2Fevil.example"} {
		// The check itself, on the raw value: a cookie header would have
		// lost a backslash or CR/LF before it got here.
		if appReturnOK(v) {
			t.Errorf("appReturnOK(%q) = true; want refused", v)
		}
		r := httptest.NewRequest(http.MethodGet, "/auth/wechat/callback", nil)
		r.AddCookie(&http.Cookie{Name: entryReturnCookie, Value: v})
		if got := loginReturn(httptest.NewRecorder(), r); !appReturnOK(got) && got != AppPrefix {
			t.Errorf("return %q → %q; want %s or a console path", v, got, AppPrefix)
		}
	}
	for _, v := range []string{"/app/s/D7KQ?view=term", "/app/sessions?q=a%20b", "/app/me/usage"} {
		r := httptest.NewRequest(http.MethodGet, "/auth/wechat/callback", nil)
		r.AddCookie(&http.Cookie{Name: entryReturnCookie, Value: v})
		if got := loginReturn(httptest.NewRecorder(), r); got != v {
			t.Errorf("return %q → %q", v, got)
		}
	}
	// An API call signed out remembers nothing (a 401, not a page).
	w := httptest.NewRecorder()
	r := httptest.NewRequest(http.MethodPost, "/app/s/X", nil)
	rememberAppReturn(w, r)
	if len(w.Result().Cookies()) != 0 {
		t.Fatal("a POST left a return cookie")
	}
}
