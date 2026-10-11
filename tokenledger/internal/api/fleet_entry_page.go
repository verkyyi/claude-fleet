package api

import (
	"errors"
	"fmt"
	"html/template"
	"net/http"
	"net/url"
	"strings"
	"time"

	"golang.org/x/crypto/ssh"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/i18n"
)

// The keys page (claude-fleet#3069, EPIC #3067 C2): one page on the hub, made
// for a phone's browser, where a person picks their address name, reads the
// four things Termius asks for (address · port · user · key), adds and
// revokes their keys and, when it must, moves their home.
//
// It is drawn on the server and works with no script at all: every change is
// a form POST answered by a redirect back (?ok=<what>), a refusal is the page
// again with one sentence; the two confirmations (revoke a key, move the
// home) are the page with a sheet at its bottom (?revoke=<id>, ?move=<machine>).
// Only the person's own book is ever drawn — the operator's ?principal= is
// the JSON doors', never this page's — and only through C1's person-side
// cores (entryViewOf · entryAdd · entryRevoke · entrySetName · entrySetHome).
// A public key's body is never drawn, only its fingerprint, shortened.

// EntryPagePath is the keys page.
const EntryPagePath = "/fleet/keys"

// entryReturnCookie remembers, across the GitHub sign-in, that the browser
// was on its way to the keys page (loginReturn reads it).
const entryReturnCookie = "ccquota_return"

// entryOK are the sentences a redirect back may carry (?ok=<key>).
var entryOK = map[string]string{
	"name":    "地址名定好了。",
	"added":   "已加上。几秒内你的家机器就认它。",
	"same":    "这把钥匙已经在你的列表里了。",
	"revoked": "已撤掉。几秒内家机器不再认它，并断开正用它连着的入口连接。",
	"home":    "已换家。你的地址几分钟内指向它；端口以下面写的为准（变了就在 Termius 里改一次）；手机第一次连会说主机钥匙变了，接受一次。",
}

type entryKeyRow struct {
	ID, Name, Type, FP, Added, LastUsed string
}

type entryChoiceRow struct {
	Machine, Display, Login string
	Online, Current         bool
	Port                    int // the door's port from outside (entryPublicPort)
}

type entryPageData struct {
	pageView
	NoPerson bool // the operator's token: no book of their own
	OK       string
	Err      string
	ErrFor   string // name | add | home
	NeedName bool
	NameVal  string // the name field's value
	Name     string
	Domain   string
	Address  string // <name>.<domain>; "" when either is missing
	Port     int
	Home     *entryChoiceRow
	HomeDown string // when the home is not reachable: since when, or ""
	Keys     []entryKeyRow
	Others   []entryChoiceRow // homes to move to
	Pasted   string           // the add form's text after a refusal (never a private key)
	Label    string
	Revoke   *entryKeyRow
	Move     *entryChoiceRow
}

// handleEntryPage serves EntryPagePath.
func (s *Server) handleEntryPage(w http.ResponseWriter, r *http.Request) {
	if !s.entryOn() {
		http.NotFound(w, r)
		return
	}
	if r.Method != http.MethodGet && r.Method != http.MethodHead && r.Method != http.MethodPost {
		w.Header().Set("Allow", "GET, POST")
		httpError(w, http.StatusMethodNotAllowed, "GET or POST")
		return
	}
	// The page is always the caller's own book: drop ?principal=.
	own := r.Clone(r.Context())
	own.URL = &url.URL{Path: r.URL.Path}
	c, code, _ := s.entryCallerFor(own)
	page := entryPageData{pageView: newPageView(r, i18n.ZhCN), Port: entryPort}
	if code == http.StatusBadRequest { // the operator, no person named
		page.NoPerson = true
		s.writeEntryPage(w, http.StatusOK, page)
		return
	}
	if code != 0 {
		httpError(w, code, "sign in first")
		return
	}
	now := time.Now()
	if r.Method == http.MethodPost {
		if !sameOrigin(r) {
			httpError(w, http.StatusForbidden, "cross-origin form")
			return
		}
		r.Body = http.MaxBytesReader(w, r.Body, entryKeyMax+4096)
		if err := r.ParseForm(); err != nil {
			httpError(w, http.StatusBadRequest, "unreadable form")
			return
		}
		if ok, status := s.entryPagePost(r, c, now, &page); ok != "" {
			http.Redirect(w, r, EntryPagePath+"?ok="+ok, http.StatusSeeOther)
			return
		} else if status != 0 {
			if err := s.fillEntryPage(r, c, now, &page); err != nil {
				httpError(w, http.StatusInternalServerError, err.Error())
				return
			}
			s.writeEntryPage(w, status, page)
			return
		}
	}
	if err := s.fillEntryPage(r, c, now, &page); err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	page.OK = entryOK[r.URL.Query().Get("ok")]
	s.writeEntryPage(w, http.StatusOK, page)
}

