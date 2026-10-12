package api

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"html/template"
	"net/http"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/i18n"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// The ways in (claude-fleet#3604, EPIC #3570 C11): WeChat, a mail, GitHub —
// in that order, always (store.IdentityKinds). Each is offered only when it
// is configured; with neither WeChat nor mail, /signin is byte for byte the
// GitHub page it was (signinTmpl), and every session is signed as it was.

// signinOn reports whether any way in is configured: a person can sign in.
func (s *Server) signinOn() bool {
	return s.GitHub.ready() || s.WeChat.ready() || s.Email.ready()
}

// sessionKey signs the people's sessions and every short signed blob of a
// sign-in. With GitHub on it is GitHub's (derived from its client secret,
// exactly as before — rotating that secret still signs everyone out); a hub
// without GitHub derives it from CCQUOTA_SESSION_SECRET, else from the first
// other way's own secret. The label keeps it from ever being a secret itself.
func (s *Server) sessionKey() string {
	if s.GitHub.ready() {
		return s.GitHub.sessionKey()
	}
	src := s.SessionSecret
	if src == "" && s.WeChat != nil {
		src = orDefault(s.WeChat.WebSecret, s.WeChat.MPSecret)
	}
	if src == "" && s.Email != nil {
		src = s.Email.SMTPURL
	}
	m := hmac.New(sha256.New, []byte(src))
	m.Write([]byte("ccquota session v1"))
	return base64.RawURLEncoding.EncodeToString(m.Sum(nil))
}

// sessionTTL is how long a session cookie lives: GitHub's setting when it is
// on, else a week. The list is re-read on every request either way.
func (s *Server) sessionTTL() time.Duration {
	if s.GitHub != nil {
		return s.GitHub.ttl()
	}
	return 7 * 24 * time.Hour
}

// otherWaysOn: WeChat or a mail is offered, so /signin is the page with
// several ways rather than GitHub's own.
func (s *Server) otherWaysOn() bool { return s.WeChat.ready() || s.Email.ready() }

// inviteCookiePath is where the invite a browser carries rides: to every way
// in once there is more than GitHub's, else to GitHub's callback only, as it
// did.
func (s *Server) inviteCookiePath() string {
	if s.otherWaysOn() {
		return "/auth/"
	}
	return githubFlowPath
}

// inWeChat: the request comes from WeChat's own browser, which signs in by
// the service account's authorisation instead of a scan.
func inWeChat(r *http.Request) bool {
	return strings.Contains(r.UserAgent(), "MicroMessenger")
}

// signinWaysPage is /signin with more than GitHub on it.
type signinWaysPage struct {
	pageView
	Note string
	// WeChat is offered; InWeChat words its button for WeChat's own browser.
	WeChat, InWeChat bool
	// Email is offered; Code is the second step: type the six digits.
	Email, Code bool
	GitHub      bool
}

// renderSigninWays draws /signin with every way that is on, in the one order.
func (s *Server) renderSigninWays(w http.ResponseWriter, r *http.Request, loc, note string) {
	page := signinWaysPage{pageView: newPageView(r, loc), Note: note,
		WeChat: s.WeChat.ready() && (s.WeChat.webReady() || inWeChat(r)), InWeChat: inWeChat(r) && s.WeChat.mpReady(),
		Email: s.Email.ready(), GitHub: s.GitHub.ready()}
	page.Code = page.Email && r.URL.Query().Get("step") == "code"
	writeAuthPage(w, http.StatusOK, signinWaysTmpl, loc, page)
}

// signinWayNotes are what /signin?e= may say beyond GitHub's three: a fixed
// set, so the page never reflects a query string.
var signinWayNotes = map[string]bool{
	"wechat": true, "wechat-cancelled": true, "wechat-app": true, "wechat-taken": true,
	"email-expired": true, "email-device": true, "email-wrong": true, "email-void": true, "email-slow": true,
	"email-bad": true,
}

