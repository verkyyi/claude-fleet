package api

import (
	"net/http"
	"net/http/httptest"
	"net/url"
	"sort"
	"strings"
	"testing"
	"testing/fstest"
)

// The new console's address table and the admin side's guard
// (claude-fleet#3925, EPIC #3923 C2).

// consoleDo is one request through h's whole handler, no redirect followed.
func consoleDo(h http.Handler, method, path string, sess *http.Cookie) *httptest.ResponseRecorder {
	req := httptest.NewRequest(method, path, nil)
	req.Header.Set("Accept", "text/html")
	if sess != nil {
		req.AddCookie(sess)
	}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec
}

// sameAnswer says how a and b differ: status, every header but Date, body.
// isNotFoundPage says whether body is 「页面不存在」 (entry_pages.go,
// claude-fleet#3932): the 404 every address a member may not see answers.
func isNotFoundPage(body string) bool {
	return strings.Contains(body, `<p class="num">404</p>`) && strings.Contains(body, `href="`+themePrefix+`theme.css"`)
}

func sameAnswer(a, b *httptest.ResponseRecorder) string {
	if a.Code != b.Code {
		return "status"
	}
	if a.Body.String() != b.Body.String() {
		return "body"
	}
	keys := map[string]bool{}
	for k := range a.Header() {
		keys[k] = true
	}
	for k := range b.Header() {
		keys[k] = true
	}
	for k := range keys {
		if k == "Date" {
			continue
		}
		if strings.Join(a.Header().Values(k), "\n") != strings.Join(b.Header().Values(k), "\n") {
			return "header " + k
		}
	}
	return ""
}

// withLive runs f with every row of the table live (all == true) or none.
func withLive(t *testing.T, all bool, f func()) {
	t.Helper()
	saved := consolePages
	rows := append([]consolePage(nil), consolePages...)
	for i := range rows {
		rows[i].live = all
		rows[i].userLive = all && rows[i].forUser != ""
	}
	consolePages = rows
	defer func() { consolePages = saved }()
	f()
}

// adminOlds is every admin page's old address — the twelve the batch counts
// (EPIC #3923: 成员能看出存在的管理页) and the rest under them.
func adminOlds() []string {
	var out []string
	for _, c := range consolePages {
		if c.side != sideAdmin || c.forUser != "" {
			continue
		}
		p := c.old
		if c.under {
			p += "x"
		}
		out = append(out, p)
	}
	return out
}

