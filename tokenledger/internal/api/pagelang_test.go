package api

import (
	"net/http"
	"net/http/httptest"
	"os"
	"regexp"
	"sort"
	"strings"
	"testing"
	"testing/fstest"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/i18n"
)

// Every public-page key says something in both languages, with the same
// placeholders: a key in one language only is how an English sentence ends up
// in the middle of a Chinese page (claude-fleet#2023).
func TestPageText_BothLanguagesEveryKey(t *testing.T) {
	vars := func(s string) string {
		m := regexp.MustCompile(`\{(\w+)\}`).FindAllString(s, -1)
		sort.Strings(m)
		return strings.Join(m, ",")
	}
	for k, txt := range pageText {
		for _, loc := range i18n.Locales {
			if strings.TrimSpace(txt[loc]) == "" {
				t.Errorf("%s has no %s text", k, loc)
			}
		}
		if vars(txt[i18n.EN]) != vars(txt[i18n.ZhCN]) {
			t.Errorf("%s: placeholders differ: en %q zh %q", k, vars(txt[i18n.EN]), vars(txt[i18n.ZhCN]))
		}
	}
}

// Every key a page template names is in pageText — a typo renders as the
// raw key, which this catches before a reader does.
func TestPageText_TemplatesNameOnlyKnownKeys(t *testing.T) {
	re := regexp.MustCompile(`\{\{\s*tb? "([\w.]+)"`)
	direct := regexp.MustCompile(`pageT\([^,]+, "([\w.]+)"\)`)
	for _, f := range []string{"github_auth.go", "fleet_certs.go", "pagelang.go", "meter.go", "../../web/dist/landing.html"} {
		src, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		n := 0
		for _, re := range []*regexp.Regexp{re, direct} {
			for _, m := range re.FindAllStringSubmatch(string(src), -1) {
				n++
				if _, ok := pageText[m[1]]; !ok {
					t.Errorf("%s names %q, which pageText does not have", f, m[1])
				}
			}
		}
		if n == 0 {
			t.Errorf("%s names no page key — did the pattern stop matching?", f)
		}
	}
}

func TestParseLang(t *testing.T) {
	for in, want := range map[string]string{
		"zh": i18n.ZhCN, "zh-CN": i18n.ZhCN, "zh-TW": i18n.ZhCN, "ZH": i18n.ZhCN,
		"en": i18n.EN, "en-US": i18n.EN, "fr": "", "": "", "xx-zh": "",
	} {
		if got := parseLang(in); got != want {
			t.Errorf("parseLang(%q) = %q, want %q", in, got, want)
		}
	}
}

// The rule, one row per rung: link > cookie > browser.
func TestPageLocale_Order(t *testing.T) {
	s := &Server{}
	for _, c := range []struct {
		name, query, cookie, accept, want string
		setsCookie                        bool
	}{
		{"browser zh", "", "", "zh-CN,zh;q=0.9,en;q=0.8", i18n.ZhCN, false},
		{"browser zh-TW", "", "", "zh-TW", i18n.ZhCN, false},
		{"browser en", "", "", "en-US,en", i18n.EN, false},
		{"no header", "", "", "", i18n.EN, false},
		{"cookie beats browser", "", "en", "zh-CN", i18n.EN, false},
		{"link beats cookie", "lang=zh", "en", "en-US", i18n.ZhCN, true},
		{"link equal to cookie", "lang=en", "en", "zh-CN", i18n.EN, false},
		{"unknown link ignored", "lang=fr", "zh-CN", "en", i18n.ZhCN, false},
	} {
		req := httptest.NewRequest("GET", "/?"+c.query, nil)
		if c.cookie != "" {
			req.AddCookie(&http.Cookie{Name: langCookie, Value: c.cookie})
		}
		if c.accept != "" {
			req.Header.Set("Accept-Language", c.accept)
		}
		rec := httptest.NewRecorder()
		if got := s.pageLocale(rec, req); got != c.want {
			t.Errorf("%s: %q, want %q", c.name, got, c.want)
		}
		set := cookieOf(rec, langCookie)
		if (set != nil) != c.setsCookie {
			t.Errorf("%s: set cookie = %+v, want set=%v", c.name, set, c.setsCookie)
		}
		if set != nil && (set.Value != c.want || set.HttpOnly || set.MaxAge < 300*24*3600) {
			t.Errorf("%s: cookie = %+v; want the locale, readable by the page's script, for a year", c.name, set)
		}
	}
}

func cookieOf(rec *httptest.ResponseRecorder, name string) *http.Cookie {
	for _, c := range rec.Result().Cookies() {
		if c.Name == name {
			return c
		}
	}
	return nil
}

func TestLangHrefKeepsTheRestOfTheQuery(t *testing.T) {
	r := httptest.NewRequest("GET", "/fleet/login?code=ABCD-EFGH&lang=en", nil)
	if got := langHref(r, i18n.ZhCN); got != "?code=ABCD-EFGH&lang=zh" {
		t.Errorf("langHref = %q", got)
	}
}

