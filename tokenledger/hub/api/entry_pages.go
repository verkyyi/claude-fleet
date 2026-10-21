package api

import (
	"html/template"
	"io/fs"
	"net/http"
	"path"
	"strings"

	"github.com/verkyyi/claude-fleet/tokenledger/shared/i18n"
)

// The way in (claude-fleet#3932, EPIC #3923 C9): /signin, /fleet/login, /i/,
// /fleet/login/refused and the 404 a member gets for the admin side are drawn
// here on the server, and wear the website's look — extras/fleet-theme, packed
// into web/theme and served at themePrefix — with the shadcn/ui shapes written
// out by hand: a header (the mark, 中文 / EN, ← the website), one column, pill
// buttons, a labelled field. Every colour and family is the theme's variable
// (bin/fleet-theme-selftest.sh reds on one defined here); the page loads
// nothing from another origin (entryCSP). Addresses, form fields and cookies
// are as they were.

// themePrefix is where the packed theme is served.
const themePrefix = AppPrefix + "/assets/fleet-theme/"

var themeTypes = map[string]string{
	".css":   "text/css; charset=utf-8",
	".woff2": "font/woff2",
	".svg":   "image/svg+xml",
}

// serveTheme answers a file of the packed theme: open to anyone (the sign-in
// page wears it), a read only, 404 for anything else.
func (s *Server) serveTheme(w http.ResponseWriter, r *http.Request, name string) {
	ct := themeTypes[path.Ext(name)]
	if s.ThemeFS == nil || ct == "" || !fs.ValidPath(name) || strings.HasPrefix(path.Base(name), ".") ||
		(r.Method != http.MethodGet && r.Method != http.MethodHead) {
		http.NotFound(w, r)
		return
	}
	b, err := fs.ReadFile(s.ThemeFS, name)
	if err != nil {
		http.NotFound(w, r)
		return
	}
	age := "300" // the stylesheets keep their names when the theme changes
	if ct == "font/woff2" || ct == "image/svg+xml" {
		age = "604800"
	}
	h := w.Header()
	h.Set("Content-Type", ct)
	h.Set("Cache-Control", "public, max-age="+age)
	h.Set("X-Content-Type-Options", "nosniff")
	writeSiteBody(w, r, b, ct != "font/woff2")
}

// entryCSP: a way-in page loads nothing from anywhere else.
const entryCSP = "default-src 'self'; script-src 'none'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; connect-src 'self'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'"

// entryHeaders are the headers every way-in page carries.
func entryHeaders(w http.ResponseWriter, loc string) {
	h := w.Header()
	h.Set("Content-Type", "text/html; charset=utf-8")
	h.Set("Cache-Control", "no-store")
	h.Set("X-Frame-Options", "DENY")
	h.Set("Content-Security-Policy", entryCSP)
	h.Set("Content-Language", loc)
}

// entryHead opens a way-in page: the theme, then entryCSS. Its template ends
// the <head> after its own <title>.
const entryHead = `<!doctype html>
<html lang="{{.Lang}}"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="robots" content="noindex, nofollow">
<link rel="icon" href="/favicon.ico" sizes="32x32">
<link rel="icon" href="/favicon.svg" type="image/svg+xml">
<link rel="apple-touch-icon" href="/apple-touch-icon.png">
<link rel="stylesheet" href="` + themePrefix + `theme.css">
<style>` + entryCSS + `</style>
`

// entryTop is the header: the mark, the language pair, the way back to the
// website. Inside <div class="page">.
const entryTop = `<header class="top"><span class="brand"><img src="` + themePrefix + `logo.svg" alt="" width="28" height="28">ClaudeFleet</span>
<span class="end">` + langSwitch + `<a class="home" href="/">` + arrowLeftIcon + `{{t "entry.site"}}</a></span></header>`

// limitedPill says, above a way-in page's heading, that the hub is open to a
// limited few for now (claude-fleet#4049).
const limitedPill = `<span class="pill"><i></i>{{t "signin.pill"}}</span>`

// The lucide icons the pages use, as lucide draws them.
const (
	arrowLeftIcon = `<svg viewBox="0 0 24 24" aria-hidden="true"><path d="m12 19-7-7 7-7"/><path d="M19 12H5"/></svg>`
	wechatIcon    = `<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M2.992 16.342a2 2 0 0 1 .094 1.167l-1.065 3.29a1 1 0 0 0 1.236 1.168l3.413-.998a2 2 0 0 1 1.099.092 10 10 0 1 0-4.777-4.719"/></svg>`
	gitIcon       = `<svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="18" cy="18" r="3"/><circle cx="6" cy="6" r="3"/><path d="M6 21V9a9 9 0 0 0 9 9"/></svg>`
	lockIcon      = `<svg viewBox="0 0 24 24" aria-hidden="true"><rect width="18" height="11" x="3" y="11" rx="2" ry="2"/><path d="M7 11V7a5 5 0 0 1 10 0v4"/></svg>`
	checkIcon     = `<svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="10"/><path d="m9 12 2 2 4-4"/></svg>`
	alertIcon     = `<svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="10"/><line x1="12" x2="12" y1="8" y2="12"/><line x1="12" x2="12.01" y1="16" y2="16"/></svg>`
)

