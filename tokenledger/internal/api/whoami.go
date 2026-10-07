package api

import (
	"context"
	"errors"
	"html/template"
	"net/http"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/authz"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// Who is behind a request, for the page header (claude-fleet#1467).
//
// Every human page on this hub — the dashboard, 连接, 我的会话, 机器节点,
// 凭据发放 — carries the same header: the signed-in person and a way out.
// web/dist/whoami.js draws it on every page from ONE answer, /v1/me: the
// door the gate let this request through, and the person when the door names
// one. "Who am I" is a fact the gate records as it admits the request, never
// something a page infers from which of its fetches happened to succeed.
//
// The shape follows OPS (24haowan-monorepo core/ops): the name top-right with
// how they got in under it, a popover with 姓名 / 企微账号, and 退出 as a plain
// same-origin form POST to /logout that clears this site's own cookie.

// The doors, as viewerOnly records them.
const (
	doorOpen    = "open"    // --no-auth: no viewer token at all
	doorToken   = "token"   // the viewer token, as a bearer or its cookie
	doorWeCom   = "wecom"   // a session this hub minted from a ticket (/enter)
	doorTailnet = "tailnet" // a named tailnet peer, on the local tailscaled's word
	doorGitHub  = "github"  // a GitHub sign-in on the list (claude-fleet#1984)
)

// viewerCookie is where viewerOnly parks the viewer token once a browser
// has presented it as ?token= (30 days). Hub-minted, like the session cookie,
// and cleared with it by /logout.
const viewerCookie = "ccquota_token"

type doorKey struct{}
type sessionKey struct{}

func withDoor(ctx context.Context, door string) context.Context {
	return context.WithValue(ctx, doorKey{}, door)
}

func doorOf(ctx context.Context) string {
	d, _ := ctx.Value(doorKey{}).(string)
	return d
}

func withSession(ctx context.Context, sess *authz.Session) context.Context {
	return context.WithValue(ctx, sessionKey{}, sess)
}

func sessionOf(ctx context.Context) *authz.Session {
	s, _ := ctx.Value(sessionKey{}).(*authz.Session)
	return s
}

// Me is the body of /v1/me.
type Me struct {
	// Via is the door: open | token | wecom | tailnet | github.
	Via string `json:"via"`
	// Role is roleOf: admin | user | operator (claude-fleet#1984).
	Role string `json:"role,omitempty"`
	// Person is the WeCom userid behind a wecom session — or the role subject
	// when the ticket named no person (authz.Session.Principal).
	Person string `json:"person,omitempty"`
	// Name is the person's directory name: the ticket's `nam`; else what the
	// hub has on record for them (an earlier ticket, the operator's adopt);
	// else empty, and the header shows the userid.
	Name string `json:"name,omitempty"`
	// Login is the tailnet login a tailnet door admitted — or, for a GitHub
	// or WeCom person, the machine login the hub knows as theirs: the os_user
	// a user's rows are cut to (claude-fleet#1985). Empty when none is set.
	Login string `json:"login,omitempty"`
	// Pages is what the menu shows this role (claude-fleet#1985): a user's
	// overview, sessions, devices, config; an admin's every page.
	Pages []string `json:"pages"`
	// CanLogout says a cookie THIS hub minted is behind the request, so
	// POST /logout has something to clear. A bearer header has none.
	CanLogout bool `json:"can_logout"`
}

// handleMe answers who the gate admitted. Mounted unconditionally, inside
// viewerOnly: the header is on the dashboard of a hub without the fleet
// module too, so this cannot live under /v1/fleet/.
func (s *Server) handleMe(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", "GET")
		httpError(w, http.StatusMethodNotAllowed, "GET only")
		return
	}
	out := Me{Via: doorOf(r.Context()), Role: roleOf(r.Context())}
	out.Pages = pagesFor(out.Role)
	if pid := principalOf(r.Context()); pid != "" {
		login, err := s.machineLoginOf(pid)
		if err != nil {
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
		out.Login = login
	}
	switch out.Via {
	case doorGitHub:
		// The person is gh:<id>; the name is their GitHub username.
		sess := sessionOf(r.Context())
		out.Person, out.Name, out.CanLogout = sess.Principal(), sess.Name, true
	case doorWeCom:
		sess := sessionOf(r.Context())
		out.Person, out.Name, out.CanLogout = sess.Principal(), sess.Name, true
		if out.Name == "" && s.Fleet && s.Store != nil {
			// The ticket named no one by name (the issuer sends `nam` only
			// beside `uid`, and not every issuer does yet). The hub may still
			// know: a row the operator adopted carries a display name.
			p, err := s.Store.Principal(out.Person)
			if err != nil && !errors.Is(err, store.ErrNoPrincipal) {
				httpError(w, http.StatusInternalServerError, err.Error())
				return
			}
			if p != nil {
				out.Name = p.DisplayName
			}
		}
	case doorToken:
		_, err := r.Cookie(viewerCookie)
		out.CanLogout = err == nil
	case doorTailnet:
		out.Login = viewerOf(r.Context())
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, out)
}

// handleLogout is the way out.
//
// POST clears every cookie this hub minted — the WeCom session, the parked
// viewer token, a pending `fleet login` code — and sends the browser to the
// signed-out page. It is mounted OUTSIDE viewerOnly on purpose: a browser
// whose session has already expired must still be able to drop it, and the
// gate would otherwise bounce a signed-out browser straight back to WeCom.
// Same-origin only: SameSite=Lax already keeps the cookies off a cross-site
// POST, and the Origin check is the second lock, so no page elsewhere can
// sign someone out.
//
// This hub's OWN cookies, and nothing beyond them — the same line OPS draws
// (core/ops `POST /logout` clears `__Host-ops_sess` and nothing else). The
// authorization service has no logout endpoint, and its 8-hour cookie on
// ai.24haowan.com is not this host's to clear; while it lives, 重新登录 signs
// a fresh ticket without a WeCom prompt. That is the platform's convention.
//
// GET is the signed-out page. Neither method takes a destination — no `rd`,
// `next` or `return` — so there is no open redirect: the one link out is the
// gate, composed from this hub's own config, or "/" when SSO is not wired up.
func (s *Server) handleLogout(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodPost:
		if !sameOrigin(r) {
			httpError(w, http.StatusForbidden, "cross-origin form")
			return
		}
		for _, name := range []string{authz.CookieName, viewerCookie, loginCookie} {
			http.SetCookie(w, &http.Cookie{
				Name: name, Value: "", Path: "/", MaxAge: -1,
				HttpOnly: true, SameSite: http.SameSiteLaxMode, Secure: isHTTPS(r),
			})
		}
		w.Header().Set("Cache-Control", "no-store")
		http.Redirect(w, r, "/logout", http.StatusSeeOther)
	case http.MethodGet:
		page := logoutPage{Again: "/"}
		if s.GitHub.ready() {
			page.Again, page.GitHub = "/signin", true
		} else if u, ok := s.ssoGateURL(); ok {
			page.Again, page.SSO = u, true
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("X-Frame-Options", "DENY")
		_ = logoutTmpl.Execute(w, page)
	default:
		w.Header().Set("Allow", "GET, POST")
		httpError(w, http.StatusMethodNotAllowed, "GET or POST")
	}
}

type logoutPage struct {
	// Again is where 重新登录 goes: the gate, or "/" without SSO.
	Again  string
	SSO    bool
	GitHub bool
}

var logoutTmpl = template.Must(template.New("logout").Parse(`<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<title>已退出登录</title>
<link rel="icon" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16'%3E%3Crect width='16' height='16' rx='4' fill='%232a78d6'/%3E%3Crect x='3' y='7' width='10' height='3' rx='1.5' fill='%23fff'/%3E%3C/svg%3E">
<style>
:root{--bg:#f9f9f7;--fg:#0b0b0b;--mut:#85847e;--card:#fcfcfb;--line:#e3e2dd;--btn:#2a78d6}
@media (prefers-color-scheme:dark){:root{--bg:#0d0d0d;--fg:#fff;--mut:#8b8a81;--card:#1a1a19;--line:#2f2f2c;--btn:#3987e5}}
body{background:var(--bg);color:var(--fg);font:15px/1.6 ui-sans-serif,-apple-system,"PingFang SC",system-ui,sans-serif;margin:0;padding:48px 16px}
main{max-width:420px;margin:0 auto;background:var(--card);border:1px solid var(--line);border-radius:12px;padding:24px}
h1{font-size:20px;margin:0 0 10px}
p{margin:0 0 10px}.mut{color:var(--mut);font-size:13px}
.btn{display:inline-block;margin-top:14px;padding:9px 18px;border-radius:8px;background:var(--btn);color:#fff;text-decoration:none;font-weight:600}
</style></head><body><main>
<h1>已退出登录</h1>
<p>这个入口自己的登录状态已经清除。</p>
{{if .GitHub}}<p class="mut">GitHub 那边的登录仍然有效：点「重新登录」用同一个 GitHub 账号再进来。</p>
{{else if .SSO}}<p class="mut">企业微信那边的登录仍然有效：点「重新登录」会直接签一张新票进来，一般不用再扫码。</p>
{{else}}<p class="mut">这台入口没有接企业微信登录；带上查看令牌重新打开即可。</p>{{end}}
<a class="btn" href="{{.Again}}">重新登录</a>
</main></body></html>`))