// entryPagePost runs one form: the ?ok= key on success, else the status the
// page is drawn again with (its sentence in page.Err).
func (s *Server) entryPagePost(r *http.Request, c entryCaller, now time.Time, page *entryPageData) (string, int) {
	fail := func(what string, code int, err error) (string, int) {
		page.ErrFor, page.Err = what, err.Error()
		if code == http.StatusNotFound {
			page.Err = "没有这把钥匙了：可能已经撤掉。"
		}
		return "", code
	}
	switch r.PostFormValue("do") {
	case "name":
		page.NameVal = r.PostFormValue("name")
		if _, _, code, err := s.entrySetName(c, page.NameVal, now); err != nil {
			return fail("name", code, err)
		}
		return "name", 0
	case "add":
		page.Label = entryLabel(r.PostFormValue("label"))
		_, added, code, err := s.entryAdd(c, r.PostFormValue("key"), page.Label, now)
		if err != nil {
			if !errors.Is(err, errEntryPrivate) && !entryLooksPrivate(r.PostFormValue("key")) {
				page.Pasted = strings.TrimSpace(r.PostFormValue("key"))
			}
			return fail("add", code, err)
		}
		if !added {
			return "same", 0
		}
		return "added", 0
	case "revoke":
		if _, code, err := s.entryRevoke(c, r.PostFormValue("id"), now); err != nil {
			return fail("revoke", code, err)
		}
		return "revoked", 0
	case "home":
		if _, _, code, err := s.entrySetHome(c, r.PostFormValue("machine"), r.PostFormValue("login"), now); err != nil {
			return fail("home", code, err)
		}
		return "home", 0
	}
	return fail("", http.StatusBadRequest, errors.New("看不懂这个表单"))
}