// entryCSS is the shadcn/ui look, by hand, on the theme's variables: Button
// (default · outline, size lg, rounded-full), Input, Label, Separator, Card,
// Alert. Light and dark follow the system, as theme.css does.
const entryCSS = `*,*::before,*::after{box-sizing:border-box}
html,body{height:100%}
body{margin:0;background:var(--background);color:var(--foreground);font:16px/1.6 var(--fleet-font-ui);-webkit-font-smoothing:antialiased;-webkit-text-size-adjust:100%;-webkit-tap-highlight-color:transparent}
html:lang(zh) body{line-height:1.75}
svg{width:16px;height:16px;flex:none;fill:none;stroke:currentColor;stroke-width:2;stroke-linecap:round;stroke-linejoin:round}
.page{min-height:100dvh;display:flex;flex-direction:column}
.top{display:flex;align-items:center;gap:10px;padding:16px 20px}
.brand{display:inline-flex;align-items:center;gap:10px;font:600 17px/1 var(--fleet-font-display);letter-spacing:-.025em}
.brand img{display:block;width:28px;height:28px}
.end{margin-inline-start:auto;display:inline-flex;align-items:center;gap:14px}
.home{display:inline-flex;align-items:center;gap:4px;color:var(--muted-foreground);font-size:14px;line-height:1;text-decoration:none}
.home:hover{color:var(--foreground)}
.langsw{display:inline-flex;border:1px solid var(--border);border-radius:9999px;overflow:hidden;flex:none}
.langsw a{padding:3px 10px;font-size:12px;line-height:1.5;color:var(--muted-foreground);text-decoration:none}
.langsw a[aria-current]{background:var(--secondary);color:var(--secondary-foreground)}
.col{width:100%;max-width:24rem;margin:0 auto;flex:1;display:flex;flex-direction:column;justify-content:center;padding:0 24px 64px}
h1{margin:0;font:600 32px/1.25 var(--fleet-font-display);letter-spacing:-.025em;overflow-wrap:anywhere}
h1 .dot{color:var(--fleet-clay)}
p{margin:0}
.lead{margin:8px 0 28px;color:var(--muted-foreground)}
.fine{margin-top:32px;text-align:center;font-size:14px;color:var(--muted-foreground)}
.fine a{color:var(--muted-foreground)}
.agree{margin-top:14px;text-align:center;font-size:12.5px;line-height:1.6;color:var(--muted-foreground)}
.agree a{color:var(--foreground);text-decoration:underline;text-underline-offset:2px}
.pill{display:inline-flex;align-items:center;gap:6px;width:max-content;margin-bottom:16px;padding:3px 10px;border:1px solid var(--fleet-clay-line);border-radius:9999px;background:var(--fleet-clay-soft);color:var(--fleet-clay);font-size:12px;line-height:1.5}
.pill i{width:6px;height:6px;border-radius:50%;background:currentColor}
.btn{display:inline-flex;align-items:center;justify-content:center;gap:8px;width:100%;height:48px;padding:0 24px;border:1px solid transparent;border-radius:9999px;font:500 14px/1 var(--fleet-font-ui);white-space:nowrap;text-decoration:none;cursor:pointer;transition:background-color .15s,color .15s,box-shadow .15s}
.btn.primary{background:var(--primary);color:var(--primary-foreground)}
.btn.primary:hover{background:color-mix(in oklab,var(--primary) 90%,transparent)}
.btn.outline{height:44px;background:var(--background);border-color:var(--border);color:var(--foreground);box-shadow:0 1px 2px rgb(0 0 0/.05)}
.btn.outline:hover{background:var(--accent);color:var(--accent-foreground)}
.btn.ghost{height:44px;background:transparent;color:var(--muted-foreground)}
.btn.ghost:hover{background:var(--accent);color:var(--accent-foreground)}
.btn.wx{background:#07c160;color:#fff}
.btn.wx:hover{background:#06ad56}
.btn:focus-visible,.input:focus-visible{outline:none;border-color:var(--ring);box-shadow:0 0 0 3px color-mix(in oklab,var(--ring) 50%,transparent)}
.or{display:flex;align-items:center;gap:12px;margin:24px 0;font-size:12px;line-height:1;color:var(--muted-foreground)}
.or::before,.or::after{content:"";flex:1;height:1px;background:var(--border)}
.stack{display:grid;gap:8px}
label{font-size:14px;font-weight:500;line-height:1;margin-bottom:4px}
.input{width:100%;height:44px;padding:4px 12px;border:1px solid var(--input);border-radius:calc(var(--radius) - 2px);background:transparent;color:var(--foreground);font:16px var(--fleet-font-ui);box-shadow:0 1px 2px rgb(0 0 0/.05)}
.input::placeholder{color:var(--muted-foreground)}
.input.code{height:56px;font:500 24px var(--fleet-font-mono);letter-spacing:.35em;text-align:center}
.alert{display:flex;gap:10px;align-items:flex-start;margin:0 0 20px;padding:12px 16px;border:1px solid var(--border);border-radius:var(--radius);background:var(--card);color:var(--card-foreground);font-size:14px;overflow-wrap:anywhere}
.alert svg{margin-top:4px;color:var(--fleet-clay)}
h1+.alert{margin-top:24px}
.alert.bad,.alert.bad svg{color:var(--destructive)}
.alert.ok svg{color:var(--fleet-ok)}
.card{margin:0 0 12px;padding:16px 20px;border:1px solid var(--border);border-radius:calc(var(--radius) + 4px);background:var(--card);color:var(--card-foreground);overflow-wrap:anywhere}
.label{font-size:13px;color:var(--muted-foreground)}
.label+*{margin-top:2px}
.card .label:not(:first-child){margin-top:12px}
.big{font:500 30px/1.2 var(--fleet-font-mono);letter-spacing:.08em}
.mono{font:13px/1.5 var(--fleet-font-mono);word-break:break-all}
.ask{margin:0 0 20px;padding:10px 14px;border-radius:calc(var(--radius) - 2px);background:var(--muted);color:var(--foreground);font:500 14px/1.5 var(--fleet-font-mono);user-select:all;overflow-wrap:anywhere}
.row{display:flex;gap:12px;margin-top:12px}
.row>*{flex:1}
.tile{width:48px;height:48px;margin-bottom:20px;border-radius:12px;display:grid;place-items:center;background:color-mix(in oklab,var(--destructive) 12%,transparent);color:var(--destructive)}
.tile svg{width:22px;height:22px}
.gone{flex:1;display:flex;flex-direction:column;align-items:center;justify-content:center;padding:24px;text-align:center}
.gone img{width:48px;height:48px;margin-bottom:24px}
.gone .num{font:700 88px/1 var(--fleet-font-display);color:color-mix(in oklab,var(--muted-foreground) 40%,transparent)}
.gone h1{margin-top:12px;font-size:24px}
.gone .lead{margin:8px 0 0}
.gone .btn{width:auto;height:36px;margin-top:24px;padding:0 16px}
.col.lift{justify-content:flex-start;padding-top:16px;max-width:28rem}
.who{display:flex;align-items:center;gap:12px;margin:0 0 24px;padding:12px 16px;border:1px solid var(--border);border-radius:var(--radius);background:var(--card);font-size:14px}
.who .av{width:36px;height:36px;border-radius:50%;display:grid;place-items:center;background:var(--fleet-clay-soft);color:var(--fleet-clay);font-weight:600;flex:none}
.who .n{font-weight:500;overflow-wrap:anywhere}
.who .m{color:var(--muted-foreground);font-size:13px;display:flex;align-items:center;gap:4px}
.who .m svg{width:14px;height:14px}
.who a{margin-inline-start:auto;font-size:13px;color:var(--muted-foreground);white-space:nowrap}
.field{display:grid;gap:6px;margin-bottom:20px}
.field label{margin:0}
.field label small{font-weight:400;color:var(--muted-foreground);margin-inline-start:4px}
.input.area{height:auto;min-height:112px;padding:10px 12px;line-height:1.6;resize:vertical}
.hint{display:flex;justify-content:space-between;gap:12px;font-size:13px;color:var(--muted-foreground)}
.hint.bad{color:var(--destructive)}
.input.bad{border-color:var(--destructive);box-shadow:0 0 0 3px color-mix(in oklab,var(--destructive) 20%,transparent)}
.opts{display:grid;gap:8px}
.opt{position:relative;display:flex;gap:12px;align-items:flex-start;padding:12px 14px;border:1px solid var(--border);border-radius:calc(var(--radius) - 2px);background:var(--background);cursor:pointer;font-size:14px;font-weight:400;line-height:1.6;margin:0}
.opt input[type=radio]{position:absolute;opacity:0;width:1px;height:1px;margin:0}
.opt .dot{width:16px;height:16px;margin-top:3px;border-radius:50%;border:1px solid var(--input);flex:none;display:grid;place-items:center}
.opt:has(input:checked){border-color:var(--ring);box-shadow:0 0 0 1px var(--ring)}
.opt:has(input:checked) .dot{border-color:var(--primary)}
.opt:has(input:checked) .dot::after{content:"";width:8px;height:8px;border-radius:50%;background:var(--primary)}
.opt:has(input:focus-visible){box-shadow:0 0 0 3px color-mix(in oklab,var(--ring) 50%,transparent)}
.opt .b{flex:1;min-width:0;overflow-wrap:anywhere}
.opt .s{font-size:13px;color:var(--muted-foreground)}
.opt .ok{color:var(--fleet-ok);font-size:13px}
.opt .input{margin-top:10px;height:40px}
.tile.wait{background:var(--fleet-clay-soft);color:var(--fleet-clay)}
.tile.ok{background:color-mix(in oklab,var(--fleet-ok) 16%,transparent);color:var(--fleet-ok)}
.tile.mute{background:var(--muted);color:var(--muted-foreground)}
.steps{list-style:none;margin:0 0 24px;padding:0;display:grid;gap:0}
.steps li{position:relative;display:flex;gap:12px;padding:0 0 18px;font-size:14px}
.steps li:last-child{padding-bottom:0}
.steps li::before{content:"";position:absolute;left:7px;top:20px;bottom:0;width:2px;background:var(--border)}
.steps li:last-child::before{display:none}
.steps .k{width:16px;height:16px;margin-top:4px;border-radius:50%;flex:none;border:2px solid var(--border);background:var(--background);position:relative;z-index:1}
.steps .done .k{background:var(--fleet-ok);border-color:var(--fleet-ok)}
.steps .now .k{border-color:var(--fleet-clay);box-shadow:0 0 0 4px var(--fleet-clay-soft)}
.steps .t{font-weight:500}
.steps .s{color:var(--muted-foreground);font-size:13px}
.steps .later .t{color:var(--muted-foreground);font-weight:400}
.quote{margin:0 0 20px;padding:12px 16px;border-left:3px solid var(--fleet-clay);background:var(--muted);border-radius:0 calc(var(--radius) - 2px) calc(var(--radius) - 2px) 0;font-size:14px;overflow-wrap:anywhere;white-space:pre-line}
.card p.pre{white-space:pre-line}
.twin{display:grid;grid-template-columns:1fr 1fr;gap:8px}
.twin form{display:contents}
.scrim{position:fixed;inset:0;z-index:10;background:rgb(0 0 0/.5);display:grid;place-items:center;padding:24px}
.dlg{width:100%;max-width:24rem;padding:24px;border:1px solid var(--border);border-radius:calc(var(--radius) + 4px);background:var(--background)}
.dlg h2{margin:0 0 8px;font:600 18px/1.4 var(--fleet-font-display)}
.dlg p{color:var(--muted-foreground);font-size:14px;margin-bottom:20px}
.dlg .twin .btn{height:40px}
`