const wechatIcon = `<svg viewBox="0 0 24 24"><path d="M9 4C5.1 4 2 6.6 2 9.8c0 1.8 1 3.4 2.6 4.5L4 16.5l2.6-1.3c.8.2 1.6.4 2.4.4M15.5 9C12.5 9 10 11 10 13.6s2.5 4.6 5.5 4.6c.6 0 1.2-.1 1.8-.3l2.2 1.1-.5-1.9c1.2-.9 2-2.1 2-3.5C21 11 18.5 9 15.5 9z"/></svg>`
const mailIcon = `<svg viewBox="0 0 24 24"><rect x="3" y="5" width="18" height="14" rx="2"/><path d="M3 7l9 6 9-6"/></svg>`

const signinWaysCSS = `<style>
.btn.wx{background:#07c160;border-color:#07c160;color:#fff}
.ways{display:grid;gap:12px}
.ways form{display:grid;gap:8px}
.ways input{font:15px var(--f-ui);padding:10px 12px;border:1px solid var(--line);border-radius:9px;background:var(--panel);color:var(--ink);width:100%}
.ways input.code{font:600 22px ui-monospace,Menlo,monospace;letter-spacing:.35em;text-align:center}
.or{display:flex;align-items:center;gap:10px;color:var(--muted);font-size:12.5px}.or:before,.or:after{content:"";flex:1;border-top:1px solid var(--line)}
</style>`

var signinWaysTmpl = template.Must(template.New("signin-ways").Funcs(pageFuncs(i18n.EN)).Parse(authPageHead + signinWaysCSS + `
<title>{{t "signin.title"}}</title></head><body><div class="pub">` + authNav + `
<div class="center"><main class="card">
<div class="big"><svg viewBox="0 0 24 24"><path d="M4 17l4-10 4 10M12 17l4-10 4 10M3 20h18"/></svg></div>
<div style="display:grid;gap:6px"><h1>{{t "signin.h1"}}</h1><p class="lead">{{if .Code}}{{t "signin.code.lead"}}{{else}}{{t "signin.ways.lead"}}{{end}}</p></div>
{{if .Note}}<p class="note" role="status">{{.Note}}</p>{{end}}
<div class="ways">
{{if .Code}}<form method="post" action="/auth/email/code">
<input class="code" name="code" inputmode="numeric" autocomplete="one-time-code" pattern="[0-9]{6}" maxlength="6" required autofocus aria-label="{{t "signin.code.label"}}">
<button class="btn lg" type="submit">{{t "signin.code.button"}}</button></form>
<a class="alt" href="/app/signin">{{t "signin.code.again"}}</a>
{{else}}{{if .WeChat}}<a class="btn wx lg" href="/auth/wechat/start">` + wechatIcon + `{{if .InWeChat}}{{t "signin.wechat.in"}}{{else}}{{t "signin.wechat"}}{{end}}</a>{{end}}
{{if .Email}}{{if .WeChat}}<div class="or">{{t "signin.or"}}</div>{{end}}<form method="post" action="/auth/email/start">
<input type="email" name="email" autocomplete="email" required placeholder="{{t "signin.email.placeholder"}}" aria-label="{{t "signin.email.placeholder"}}">
<button class="btn lg" type="submit">` + mailIcon + `{{t "signin.email.button"}}</button></form>{{end}}
{{if .GitHub}}{{if or .WeChat .Email}}<div class="or">{{t "signin.or"}}</div>{{end}}<a class="btn gh lg" href="/auth/github/start">` + gitIcon + `{{t "signin.button"}}</a>{{end}}
{{end}}</div>
<p class="fine">{{t "signin.ways.fine"}}</p>
</main></div></div></body></html>`))