// The front page, drawn from the real landing.html: a Chinese browser gets
// <html lang="zh-CN"> and Chinese on the first paint; ?lang=en gets English
// and remembers it; nothing is left untranslated.
func TestLanding_ServerPicksTheLanguage(t *testing.T) {
	src, err := os.ReadFile("../../web/dist/landing.html")
	if err != nil {
		t.Fatal(err)
	}
	s := badgeServer(t, false)
	s.UI = fstest.MapFS{"index.html": {Data: []byte("APP")}, "landing.html": {Data: src}}

	rec := meterGet(t, s, "/", map[string]string{"Accept-Language": "zh-CN,zh;q=0.9"})
	body := rec.Body.String()
	if rec.Code != 200 || !strings.Contains(body, `<html lang="zh-CN">`) || !strings.Contains(body, "一个任务一个窗口") {
		t.Fatalf("zh browser: %d %.300s", rec.Code, body)
	}
	if !strings.Contains(body, `href="?lang=en"`) || !strings.Contains(body, `aria-current="true">中文`) {
		t.Errorf("zh page has no working switch to EN")
	}
	for _, en := range []string{"How it works", "Sign in", "Copy", "Many sessions", "Hosted at"} {
		if strings.Contains(body, en) {
			t.Errorf("zh page still says %q", en)
		}
	}

	rec = meterGet(t, s, "/?lang=en", map[string]string{"Accept-Language": "zh-CN"})
	body = rec.Body.String()
	if !strings.Contains(body, `<html lang="en">`) || !strings.Contains(body, "One task per window") {
		t.Fatalf("?lang=en: %.300s", body)
	}
	if c := cookieOf(rec, langCookie); c == nil || c.Value != i18n.EN {
		t.Errorf("?lang=en did not remember the choice: %+v", c)
	}
	if !strings.Contains(rec.Header().Get("Vary"), "Accept-Language") {
		t.Errorf("Vary = %q; a cache must not hand one language's page to the other", rec.Header().Get("Vary"))
	}
}

func TestSigninAndDeny_InChinese(t *testing.T) {
	h := newGitHubHarness(t, "verkyyi")
	req, _ := http.NewRequest("GET", h.http.URL+"/signin?e=expired", nil)
	req.Header.Set("Accept-Language", "zh-CN")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	b := readAll(t, resp)
	if !strings.Contains(b, `<html lang="zh-CN">`) || !strings.Contains(b, "用 GitHub 继续") || !strings.Contains(b, "请再试一次") {
		t.Fatalf("/signin in zh: %s", b)
	}
	if !strings.Contains(b, `href="?e=expired&amp;lang=en"`) {
		t.Errorf("the switch drops ?e=: %s", b)
	}

	rec := httptest.NewRecorder()
	r := httptest.NewRequest("GET", "/auth/github/callback", nil)
	r.Header.Set("Accept", "text/html")
	r.Header.Set("Accept-Language", "zh")
	h.srv.githubDeny(rec, r, "", "<mallory>")
	b = rec.Body.String()
	if rec.Code != 403 || !strings.Contains(b, "<b>&lt;mallory&gt;</b> 不在本入口的名单上") {
		t.Fatalf("deny in zh: %d %s", rec.Code, b)
	}
}

// A choice made while signed in is the account's: a second browser with no
// cookie, signed in as the same person, gets it back.
func TestPageLocale_FollowsTheAccount(t *testing.T) {
	h := newGitHubHarness(t, "verkyyi")
	// The settings table rides the fleet module, as on the live hub; a hub
	// without it simply has no account rung (cookie only).
	if err := h.srv.Store.EnsureNodes(); err != nil {
		t.Fatal(err)
	}
	_, sess := h.signIn(t, fakeGHUser{ID: 999, Login: "verkyyi"})
	if sess == nil {
		t.Fatal("no session")
	}
	get := func(path, accept string) *http.Response {
		req, _ := http.NewRequest("GET", h.http.URL+path, nil)
		req.AddCookie(sess)
		req.Header.Set("Accept-Language", accept)
		resp, err := noFollow.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		return resp
	}
	get("/?lang=zh", "en-US")
	if set, _ := h.srv.Store.FleetSettings(); set["user.999.lang"] != i18n.ZhCN {
		t.Fatalf("account setting = %q, want zh-CN", set["user.999.lang"])
	}
	// Another device: English browser, no cf_lang — the account wins.
	resp := get("/", "en-US")
	if c := cookieNamed(resp, langCookie); c == nil || c.Value != i18n.ZhCN {
		t.Fatalf("second device cookie = %+v, want zh-CN from the account", c)
	}
}

func readAll(t *testing.T, resp *http.Response) string {
	t.Helper()
	defer resp.Body.Close()
	var b strings.Builder
	buf := make([]byte, 4096)
	for {
		n, err := resp.Body.Read(buf)
		b.Write(buf[:n])
		if err != nil {
			return b.String()
		}
	}
}
