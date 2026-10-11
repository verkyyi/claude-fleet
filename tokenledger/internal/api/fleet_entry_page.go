package api

import (
	"embed"
	"errors"
	"fmt"
	"html/template"
	"net/http"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"time"

	"golang.org/x/crypto/ssh"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
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

// EntryConnPath is 我的连接 (claude-fleet#3199): the same book as a settings
// page — the home every device shares, the address, the keys — for every role.
const EntryConnPath = "/fleet/connection"

// entryReturnCookie remembers, across the GitHub sign-in, that the browser
// was on its way to the keys page (loginReturn reads it).
const entryReturnCookie = "ccquota_return"

// entryOK are the sentences a redirect back may carry (?ok=<key>).
var entryOK = map[string]string{
	"name":    "地址名定好了。",
	"added":   "已加上。家机器正在为你打开入口，约 1 分钟。",
	"same":    "这把钥匙已经在你的列表里了。",
	"revoked": "已撤掉。几秒内家机器不再认它，并断开正用它连着的入口连接。",
	"home":    "已换家。你的地址几分钟内指向它；端口以下面写的为准（变了就在 Termius 里改一次）；手机第一次连会说主机钥匙变了，接受一次。",
	"enabled": "直连入口打开了。",
}

// The wizard (claude-fleet#3199): six steps, one shown at a time, each one
// thing to do in Termius on an iPhone. Which step is open comes from the book
// (no key yet → 1; a key never used → 4; a key used → all done) unless
// ?step=N names one; the steps before it fold up with a tick.
// entryOpenGrace is how long after a new key (or home) the page says
// 「正在打开」 before it says what is in the way (a var for tests).
var entryOpenGrace = 10 * time.Minute

const (
	entryStepCount = 6
	// entryAppStore is Termius on the App Store.
	entryAppStore = "https://apps.apple.com/app/termius-terminal-ssh-client/id549039908"
)

var entryStepTitles = [entryStepCount]string{"装 Termius", "在 Termius 里生成钥匙", "复制公钥，贴到这一页", "在 Termius 里新建主机", "连接，信任主机钥匙", "进到看台，打开会话列表"}

//go:embed entryshots
var entryShots embed.FS

type entryStep struct {
	N          int
	Title      string
	Done, Open bool
	Shot       string // the picture's URL, "" when there is none
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
	Off      bool // fleet.entry is off
	CanOn    bool // … and the caller may switch it on (an admin)
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
	HomeWhy  string // why this machine is the home
	HomeDown string // when the home is not reachable: since when, or ""
	Keys     []entryKeyRow
	Others   []entryChoiceRow // homes to move to
	Pasted   string           // the add form's text after a refusal (never a private key)
	Label    string
	Revoke   *entryKeyRow
	Move     *entryChoiceRow

	Conn     bool   // 我的连接 (EntryConnPath), not the wizard
	Self     string // the path the page is on: its forms post back there
	ConnPath string

	Steps   []entryStep
	Step    int  // the open step, 0 = all done
	Used    bool // a key of theirs has come in through the door
	AppURL  string
	State   string // nokey | opening | ok | down | far | nohome
	Why     string // State far: where it is stuck
	Refresh bool   // State opening: the page reloads itself
}

// handleEntryPage serves EntryPagePath.
func (s *Server) handleEntryPage(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead && r.Method != http.MethodPost {
		w.Header().Set("Allow", "GET, POST")
		httpError(w, http.StatusMethodNotAllowed, "GET or POST")
		return
	}
	page := entryPageData{pageView: newPageView(r, i18n.ZhCN), Port: entryPort, AppURL: entryAppStore,
		Conn: r.URL.Path == EntryConnPath, Self: EntryPagePath, ConnPath: EntryConnPath}
	if page.Conn {
		page.Self = EntryConnPath
	}
	if !s.entryOn() {
		s.entryPageOff(w, r, page)
		return
	}
	// The page is always the caller's own book: drop ?principal=.
	own := r.Clone(r.Context())
	own.URL = &url.URL{Path: r.URL.Path}
	c, code, _ := s.entryCallerFor(own)
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
			http.Redirect(w, r, page.Self+"?ok="+ok, http.StatusSeeOther)
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

// entryPageOff is the page while fleet.entry is off: said plainly, and an
// admin opens it with one press (claude-fleet#3199) — never a bare 404.
func (s *Server) entryPageOff(w http.ResponseWriter, r *http.Request, page entryPageData) {
	id, signed := s.sshRelayHTTPIdentity(r)
	if !signed {
		httpError(w, http.StatusUnauthorized, "sign in first")
		return
	}
	page.Off, page.CanOn = true, id.Admin
	if r.Method == http.MethodPost {
		if !sameOrigin(r) {
			httpError(w, http.StatusForbidden, "cross-origin form")
			return
		}
		if !id.Admin {
			httpError(w, http.StatusForbidden, "only an admin switches the direct door on")
			return
		}
		if r.PostFormValue("do") != "enable" {
			httpError(w, http.StatusBadRequest, "看不懂这个表单")
			return
		}
		if code, why := s.putHubSetting(id.Actor, EntryKey, "on", time.Now()); code != http.StatusOK {
			httpError(w, code, why)
			return
		}
		http.Redirect(w, r, page.Self+"?ok=enabled", http.StatusSeeOther)
		return
	}
	s.writeEntryPage(w, http.StatusOK, page)
}

// handleEntryPageAside serves what sits beside the keys page: its pictures
// (/fleet/keys/img/<step>.png) and the paths a person types for it —
// /fleet/key, /fleet/keys/, /keys — sent on to it.
func (s *Server) handleEntryPageAside(w http.ResponseWriter, r *http.Request) {
	if name, ok := strings.CutPrefix(r.URL.Path, EntryPagePath+"/img/"); ok {
		b, ctype := entryShot(name)
		if b == nil {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", ctype)
		w.Header().Set("Cache-Control", "public, max-age=86400")
		_, _ = w.Write(b)
		return
	}
	to := EntryPagePath
	if r.URL.RawQuery != "" {
		to += "?" + r.URL.RawQuery
	}
	http.Redirect(w, r, to, http.StatusMovedPermanently)
}

// entryShotRE is the only names a picture may have: step<N>.<png|jpg>.
var entryShotRE = regexp.MustCompile(`^step[1-6]\.(png|jpg)$`)

// entryShot is one step's picture and its type; nil when there is none.
func entryShot(name string) ([]byte, string) {
	if !entryShotRE.MatchString(name) {
		return nil, ""
	}
	b, err := entryShots.ReadFile("entryshots/" + name)
	if err != nil {
		return nil, ""
	}
	if strings.HasSuffix(name, ".jpg") {
		return b, "image/jpeg"
	}
	return b, "image/png"
}

// entryShotURL is step n's picture's URL, "" when it has none.
func entryShotURL(n int) string {
	for _, ext := range []string{"png", "jpg"} {
		name := fmt.Sprintf("step%d.%s", n, ext)
		if b, _ := entryShot(name); b != nil {
			return EntryPagePath + "/img/" + name
		}
	}
	return ""
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
	var changed time.Time // the newest key, or the home's move: what the door must catch up with
	for _, k := range v.Keys {
		page.Keys = append(page.Keys, entryKeyRow{ID: k.ID, Name: k.Name, Type: entryKeyType(k.Type), FP: entryShortFP(k.FP),
			Added: entryWhen(k.Created, now), LastUsed: entryLastUsed(k.LastUsed, now)})
		if k.LastUsed != nil {
			page.Used = true
		}
		if k.Created.After(changed) {
			changed = k.Created
		}
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
		// port the router forwards (EPIC #3067 改约定 3, the entry= route): Termius's port is
		// the home's, not a constant.
		page.Port = page.Home.Port
		page.HomeWhy = "你自己选的。"
		if v.Home.SetBy == "auto" {
			page.HomeWhy = "系统替你选的：你在这台上有登录、上面开着 fleet"
			if len(v.HomeChoices) > 1 {
				page.HomeWhy += "，也是你平时打 fleet 进的那台"
			}
			page.HomeWhy += "。"
		}
		if v.Home.SetAt.After(changed) {
			changed = v.Home.SetAt
		}
	}
	if page.Home != nil && !page.Home.Online {
		page.HomeDown = "现在"
		if t := s.entryLastBeat(page.Home.Machine); t != nil {
			page.HomeDown = entryWhen(*t, now) + "起"
		}
	}
	page.State, page.Why = s.entryDoorState(page, changed, now)
	page.Refresh = page.State == "opening"
	s.entrySteps(r, page)
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

// entryDoorState is how the door stands for this person, said as a state
// rather than a failed check (claude-fleet#3199): no key yet (nothing to
// open); the home opening it since the last change (changed); the outside
// reaching it; the home itself away; or stuck — and then where.
func (s *Server) entryDoorState(page *entryPageData, changed, now time.Time) (string, string) {
	switch {
	case page.Home == nil:
		return "nohome", ""
	case len(page.Keys) == 0:
		return "nokey", ""
	case page.HomeDown != "":
		return "down", ""
	}
	m := page.Home.Machine
	if reach, err := s.EntryReachable(m, now); err == nil && len(reach) > 0 {
		return "ok", ""
	}
	rows, _ := s.entryReachRows(m)
	var checked time.Time
	for _, r := range rows {
		if r.CheckedAt.After(checked) {
			checked = r.CheckedAt
		}
	}
	last, seen := s.entryLastReport(m)
	// The newest word: a report that said nothing listens, else the dials.
	deaf := seen && !last.Listening && !last.At.Before(checked)
	if seen && last.At.After(checked) {
		checked = last.At
	}
	if now.Sub(changed) < entryOpenGrace && (checked.Before(changed) || deaf) {
		return "opening", ""
	}
	name := page.Home.Display
	switch {
	case !seen && len(rows) == 0:
		return "far", "家机器 " + name + " 还没报告它的入口（每 5 分钟报一次）。一直这样，多半是那台的直连入口没开：请管理员在它上面看 fleet doctor 的 entry 一行。"
	case deaf:
		return "far", "家机器 " + name + " 上的入口没在听：请管理员在它上面看 fleet doctor 的 entry 一行。"
	case len(rows) == 0:
		return "far", "看不到家机器 " + name + " 的公网地址：它在运营商级 NAT 后面，又没有 IPv6。请管理员看那台 fleet doctor 的 public 一行。"
	}
	r := rows[0]
	at := fmt.Sprintf("%s:%d", r.Addr, r.Port)
	if r.Family == "ipv6" {
		at = fmt.Sprintf("[%s]:%d", r.Addr, r.Port)
	}
	switch r.Reason {
	case control.ReachHostKey:
		return "far", "从外面敲 " + at + "，应答的是另一台机器：路由器的端口 " + strconv.Itoa(r.Port) + " 转到了别处，请管理员改成转到 " + name + "。"
	case control.ReachNotSSH:
		return "far", "从外面敲 " + at + "，应答的不是入口：端口 " + strconv.Itoa(r.Port) + " 被别的程序占着，请管理员看一眼。"
	}
	return "far", "从外面敲 " + at + " 没有回应：路由器还没把端口 " + strconv.Itoa(r.Port) + " 转到 " + name + "。请管理员在路由器上开这个端口（或看那台 fleet doctor 的 public 一行）。"
}

// entrySteps lays out the wizard: which step is open, which are done.
func (s *Server) entrySteps(r *http.Request, page *entryPageData) {
	hasKey, used := len(page.Keys) > 0, page.Used
	open := 1
	switch {
	case used:
		open = 0
	case hasKey:
		open = 4
	}
	if q := r.URL.Query().Get("step"); q != "" {
		if n, err := strconv.Atoi(q); err == nil && n >= 1 && n <= entryStepCount {
			open = n
		} else if q == "done" {
			open = 0
		}
	}
	if page.ErrFor == "add" {
		open = 3
	} else if page.ErrFor == "name" {
		open = 4
	}
	page.Step = open
	for i, t := range entryStepTitles {
		n := i + 1
		done := (n <= 3 && hasKey) || used || (open == 0) || n < open
		page.Steps = append(page.Steps, entryStep{N: n, Title: t, Done: done && n != open, Open: n == open, Shot: entryShotURL(n)})
	}
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
		if _, ok := s.sshRelayHTTPIdentity(r); !ok && r.Method == http.MethodGet {
			back := EntryPagePath
			if r.URL.Path == EntryConnPath {
				back = EntryConnPath
			}
			http.SetCookie(w, &http.Cookie{Name: entryReturnCookie, Value: back, Path: "/",
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
	switch c.Value { // the only places it may send anyone
	case EntryPagePath, EntryConnPath:
		return c.Value
	}
	return ""
}

var entryPageTmpl = template.Must(template.Must(template.New("keys").Funcs(template.FuncMap{"stepOf": entryStepOf, "inc": func(n int) int { return n + 1 }, "dec": func(n int) int { return n - 1 }}).Parse(entryStepTmpl)).Parse(`<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="robots" content="noindex, nofollow">
{{if .Refresh}}<meta http-equiv="refresh" content="15">{{end}}
<title>{{if .Conn}}我的连接{{else}}从手机连 fleet{{end}} · claudefleet</title>
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
.row .k{width:5.6em;flex:none;color:var(--muted);font-size:13.5px}
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
.steps{margin:14px 0 0}
.st{display:flex;align-items:center;gap:10px;padding:10px 12px;margin:6px 0;border:1px solid var(--line-2);border-radius:10px;color:var(--muted);text-decoration:none;font-size:14.5px}
a.st{color:var(--ink-2)}
.st .no{width:24px;height:24px;flex:none;border-radius:99px;display:grid;place-items:center;font:600 13px var(--f-ui);background:var(--line-2);color:var(--muted)}
.st.done .no{background:var(--brand);color:var(--brand-ink)}
.st .re{margin-left:auto;font-size:12.5px;color:var(--muted)}
.card.now{border-color:var(--brand)}
.card.now h2{display:flex;gap:10px;align-items:center}
.card.now h2 .no{width:26px;height:26px;flex:none;border-radius:99px;display:grid;place-items:center;font:600 14px var(--f-ui);background:var(--brand);color:var(--brand-ink)}
ol.do{margin:6px 0 0;padding-left:1.3em}ol.do li{margin:6px 0}
.tap{display:inline-block;font:600 13.5px var(--f-ui);padding:0 7px;border-radius:6px;border:1px solid var(--line);background:var(--bg);white-space:nowrap}
.shot{display:block;width:100%;max-width:320px;margin:12px auto 2px;border:1px solid var(--line);border-radius:12px}
.mock{max-width:300px;margin:14px auto 2px;border-radius:18px;padding:7px;background:#0b0c10;box-shadow:0 14px 30px -18px rgba(0,0,0,.6)}
.mock .in{border-radius:12px;overflow:hidden;background:#1a1b26;color:#a9b1d6;font:12px/1.55 ui-monospace,Menlo,monospace;position:relative}
.mock .hd{display:flex;justify-content:space-between;align-items:center;padding:9px 12px;background:#24283b;color:#c0caf5;font:600 13px var(--f-ui)}
.mock .hd span{color:#787c99;font-weight:400}
.mock .li{display:flex;justify-content:space-between;gap:8px;padding:8px 12px;border-top:1px solid #2a2e42;font-family:var(--f-ui);font-size:12.5px}
.mock .li i{font-style:normal;color:#787c99;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.mock .li b{font-weight:500;color:#c0caf5;white-space:nowrap}
.mock .hit{box-shadow:0 0 0 2px #f7768e;border-radius:6px}
.mock .bt{display:inline-block;padding:3px 10px;border-radius:7px;background:#7aa2f7;color:#16161e;font:600 12.5px var(--f-ui)}
.mock .bt.dim{background:#3b4261;color:#c0caf5}
.mock .hd .bt{color:#16161e}
.mock .pad{padding:12px}
.mock .tl{display:flex;gap:6px;padding:3px 9px;background:#1f2335;border-bottom:1px solid #2a2e42;white-space:nowrap;overflow:hidden}
.mock .tl .tt{color:#c0caf5;overflow:hidden;text-overflow:ellipsis}
.mock .tl .sp{flex:1}
.mock .dm{color:#565f89}.mock .hl{color:#7aa2f7}.mock .ok{color:#9ece6a}.mock .ask{color:#f7768e}
.mock .qp{margin:8px;border:1px solid #3b4261;border-radius:8px;background:#16161e;padding:5px 0}
.mock .qp p{padding:0 10px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.mock .qp .lit{background:#283457}
.mock .kb{display:flex;gap:4px;padding:6px;background:#24283b}
.mock .kb span{flex:1;text-align:center;font:500 11px var(--f-ui);color:#c0caf5;background:#3b4261;border-radius:5px;padding:5px 0}
.mock .kb span.hit{background:#7aa2f7;color:#16161e}
.mock .dlg{margin:28px 14px;padding:12px;border-radius:12px;background:#24283b;font-family:var(--f-ui);font-size:12.5px;color:#c0caf5}
.mock .dlg .two{display:flex;justify-content:flex-end;gap:8px;margin-top:10px}
.nav2{display:flex;gap:10px;margin-top:14px}.nav2>*{flex:1}
.state{display:flex;gap:10px;align-items:flex-start;border-radius:10px;padding:10px 12px;margin:10px 0;font-size:14px}
.state.ok{background:var(--line-2);color:var(--brand)}
.state.wait{background:var(--warn-soft);color:var(--warn)}
.state.bad{background:var(--bad-soft);color:var(--bad)}
.state.info{background:var(--line-2);color:var(--ink-2)}
.foot{font-size:13px;color:var(--muted);margin-top:16px}
</style></head><body><main>
<nav><a class="logo" href="/"><span class="mark"><svg viewBox="0 0 24 24"><path d="M4 17l4-10 4 10M12 17l4-10 4 10M3 20h18"/></svg></span>claudefleet</a></nav>
{{if .Conn}}<h1>我的连接</h1>
<p class="hint">你的家机器、你的地址和你的钥匙：每台设备共用这一份。Mac 上的 <code>fleet</code> 和手机都先进家机器。</p>
{{else}}<h1>从手机连 fleet</h1>
<p class="hint">在 iPhone 上用 Termius 直接连进你的会话。一步一步来，每步只做一件事。</p>{{end}}
{{if .OK}}<p class="msg ok" role="status">{{.OK}}</p>{{end}}
{{if and .Err (or (eq .ErrFor "revoke") (eq .ErrFor "") (and (eq .ErrFor "home") (not .Conn)))}}<p class="msg err" role="alert">{{.Err}}</p>{{end}}
{{if .Off}}
<div class="card"><h2>直连入口还没开</h2>
<p>这个入口（hub）还没打开「从手机直连」，所以这一页还加不了钥匙。</p>
{{if .CanOn}}<p class="hint" style="margin-top:6px">你是管理员：点一下就打开（设置 <code>fleet.entry</code>，随时可在「设置」里关掉）。</p>
<form method="post" action="{{$.Self}}"><input type="hidden" name="do" value="enable"><button class="go wide" type="submit">打开直连入口</button></form>
{{else}}<p class="hint" style="margin-top:6px">请管理员打开它（设置里的 <code>fleet.entry</code>），打开后再来这一页。</p>{{end}}</div>
{{else if .NoPerson}}
<div class="card"><p>这一页给每个人管自己的钥匙。请用你自己的 GitHub 登录打开它（管理员的口令不代表任何人）。</p>
<a class="btn wide" href="/signin">用 GitHub 登录</a></div>
{{else if .Conn}}
<div class="card" id="addr"><h2>你的地址</h2>
<div class="row"><span class="k">地址</span>{{if .Address}}<span class="v">{{.Address}}</span><button class="cp" type="button" data-cp="{{.Address}}">复制</button>{{else}}<span class="v miss">{{if .NeedName}}还没起名{{else}}地址还没配好{{end}}</span>{{end}}</div>
<div class="row"><span class="k">端口</span><span class="v">{{.Port}}</span><button class="cp" type="button" data-cp="{{.Port}}">复制</button></div>
<div class="row"><span class="k">用户名</span>{{if .Home}}<span class="v">{{.Home.Login}}</span><button class="cp" type="button" data-cp="{{.Home.Login}}">复制</button>{{else}}<span class="v miss">还没有家</span>{{end}}</div>
{{template "state" .}}
<details style="margin-top:6px"{{if or .NeedName (eq .ErrFor "name")}} open{{end}}><summary>{{if .NeedName}}起地址名{{else}}改地址名（现在：{{.Name}}）{{end}}</summary>
<form method="post" action="{{$.Self}}"><input type="hidden" name="do" value="name">
<input name="name" value="{{.NameVal}}" autocapitalize="off" autocorrect="off" spellcheck="false" autocomplete="off" maxlength="20" aria-label="地址名">
<p class="hint" style="margin-top:6px">小写字母、数字和「-」，3–20 个。{{if not .NeedName}}旧名字还能用 7 天。{{end}}</p>
{{if eq .ErrFor "name"}}<p class="msg err">{{.Err}}</p>{{end}}
<button class="wide" type="submit">{{if .NeedName}}就用这个{{else}}改成这个{{end}}</button></form></details></div>
<div class="card" id="home"><h2>家机器{{if .Home}}：{{.Home.Display}}{{end}}</h2>
{{if .Home}}<p class="hint">手机的地址指向它（登录 <b>{{.Home.Login}}</b>），Mac 上的 <code>fleet</code> 也先进它；它离线时才临时进别的机器，并告诉你进了哪台。{{.HomeWhy}}</p>
<div class="choice"><span><b>{{.Home.Display}}</b> · {{.Home.Login}} {{if .Home.Online}}<span class="pill">在线</span>{{else}}<span class="pill off">连不上</span>{{end}}</span><span class="pill">现在的家</span></div>
{{range .Others}}<div class="choice"><span><b>{{.Display}}</b> · {{.Login}} {{if .Online}}<span class="pill">在线</span>{{else}}<span class="pill off">连不上</span>{{end}}</span>
<a class="btn cp" href="?move={{.Machine}}&amp;login={{.Login}}#confirm">设为家</a></div>{{else}}<p class="hint" style="margin-top:8px">现在没有别的机器可换：只列你有登录、上面开着你的 fleet 的机器。</p>{{end}}
<p class="hint" style="margin-top:8px">换家后地址几分钟内指向新家；两台在同一个路由器后面时端口会变；手机第一次连会说主机钥匙变了，接受一次。</p>
{{if eq .ErrFor "home"}}<p class="msg err">{{.Err}}</p>{{end}}
{{else}}<p class="hint">你还没有家：家是你有登录、上面开着 fleet 的那台机器。先在一台机器上把 fleet 开起来，这里就会写出来。</p>{{end}}</div>
<div class="card" id="keys"><h2>我的设备钥匙（{{len .Keys}}）</h2>
{{range .Keys}}<div class="key"><div class="t"><div class="n">{{if .Name}}{{.Name}}{{else}}（没起名）{{end}}</div>
<div class="s">{{.Type}} · <code>{{.FP}}</code> · 加于 {{.Added}}</div><div class="s">上次用：{{.LastUsed}}</div></div>
<a class="btn bad cp" href="?revoke={{.ID}}#confirm">撤掉</a></div>{{else}}<p class="hint">还没有钥匙。</p>{{end}}
<a class="btn wide" href="/fleet/keys?step={{if .Keys}}3{{else}}1{{end}}#now">{{if .Keys}}再加一把（照「从手机连」第 3 步）{{else}}从手机连：一步步来{{end}}</a></div>
{{else}}
<div class="steps">
{{range .Steps}}{{if .Open}}{{template "step" (stepOf $ .)}}{{else if .Done}}<a class="st done" href="?step={{.N}}"><span class="no">✓</span>{{.Title}}<span class="re">再看</span></a>
{{else}}<a class="st" href="?step={{.N}}"><span class="no">{{.N}}</span>{{.Title}}</a>
{{end}}{{end}}
</div>
{{if eq .Step 0}}<div class="card now" id="done"><h2><span class="no">✓</span>都好了</h2>
<p>以后在 Termius 里点这台主机就进看台。记住一个键：<span class="tap">ctrl</span> 再点 <span class="tap">空格</span> 是会话面板（也可以 ctrl ] 再 p）。</p>
{{template "state" .}}
<div class="row"><span class="k">地址</span>{{if .Address}}<span class="v">{{.Address}}</span>{{else}}<span class="v miss">地址还没配好</span>{{end}}</div>
<div class="row"><span class="k">端口</span><span class="v">{{.Port}}</span></div>
<div class="row"><span class="k">用户名</span>{{if .Home}}<span class="v">{{.Home.Login}}</span>{{else}}<span class="v miss">还没有家</span>{{end}}</div>
</div>{{end}}
{{if .Home}}<div class="card" id="where"><div class="choice" style="border:0;padding:0"><span>家机器：<b>{{.Home.Display}}</b>（登录 {{.Home.Login}}）</span><a class="btn cp" href="{{.ConnPath}}#home">去改</a></div>
<p class="hint" style="margin-top:6px">手机连的就是这台。{{.HomeWhy}}</p></div>{{end}}
<p class="hint" style="text-align:center;margin-top:10px"><a href="{{.ConnPath}}">我的连接：钥匙、地址名、家机器</a></p>
{{end}}
<p class="foot">入口不在时，已加的钥匙照常能进；只是那时加钥匙、撤钥匙和换家要等它回来。</p>
</main>
{{if .Revoke}}<div class="sheet" id="confirm" role="dialog" aria-modal="true"><div class="in">
<p><b>撤掉「{{if .Revoke.Name}}{{.Revoke.Name}}{{else}}{{.Revoke.FP}}{{end}}」？</b></p>
<p class="hint" style="margin-top:6px">几秒内家机器不再认它；正用它连着的入口连接也会断开（会话本身不受影响）。</p>
<form method="post" action="{{$.Self}}" class="two"><input type="hidden" name="do" value="revoke"><input type="hidden" name="id" value="{{.Revoke.ID}}">
<a class="btn" href="{{$.Self}}">算了</a><button class="bad" type="submit">撤掉</button></form></div></div>{{end}}
{{if .Move}}<div class="sheet" id="confirm" role="dialog" aria-modal="true"><div class="in">
<p><b>把家换到 {{.Move.Display}} · {{.Move.Login}}？</b></p>
<p class="hint" style="margin-top:6px">{{if ne .Move.Port $.Port}}你的地址几分钟内指向它；Termius 里改一样：端口改成 <b>{{.Move.Port}}</b>（原来 {{$.Port}}）。{{else}}你的地址几分钟内指向它，Termius 里的四样都不用改；{{end}}手机第一次连会说主机钥匙变了，接受一次。</p>
<form method="post" action="{{$.Self}}" class="two"><input type="hidden" name="do" value="home"><input type="hidden" name="machine" value="{{.Move.Machine}}"><input type="hidden" name="login" value="{{.Move.Login}}">
<a class="btn" href="{{$.Self}}">算了</a><button class="go" type="submit">换过去</button></form></div></div>{{end}}
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

// entryStepView is one open step with the page it sits on.
type entryStepView struct {
	*entryPageData
	P *entryPageData // the page, for templates that take it whole
	S entryStep
}

func entryStepOf(p entryPageData, st entryStep) entryStepView {
	return entryStepView{entryPageData: &p, P: &p, S: st}
}

// entryStepTmpl is the open step: what to tap in Termius, where, by its name
// on the screen; its picture when the repo has one (entryshots/), else a
// drawing of that Termius screen (claude-fleet#3307) — HTML, the same look as
// the front page's mockups, with the place to tap ringed.
const entryStepTmpl = `{{define "mock"}}<div class="mock" role="img" aria-label="Termius 里第 {{.S.N}} 步的样子，要点的地方圈了出来"><div class="in" aria-hidden="true">
{{if eq .S.N 1}}<div class="hd">App Store<span>搜索</span></div>
<div class="li" style="border:0;align-items:center"><span style="display:flex;gap:10px;align-items:center"><span style="width:42px;height:42px;border-radius:10px;background:#000;color:#9ece6a;display:grid;place-items:center;font:600 15px ui-monospace,Menlo,monospace">&gt;_</span><span><b>Termius</b><br><i>SSH 客户端</i></span></span><span class="bt hit">获取</span></div>
<div class="li"><i>免费 · 不用买</i><i>4.7 ★</i></div>
{{else if eq .S.N 2}}<div class="hd">Keychain<span class="hl hit" style="padding:0 6px;font-size:16px">+</span></div>
<div class="li"><b class="hit" style="padding:0 4px">Generate Key</b><i>生成钥匙</i></div>
<div class="li"><i>Label</i><b>iPhone</b></div>
<div class="li"><i>Type</i><b class="hit" style="padding:0 4px">ED25519</b></div>
<div class="li"><i></i><span class="bt">Save</span></div>
{{else if eq .S.N 3}}<div class="hd">‹ Keychain<span>iPhone</span></div>
<div class="li"><i>Type</i><b>ED25519</b></div>
<div class="li"><i>Public key</i><i>ssh-ed25519 AAAAC3Nz…</i></div>
<div class="li"><b class="hit" style="padding:0 4px;color:#7aa2f7">Copy Public Key</b><i></i></div>
<div class="li"><i>私钥留在手机上，不要复制它</i><i></i></div>
{{else if eq .S.N 4}}<div class="hd">New Host<span class="bt hit">Save</span></div>
<div class="li"><i>Hostname</i><b>{{if .Address}}{{.Address}}{{else}}你的地址{{end}}</b></div>
<div class="li"><i>Port</i><b>{{.Port}}</b></div>
<div class="li"><i>Username</i><b>{{if .Home}}{{.Home.Login}}{{else}}你的登录{{end}}</b></div>
<div class="li"><i>Key</i><b>iPhone</b></div>
<div class="li"><i>Password</i><i>不填</i></div>
{{else if eq .S.N 5}}<div class="hd">Hosts<span>+</span></div>
<div class="dlg"><b>New host key</b><p style="margin-top:6px;color:#a9b1d6">第一次连这台主机，要信任它的钥匙吗？</p><p style="margin-top:4px;color:#565f89;font:11px ui-monospace,Menlo,monospace">ED25519 · SHA256:q3Vt…9xKc</p>
<div class="two"><span class="bt dim">Cancel</span><span class="bt hit">Accept</span></div></div>
{{else if eq .S.N 6}}<div class="tl"><span class="ok">»</span><span class="hl">#12</span><span class="tt">每周销售周报</span><span class="sp"></span><span class="dm">62%</span></div>
<div class="qp"><p class="dm">打字筛选</p><p class="hl">⚡ 派一件事…</p><p class="dm">等你 1</p><p><span class="ask">!</span> 修好报名表</p><p class="dm">在干活 2</p><p class="lit"><span class="ok">»</span> 每周销售周报</p><p><span class="ok">»</span> 写本期简报</p></div>
<div class="pad dm" style="padding-top:0">点 ctrl，再点空格</div>
<div class="kb"><span>esc</span><span class="hit">ctrl</span><span>alt</span><span>tab</span><span>↑</span><span>↓</span></div>
{{end}}</div></div>{{end}}
{{define "state"}}{{if eq .State "nokey"}}<p class="state info">加上第一把钥匙后，家机器会打开入口。</p>
{{else if eq .State "opening"}}<p class="state wait" role="status">正在为你打开入口，约 1 分钟。这一页会自己刷新。</p>
{{else if eq .State "ok"}}<p class="state ok">入口开着，外面连得上。</p>
{{else if eq .State "down"}}<p class="state bad">家机器 <b>{{.Home.Display}}</b> {{.HomeDown}}连不上（关机、睡着或断网），你的地址也就连不上。它回来就好；要换一台当家，见页底。</p>
{{else if eq .State "far"}}<p class="state bad">外面还连不上：{{.Why}}</p>
{{else if eq .State "nohome"}}<p class="state wait">你还没有家：家是你有登录、上面开着 fleet 的那台机器。先在一台机器上把 fleet 开起来，这里就会写出来。</p>{{end}}{{end}}
{{define "step"}}<div class="card now" id="now"><h2><span class="no">{{.S.N}}</span>{{.S.Title}}</h2>
{{if eq .S.N 1}}<ol class="do"><li>在 iPhone 上打开 <b>App Store</b>，搜 <b>Termius</b>（图标是黑底的 &gt;_）。</li>
<li>点 <span class="tap">获取</span> 装上。免费版就够，不用买。</li>
<li>打开 Termius。它请你注册或登录时，不用账号也能用：跳过即可。</li></ol>
<a class="btn wide" href="{{.AppURL}}" rel="noopener">去 App Store 装 Termius</a>
{{else if eq .S.N 2}}<p class="hint">钥匙是手机上的一对密钥：私钥一直留在手机里，只有公钥交给我们。</p>
<ol class="do"><li>在 Termius 里打开 <span class="tap">Keychain</span>（钥匙串）。</li>
<li>点右上角的 <span class="tap">+</span>。</li>
<li>选 <span class="tap">Generate Key</span>。</li>
<li><b>Type</b> 选 <span class="tap">ED25519</span>；<b>Label</b> 写 <code>iPhone</code>。</li>
<li>点 <span class="tap">Save</span>。</li></ol>
{{else if eq .S.N 3}}<ol class="do"><li>在 Termius 的 <span class="tap">Keychain</span> 里，点开刚才那把 <code>iPhone</code>。</li>
<li>点 <span class="tap">Copy Public Key</span>（复制公钥：以 <code>ssh-ed25519</code> 开头的一行）。</li>
<li>回到这一页，长按下面的框，点 <span class="tap">粘贴</span>，再点「加上」。</li></ol>
<form method="post" action="{{$.Self}}" style="margin-top:10px"><input type="hidden" name="do" value="add">
<textarea name="key" rows="3" autocapitalize="off" autocorrect="off" spellcheck="false" placeholder="ssh-ed25519 AAAA…（贴公钥，以 ssh-ed25519 开头的一行）" aria-label="公钥">{{.Pasted}}</textarea>
<input class="lbl" name="label" value="{{if .Label}}{{.Label}}{{else}}iPhone{{end}}" maxlength="40" placeholder="给它起个名（如：iPhone）" aria-label="钥匙的名字">
{{if eq .ErrFor "add"}}<p class="msg err">{{.Err}}</p>{{end}}
<button class="go wide" type="submit">加上</button></form>
{{if .Keys}}<p class="hint" style="margin-top:8px">你已经加过 {{len .Keys}} 把；再加一把也行。</p>{{end}}
{{else if eq .S.N 4}}{{if .NeedName}}<p>先给你的地址起个名字，它就是下面的「Hostname」。</p>
<form method="post" action="{{$.Self}}"><input type="hidden" name="do" value="name">
<input id="nm" name="name" value="{{.NameVal}}" autocapitalize="off" autocorrect="off" spellcheck="false" autocomplete="off" maxlength="20" style="margin-top:10px" aria-label="地址名">
<p class="hint" style="margin-top:6px">小写字母、数字和「-」，3–20 个。你的地址会是 <b><span id="nmv">{{if .NameVal}}{{.NameVal}}{{else}}…{{end}}</span>.{{if .Domain}}{{.Domain}}{{else}}（地址还没配好）{{end}}</b></p>
<p class="hint" id="nmw" style="color:var(--bad)"></p>
{{if eq .ErrFor "name"}}<p class="msg err">{{.Err}}</p>{{end}}
<button class="go wide" type="submit">就用这个</button></form>
{{else}}<ol class="do"><li>在 Termius 里打开 <span class="tap">Hosts</span>，点右上角的 <span class="tap">+</span>，选 <span class="tap">New Host</span>。</li>
<li>照抄这四项（每项点「复制」，再到 Termius 里长按粘贴）：</li></ol>
<div class="row"><span class="k">Hostname</span>{{if .Address}}<span class="v">{{.Address}}</span><button class="cp" type="button" data-cp="{{.Address}}">复制</button>{{else}}<span class="v miss">地址还没配好</span>{{end}}</div>
<div class="row"><span class="k">Port</span><span class="v">{{.Port}}</span><button class="cp" type="button" data-cp="{{.Port}}">复制</button></div>
<div class="row"><span class="k">Username</span>{{if .Home}}<span class="v">{{.Home.Login}}</span><button class="cp" type="button" data-cp="{{.Home.Login}}">复制</button>{{else}}<span class="v miss">还没有家</span>{{end}}</div>
<div class="row"><span class="k">Key</span><span class="v plain">点 <span class="tap">Keys</span>，选第 2 步那把 <code>iPhone</code>（不填密码）</span></div>
<ol class="do" start="3"><li>点右上角 <span class="tap">Save</span>。</li></ol>
{{if not .Address}}<p class="msg warn">地址还没配好：这个入口还没设地址用的域名（设置 <code>fleet.entry_domain</code>）。请管理员配好，这里就写出来。</p>{{end}}
{{if .Home}}<p class="hint" style="margin-top:8px">Username 是你在家机器 <b>{{.Home.Display}}</b> 上的登录。</p>{{end}}
{{template "state" .P}}{{end}}
{{else if eq .S.N 5}}<ol class="do"><li>在 Termius 的 <span class="tap">Hosts</span> 里点刚建的那台主机。</li>
<li>第一次会问要不要信任这台主机的钥匙（<i>new host key</i>）：点 <span class="tap">Accept</span>（或 <span class="tap">Continue</span>）。以后不再问；换家后会再问一次。</li></ol>
{{template "state" .P}}
<p class="hint">连不进去？说 <i>Permission denied</i> 是钥匙没选对：回第 4 步看 Key 那一项。说 <i>timed out</i> 看上面那一行。</p>
{{else if eq .S.N 6}}<p>连上后你就在<b>看台</b>：你正在用的那个会话，整屏显示。</p>
<ol class="do"><li>Termius 键盘上方那一排有 <span class="tap">ctrl</span>：点一下它。</li>
<li>再点 <span class="tap">空格</span>：会话面板就出来了——你所有的会话，等你回答的排在前面，点一个就进去。</li></ol>
<p class="hint">空格不灵？也可以 <b>ctrl</b> 再 <b>]</b>，然后 <b>p</b>。ctrl ] 之后还有：<b>n</b> 下一个、<b>b</b> 上一个、<b>c</b> 新会话、<b>q</b> 退出看台。</p>{{end}}
{{if .S.Shot}}<img class="shot" src="{{.S.Shot}}" alt="Termius 里第 {{.S.N}} 步要点的地方" loading="lazy">{{else if not (and (eq .S.N 4) .NeedName)}}{{template "mock" .}}{{end}}
<div class="nav2">{{if gt .S.N 1}}<a class="btn" href="?step={{dec .S.N}}">上一步</a>{{end}}{{if and (eq .S.N 3) (not .Keys)}}{{else if lt .S.N 6}}<a class="btn go" href="?step={{inc .S.N}}#now">下一步</a>{{else}}<a class="btn go" href="?step=done">做完了</a>{{end}}</div>
</div>{{end}}`
