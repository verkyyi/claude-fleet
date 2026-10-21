package api

import (
	"bytes"
	"context"
	"fmt"
	"io/fs"
	"net/http"
	"net/url"
	"path"
	"regexp"
	"strings"
	"time"
)

// The console lives under /app; the root is the public site (claude-fleet#3583,
// EPIC #3569 C13).
//
// One prefix, one table: AppPrefix is the only place the console's address is
// spelled, and appPagePaths / appPagePrefixes are its pages — the web pages a
// person signs in to see, plus the sign-in and sign-out pages. The router
// keeps mounting each page at its old path (roles.go's routeAccess names it
// there, unchanged); appMount, in front of the router, is what moves them:
//
//   - /app and /app/<page> serve <page>, with X-Robots-Tag: noindex — a
//     console page is never a search result;
//   - an old page path (GET / HEAD) answers 301 to /app/<page>, so every
//     bookmark still opens; any other method still reaches it as before;
//   - "/" is the public site for someone signed out (CCQUOTA_SITE=on, our
//     own hub) and 302 /app for someone signed in — with the site off (the
//     default, a self-hoster's hub) "/" is always 302 /app;
//   - everything else — /v1, /install, /connect's client half (/v1/fleet/connect),
//     /fleet/login*, /mcp, the app's own files — passes
//     through untouched (TestClientPathsUnchanged).

// AppPrefix is where the console is mounted.
const AppPrefix = "/app"

// appPagePaths are the console's pages, by their path under AppPrefix ("/" is
// /app itself, the overview).
var appPagePaths = map[string]bool{
	"/": true, "/usage": true, "/quota": true, "/sessions": true, TasksPagePath: true,
	"/machines": true, "/connect": true, "/config": true, "/nodes": true,
	"/subscriptions": true, "/subscriptions/settings": true,
	"/admin/users": true, "/admin/settings": true, "/admin/audit": true,
	"/admin/sessions": true, "/admin/overview": true, "/admin/devices": true, trainsPagePath: true,
	"/signin": true, "/logout": true,
	// the new console's own pages, with no old page behind them (EPIC #3923)
	mePagePath: true, devicesPagePath: true, settingsPagePath: true, "/terminal": true,
}

// appPagePrefixes are the console's pages that carry one name under them
// (/machines/<host>, /subscriptions/<id>, /admin/users/<principal>).
var appPagePrefixes = []string{"/machines/", "/subscriptions/", "/admin/users/"}

// isAppPage says whether p (a path under AppPrefix, or an old one) is a
// console page.
func isAppPage(p string) bool {
	if appPagePaths[p] {
		return true
	}
	for _, pre := range appPagePrefixes {
		if strings.HasPrefix(p, pre) {
			return true
		}
	}
	return false
}

// The console (claude-fleet#3925, EPIC #3923): a member's side under
// AppPrefix and an admin's under AdminPrefix. consolePages is the ONE table
// of where every old page went: its old address (GET / HEAD) answers 301 to
// the new one, query kept, in one hop — kept for good, so no bookmark
// breaks. The old pages themselves were taken down (claude-fleet#3939): any
// other method at an old address is the 404 an unknown address gets.
//
// The admin side is guarded whole (EPIC #3923 rule 6): to anyone who is not
// an admin, AdminPrefix and everything under it, every admin page's old
// address and the bare ones before /app, answer exactly what an address that
// does not exist answers — a 404, one role_denied audit row — never a
// redirect, which would itself say the page is there.

// mePagePath is 我的 (C3): the person, their devices and settings, sign-out
// and — for an admin — the way to the admin side. A page of the new console
// only: no old page answers at it.
const mePagePath = "/me"

// devicesPagePath is 设备 (C7): the computer's install, the phone's way in,
// the keys and the person's own machines, one tab each (?tab=pc|phone|keys|home).
// It takes over 设备与 SSH, 从手机连, 我的连接 and 我的机器.
const devicesPagePath = "/devices"