// notFoundTmpl is 「页面不存在」. It reflects nothing of the request — no
// path, no query (the language links are bare ?lang=) — so every address a
// member may not see answers it byte for byte (TestAdminIs404ForMember).
var notFoundTmpl = template.Must(template.New("404").Funcs(pageFuncs(i18n.EN)).Parse(entryHead + `
<title>{{t "nf.title"}}</title></head><body><div class="page">
<main class="gone"><img src="` + themePrefix + `logo.svg" alt="" width="48" height="48">
<p class="num">404</p>
<h1>{{t "nf.h1"}}<span class="dot">.</span></h1>
<p class="lead">{{t "nf.lead"}}</p>
<a class="btn primary" href="/app">{{t "nf.back"}}</a></main>
</div></body></html>`))

// notFoundPage answers 404 with 「页面不存在」 in r's language.
func (s *Server) notFoundPage(w http.ResponseWriter, r *http.Request) {
	loc := s.pageLocale(w, r)
	entryHeaders(w, loc)
	w.WriteHeader(http.StatusNotFound)
	if r.Method == http.MethodHead {
		return
	}
	if c, err := notFoundTmpl.Clone(); err == nil {
		_ = c.Funcs(pageFuncs(loc)).Execute(w, newPageView(nil, loc))
	}
}

func init() {
	for k, v := range map[string]i18n.Text{
		"entry.site": {i18n.EN: "Website", i18n.ZhCN: "官网"},
		"nf.title":   {i18n.EN: "Page not found · ClaudeFleet", i18n.ZhCN: "页面不存在 · ClaudeFleet"},
		"nf.h1":      {i18n.EN: "Page not found", i18n.ZhCN: "页面不存在"},
		"nf.lead": {
			i18n.EN:   "The address may be mistyped, or the page has moved.",
			i18n.ZhCN: "地址可能写错了，或这一页已经搬走。",
		},
		"nf.back": {i18n.EN: "Back to my pages", i18n.ZhCN: "回到我的页面"},
	} {
		pageText[k] = v
	}
}
