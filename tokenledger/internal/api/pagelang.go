package api

import (
	"context"
	"html"
	"html/template"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/i18n"
)

// Which language a PAGE is drawn in (claude-fleet#2023).
//
// One rule, read the same way here and in web/dist/lib/i18n.js's pickLocale:
//
//	?lang=zh|en in the link  >  the signed-in account's user.<id>.lang
//	                         >  the cf_lang cookie  >  the browser's language
//
// A link wins so a shared link opens in the language it was sent in. The
// account wins over the cookie so a choice made on one device follows the
// person to the next. The browser's language is only the first guess: any zh*
// is 中文, everything else English (i18n.FromAcceptLanguage).
//
// The server resolves it so a public page arrives already in its language,
// with <html lang> set — no English painted first and swapped after. The
// cookie is readable by script (not HttpOnly) on purpose: it is a display
// preference, and the app's own pickLocale reads it to agree with the server.
const (
	langCookie    = "cf_lang"
	langCookieAge = 365 * 24 * 3600
)

// langSettingKey is the account setting that carries a person's choice, in
// the hub's settings table (EPIC #1982 C4's user.<id>.* family).
func langSettingKey(id int64) string { return "user." + strconv.FormatInt(id, 10) + ".lang" }

// parseLang reads a ?lang= or cookie value: zh / zh-CN / en and friends.
// Anything this build has no dictionary for is "" — not a choice.
func parseLang(v string) string {
	v = strings.TrimSpace(v)
	if v == "" {
		return ""
	}
	got := i18n.Normalize(v)
	if got == i18n.EN {
		if p, _, _ := strings.Cut(strings.ToLower(v), "-"); p != "en" {
			return ""
		}
	}
	return got
}

// pageLocale resolves r's language and keeps the two remembered copies in
// step: a ?lang= choice is written to the cookie and, for a signed-in GitHub
// person, to their account; an account choice that differs from this
// browser's cookie refreshes the cookie, so the app's script reads the same
// answer on a new device.
func (s *Server) pageLocale(w http.ResponseWriter, r *http.Request) string {
	if loc, ok := r.Context().Value(pageLangKey{}).(string); ok {
		return loc // withPageLang already settled it, cookie and all
	}
	var account string
	var id int64
	var signedIn bool
	if s.GitHub.ready() && s.Store != nil {
		if _, gid, ok := s.githubSession(r); ok {
			id, signedIn = gid, true
			if set, err := s.Store.FleetSettings(); err == nil {
				account = parseLang(set[langSettingKey(id)])
			}
		}
	}
	var cookie string
	if c, err := r.Cookie(langCookie); err == nil {
		cookie = parseLang(c.Value)
	}

	if q := parseLang(r.URL.Query().Get("lang")); q != "" {
		if signedIn && q != account {
			// Through the settings store, so the change is audited like
			// every other setting (claude-fleet#1986).
			_, _ = s.putHubSetting(githubPrincipal(id), langSettingKey(id), q, time.Now())
		}
		if q != cookie {
			setLangCookie(w, r, q)
		}
		return q
	}
	if account != "" {
		if account != cookie {
			setLangCookie(w, r, account)
		}
		return account
	}
	if cookie != "" {
		return cookie
	}
	return i18n.FromAcceptLanguage(r.Header.Get("Accept-Language"))
}

type pageLangKey struct{}

func setLangCookie(w http.ResponseWriter, r *http.Request, loc string) {
	http.SetCookie(w, &http.Cookie{
		Name: langCookie, Value: loc, Path: "/", MaxAge: langCookieAge,
		SameSite: http.SameSiteLaxMode, Secure: isHTTPS(r),
	})
}