// settingsPagePath is 设置 (C8, claude-fleet#3931): the person's name and ways
// of signing in, their own configuration (export / import), light or dark and
// the language, sign-out. It took over /app/config; the sign-in flows that
// hang a new way on a person come back here (settingsBack).
const settingsPagePath = "/settings"

// settingsBack is where adding a way of signing in returns to: 设置's 登录方式
// card, with ?e=<why> when it did not go through.
func settingsBack(e string) string {
	if e != "" {
		return AppPrefix + settingsPagePath + "?e=" + e + "#logins"
	}
	return AppPrefix + settingsPagePath + "#logins"
}

// AdminPrefix is where the admin side of the new console is mounted.
const AdminPrefix = "/admin"

// The sides of the console.
const (
	sideMe    = "me"    // 我的: every signed-in person's
	sideAdmin = "admin" // 管理: an admin's
)

// consolePage is one old page and where it went. old and new are paths;
// under = old is everything below it, its rest carried over into a new that
// ends in "/". new may carry a query, merged ahead of the request's. forUser
// is where a member goes from an admin-side row that also shows a member
// their own (one machine); empty = a member gets the 404. owner is the EPIC
// member that moved it.
type consolePage struct {
	old, new string
	side     string
	owner    string
	under    bool
	forUser  string
}

// consolePages is every page the console moves (EPIC #3923 «逐页去向»).
var consolePages = []consolePage{
	// 我的 — the conversation is its front page, 我的 its own (C3)
	{old: AppPrefix, new: AppPrefix, side: sideMe, owner: "C3"},
	{old: ChatPagePath, new: AppPrefix, side: sideMe, owner: "C3"},
	{old: "/chat", new: AppPrefix, side: sideMe, owner: "C16"},
	{old: AppPrefix + mePagePath, new: AppPrefix + mePagePath, side: sideMe, owner: "C3"},
	{old: AppPrefix + "/sessions", new: AppPrefix + "/sessions", side: sideMe, owner: "C4"},
	{old: "/term", new: AppPrefix + "/terminal", side: sideMe, owner: "term-C2"},
	{old: AppPrefix + "/terminal", new: AppPrefix + "/terminal", side: sideMe, owner: "term-C2"},
	// 任务 (C5) is one list with 会话 since T769: its address, a code's ?q=
	// carried along, opens that row there. Its tickets tab and pages left with
	// the hub's tickets (claude-fleet#4898).
	{old: AppPrefix + TasksPagePath, new: AppPrefix + "/sessions", side: sideMe, owner: "T769"},
	{old: AppPrefix + "/usage", new: AppPrefix + "/usage", side: sideMe, owner: "C6"},
	// 我的额度 is folded into 我的用量 already; the page only moved on in
	// the browser, a second hop.
	{old: AppPrefix + "/quota", new: AppPrefix + "/usage", side: sideMe, owner: "C2"},
	{old: AppPrefix + devicesPagePath, new: AppPrefix + devicesPagePath, side: sideMe, owner: "C7"},
	{old: AppPrefix + "/connect", new: AppPrefix + devicesPagePath, side: sideMe, owner: "C7"},
	{old: EntryPagePath, new: AppPrefix + devicesPagePath + "?tab=phone", side: sideMe, owner: "C7"},
	// the keys page's pictures and the paths a person typed for it (claude-fleet#3199)
	{old: EntryPagePath + "/", new: AppPrefix + devicesPagePath + "?tab=phone", side: sideMe, owner: "C16", under: true},
	{old: "/fleet/key", new: AppPrefix + devicesPagePath + "?tab=phone", side: sideMe, owner: "C16"},
	{old: "/keys", new: AppPrefix + devicesPagePath + "?tab=phone", side: sideMe, owner: "C16"},
	{old: EntryConnPath, new: AppPrefix + devicesPagePath + "?tab=home", side: sideMe, owner: "C7"},
	{old: AppPrefix + "/machines", new: AppPrefix + devicesPagePath + "?tab=home", side: sideMe, owner: "C7"},
	{old: AppPrefix + "/config", new: AppPrefix + settingsPagePath, side: sideMe, owner: "C8"},
	// 管理
	// a member's branch is C7's (设备 · 我的机器); an admin's is C11's
	{old: AppPrefix + "/machines/", new: AdminPrefix + "/machines/", side: sideAdmin, owner: "C11", forUser: AppPrefix + devicesPagePath + "?tab=home", under: true},
	{old: AppPrefix + "/admin/users", new: AdminPrefix + "/people", side: sideAdmin, owner: "C10"},
	{old: AppPrefix + "/admin/users/", new: AdminPrefix + "/people/", side: sideAdmin, owner: "C10", under: true},
	{old: AppPrefix + "/nodes", new: AdminPrefix + "/machines", side: sideAdmin, owner: "C11"},
	// All devices is the machines page's 客户端 tab: one hop to the end.
	{old: AppPrefix + "/admin/devices", new: AppPrefix + "/nodes?tab=clients", side: sideAdmin, owner: "C2"},
	{old: AppPrefix + "/subscriptions", new: AdminPrefix + "/pool", side: sideAdmin, owner: "C12"},
	{old: AppPrefix + "/subscriptions/", new: AdminPrefix + "/pool/", side: sideAdmin, owner: "C12", under: true},
	{old: AppPrefix + "/subscriptions/settings", new: AdminPrefix + "/pool/settings", side: sideAdmin, owner: "C12"},
	{old: AppPrefix + "/admin/overview", new: AdminPrefix + "/usage", side: sideAdmin, owner: "C13"},
	{old: AppPrefix + "/admin/sessions", new: AdminPrefix + "/usage?tab=sessions", side: sideAdmin, owner: "C13"},
	{old: AppPrefix + trainsPagePath, new: AdminPrefix + "/release", side: sideAdmin, owner: "C14"},
	{old: AppPrefix + "/admin/settings", new: AdminPrefix + "/settings", side: sideAdmin, owner: "C15"},
	{old: AppPrefix + "/admin/audit", new: AdminPrefix + "/audit", side: sideAdmin, owner: "C15"},
}

