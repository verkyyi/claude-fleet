package api

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"sort"
	"strings"
	"testing"
	"testing/fstest"
)

// pagePath is where a test reaches page p: a console page under /app
// (claude-fleet#3583), anything else where it is.
func pagePath(p string) string {
	if isAppPage(p) {
		return appURL(p)
	}
	return p
}

// appGet is one request through h's whole handler, no redirect followed.
func appGet(t *testing.T, h *ghHarness, method, path string, sess *http.Cookie) *http.Response {
	t.Helper()
	req, _ := http.NewRequest(method, h.http.URL+path, nil)
	req.Header.Set("Accept", "text/html")
	if sess != nil {
		req.AddCookie(sess)
	}
	resp, err := noFollow.Do(req)
	if err != nil {
		t.Fatalf("%s %s: %v", method, path, err)
	}
	resp.Body.Close()
	return resp
}

// Every old console address answers 301 to the same page under /app, its
// query kept — a bookmark never lands on nothing; any other method still
// reaches the page where it was.
func TestAppOldPathsMoveUnderApp(t *testing.T) {
	h, admin, _ := rolesHarness(t)
	var olds []string
	for p := range appPagePaths {
		if p != "/" {
			olds = append(olds, p)
		}
	}
	for _, pre := range appPagePrefixes {
		olds = append(olds, pre+"x")
	}
	sort.Strings(olds)
	for _, p := range olds {
		resp := appGet(t, h, http.MethodGet, p+"?tab=a&b=c", admin)
		if resp.StatusCode != http.StatusMovedPermanently || resp.Header.Get("Location") != AppPrefix+p+"?tab=a&b=c" {
			t.Errorf("GET %s = %d → %q; want 301 → %s?tab=a&b=c", p, resp.StatusCode, resp.Header.Get("Location"), AppPrefix+p)
		}
		if resp := appGet(t, h, http.MethodHead, p, nil); resp.StatusCode != http.StatusMovedPermanently {
			t.Errorf("HEAD %s = %d; want 301", p, resp.StatusCode)
		}
	}
	// The app's own files stay where they are.
	for _, p := range []string{"/admin/users.js", "/machines.js", "/app.css", "/app-shell.js"} {
		if resp := appGet(t, h, http.MethodGet, p, admin); resp.StatusCode == http.StatusMovedPermanently {
			t.Errorf("GET %s = 301; an app file is not a page", p)
		}
	}
	// A form POST to the old /logout still signs out (303), not a redirect.
	req, _ := http.NewRequest(http.MethodPost, h.http.URL+"/logout", nil)
	req.Header.Set("Origin", h.http.URL)
	resp, err := noFollow.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusSeeOther {
		t.Errorf("POST /logout = %d; want 303 (the sign-out itself)", resp.StatusCode)
	}
}

// /app and every page under it is the console, never indexed; a path under
// /app that is no console page is a 404 — /app is not a second road to /v1.
func TestAppIsNoindex(t *testing.T) {
	h, admin, user := rolesHarness(t)
	h.srv.UI = fstest.MapFS{"index.html": {Data: []byte("APP")}, appPage: {Data: []byte("APP")}}
	for _, c := range []struct {
		path string
		sess *http.Cookie
		code int
	}{
		{AppPrefix, admin, http.StatusOK}, {AppPrefix + "/", admin, http.StatusOK},
		{AppPrefix + "/sessions", user, http.StatusOK}, {AppPrefix + "/machines/mac-a", user, http.StatusOK},
		{AppPrefix + "/nodes", user, http.StatusForbidden}, {AppPrefix + "/signin", nil, http.StatusOK},
		{AppPrefix + "/sessions", nil, http.StatusFound},
		{AppPrefix + "/v1/fleet/me", admin, http.StatusNotFound}, {AppPrefix + "/install", nil, http.StatusNotFound},
		{AppPrefix + "/app.css", admin, http.StatusNotFound},
	} {
		resp := appGet(t, h, http.MethodGet, c.path, c.sess)
		if resp.StatusCode != c.code {
			t.Errorf("GET %s = %d; want %d", c.path, resp.StatusCode, c.code)
		}
		if got := resp.Header.Get("X-Robots-Tag"); !strings.Contains(got, "noindex") {
			t.Errorf("GET %s: X-Robots-Tag = %q; want noindex", c.path, got)
		}
	}
	// Signed out under /app: the sign-in page under /app, never the site.
	if resp := appGet(t, h, http.MethodGet, AppPrefix+"/sessions", nil); resp.Header.Get("Location") != AppPrefix+"/signin" {
		t.Errorf("signed-out /app/sessions → %q; want /app/signin", resp.Header.Get("Location"))
	}
}