// fillEntryPage reads the book into the page.
func (s *Server) fillEntryPage(r *http.Request, c entryCaller, now time.Time, page *entryPageData) error {
	v, err := s.entryViewOf(c, now)
	if err != nil {
		return err
	}
	page.Name = v.Name
	page.NeedName = v.Name == ""
	if page.NameVal == "" {
		page.NameVal = v.Name
		if page.NeedName {
			page.NameVal = v.SuggestedName
		}
	}
	page.Domain = s.setting(EntryDomainKey)
	if page.Name != "" && page.Domain != "" {
		page.Address = page.Name + "." + page.Domain
	}
	for _, k := range v.Keys {
		page.Keys = append(page.Keys, entryKeyRow{ID: k.ID, Name: k.Name, Type: entryKeyType(k.Type), FP: entryShortFP(k.FP),
			Added: entryWhen(k.Created, now), LastUsed: entryLastUsed(k.LastUsed, now)})
	}
	for _, ch := range v.HomeChoices {
		row := entryChoiceRow{Machine: ch.Machine, Display: s.entryMachineName(ch.Machine), Login: ch.Login, Online: ch.Online,
			Port: s.entryPublicPort(ch.Machine, now)}
		if v.Home != nil && sameMachine(ch.Machine, v.Home.Machine) && ch.Login == v.Home.Login {
			row.Current = true
			page.Home = &row
			continue
		}
		page.Others = append(page.Others, row)
	}
	if v.Home != nil && page.Home == nil {
		// The home has no live fleet right now: the machine is gone, or the
		// fleet on it is.
		page.Home = &entryChoiceRow{Machine: v.Home.Machine, Display: s.entryMachineName(v.Home.Machine), Login: v.Home.Login, Current: true,
			Port: s.entryPublicPort(v.Home.Machine, now)}
	}
	if page.Home != nil {
		// Two homes behind one router share the address and differ by the
		// port the router forwards (EPIC #3067 改约定 2): Termius's port is
		// the home's, not a constant.
		page.Port = page.Home.Port
	}
	if page.Home != nil && !page.Home.Online {
		page.HomeDown = "现在"
		if t := s.entryLastBeat(page.Home.Machine); t != nil {
			page.HomeDown = entryWhen(*t, now) + "起"
		}
	} else if page.Home != nil && s.EntryDNS != nil {
		// Online but nobody outside reaches it (C6): the address keeps its
		// last records and goes nowhere new (claude-fleet#3073).
		if reach, err := s.EntryReachable(page.Home.Machine, now); err == nil && len(reach) == 0 {
			page.HomeDown = "从外面"
		}
	}
	q := r.URL.Query()
	if id := q.Get("revoke"); id != "" && r.Method != http.MethodPost {
		for i := range page.Keys {
			if page.Keys[i].ID == id {
				page.Revoke = &page.Keys[i]
			}
		}
	}
	if m := q.Get("move"); m != "" && r.Method != http.MethodPost {
		for i := range page.Others {
			if page.Others[i].Machine == m && (q.Get("login") == "" || q.Get("login") == page.Others[i].Login) {
				page.Move = &page.Others[i]
			}
		}
	}
	return nil
}

// entryMachineName is how a person knows a machine: its short name, else its
// first label.
func (s *Server) entryMachineName(host string) string {
	if a := machineAlias(host, s.machineNames()); a != "" {
		return a
	}
	for _, m := range s.fleetMachines() {
		if sameMachine(m.Hostname, host) && m.Alias != "" {
			return m.Alias
		}
	}
	return firstLabel(host)
}

// entryLastBeat is the newest heartbeat any login on host sent.
func (s *Server) entryLastBeat(host string) *time.Time {
	rows, err := s.Store.Nodes()
	if err != nil {
		return nil
	}
	var last *time.Time
	for _, n := range rows {
		if n.LastHeartbeat != nil && sameMachine(n.Hostname, host) && (last == nil || n.LastHeartbeat.After(*last)) {
			last = n.LastHeartbeat
		}
	}
	return last
}

// entryKeyType is a key's kind as a person says it.
func entryKeyType(t string) string {
	switch {
	case t == ssh.KeyAlgoED25519:
		return "ed25519"
	case strings.HasPrefix(t, "ecdsa-"):
		return "ecdsa"
	case t == ssh.KeyAlgoRSA:
		return "rsa"
	}
	return t
}

// entryShortFP is SHA256:q3Vt…9xKc — enough to tell two keys apart.
func entryShortFP(fp string) string {
	body := strings.TrimPrefix(fp, "SHA256:")
	if len(body) <= 10 {
		return fp
	}
	return "SHA256:" + body[:4] + "…" + body[len(body)-4:]
}

// entryWhen is a time as a person reads it on a phone: how long ago, then the
// day (UTC+8, the people this page is for).
func entryWhen(t, now time.Time) string {
	d := now.Sub(t)
	switch {
	case d < time.Minute:
		return "刚才"
	case d < time.Hour:
		return fmt.Sprintf("%d 分钟前", int(d.Minutes()))
	case d < 24*time.Hour:
		return fmt.Sprintf("%d 小时前", int(d.Hours()))
	case d < 7*24*time.Hour:
		return fmt.Sprintf("%d 天前", int(d.Hours()/24))
	}
	return t.In(time.FixedZone("CST", 8*3600)).Format("2006-01-02")
}