// consoleRow is the row for path p: an exact old first, else the longest
// old prefix.
func consoleRow(p string) (consolePage, bool) {
	var best consolePage
	found := false
	for _, c := range consolePages {
		if c.old == p {
			return c, true
		}
		if c.under && strings.HasPrefix(p, c.old) && len(c.old) > len(best.old) {
			best, found = c, true
		}
	}
	return best, found
}

// isAdminPath says whether p is the admin side's: AdminPrefix and below, an
// admin row's old address, or the bare address before /app of one.
func isAdminPath(p string) bool {
	if p == AdminPrefix || strings.HasPrefix(p, AdminPrefix+"/") {
		return true
	}
	c, ok := consoleRow(p)
	if !ok && isAppPage(p) {
		c, ok = consoleRow(appURL(p))
	}
	// a row that also shows a member their own is not the admin side's
	return ok && c.side == sideAdmin && c.forUser == ""
}

// joinQuery is to with the request's query q after the query to already
// carries — a key q names itself is q's (?tab=a on a row that says
// ?tab=clients keeps tab=a), q kept byte for byte.
func joinQuery(to, q string) string {
	if q == "" {
		return to
	}
	pth, tq, _ := strings.Cut(to, "?")
	if tq == "" {
		return pth + "?" + q
	}
	have, _ := url.ParseQuery(q)
	var keep []string
	for _, kv := range strings.Split(tq, "&") {
		k, _, _ := strings.Cut(kv, "=")
		if k, err := url.QueryUnescape(k); err == nil && have.Has(k) {
			continue
		}
		keep = append(keep, kv)
	}
	return pth + "?" + strings.Join(append(keep, q), "&")
}