// A member asking for any admin address — an old one under /app, a bare one
// from before it, anything under /admin — gets exactly what /admin/no-such-page
// gets them: 「页面不存在」, byte for byte, headers and all (Date aside), and
// one role_denied audit row. Never a redirect: one would say the page is there.
func TestAdminIs404ForMember(t *testing.T) {
	h, admin, user := rolesHarness(t)
	h.srv.UI = fstest.MapFS{"index.html": {Data: []byte("APP")}, "admin/users.js": {Data: []byte("ADMIN-SCRIPT")}}
	h.srv.ConsoleFS = fstest.MapFS{
		"admin/index.html":     {Data: []byte("ADMIN-ENTRY")},
		"admin/assets/main.js": {Data: []byte("ADMIN-CODE")},
		"app/index.html":       {Data: []byte("APP-ENTRY")},
		"app/assets/main.js":   {Data: []byte("APP-CODE")},
	}
	hd := h.srv.Handler()
	unknown := consoleDo(hd, http.MethodGet, AdminPrefix+"/no-such-page", user)
	if unknown.Code != http.StatusNotFound || !isNotFoundPage(unknown.Body.String()) {
		t.Fatalf("member GET /admin/no-such-page = %d %.80q; want 「页面不存在」", unknown.Code, unknown.Body.String())
	}
	paths := adminOlds()
	if len(paths) < 12 {
		t.Fatalf("%d admin pages in the table; the batch counts 12", len(paths))
	}
	for _, p := range adminOlds() {
		paths = append(paths, strings.TrimPrefix(p, AppPrefix)) // the bare one
	}
	for _, c := range consolePages {
		if c.side == sideAdmin {
			np, _, _ := strings.Cut(c.new, "?")
			paths = append(paths, np)
		}
	}
	paths = append(paths, AdminPrefix, AdminPrefix+"/", AdminPrefix+"/assets/main.js", AdminPrefix+"/users.js")
	for _, all := range []bool{false, true} {
		withLive(t, all, func() {
			for _, p := range paths {
				for _, q := range []string{"", "?tab=clients"} {
					got := consoleDo(hd, http.MethodGet, p+q, user)
					if d := sameAnswer(got, unknown); d != "" {
						t.Errorf("live=%v member GET %s%s = %d → %q %.60q; differs from /admin/no-such-page in its %s",
							all, p, q, got.Code, got.Header().Get("Location"), got.Body.String(), d)
					}
				}
			}
		})
	}
	var refused int
	if err := h.srv.Store.DB().QueryRow(`SELECT COUNT(*) FROM fleet_audit WHERE action = 'role_denied'
		AND actor LIKE 'gh:200%'`).Scan(&refused); err != nil {
		t.Fatal(err)
	}
	if want := 1 + 4*len(paths); refused < want {
		t.Errorf("%d role_denied rows; want one per refusal (%d)", refused, want)
	}
	// An admin: the new entry and its files, the old pages' scripts as before.
	for p, want := range map[string]string{
		AdminPrefix: "ADMIN-ENTRY", AdminPrefix + "/people": "ADMIN-ENTRY", AdminPrefix + "/no-such-page": "ADMIN-ENTRY",
		AdminPrefix + "/assets/main.js": "ADMIN-CODE", AdminPrefix + "/users.js": "ADMIN-SCRIPT",
	} {
		if got := consoleDo(hd, http.MethodGet, p, admin); got.Code != http.StatusOK || got.Body.String() != want {
			t.Errorf("admin GET %s = %d %.60q; want 200 %s", p, got.Code, got.Body.String(), want)
		}
	}
	// The member side's files are anyone's, like the site's.
	if got := consoleDo(hd, http.MethodGet, AppPrefix+"/assets/main.js", user); got.Code != http.StatusOK || got.Body.String() != "APP-CODE" {
		t.Errorf("member GET /app/assets/main.js = %d %q; want 200 APP-CODE", got.Code, got.Body.String())
	}
	// No build: the admin entry is a 404 for an admin too.
	h.srv.ConsoleFS = nil
	if got := consoleDo(hd, http.MethodGet, AdminPrefix+"/people", admin); got.Code != http.StatusNotFound {
		t.Errorf("no console build: admin GET /admin/people = %d; want 404", got.Code)
	}
	// A stranger is asked to sign in, whatever the address — never a 301.
	for _, p := range []string{AdminPrefix + "/people", AdminPrefix + "/no-such-page", AppPrefix + "/admin/users", "/nodes", "/admin/users"} {
		if got := consoleDo(hd, http.MethodGet, p, nil); got.Code == http.StatusMovedPermanently || got.Code == http.StatusOK {
			t.Errorf("stranger GET %s = %d → %q; want the gate", p, got.Code, got.Header().Get("Location"))
		}
	}
}