func entryLastUsed(t *time.Time, now time.Time) string {
	if t == nil {
		return "还没用过"
	}
	return entryWhen(*t, now)
}

func (s *Server) writeEntryPage(w http.ResponseWriter, status int, page entryPageData) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Frame-Options", "DENY")
	w.Header().Set("Referrer-Policy", "same-origin")
	w.WriteHeader(status)
	_ = entryPageTmpl.Execute(w, page)
}

// rememberEntryReturn sends a browser that is not signed in back to the keys
// page after GitHub's: the cookie loginReturn reads.
func (s *Server) rememberEntryReturn(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if _, ok := s.sshRelayHTTPIdentity(r); !ok && r.Method == http.MethodGet && s.entryOn() {
			http.SetCookie(w, &http.Cookie{Name: entryReturnCookie, Value: EntryPagePath, Path: "/",
				HttpOnly: true, SameSite: http.SameSiteLaxMode, Secure: isHTTPS(r), MaxAge: int(loginCookieTTL.Seconds())})
		}
		next.ServeHTTP(w, r)
	})
}

// entryReturnTo is where the GitHub sign-in sends a browser that came for the
// keys page, "" for any other; the cookie is spent.
func entryReturnTo(w http.ResponseWriter, r *http.Request) string {
	c, err := r.Cookie(entryReturnCookie)
	if err != nil {
		return ""
	}
	http.SetCookie(w, &http.Cookie{Name: entryReturnCookie, Value: "", Path: "/", MaxAge: -1})
	if c.Value != EntryPagePath { // the one place it may send anyone
		return ""
	}
	return EntryPagePath
}