// consoleTarget is where path p (query q) ends up through the table for
// role: every row followed to its end, so an old address is one hop from its
// final page. ok=false when no row moves it.
func consoleTarget(p, q, role string) (string, bool) {
	to, moved := joinQuery(p, q), false
	for i := 0; i <= len(consolePages); i++ {
		pth, query, _ := strings.Cut(to, "?")
		c, ok := consoleRow(pth)
		member := role == roleUser && c.forUser != ""
		if !ok {
			break
		}
		dest := c.new
		if member {
			dest = c.forUser
		}
		if c.under && c.old != pth {
			// carry the rest over, into a destination that takes one
			if rest := strings.TrimPrefix(pth, c.old); strings.HasSuffix(dest, "/") {
				dest += rest
			}
		}
		next := joinQuery(dest, query)
		if next == to {
			break
		}
		to, moved = next, true
	}
	return to, moved
}

// consoleRedirect is where r should be sent through the table — its old
// address in the table, or a bare one before /app (one hop to the end, not
// two). ok=false: no redirect, serve r where it is.
func consoleRedirect(r *http.Request) (to string, ok bool) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		return "", false
	}
	if r.URL.Query().Has("token") {
		return "", false // the gate moves a ?token= link into its cookie first
	}
	p, role := r.URL.Path, roleOf(r.Context())
	if !strings.HasPrefix(p, AppPrefix+"/") && p != AppPrefix && isAppPage(p) {
		// a bookmark from before /app (claude-fleet#3583)
		to, _ := consoleTarget(appURL(p), r.URL.RawQuery, role)
		return to, true
	}
	return consoleTarget(p, r.URL.RawQuery, role)
}

// moveOn sends r on through the table (consoleRedirect), else to serve. A
// row that sends a member somewhere else than an admin asks the gate who r
// is first.
func (s *Server) moveOn(w http.ResponseWriter, r *http.Request, serve http.HandlerFunc) {
	move := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if to, ok := consoleRedirect(r); ok {
			http.Redirect(w, r, to, http.StatusMovedPermanently)
			return
		}
		serve(w, r)
	})
	if r.URL.Query().Has("token") {
		// the gate moves a ?token= link into its cookie first, then the
		// address moves on (consoleRedirect)
		s.viewerOnly(move).ServeHTTP(w, r)
		return
	}
	if r.Method == http.MethodGet || r.Method == http.MethodHead {
		p := r.URL.Path
		if p != AppPrefix && !strings.HasPrefix(p, AppPrefix+"/") && isAppPage(p) {
			p = appURL(p)
		}
		if c, ok := consoleRow(p); ok && c.forUser != "" {
			s.viewerOnly(move).ServeHTTP(w, r)
			return
		}
	}
	move.ServeHTTP(w, r)
}

// adminGate answers a request on the admin side: to anyone who is not an
// admin the 404 an unknown address gets (audited), else next. Mounted
// behind viewerOnly, so a stranger is asked to sign in first, as for any
// page, whatever the address — and a request page asked for signed out is
// where the sign-in comes back to (rememberAdminReturn).
func (s *Server) adminGate(next http.Handler) http.Handler {
	return s.viewerOr(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if memberRole(roleOf(r.Context())) {
			s.denyAdminPage(w, r)
			return
		}
		next.ServeHTTP(w, r)
	}), rememberAdminReturn)
}

// adminSide is the router's AdminPrefix and below: past the admin gate, the
// new console's admin entry.
func (s *Server) adminSide() http.Handler {
	return s.adminGate(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		s.serveConsole(w, r, "admin", strings.TrimPrefix(r.URL.Path, AdminPrefix))
	}))
}

// consoleNewLive says whether p is a new page of the table (so a bare old
// address of the same spelling, /admin/settings, is the new page).
func consoleNewLive(p string) bool {
	for _, c := range consolePages {
		np, _, _ := strings.Cut(c.new, "?")
		if np == p || (strings.HasSuffix(np, "/") && strings.HasPrefix(p, np)) {
			return true
		}
	}
	return false
}