// Every old address — in the table, or a bare one from before /app — is at
// most ONE hop from where it ends, its query kept, with every row live (the
// batch's end) and as the table stands today.
func TestConsoleTableOneHop(t *testing.T) {
	h, admin, user := rolesHarness(t)
	hd := h.srv.Handler()
	var olds []string
	for _, c := range consolePages {
		p := c.old
		if c.under {
			p += "x"
		}
		olds = append(olds, p)
	}
	for p := range appPagePaths {
		olds = append(olds, p)
	}
	for _, pre := range appPagePrefixes {
		olds = append(olds, pre+"x")
	}
	sort.Strings(olds)
	for _, all := range []bool{false, true} {
		withLive(t, all, func() {
			for _, p := range olds {
				for _, sess := range []*http.Cookie{admin, user} {
					got := consoleDo(hd, http.MethodGet, p+"?x=1&y=two", sess)
					if got.Code != http.StatusMovedPermanently {
						continue
					}
					to := got.Header().Get("Location")
					u, err := url.Parse(to)
					if err != nil || u.Query().Get("x") != "1" || u.Query().Get("y") != "two" {
						t.Errorf("live=%v GET %s → %q: the query is lost", all, p, to)
					}
					if again := consoleDo(hd, http.MethodGet, to, sess); again.Code == http.StatusMovedPermanently {
						t.Errorf("live=%v GET %s → %s → %s: two hops", all, p, to, again.Header().Get("Location"))
					}
				}
			}
		})
	}
	// The three that move today: 我的额度, All devices, and the bare ones.
	for p, want := range map[string]string{
		AppPrefix + "/quota?a=1":        AppPrefix + "/usage?a=1",
		"/quota":                        AppPrefix + "/usage",
		AppPrefix + "/admin/devices":    AppPrefix + "/nodes?tab=clients",
		"/admin/devices?tab=x":          AppPrefix + "/nodes?tab=x",
		AppPrefix + "/admin/devices?b=": AppPrefix + "/nodes?tab=clients&b=",
		"/sessions?a=1":                 AppPrefix + "/sessions?a=1",
		"/admin/users/gh:1":             AdminPrefix + "/people/gh:1",
		AppPrefix + "/admin/users?q=a":  AdminPrefix + "/people?q=a",
		AppPrefix + "/admin/users/p:x":  AdminPrefix + "/people/p:x",
		"/admin/users":                  AdminPrefix + "/people",
	} {
		if got := consoleDo(hd, http.MethodGet, p, admin); got.Code != http.StatusMovedPermanently || got.Header().Get("Location") != want {
			t.Errorf("admin GET %s = %d → %q; want 301 → %s", p, got.Code, got.Header().Get("Location"), want)
		}
	}
	// Live, one machine is a member's own: theirs goes to 设备, an admin's on.
	withLive(t, true, func() {
		if got := consoleDo(hd, http.MethodGet, "/machines/mac-a", user); got.Header().Get("Location") != AppPrefix+"/devices?tab=home" {
			t.Errorf("live: member /machines/mac-a → %q; want /app/devices?tab=home", got.Header().Get("Location"))
		}
		if got := consoleDo(hd, http.MethodGet, AppPrefix+"/machines/mac-a", admin); got.Header().Get("Location") != AdminPrefix+"/machines/mac-a" {
			t.Errorf("live: admin /app/machines/mac-a → %q; want /admin/machines/mac-a", got.Header().Get("Location"))
		}
		if got := consoleDo(hd, http.MethodGet, AppPrefix+"/admin/devices", admin); got.Header().Get("Location") != AdminPrefix+"/machines?tab=clients" {
			t.Errorf("live: admin /app/admin/devices → %q; want /admin/machines?tab=clients", got.Header().Get("Location"))
		}
		// A new page spelled like a bare old one is the new page.
		h.srv.ConsoleFS = fstest.MapFS{"admin/index.html": {Data: []byte("ADMIN-ENTRY")}}
		if got := consoleDo(hd, http.MethodGet, AdminPrefix+"/settings", admin); got.Code != http.StatusOK || got.Body.String() != "ADMIN-ENTRY" {
			t.Errorf("live: admin /admin/settings = %d %q; want the new page", got.Code, got.Body.String())
		}
		h.srv.ConsoleFS = nil
	})
	// Only GET and HEAD move: a form still reaches the old page.
	withLive(t, true, func() {
		if got := consoleDo(hd, http.MethodPost, TicketsPagePath, user); got.Code == http.StatusMovedPermanently {
			t.Errorf("live: POST %s = 301; a form is not moved", TicketsPagePath)
		}
	})
}

// appMountBefore is appMount as it stood before the table (claude-fleet#3583),
// kept here as the measure of «unchanged».
func (s *Server) appMountBefore(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		p := r.URL.Path
		switch {
		case p == AppPrefix || strings.HasPrefix(p, AppPrefix+"/"):
			w.Header().Set("X-Robots-Tag", "noindex, nofollow")
			s.serveAppPage(w, r, next)
		case p == "/":
			s.serveRoot(w, r)
		case s.serveSitePath(w, r):
		case isAppPage(p) && (r.Method == http.MethodGet || r.Method == http.MethodHead):
			http.Redirect(w, r, withQuery(AppPrefix+p, r), http.StatusMovedPermanently)
		default:
			next.ServeHTTP(w, r)
		}
	})
}