// "/" is the public site for a stranger and /app for someone signed in while
// the site is on; off (a self-hoster's default) it is always /app.
func TestAppRoot(t *testing.T) {
	h, admin, _ := rolesHarness(t)
	h.srv.UI = fstest.MapFS{"index.html": {Data: []byte("APP")}, "app.html": {Data: []byte("APP")},
		"landing.html": {Data: []byte("<title>x</title>FRONT-PAGE")}}
	for _, site := range []bool{false, true} {
		h.srv.Site = site
		resp := appGet(t, h, http.MethodGet, "/", admin)
		if resp.StatusCode != http.StatusFound || resp.Header.Get("Location") != AppPrefix {
			t.Errorf("site=%v signed-in / = %d → %q; want 302 → /app", site, resp.StatusCode, resp.Header.Get("Location"))
		}
		if resp.Header.Get("X-Robots-Tag") != "" {
			t.Errorf("site=%v: / carries X-Robots-Tag %q", site, resp.Header.Get("X-Robots-Tag"))
		}
	}
	h.srv.Site = false
	if resp := appGet(t, h, http.MethodGet, "/?lang=zh", nil); resp.StatusCode != http.StatusFound || resp.Header.Get("Location") != AppPrefix+"?lang=zh" {
		t.Errorf("site off, signed-out / = %d → %q; want 302 → /app?lang=zh", resp.StatusCode, resp.Header.Get("Location"))
	}
	h.srv.Site = true
	resp := appGet(t, h, http.MethodGet, "/", nil)
	if resp.StatusCode != http.StatusOK {
		t.Errorf("site on, signed-out / = %d; want 200 and the site", resp.StatusCode)
	}
	// The built site, when the hub carries one (web/site, C14).
	h.srv.SiteFS = fstest.MapFS{"index.html": {Data: []byte("<title>site</title>SITE")}}
	rec := httptest.NewRecorder()
	h.srv.Handler().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/", nil))
	if rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), "SITE") || rec.Header().Get("X-Robots-Tag") != "" {
		t.Errorf("site on, signed-out / = %d %q (robots %q); want 200 SITE, indexable", rec.Code, rec.Body.String(), rec.Header().Get("X-Robots-Tag"))
	}
}

// A ?token= link is moved into its cookie on the way in, at "/" and under
// /app, and the address it is sent on to never carries it.
func TestAppTokenLinkLandsUnderApp(t *testing.T) {
	h := newHarness(t)
	for path, want := range map[string]string{
		"/?token=" + viewerToken:                      "/",
		AppPrefix + "?token=" + viewerToken:           AppPrefix,
		AppPrefix + "/quota?x=1&token=" + viewerToken: AppPrefix + "/quota?x=1",
	} {
		resp, err := noFollow.Get(h.http.URL + path)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		if resp.StatusCode != http.StatusFound || resp.Header.Get("Location") != want {
			t.Errorf("GET %s = %d → %q; want 302 → %s", strings.Replace(path, viewerToken, "…", 1), resp.StatusCode, resp.Header.Get("Location"), want)
		}
	}
}

// The client protocol is byte for byte what it was: every path a machine or
// the fleet client calls answers through the mounted handler exactly as it
// does without the mount — status, body, and no X-Robots-Tag.
func TestClientPathsUnchanged(t *testing.T) {
	h, admin, _ := rolesHarness(t)
	bare := h.srv.logRequests(h.srv.readOnlyGate(h.srv.routes()))
	mounted := h.srv.Handler()
	for _, p := range []string{
		"/v1/fleet/me", "/v1/me", "/v1/fleet/connect", "/v1/fleet/ssh-ca.pub", "/install", "/install/bin/fleet",
		"/fleet/login", "/fleet/login?code=ABCD-EFGH", "/fleet/keys", "/mcp", "/badge/u/x", "/embed/u/x",
		"/healthz", "/version", "/v1/node/self", "/meter.json", "/i/nosuchcode",
		"/app.css", "/no-such-page",
	} {
		for _, sess := range []*http.Cookie{nil, admin} {
			do := func(hd http.Handler) *httptest.ResponseRecorder {
				req := httptest.NewRequest(http.MethodGet, p, nil)
				if sess != nil {
					req.AddCookie(sess)
				}
				rec := httptest.NewRecorder()
				hd.ServeHTTP(rec, req)
				return rec
			}
			a, b := do(bare), do(mounted)
			if a.Code != b.Code || !bytes.Equal(sansNow(a.Body.Bytes()), sansNow(b.Body.Bytes())) {
				t.Errorf("GET %s (signed in %v): %d %.80q mounted, %d %.80q bare", p, sess != nil, b.Code, b.Body.String(), a.Code, a.Body.String())
			}
			if b.Header().Get("X-Robots-Tag") != "" || b.Header().Get("Location") != a.Header().Get("Location") {
				t.Errorf("GET %s: robots %q, location %q vs %q", p, b.Header().Get("X-Robots-Tag"), b.Header().Get("Location"), a.Header().Get("Location"))
			}
		}
	}
}

// sansNow drops what differs between two identical requests a moment
// apart (a timestamp in a JSON answer), so the comparison is of the shape.
func sansNow(b []byte) []byte {
	if i := bytes.Index(b, []byte(`"now"`)); i >= 0 {
		return b[:i]
	}
	return b
}

// Every console page is a route roles.go names — the table and the mount
// speak of the same pages, so moving one never leaves it ungated.
func TestAppPagesAreRoutes(t *testing.T) {
	for p := range appPagePaths {
		if _, ok := routeAccess[p]; !ok {
			t.Errorf("console page %s has no routeAccess row", p)
		}
	}
	for _, p := range appPagePrefixes {
		if _, ok := routeAccess[p]; !ok {
			t.Errorf("console prefix %s has no routeAccess row", p)
		}
	}
}