// consoleBuilt says this hub carries a build of the console's side; without
// one its pages are a 404.
func (s *Server) consoleBuilt(side string) bool {
	if s.ConsoleFS == nil {
		return false
	}
	_, err := fs.Stat(s.ConsoleFS, side+"/index.html")
	return err == nil
}

// appSide is the member side's page: signed-in people only, its language
// settled first (the cf_lang cookie the page reads), then the side's
// index.html.
func (s *Server) appSide() http.Handler {
	return s.withPageLang(s.viewerOnly(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		s.serveConsole(w, r, "app", strings.TrimPrefix(r.URL.Path, AppPrefix))
	})))
}

// AppManifestPath is the console's web app manifest (claude-fleet#3943): what
// 「添加到主屏幕」 reads — name, icon, start_url /app, full screen. ONE manifest
// for the whole hub (/term links the same). Served to anyone: a browser
// fetches a manifest without its cookies, and it names nothing of anyone's.
const AppManifestPath = AppPrefix + "/manifest.webmanifest"

// serveAppManifest serves the member side's build of the manifest
// (vite.config.ts writes it beside index.html); 404 with no build.
func (s *Server) serveAppManifest(w http.ResponseWriter, r *http.Request) {
	if s.ConsoleFS == nil || (r.Method != http.MethodGet && r.Method != http.MethodHead) {
		http.NotFound(w, r)
		return
	}
	b, err := fs.ReadFile(s.ConsoleFS, "app/manifest.webmanifest")
	if err != nil {
		http.NotFound(w, r)
		return
	}
	h := w.Header()
	h.Set("Content-Type", "application/manifest+json")
	h.Set("Cache-Control", "no-cache")
	h.Set("X-Content-Type-Options", "nosniff")
	http.ServeContent(w, r, "manifest.webmanifest", time.Time{}, bytes.NewReader(b))
}

// consoleCSP is the console's policy: every byte its own — same origin only,
// no CDN, no font or script from anywhere else (EPIC #3923 rule 4). The one
// thing it may frame is a page the person's agent published (task T773 ④):
// ChatFrameOrigins (CCQUOTA_FLEET_CHAT_FRAME_ORIGINS), none by default.
const consoleCSP = chatCSP

// consolePolicy is consoleCSP with the origins a chat card may frame.
func (s *Server) consolePolicy() string {
	if len(s.ChatFrameOrigins) == 0 {
		return consoleCSP
	}
	return consoleCSP + "; frame-src " + strings.Join(s.ChatFrameOrigins, " ")
}

// chatFrameOrigin is the shape an origin a card may frame takes: https, a host
// (a leading *. allowed), an optional port — nothing a policy could be bent with.
var chatFrameOrigin = regexp.MustCompile(`^https://(?:\*\.)?[a-z0-9-]+(?:\.[a-z0-9-]+)+(?::[0-9]{1,5})?$`)

// ParseChatFrameOrigins reads CCQUOTA_FLEET_CHAT_FRAME_ORIGINS: comma-separated
// origins; one that is not an https origin refuses the whole value.
func ParseChatFrameOrigins(v string) ([]string, error) {
	var out []string
	for _, o := range strings.Split(v, ",") {
		o = strings.TrimSpace(o)
		if o == "" {
			continue
		}
		if !chatFrameOrigin.MatchString(o) {
			return nil, fmt.Errorf("not an https origin: %q", o)
		}
		out = append(out, o)
	}
	return out, nil
}