// With no row live, every address answers byte for byte what it did before
// the table — but for the three that move today (我的额度, All devices, the
// bare ones' one hop) and the admin side's answers to anyone not an admin.
func TestConsoleLiveOffIsUnchanged(t *testing.T) {
	h, admin, user := rolesHarness(t)
	h.srv.UI = fstest.MapFS{"index.html": {Data: []byte("APP")}, appPage: {Data: []byte("APP")}}
	routes := h.srv.routes()
	before := h.srv.logRequests(h.srv.readOnlyGate(h.srv.appMountBefore(routes)))
	now := h.srv.Handler()
	moved := func(p string) bool {
		inner := strings.TrimPrefix(p, AppPrefix)
		return inner == "/quota" || inner == "/admin/devices"
	}
	var paths []string
	for _, c := range consolePages {
		p := c.old
		if c.under {
			p += "x"
		}
		paths = append(paths, p, p+"?tab=a")
	}
	for p := range appPagePaths {
		paths = append(paths, p, appURL(p))
	}
	for _, pre := range appPagePrefixes {
		paths = append(paths, pre+"x")
	}
	paths = append(paths, "/", "/no-such-page", AppPrefix+"/no-such-page", AppPrefix+"/try", "/v1/me", "/fleet/keys/x.png")
	sort.Strings(paths)
	withLive(t, false, func() {
		for _, p := range paths {
			pth, _, _ := strings.Cut(p, "?")
			if moved(pth) {
				continue
			}
			for _, sess := range []*http.Cookie{admin, user, nil} {
				if sess != admin && isAdminPath(pth) {
					continue // the admin side's, to anyone else: TestAdminIs404ForMember
				}
				for _, m := range []string{http.MethodGet, http.MethodHead, http.MethodPost} {
					a, b := consoleDo(before, m, p, sess), consoleDo(now, m, p, sess)
					a.Body.Reset()
					a.Body.Write(sansNow(consoleDo(before, m, p, sess).Body.Bytes()))
					b.Body.Reset()
					b.Body.Write(sansNow(consoleDo(now, m, p, sess).Body.Bytes()))
					if d := sameAnswer(a, b); d != "" && d != "header Set-Cookie" {
						t.Errorf("%s %s (signed in %v): %d → %q now, %d → %q before; differs in its %s",
							m, p, sess != nil, b.Code, b.Header().Get("Location"), a.Code, a.Header().Get("Location"), d)
					}
				}
			}
		}
	})
}

// The table and the routes speak of the same pages: every old address is a
// page the hub serves, every admin-side new address is an admin route, a
// live member-side one is a console page, and a member's /v1/me lists no
// admin page (the menu never shows one).
func TestConsoleTableNamesRoutes(t *testing.T) {
	route := func(p string) (string, bool) {
		best := ""
		for pat := range routeAccess {
			if pat == p || (strings.HasSuffix(pat, "/") && strings.HasPrefix(p, pat) && len(pat) > len(best)) {
				if pat == p {
					return routeAccess[pat], true
				}
				best = pat
			}
		}
		a, ok := routeAccess[best]
		return a, ok && best != ""
	}
	for _, c := range consolePages {
		old := c.old
		if old == AppPrefix || strings.HasPrefix(old, AppPrefix+"/") {
			inner := strings.TrimPrefix(old, AppPrefix)
			if inner == "" {
				inner = "/"
			}
			if !isAppPage(inner) {
				t.Errorf("row %s: %s is no console page", c.owner, old)
			}
			old = inner
		}
		acc, ok := route(old)
		if !ok {
			t.Errorf("row %s: old %s is no route", c.owner, c.old)
		}
		if c.side == sideAdmin && c.forUser == "" && acc != accessAdmin {
			t.Errorf("row %s: %s is the admin side's but its route is %q", c.owner, c.old, acc)
		}
		np, _, _ := strings.Cut(c.new, "?")
		switch {
		case c.side == sideAdmin:
			if r, ok := consoleRow(np); ok && r.side == sideAdmin && r.forUser == "" {
				// a hop through another admin page's old address, on to its new one
			} else if !strings.HasPrefix(np, AdminPrefix) {
				t.Errorf("row %s: admin page %s goes to %s, outside %s", c.owner, c.old, np, AdminPrefix)
			} else if acc, ok := route(np); !ok || acc != accessAdmin {
				t.Errorf("row %s: new %s is route %q; want an admin route", c.owner, np, acc)
			}
		case c.live && strings.HasPrefix(np, AppPrefix):
			if !isAppPage(strings.TrimPrefix(np, AppPrefix)) && np != AppPrefix {
				t.Errorf("row %s is live but %s is no console page yet", c.owner, np)
			}
		}
	}
	for _, id := range pagesFor(roleUser) {
		for _, a := range adminPages {
			isMine := false
			for _, u := range userPages {
				isMine = isMine || u == a
			}
			if !isMine && id == a {
				t.Errorf("a member's pages list the admin page %q", id)
			}
		}
	}
}