// signinWaysText is the words the page with several ways adds; merged into
// pageText at start.
var signinWaysText = map[string]i18n.Text{
	"signin.ways.lead": {
		i18n.EN:   "This hub is private. Sign in the way an admin let you in — WeChat, your email, or GitHub.",
		i18n.ZhCN: "这个入口是私有的。用管理员给你开的方式登录：微信、邮箱或 GitHub。",
	},
	"signin.ways.fine": {
		i18n.EN:   "claudefleet learns only who you are — never your chats, contacts or repositories.",
		i18n.ZhCN: "claudefleet 只知道你是谁，拿不到你的聊天、通讯录和仓库。",
	},
	"signin.wechat":    {i18n.EN: "Scan with WeChat", i18n.ZhCN: "微信扫码登录"},
	"signin.wechat.in": {i18n.EN: "Continue with WeChat", i18n.ZhCN: "用微信继续"},
	"signin.or":        {i18n.EN: "or", i18n.ZhCN: "或"},
	"signin.email.placeholder": {
		i18n.EN: "Your email", i18n.ZhCN: "你的邮箱",
	},
	"signin.email.button": {i18n.EN: "Email me a sign-in link", i18n.ZhCN: "发登录邮件"},
	"signin.code.lead": {
		i18n.EN:   "If that address can sign in here, a mail is on its way: open its link in this browser, or type its six digits here. It lasts 15 minutes. Not there? Look in spam.",
		i18n.ZhCN: "如果这个邮箱能登录本入口，信已经发出：在这个浏览器里点信里的链接，或在这里输入信里的 6 位数字。15 分钟内有效。没收到？看看垃圾箱。",
	},
	"signin.code.label":  {i18n.EN: "The six digits from the mail", i18n.ZhCN: "邮件里的 6 位数字"},
	"signin.code.button": {i18n.EN: "Sign in", i18n.ZhCN: "登录"},
	"signin.code.again":  {i18n.EN: "Use another address, or another way", i18n.ZhCN: "换个邮箱，或换种方式"},
	"signin.note.wechat": {
		i18n.EN:   "WeChat couldn't be reached to finish signing you in. Try again in a minute.",
		i18n.ZhCN: "连不上微信，没能完成登录。过一分钟再试。",
	},
	"signin.note.wechat-cancelled": {
		i18n.EN:   "WeChat didn't sign you in. Try again when you're ready.",
		i18n.ZhCN: "微信没有让你登录。准备好了再试一次。",
	},
	"signin.note.wechat-app": {
		i18n.EN:   "Scanning on a computer isn't open on this hub yet. Open this page inside WeChat, or use your email.",
		i18n.ZhCN: "本入口暂时还不能在电脑上扫码。请在微信里打开这个页面，或者用邮箱登录。",
	},
	"signin.note.wechat-taken": {
		i18n.EN:   "That WeChat already signs another person in here. Nothing was changed.",
		i18n.ZhCN: "这个微信已经挂在另一个人的账号上了，什么都没改。",
	},
	"signin.note.email-expired": {
		i18n.EN:   "That sign-in mail was already used, or is older than 15 minutes. Send another — the old one stops working.",
		i18n.ZhCN: "这封登录邮件已经用过，或超过了 15 分钟。再发一封就好，旧的作废。",
	},
	"signin.note.email-device": {
		i18n.EN:   "That link only works in the browser you asked for it from. There, type the mail's six digits instead.",
		i18n.ZhCN: "这个链接只能在发起登录的那个浏览器里打开。请在那个浏览器里输入邮件里的 6 位数字。",
	},
	"signin.note.email-wrong": {
		i18n.EN:   "Those digits don't match. Look at the newest mail again.",
		i18n.ZhCN: "数字不对，再看一眼最新的那封邮件。",
	},
	"signin.note.email-void": {
		i18n.EN:   "Too many wrong tries — that mail no longer works. Send another.",
		i18n.ZhCN: "错了太多次，这封邮件已作废。再发一封吧。",
	},
	"signin.note.email-slow": {
		i18n.EN:   "A mail was sent to that address a moment ago. Wait a minute before asking for another.",
		i18n.ZhCN: "刚给这个邮箱发过信。等一分钟再要下一封。",
	},
	"signin.note.email-bad": {
		i18n.EN:   "That doesn't look like an email address.",
		i18n.ZhCN: "这看起来不是一个邮箱地址。",
	},
}

func init() {
	for k, v := range signinWaysText {
		pageText[k] = v
	}
}

// identityWord names a way in for a person to read.
func identityWord(loc, kind string) string {
	switch kind {
	case store.IdentityWeChat:
		return pageT(loc, "way.wechat")
	case store.IdentityEmail:
		return pageT(loc, "way.email")
	}
	return "GitHub"
}

func init() {
	pageText["way.wechat"] = i18n.Text{i18n.EN: "WeChat", i18n.ZhCN: "微信"}
	pageText["way.email"] = i18n.Text{i18n.EN: "email", i18n.ZhCN: "邮箱"}
}