// serveConsole serves the new console's side ("app" or "admin"): a file
// under assets/ as it is, any other path the side's index.html (its router
// draws the page). 404 while this hub carries no build of that side.
func (s *Server) serveConsole(w http.ResponseWriter, r *http.Request, side, rest string) {
	if s.ConsoleFS == nil || (r.Method != http.MethodGet && r.Method != http.MethodHead) {
		http.NotFound(w, r)
		return
	}
	name := side + "/index.html"
	if strings.HasPrefix(rest, "/assets/") {
		name = side + rest
	}
	b, err := fs.ReadFile(s.ConsoleFS, name)
	if err != nil {
		http.NotFound(w, r)
		return
	}
	if strings.HasSuffix(name, "/index.html") {
		h := w.Header()
		h.Set("Cache-Control", "no-store")
		h.Set("Content-Security-Policy", s.consolePolicy())
		h.Set("X-Frame-Options", "DENY")
		h.Set("Referrer-Policy", "no-referrer")
		h.Set("X-Content-Type-Options", "nosniff")
	} else {
		w.Header().Set("Cache-Control", "public, max-age=31536000, immutable")
		b = consoleAsset(w, r, name, b)
	}
	http.ServeContent(w, r, path.Base(name), time.Time{}, bytes.NewReader(b))
}

type appMountedKey struct{}

// appMounted says whether r came in under AppPrefix.
func appMounted(r *http.Request) bool {
	v, _ := r.Context().Value(appMountedKey{}).(bool)
	return v
}

// appPath is p as the browser should see it: under AppPrefix when r came in
// there ("/" is AppPrefix itself).
func appPath(r *http.Request, p string) string {
	if !appMounted(r) {
		return p
	}
	if p == "/" {
		return AppPrefix
	}
	return AppPrefix + p
}

// appURL is a console page's address: AppPrefix + p ("/" is AppPrefix).
func appURL(p string) string {
	if p == "" || p == "/" {
		return AppPrefix
	}
	return AppPrefix + p
}

// withQuery is to + r's query string, when it has one.
func withQuery(to string, r *http.Request) string {
	if r.URL.RawQuery != "" {
		return to + "?" + r.URL.RawQuery
	}
	return to
}

// appMount moves the console under AppPrefix in front of next (see above).
func (s *Server) appMount(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		p := r.URL.Path
		if (strings.HasPrefix(p, "/v1/") || p == "/mcp") && s.trialOutside(r) {
			// A trial person's API is the chat and their trial; the rest is an
			// unknown address (claude-fleet#4058).
			http.NotFound(w, r)
			return
		}
		switch {
		case strings.HasPrefix(p, themePrefix):
			// the theme the way-in pages wear (claude-fleet#3932)
			s.serveTheme(w, r, strings.TrimPrefix(p, themePrefix))
		case p == signinPollScriptPath && s.wxScanOn():
			// the sign-in page's one script (claude-fleet#4054)
			w.Header().Set("X-Robots-Tag", "noindex, nofollow")
			serveSigninPollScript(w, r)
		case p == AppManifestPath:
			// 添加到主屏幕 (claude-fleet#3943)
			w.Header().Set("X-Robots-Tag", "noindex, nofollow")
			s.serveAppManifest(w, r)
		case strings.HasPrefix(p, AppPrefix+"/assets/"):
			// the new console's member side (claude-fleet#3925)
			w.Header().Set("X-Robots-Tag", "noindex, nofollow")
			s.serveConsole(w, r, "app", strings.TrimPrefix(p, AppPrefix))
		case (p == AdminPrefix || strings.HasPrefix(p, AdminPrefix+"/")) && (!isAppPage(p) || consoleNewLive(p)):
			// the admin side (adminSide, mounted in the router); a new page
			// spelled like a bare old one (/admin/settings) is the router's
			// old route, so it is answered here
			w.Header().Set("X-Robots-Tag", "noindex, nofollow")
			if isAppPage(p) {
				s.adminSide().ServeHTTP(w, r)
				return
			}
			next.ServeHTTP(w, r)
		case isAdminPath(p) && (r.Method == http.MethodGet || r.Method == http.MethodHead):
			// an admin page's old address: an admin moves on; anyone else,
			// the 404
			if strings.HasPrefix(p, AppPrefix+"/") {
				w.Header().Set("X-Robots-Tag", "noindex, nofollow")
			}
			s.adminGate(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if to, ok := consoleRedirect(r); ok {
					http.Redirect(w, r, to, http.StatusMovedPermanently)
					return
				}
				http.NotFound(w, r)
			})).ServeHTTP(w, r)
		case (p == TryPagePath || p == tryScriptPath) && s.trialOn():
			// the 60-second trial (claude-fleet#3590): open to anyone
			w.Header().Set("X-Robots-Tag", "noindex, nofollow")
			if p == tryScriptPath {
				serveTryScript(w, r)
				return
			}
			s.serveTryPage(w, r)
		case p == AppPrefix || strings.HasPrefix(p, AppPrefix+"/"):
			w.Header().Set("X-Robots-Tag", "noindex, nofollow")
			s.moveOn(w, r, func(w http.ResponseWriter, r *http.Request) {
				if consoleNewLive(strings.TrimSuffix(p, "/")) && s.consoleBuilt("app") {
					// a page the new console has taken over (claude-fleet#3926)
					s.appSide().ServeHTTP(w, r)
					return
				}
				s.serveAppPage(w, r, next)
			})
		case p == "/":
			s.serveRoot(w, r)
		case s.serveSitePath(w, r):
			// the site's other paths: /en/, /site/, icons, /docs/ (site_serve.go)
		default:
			// an old page outside /app, or a bare one from before it, moves on
			s.moveOn(w, r, next.ServeHTTP)
		}
	})
}