// The member side (claude-fleet#3926, C3): the conversation is /app itself,
// 我的 is /app/me, 用量 /app/usage (claude-fleet#3929, C6) — each the console's
// index.html for a signed-in person, with the console's own-origin policy;
// /chat/ is one 301 to /app, /app/quota and the bare /usage one 301 to
// /app/usage; a page whose own row is not live yet (/app/sessions) is still
// the old page; a stranger is asked to sign in; and a hub with no
// console build serves /app as it always did.
func TestConsoleMemberSide(t *testing.T) {
	h, admin, user := rolesHarness(t)
	h.srv.UI = fstest.MapFS{"index.html": {Data: []byte("OLD-APP")}}
	h.srv.ConsoleFS = fstest.MapFS{
		"app/index.html":     {Data: []byte("APP-ENTRY")},
		"app/assets/main.js": {Data: []byte("APP-CODE")},
	}
	hd := h.srv.Handler()
	for _, who := range []*http.Cookie{user, admin} {
		for _, p := range []string{AppPrefix, AppPrefix + "/", AppPrefix + mePagePath, AppPrefix + "?x=1", AppPrefix + "/usage", AppPrefix + "/usage?range=today"} {
			got := consoleDo(hd, http.MethodGet, p, who)
			if got.Code != http.StatusOK || got.Body.String() != "APP-ENTRY" {
				t.Errorf("GET %s = %d %.60q; want the console's page", p, got.Code, got.Body.String())
				continue
			}
			if csp := got.Header().Get("Content-Security-Policy"); !strings.Contains(csp, "default-src 'self'") || strings.Contains(csp, "http") {
				t.Errorf("GET %s CSP %q; want same origin only", p, csp)
			}
			if got.Header().Get("Cache-Control") != "no-store" {
				t.Errorf("GET %s Cache-Control %q; want no-store", p, got.Header().Get("Cache-Control"))
			}
		}
	}
	if got := consoleDo(hd, http.MethodGet, ChatPagePath, user); got.Code != http.StatusMovedPermanently || got.Header().Get("Location") != AppPrefix {
		t.Errorf("GET /chat/ = %d → %q; want 301 %s", got.Code, got.Header().Get("Location"), AppPrefix)
	}
	if got := consoleDo(hd, http.MethodGet, mePagePath, user); got.Code != http.StatusMovedPermanently || got.Header().Get("Location") != AppPrefix+mePagePath {
		t.Errorf("GET /me = %d → %q; want 301 %s", got.Code, got.Header().Get("Location"), AppPrefix+mePagePath)
	}
	for _, p := range []string{AppPrefix + "/sessions"} {
		if got := consoleDo(hd, http.MethodGet, p, user); got.Body.String() == "APP-ENTRY" {
			t.Errorf("GET %s is the console's page; its own row is not live yet", p)
		}
	}
	for _, p := range []string{AppPrefix + "/quota", "/quota", "/usage"} {
		if got := consoleDo(hd, http.MethodGet, p+"?range=30d", user); got.Code != http.StatusMovedPermanently || got.Header().Get("Location") != AppPrefix+"/usage?range=30d" {
			t.Errorf("GET %s?range=30d = %d → %q; want 301 /app/usage?range=30d", p, got.Code, got.Header().Get("Location"))
		}
	}
	for _, p := range []string{AppPrefix, AppPrefix + mePagePath} {
		if got := consoleDo(hd, http.MethodGet, p, nil); got.Code == http.StatusOK {
			t.Errorf("stranger GET %s = 200; want the gate", p)
		}
	}
	// no build: /app is the old overview, /app/me has nothing to show
	h.srv.ConsoleFS = nil
	if got := consoleDo(hd, http.MethodGet, AppPrefix, user); got.Body.String() != "OLD-APP" {
		t.Errorf("no console build: GET /app = %d %.60q; want the old page", got.Code, got.Body.String())
	}
	if got := consoleDo(hd, http.MethodGet, AppPrefix+mePagePath, user); got.Code != http.StatusNotFound {
		t.Errorf("no console build: GET /app/me = %d; want 404", got.Code)
	}
}