var entryPageTmpl = template.Must(template.New("keys").Parse(`<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="robots" content="noindex, nofollow">
<title>从手机连 fleet · claudefleet</title>
<link rel="icon" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24'%3E%3Crect width='24' height='24' rx='6' fill='%230e6e5e'/%3E%3Cpath d='M4 17l4-10 4 10M12 17l4-10 4 10M3 20h18' stroke='%23fff' stroke-width='2.2' fill='none' stroke-linecap='round'/%3E%3C/svg%3E">
<style>
` + authPaletteCSS + zhTypeCSS + `*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--ink);font:15px/1.6 var(--f-ui);-webkit-font-smoothing:antialiased;-webkit-text-size-adjust:100%}
main{max-width:520px;margin:0 auto;padding:16px 14px 120px}
nav{display:flex;align-items:center;justify-content:space-between;gap:12px;margin:0 0 14px}
.logo{display:inline-flex;align-items:center;gap:8px;font:700 17px var(--f-display);color:var(--ink);text-decoration:none}
.mark{width:24px;height:24px;border-radius:7px;background:var(--brand);display:grid;place-items:center}
.mark svg{width:15px;height:15px;stroke:var(--brand-ink);stroke-width:2.2;fill:none;stroke-linecap:round}
h1{font:700 1.35rem var(--f-display);margin:4px 0 2px}
h2{font-size:1rem;margin:0 0 10px}
p{margin:0}.hint{color:var(--muted);font-size:13.5px}
.card{background:var(--panel);border:1px solid var(--line);border-radius:12px;box-shadow:var(--shadow);padding:14px;margin:12px 0;overflow-wrap:anywhere}
.row{display:flex;align-items:center;gap:10px;padding:9px 0;border-top:1px solid var(--line-2)}
.row:first-of-type{border-top:0}
.row .k{width:3.4em;flex:none;color:var(--muted);font-size:13.5px}
.row .v{flex:1;min-width:0;font:500 14.5px ui-monospace,Menlo,monospace;user-select:all;-webkit-user-select:all}
.row .v.plain{font:inherit;user-select:auto;-webkit-user-select:auto}
.row .v.miss{font:inherit;color:var(--warn)}
button,.btn{font:500 15px var(--f-ui);border:1px solid var(--line);background:var(--panel);color:var(--ink);padding:10px 14px;border-radius:9px;text-decoration:none;display:inline-flex;align-items:center;justify-content:center;min-height:44px;cursor:pointer}
.btn.go,button.go{background:var(--brand);border-color:var(--brand);color:var(--brand-ink)}
.btn.bad,button.bad{background:var(--bad);border-color:var(--bad);color:#fff}
.btn.wide,button.wide{width:100%;margin-top:10px}
.cp{min-height:36px;padding:6px 12px;font-size:13.5px;flex:none}
input,textarea{width:100%;font:16px/1.4 ui-monospace,Menlo,monospace;color:var(--ink);background:var(--bg);border:1px solid var(--line);border-radius:9px;padding:10px}
textarea{min-height:84px;resize:vertical}
textarea::placeholder{font-family:var(--f-ui)}
input.lbl{font-family:var(--f-ui);margin-top:8px}
.msg{border-radius:9px;padding:9px 12px;font-size:14px;margin:10px 0}
.msg.ok{background:var(--line-2);color:var(--brand)}
.msg.err{background:var(--bad-soft);color:var(--bad)}
.msg.warn{background:var(--warn-soft);color:var(--warn)}
.pill{display:inline-block;font-size:12px;border-radius:99px;padding:0 8px;background:var(--line-2);color:var(--brand)}
.pill.off{color:var(--bad);background:var(--bad-soft)}
.key{display:flex;gap:10px;align-items:flex-start;padding:10px 0;border-top:1px solid var(--line-2)}
.key:first-of-type{border-top:0}
.key .t{flex:1;min-width:0}.key .n{font-weight:600}.key .s{font-size:13px;color:var(--muted)}
details summary{cursor:pointer;color:var(--ink-2);font-size:14px;padding:6px 0}
.choice{display:flex;justify-content:space-between;align-items:center;gap:10px;padding:8px 0;border-top:1px solid var(--line-2)}
.sheet{position:fixed;left:0;right:0;bottom:0;background:var(--panel);border-top:1px solid var(--line);box-shadow:0 -8px 24px rgba(0,0,0,.18);padding:16px 16px calc(16px + env(safe-area-inset-bottom));border-radius:14px 14px 0 0}
.sheet .in{max-width:520px;margin:0 auto}
.sheet .two{display:flex;gap:10px;margin-top:12px}.sheet .two>*{flex:1}
code{font:13px ui-monospace,Menlo,monospace}
.foot{font-size:13px;color:var(--muted);margin-top:16px}
</style></head><body><main>
<nav><a class="logo" href="/"><span class="mark"><svg viewBox="0 0 24 24"><path d="M4 17l4-10 4 10M12 17l4-10 4 10M3 20h18"/></svg></span>claudefleet</a></nav>
<h1>从手机连 fleet</h1>
<p class="hint">贴上一把钥匙，在 Termius 里填四样，就进你的会话。不用装别的 App。</p>
{{if .OK}}<p class="msg ok" role="status">{{.OK}}</p>{{end}}
{{if and .Err (or (eq .ErrFor "revoke") (eq .ErrFor ""))}}<p class="msg err" role="alert">{{.Err}}</p>{{end}}
{{if .NoPerson}}
<div class="card"><p>这一页给每个人管自己的钥匙。请用你自己的 GitHub 登录打开它（管理员的口令不代表任何人）。</p>
<a class="btn wide" href="/signin">用 GitHub 登录</a></div>
{{else if .NeedName}}
<div class="card" id="name"><h2>先给你的地址起个名字</h2>
<p class="hint">小写字母、数字和「-」，3–20 个。以后可以改，旧名字还能用 7 天。</p>
<form method="post" action="/fleet/keys"><input type="hidden" name="do" value="name">
<input id="nm" name="name" value="{{.NameVal}}" autocapitalize="off" autocorrect="off" spellcheck="false" autocomplete="off" maxlength="20" style="margin-top:10px" aria-label="地址名">
<p class="hint" style="margin-top:6px">你的地址会是 <b><span id="nmv">{{if .NameVal}}{{.NameVal}}{{else}}…{{end}}</span>.{{if .Domain}}{{.Domain}}{{else}}（地址还没配好）{{end}}</b></p>
<p class="hint" id="nmw" style="color:var(--bad)"></p>
{{if eq .ErrFor "name"}}<p class="msg err">{{.Err}}</p>{{end}}
<button class="go wide" type="submit">就用这个</button></form></div>
{{else}}
<div class="card" id="termius"><h2>在 Termius 里新建一台主机，填这四样</h2>
<div class="row"><span class="k">地址</span>{{if .Address}}<span class="v">{{.Address}}</span><button class="cp" type="button" data-cp="{{.Address}}">复制</button>{{else}}<span class="v miss">地址还没配好</span>{{end}}</div>
<div class="row"><span class="k">端口</span><span class="v">{{.Port}}</span><button class="cp" type="button" data-cp="{{.Port}}">复制</button></div>
<div class="row"><span class="k">用户名</span>{{if .Home}}<span class="v">{{.Home.Login}}</span><button class="cp" type="button" data-cp="{{.Home.Login}}">复制</button>{{else}}<span class="v miss">还没有家</span>{{end}}</div>
<div class="row"><span class="k">钥匙</span><span class="v plain">选你在下面加的那把</span></div>
{{if not .Address}}<p class="msg warn">地址还没配好：入口还没设地址用的域名。钥匙照样可以先加上，配好后这里就写出来。</p>{{end}}
{{if not .Home}}<p class="msg warn">你还没有家：家是你有登录、上面有在用的 fleet 的那台机器。先在一台机器上把 fleet 开起来，这里就会写出来。</p>
{{else if .HomeDown}}<p class="msg err">家机器 <b>{{.Home.Display}}</b> {{.HomeDown}}连不上，你的地址也就连不上。它回来就好；要换一台当家，点下面。</p>
<a class="btn wide" href="#home">换一台当家…</a>
{{else}}<p class="hint" style="margin-top:8px">现在指向你的家机器 <b>{{.Home.Display}}</b> <span class="pill">在线</span></p>{{end}}
<details style="margin-top:6px"{{if eq .ErrFor "name"}} open{{end}}><summary>改地址名</summary>
<form method="post" action="/fleet/keys"><input type="hidden" name="do" value="name">
<input name="name" value="{{.NameVal}}" autocapitalize="off" autocorrect="off" spellcheck="false" autocomplete="off" maxlength="20" aria-label="地址名">
<p class="hint" style="margin-top:6px">旧名字还能用 7 天。</p>
{{if eq .ErrFor "name"}}<p class="msg err">{{.Err}}</p>{{end}}
<button class="wide" type="submit">改成这个</button></form></details>
</div>
{{if .Keys}}<div class="card" id="keys"><h2>你的钥匙（{{len .Keys}}）</h2>
{{range .Keys}}<div class="key"><div class="t"><div class="n">{{if .Name}}{{.Name}}{{else}}（没起名）{{end}}</div>
<div class="s">{{.Type}} · <code>{{.FP}}</code> · 加于 {{.Added}}</div><div class="s">上次用：{{.LastUsed}}</div></div>
<a class="btn bad cp" href="?revoke={{.ID}}#confirm">撤掉</a></div>{{end}}
</div>{{end}}
<div class="card" id="add"><h2>加一把钥匙</h2>
<form method="post" action="/fleet/keys"><input type="hidden" name="do" value="add">
<textarea name="key" rows="3" autocapitalize="off" autocorrect="off" spellcheck="false" placeholder="在 Termius：钥匙 → 点一把 → 复制公钥（以 ssh-ed25519 开头的一行），贴到这里" aria-label="公钥">{{.Pasted}}</textarea>
<input class="lbl" name="label" value="{{.Label}}" maxlength="40" placeholder="给它起个名（如：iPhone）" aria-label="钥匙的名字">
{{if eq .ErrFor "add"}}<p class="msg err">{{.Err}}</p>{{end}}
<button class="go wide" type="submit">加上</button></form>
<p class="hint" style="margin-top:8px">手机上的钥匙和电脑上的一样，是你登录的普通钥匙。加上后几秒内你的家机器就认它。</p></div>
{{if .Home}}<div class="card" id="home"><details{{if or .HomeDown (eq .ErrFor "home")}} open{{end}}><summary>换一台当家</summary>
<p class="hint">只列你有登录、上面有你在用的 fleet 的机器。换过去后你的地址几分钟内指向它；手机第一次连会说主机钥匙变了，接受一次。</p>
{{range .Others}}<div class="choice"><span><b>{{.Display}}</b> · {{.Login}} {{if .Online}}<span class="pill">在线</span>{{else}}<span class="pill off">连不上</span>{{end}}</span>
<a class="btn cp" href="?move={{.Machine}}&amp;login={{.Login}}#confirm">换到这台</a></div>{{else}}<p class="hint" style="margin-top:8px">现在没有别的机器可换。</p>{{end}}
{{if eq .ErrFor "home"}}<p class="msg err">{{.Err}}</p>{{end}}
</details></div>{{end}}
{{end}}
<p class="foot">入口不在时，已加的钥匙照常能进；只是那时加钥匙、撤钥匙和换家要等它回来。</p>
</main>
{{if .Revoke}}<div class="sheet" id="confirm" role="dialog" aria-modal="true"><div class="in">
<p><b>撤掉「{{if .Revoke.Name}}{{.Revoke.Name}}{{else}}{{.Revoke.FP}}{{end}}」？</b></p>
<p class="hint" style="margin-top:6px">几秒内家机器不再认它；正用它连着的入口连接也会断开（会话本身不受影响）。</p>
<form method="post" action="/fleet/keys" class="two"><input type="hidden" name="do" value="revoke"><input type="hidden" name="id" value="{{.Revoke.ID}}">
<a class="btn" href="/fleet/keys">算了</a><button class="bad" type="submit">撤掉</button></form></div></div>{{end}}
{{if .Move}}<div class="sheet" id="confirm" role="dialog" aria-modal="true"><div class="in">
<p><b>把家换到 {{.Move.Display}} · {{.Move.Login}}？</b></p>
<p class="hint" style="margin-top:6px">{{if ne .Move.Port $.Port}}你的地址几分钟内指向它；Termius 里改一样：端口改成 <b>{{.Move.Port}}</b>（原来 {{$.Port}}）。{{else}}你的地址几分钟内指向它，Termius 里的四样都不用改；{{end}}手机第一次连会说主机钥匙变了，接受一次。</p>
<form method="post" action="/fleet/keys" class="two"><input type="hidden" name="do" value="home"><input type="hidden" name="machine" value="{{.Move.Machine}}"><input type="hidden" name="login" value="{{.Move.Login}}">
<a class="btn" href="/fleet/keys">算了</a><button class="go" type="submit">换过去</button></form></div></div>{{end}}
<script>
(function(){
document.querySelectorAll('[data-cp]').forEach(function(b){b.addEventListener('click',function(){
var v=b.getAttribute('data-cp'),done=function(){var o=b.textContent;b.textContent='已复制';setTimeout(function(){b.textContent=o},1500)};
if(navigator.clipboard&&navigator.clipboard.writeText){navigator.clipboard.writeText(v).then(done,function(){})}});});
var nm=document.getElementById('nm');if(!nm)return;
var out=document.getElementById('nmv'),warn=document.getElementById('nmw'),re=/^[a-z0-9][a-z0-9-]{1,18}[a-z0-9]$/,held=['ssh','www','hub','admin','api','fleet','root'];
nm.addEventListener('input',function(){var v=nm.value.toLowerCase().replace(/[^a-z0-9-]/g,'');if(v!==nm.value)nm.value=v;out.textContent=v||'…';
warn.textContent=!v?'':(held.indexOf(v)>=0?'「'+v+'」留作他用，换一个':(re.test(v)?'':'3–20 个小写字母、数字或「-」，不以「-」开头或结尾'));});
})();
</script>
</body></html>`))