// withPageLang settles the language for every page under "/" — the front
// page and the app's own .html — before the page is served, so a ?lang= link
// into the app is remembered and a signed-in person's choice reaches this
// browser's cookie. Assets (.js, .css, …) pass untouched.
func (s *Server) withPageLang(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodGet || r.Method == http.MethodHead {
			p := r.URL.Path
			if base := p[strings.LastIndexByte(p, '/')+1:]; !strings.Contains(base, ".") || strings.HasSuffix(base, ".html") {
				loc := s.pageLocale(w, r)
				r = r.WithContext(context.WithValue(r.Context(), pageLangKey{}, loc))
			}
		}
		next.ServeHTTP(w, r)
	})
}

// langHref is r's own URL with lang set: the switch keeps every other query
// parameter (a /fleet/login?code=…, a /signin?e=…) where it was.
func langHref(r *http.Request, loc string) string {
	q := url.Values{}
	if r != nil {
		for k, v := range r.URL.Query() {
			q[k] = v
		}
	}
	q.Set("lang", langParam(loc))
	return "?" + q.Encode()
}

// langParam is the short form a link carries: zh or en.
func langParam(loc string) string {
	if loc == i18n.ZhCN {
		return "zh"
	}
	return "en"
}

// pageView is what every public page's template gets besides its own data.
type pageView struct {
	Lang   string // en | zh-CN, for <html lang>
	ZhHref string // this page in 中文
	EnHref string // this page in English
	IsZh   bool
}

func newPageView(r *http.Request, loc string) pageView {
	return pageView{Lang: loc, IsZh: loc == i18n.ZhCN, ZhHref: langHref(r, i18n.ZhCN), EnHref: langHref(r, i18n.EN)}
}

// pageFuncs gives a page template its t (plain text, escaped by the
// template) and tb (a sentence with one bolded, escaped value in it).
func pageFuncs(loc string) template.FuncMap {
	return template.FuncMap{
		"t": func(key string) string { return pageT(loc, key) },
		"tb": func(key, v string) template.HTML {
			return template.HTML(i18n.Interpolate(html.EscapeString(pageT(loc, key)),
				map[string]string{"v": "<b>" + html.EscapeString(v) + "</b>"}))
		},
	}
}

// pageT is one public-page string in loc. A key with no text at all renders
// as itself — visibly a bug, never a blank (pagelang_test.go keeps every key
// in both languages).
func pageT(loc, key string) string {
	txt, ok := pageText[key]
	if !ok {
		return key
	}
	return txt.In(loc)
}

// langSwitchCSS + langSwitch are the 中文 / EN pair on the public pages' top
// bar. Plain links: the server does the remembering, so it works with no
// script at all.
const langSwitchCSS = `.langsw{display:inline-flex;border:1px solid var(--line);border-radius:7px;overflow:hidden;flex:none}
.langsw a{padding:4px 9px;font-size:12.5px;color:var(--ink-2);text-decoration:none;line-height:1.4}
.langsw a[aria-current]{background:var(--ink);color:var(--bg)}
`

const langSwitch = `<span class="langsw" role="group" aria-label="{{t "lang.label"}}"><a href="{{.ZhHref}}" lang="zh-CN" hreflang="zh-CN"{{if .IsZh}} aria-current="true"{{end}}>中文</a><a href="{{.EnHref}}" lang="en" hreflang="en"{{if not .IsZh}} aria-current="true"{{end}}>EN</a></span>`

// zhTypeCSS sets Chinese as Chinese: the system's Chinese faces (no web font —
// a Chinese one is megabytes), no letter-spacing or case change on labels,
// and a taller line for body text.
const zhTypeCSS = `:lang(zh){--f-ui:-apple-system,"PingFang SC","Hiragino Sans GB","Noto Sans SC","Microsoft YaHei",system-ui,sans-serif;--f-display:-apple-system,"PingFang SC","Hiragino Sans GB","Noto Sans SC","Microsoft YaHei",system-ui,sans-serif}
html:lang(zh) body{line-height:1.75}
:lang(zh) h1,:lang(zh) h2,:lang(zh) h3{line-height:1.25;letter-spacing:0}
:lang(zh) .eyebrow{letter-spacing:0;text-transform:none}
`
