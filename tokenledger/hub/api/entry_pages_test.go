package api

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"os"
	"regexp"
	"strings"
	"testing"
)

// The theme the way-in pages wear (claude-fleet#3932): extras/fleet-theme as
// it is, at /app/assets/fleet-theme/, to anyone — the sign-in page wears it
// before anyone is signed in — reads only, its own files only.
func TestThemeServed(t *testing.T) {
	h := newGitHubHarness(t)
	get := func(method, p string) (int, string, string) {
		req, _ := http.NewRequest(method, h.http.URL+p, nil)
		resp, err := noFollow.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		b, _ := io.ReadAll(resp.Body)
		return resp.StatusCode, resp.Header.Get("Content-Type"), string(b)
	}
	if code, _, _ := get(http.MethodGet, themePrefix+"theme.css"); code != http.StatusNotFound {
		t.Fatalf("no theme packed: GET theme.css = %d, want 404", code)
	}
	h.srv.ThemeFS = os.DirFS("../../../extras/fleet-theme")
	for p, want := range map[string]string{
		"theme.css":                           "text/css; charset=utf-8",
		"fonts.css":                           "text/css; charset=utf-8",
		"logo.svg":                            "image/svg+xml",
		"fonts/ibm-plex-sans-400-latin.woff2": "font/woff2",
	} {
		code, ct, body := get(http.MethodGet, themePrefix+p)
		if code != http.StatusOK || ct != want || body == "" {
			t.Errorf("GET %s = %d %q (%d bytes); want 200 %s", p, code, ct, len(body), want)
		}
	}
	if _, _, body := get(http.MethodGet, themePrefix+"theme.css"); !strings.Contains(body, "/* fleet:tokens */") {
		t.Errorf("theme.css is not the package's: %.80q", body)
	}
	for _, p := range []string{"README.md", "fonts/OFL-ibmplexsans.txt", "fonts-src/glyphs.txt", ".hidden.css", "nope.css"} {
		if code, _, _ := get(http.MethodGet, themePrefix+p); code != http.StatusNotFound {
			t.Errorf("GET %s = %d; want 404", p, code)
		}
	}
	if code, _, _ := get(http.MethodPost, themePrefix+"theme.css"); code != http.StatusNotFound {
		t.Errorf("POST theme.css = %d; want 404", code)
	}
}

// offOrigin is a page attribute that would load something from elsewhere.
var offOrigin = regexp.MustCompile(`(?i)(src|href|action)="(https?:)?//`)

// Every way-in page wears the theme and loads nothing from another origin:
// /signin (GitHub alone, and every way), an invite that cannot be used (the
// refusal page /fleet/login/refused shows too), the page the QR opens, and
// 「页面不存在」.
func TestEntryPagesWearTheTheme(t *testing.T) {
	type page struct {
		name string
		code int
		hdr  http.Header
		body string
	}
	var pages []page
	fetch := func(name, base, p string, c *http.Cookie, want int) {
		req, _ := http.NewRequest(http.MethodGet, base+p, nil)
		req.Header.Set("Accept", "text/html")
		req.Header.Set("Accept-Language", "zh-CN")
		if c != nil {
			req.AddCookie(c)
		}
		resp, err := noFollow.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		b, _ := io.ReadAll(resp.Body)
		if resp.StatusCode != want {
			t.Fatalf("%s: GET %s = %d, want %d", name, p, resp.StatusCode, want)
		}
		pages = append(pages, page{name, resp.StatusCode, resp.Header, string(b)})
	}

	gh := newGitHubHarness(t)
	fetch("signin", gh.http.URL, "/app/signin", nil, http.StatusOK)
	fetch("invite", gh.http.URL, InvitePath+"AAAAAAAAAAAAAAAAAAAAAAAAAA", nil, http.StatusForbidden)
	gh.srv.Email = &EmailAuth{Send: func(context.Context, string, string, string) error { return nil }}
	gh.srv.WeChat = &WeChatAuth{WebAppID: "wx", WebSecret: "s"}
	fetch("signin-ways", gh.http.URL, "/app/signin", nil, http.StatusOK)
	fetch("signin-code", gh.http.URL, "/app/signin?step=code", nil, http.StatusOK)

	h, _ := certHarness(t)
	_, body := postJSON(t, h, "/v1/fleet/login/start", map[string]string{"public_key": newUserKey(t)})
	var st DeviceStart
	_ = json.Unmarshal(body, &st)
	listPerson(t, h, pAlice, "")
	fetch("fleet-login", h.http.URL, "/fleet/login?code="+st.UserCode, personCookie(pAlice, ""), http.StatusOK)
	fetch("not-found", h.http.URL, AdminPrefix+"/people", personCookie(pAlice, ""), http.StatusNotFound)

	for _, p := range pages {
		if !strings.Contains(p.body, `<link rel="stylesheet" href="`+themePrefix+`theme.css">`) {
			t.Errorf("%s does not link the theme", p.name)
		}
		if m := offOrigin.FindString(p.body); m != "" || strings.Contains(p.body, "googleapis") {
			t.Errorf("%s loads from another origin: %q", p.name, m)
		}
		if got := p.hdr.Get("Content-Security-Policy"); got != entryCSP {
			t.Errorf("%s CSP = %q", p.name, got)
		}
		if !strings.Contains(p.body, `<html lang="zh-CN">`) {
			t.Errorf("%s is not in the asked language", p.name)
		}
	}
	for name, want := range map[string]string{
		"signin":      `href="/auth/github/start"`,
		"signin-ways": `action="/auth/email/start"`,
		"signin-code": `name="code" inputmode="numeric"`,
		"fleet-login": `name="action" value="approve"`,
		"not-found":   `<p class="num">404</p>`,
	} {
		for _, p := range pages {
			if p.name == name && !strings.Contains(p.body, want) {
				t.Errorf("%s lacks %s", name, want)
			}
		}
	}
}