// 设备 (claude-fleet#3930, C7): /app/devices is the console's page; the four
// old addresses it took over — 设备与 SSH, 从手机连, 我的连接, 我的机器 — are
// one 301 to its tab, query kept; a member's one machine goes to its 我的机器
// tab while an admin's still opens the old page (C11 moves that); a form still
// reaches the keys page.
func TestConsoleDevices(t *testing.T) {
	h, admin, user := rolesHarness(t)
	h.srv.ConsoleFS = fstest.MapFS{"app/index.html": {Data: []byte("APP-ENTRY")}}
	hd := h.srv.Handler()
	for _, who := range []*http.Cookie{user, admin} {
		if got := consoleDo(hd, http.MethodGet, AppPrefix+devicesPagePath+"?tab=keys", who); got.Code != http.StatusOK || got.Body.String() != "APP-ENTRY" {
			t.Errorf("GET /app/devices = %d %.60q; want the console's page", got.Code, got.Body.String())
		}
	}
	for p, want := range map[string]string{
		AppPrefix + "/connect":      AppPrefix + "/devices",
		"/connect?x=1":              AppPrefix + "/devices?x=1",
		EntryPagePath:               AppPrefix + "/devices?tab=phone",
		EntryPagePath + "?step=3":   AppPrefix + "/devices?tab=phone&step=3",
		EntryConnPath:               AppPrefix + "/devices?tab=home",
		AppPrefix + "/machines":     AppPrefix + "/devices?tab=home",
		"/machines":                 AppPrefix + "/devices?tab=home",
		AppPrefix + "/machines/x":   AppPrefix + "/devices?tab=home",
		"/machines/x":               AppPrefix + "/devices?tab=home",
		AppPrefix + "/machines/x/y": AppPrefix + "/devices?tab=home",
	} {
		if got := consoleDo(hd, http.MethodGet, p, user); got.Code != http.StatusMovedPermanently || got.Header().Get("Location") != want {
			t.Errorf("member GET %s = %d → %q; want 301 → %s", p, got.Code, got.Header().Get("Location"), want)
		}
	}
	// an admin's one machine is still the old page until C11's row is live
	if got := consoleDo(hd, http.MethodGet, AppPrefix+"/machines/x", admin); got.Code == http.StatusMovedPermanently {
		t.Errorf("admin GET /app/machines/x = 301 → %q; want the old page", got.Header().Get("Location"))
	}
	if got := consoleDo(hd, http.MethodGet, AppPrefix+"/connect", admin); got.Header().Get("Location") != AppPrefix+"/devices" {
		t.Errorf("admin GET /app/connect → %q; want /app/devices", got.Header().Get("Location"))
	}
	if got := consoleDo(hd, http.MethodPost, EntryPagePath, user); got.Code == http.StatusMovedPermanently {
		t.Errorf("POST %s = 301; a form is not moved", EntryPagePath)
	}
	// a stranger is asked to sign in at the end, never shown the page
	if got := consoleDo(hd, http.MethodGet, AppPrefix+devicesPagePath, nil); got.Code == http.StatusOK {
		t.Errorf("stranger GET /app/devices = 200; want the gate")
	}
}

// 设置 (claude-fleet#3931, C8) took over /app/config: the old address (and the
// bare /config before /app) is one 301 to /app/settings with its query, the
// new one is the console's page for each signed-in person, a stranger is asked
// to sign in, and a way of signing in that was just added comes back to it.
func TestConsoleSettings(t *testing.T) {
	h, admin, user := rolesHarness(t)
	h.srv.UI = fstest.MapFS{"index.html": {Data: []byte("OLD-APP")}, "config.html": {Data: []byte("OLD-CONFIG")}}
	h.srv.ConsoleFS = fstest.MapFS{"app/index.html": {Data: []byte("APP-ENTRY")}}
	hd := h.srv.Handler()
	for _, who := range []*http.Cookie{user, admin} {
		if got := consoleDo(hd, http.MethodGet, AppPrefix+settingsPagePath, who); got.Code != http.StatusOK || got.Body.String() != "APP-ENTRY" {
			t.Errorf("GET /app/settings = %d %.60q; want the console's page", got.Code, got.Body.String())
		}
		for from, to := range map[string]string{
			AppPrefix + "/config":         AppPrefix + settingsPagePath,
			AppPrefix + "/config?e=taken": AppPrefix + settingsPagePath + "?e=taken",
			"/config":                     AppPrefix + settingsPagePath,
			"/settings":                   AppPrefix + settingsPagePath,
		} {
			if got := consoleDo(hd, http.MethodGet, from, who); got.Code != http.StatusMovedPermanently || got.Header().Get("Location") != to {
				t.Errorf("GET %s = %d → %q; want 301 %s", from, got.Code, got.Header().Get("Location"), to)
			}
		}
	}
	if got := consoleDo(hd, http.MethodGet, AppPrefix+settingsPagePath, nil); got.Code == http.StatusOK {
		t.Errorf("stranger GET /app/settings = 200; want the gate")
	}
	if got, want := settingsBack("wechat-taken"), AppPrefix+settingsPagePath+"?e=wechat-taken#logins"; got != want {
		t.Errorf("settingsBack = %q; want %q", got, want)
	}
}