// serveAppPage serves a console page under AppPrefix: the page at its old
// path, marked as having come in under /app.
func (s *Server) serveAppPage(w http.ResponseWriter, r *http.Request, next http.Handler) {
	inner := strings.TrimPrefix(r.URL.Path, AppPrefix)
	if inner == "" || inner == "/" {
		inner = "/"
	}
	if inner == "/try" {
		// A trial link with fleet.trial off: 试用暂未开放, apply
		// (claude-fleet#4269; it used to open the console). On, appMount
		// serves the try page (claude-fleet#3590).
		s.serveTryClosed(w, r)
		return
	}
	if !isAppPage(inner) {
		s.notFoundPage(w, r)
		return
	}
	r2 := r.WithContext(context.WithValue(r.Context(), appMountedKey{}, true))
	u := *r.URL
	u.Path, u.RawPath = inner, ""
	r2.URL = &u
	next.ServeHTTP(w, r2)
}

// serveRoot answers "/": the public site for someone signed out while the
// site is on, else the console. The gate decides who is signed in — a
// ?token= link is moved into its cookie on the way, as on every page, so the
// token never rides on into /app's address. Signed in, the built site is
// shown too (its nav then says 进入控制台 · 退出 — claude-fleet#3798), so the
// front page is never a door that only leads in.
func (s *Server) serveRoot(w http.ResponseWriter, r *http.Request) {
	toApp := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if s.siteServed() && s.serveSite(w, r) {
			return
		}
		http.Redirect(w, r, withQuery(AppPrefix, r), http.StatusFound)
	})
	signedOut := s.serveSite
	if !s.Site {
		signedOut = func(w http.ResponseWriter, r *http.Request) bool { toApp(w, r); return true }
	}
	s.withPageLang(s.viewerOr(toApp, signedOut)).ServeHTTP(w, r)
}

// siteServed: the site is on and this hub carries its built front page.
func (s *Server) siteServed() bool {
	if !s.Site || s.SiteFS == nil {
		return false
	}
	_, err := fs.Stat(s.SiteFS, "index.html")
	return err == nil
}

// serveSite is the public site's front page: SiteFS's index.html (中文; the
// English one is /en/, site_serve.go) when the hub carries the built site
// (web/site, C14); without one, false — the old landing page went with the
// old console (claude-fleet#3939). Cacheable: it holds nothing of anyone's.
func (s *Server) serveSite(w http.ResponseWriter, r *http.Request) bool {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		return false
	}
	if s.SiteFS != nil {
		if _, err := fs.Stat(s.SiteFS, "index.html"); err == nil {
			w.Header().Add("Vary", "Cookie")
			return s.sitePage(w, r, "index.html", "zh-CN")
		}
	}
	return false
}
