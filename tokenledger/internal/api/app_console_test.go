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
	for _, p := range paths {
		for _, q := range []string{"", "?tab=clients"} {
			got := consoleDo(hd, http.MethodGet, p+q, user)
			if d := sameAnswer(got, unknown); d != "" {
				t.Errorf("member GET %s%s = %d → %q %.60q; differs from /admin/no-such-page in its %s",
					p, q, got.Code, got.Header().Get("Location"), got.Body.String(), d)
			}
		}
	}
	var refused int
	if err := h.srv.Store.DB().QueryRow(`SELECT COUNT(*) FROM fleet_audit WHERE action = 'role_denied'
		AND actor LIKE 'gh:200%'`).Scan(&refused); err != nil {
		t.Fatal(err)
	}
	if want := 1 + 2*len(paths); refused < want {
		t.Errorf("%d role_denied rows; want one per refusal (%d)", refused, want)
	}
	// An admin: the new entry and its files — an old page's script is gone,
	// the entry draws it as the console's own unknown page.
	for p, want := range map[string]string{
		AdminPrefix: "ADMIN-ENTRY", AdminPrefix + "/people": "ADMIN-ENTRY", AdminPrefix + "/no-such-page": "ADMIN-ENTRY",
		AdminPrefix + "/assets/main.js": "ADMIN-CODE", AdminPrefix + "/users.js": "ADMIN-ENTRY",
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

// Every old address — in the table, or a bare one from before /app — is ONE
// hop from where it ends, its query kept, for good (claude-fleet#3939): an
// admin moves on from every row, a member from every row that is theirs, and
// any other method is the 404 an unknown address gets — the old pages are
// gone.
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
	for _, p := range olds {
		for _, sess := range []*http.Cookie{admin, user} {
			got := consoleDo(hd, http.MethodGet, p+"?x=1&y=two", sess)
			if got.Code != http.StatusMovedPermanently {
				continue
			}
			to := got.Header().Get("Location")
			u, err := url.Parse(to)
			if err != nil || u.Query().Get("x") != "1" || u.Query().Get("y") != "two" {
				t.Errorf("GET %s → %q: the query is lost", p, to)
			}
			if again := consoleDo(hd, http.MethodGet, to, sess); again.Code == http.StatusMovedPermanently {
				t.Errorf("GET %s → %s → %s: two hops", p, to, again.Header().Get("Location"))
			}
		}
	}
	// Every row moves on: an admin from each, a member from each that is
	// theirs (an admin row the member's 404 — TestAdminIs404ForMember).
	for _, c := range consolePages {
		p := c.old
		if c.under {
			p += "x"
		}
		for _, sess := range []*http.Cookie{admin, user} {
			if sess == user && c.side == sideAdmin && c.forUser == "" {
				continue
			}
			if c.old == c.new && !c.under {
				continue // a console page that kept its address (/app/usage)
			}
			for _, m := range []string{http.MethodGet, http.MethodHead} {
				if got := consoleDo(hd, m, p, sess); got.Code != http.StatusMovedPermanently {
					t.Errorf("row %s: %s %s = %d; want 301 — an old bookmark stays one hop", c.owner, m, p, got.Code)
				}
			}
			for _, m := range []string{http.MethodPost, http.MethodPut, http.MethodDelete} {
				if got := consoleDo(hd, m, p, sess); got.Code != http.StatusNotFound && got.Code != http.StatusMethodNotAllowed {
					t.Errorf("row %s: %s %s = %d; want 404/405 — the old page is gone", c.owner, m, p, got.Code)
				}
			}
		}
	}
	// A sample, spelled out.
	for p, want := range map[string]string{
		AppPrefix + "/quota?a=1":         AppPrefix + "/usage?a=1",
		"/quota":                         AppPrefix + "/usage",
		AppPrefix + "/admin/devices":     AdminPrefix + "/machines?tab=clients",
		"/admin/devices?tab=x":           AdminPrefix + "/machines?tab=x",
		AppPrefix + "/admin/devices?b=":  AdminPrefix + "/machines?tab=clients&b=",
		AppPrefix + "/nodes?tab=clients": AdminPrefix + "/machines?tab=clients",
		"/nodes":                         AdminPrefix + "/machines",
		AppPrefix + "/machines/mac-a":    AdminPrefix + "/machines/mac-a",
		"/machines/mac-a?log=x":          AdminPrefix + "/machines/mac-a?log=x",
		"/sessions?a=1":                  AppPrefix + "/sessions?a=1",
		"/admin/users/gh:1":              AdminPrefix + "/people/gh:1",
		AppPrefix + "/admin/users?q=a":   AdminPrefix + "/people?q=a",
		AppPrefix + "/admin/users/p:x":   AdminPrefix + "/people/p:x",
		"/admin/users":                   AdminPrefix + "/people",
		AppPrefix + "/admin/overview":    AdminPrefix + "/usage",
		"/admin/overview?since=7d":       AdminPrefix + "/usage?since=7d",
		AppPrefix + "/admin/sessions":    AdminPrefix + "/usage?tab=sessions",
		"/admin/sessions?q=a":            AdminPrefix + "/usage?tab=sessions&q=a",
		// 入口设置 · 审计 · 反馈 (claude-fleet#3938)
		AppPrefix + "/admin/settings":         AdminPrefix + "/settings",
		AppPrefix + "/admin/audit?kind=set":   AdminPrefix + "/audit?kind=set",
		AppPrefix + "/admin/feedback?state=a": AdminPrefix + "/feedback?state=a",
	} {
		if got := consoleDo(hd, http.MethodGet, p, admin); got.Code != http.StatusMovedPermanently || got.Header().Get("Location") != want {
			t.Errorf("admin GET %s = %d → %q; want 301 → %s", p, got.Code, got.Header().Get("Location"), want)
		}
	}
	// 订阅池 (claude-fleet#3935): the list, one subscription, its settings —
	// an admin on in one hop, a member the 404 an unknown address gets.
	for p, want := range map[string]string{
		AppPrefix + "/subscriptions":               AdminPrefix + "/pool",
		AppPrefix + "/subscriptions?f=near":        AdminPrefix + "/pool?f=near",
		AppPrefix + "/subscriptions/5b0e8c1a-1111": AdminPrefix + "/pool/5b0e8c1a-1111",
		AppPrefix + "/subscriptions/settings":      AdminPrefix + "/pool/settings",
		"/subscriptions":                           AdminPrefix + "/pool",
		"/subscriptions/settings":                  AdminPrefix + "/pool/settings",
		"/subscriptions/codex:account:0123?x=1":    AdminPrefix + "/pool/codex:account:0123?x=1",
	} {
		if got := consoleDo(hd, http.MethodGet, p, admin); got.Code != http.StatusMovedPermanently || got.Header().Get("Location") != want {
			t.Errorf("admin GET %s = %d → %q; want 301 → %s", p, got.Code, got.Header().Get("Location"), want)
		}
		if got := consoleDo(hd, http.MethodGet, p, user); got.Code != http.StatusNotFound {
			t.Errorf("member GET %s = %d; want 404", p, got.Code)
		}
	}
	// One machine (C11) is the admin's: a member goes to 设备 (C7).
	for _, p := range []string{AppPrefix + "/machines/mac-a", "/machines/mac-a"} {
		if got := consoleDo(hd, http.MethodGet, p, user); got.Code != http.StatusMovedPermanently || got.Header().Get("Location") != AppPrefix+"/devices?tab=home" {
			t.Errorf("member GET %s = %d → %q; want 301 → /app/devices?tab=home", p, got.Code, got.Header().Get("Location"))
		}
	}
	// A new page spelled like a bare old one is the new page.
	h.srv.ConsoleFS = fstest.MapFS{"admin/index.html": {Data: []byte("ADMIN-ENTRY")}}
	if got := consoleDo(hd, http.MethodGet, AdminPrefix+"/settings", admin); got.Code != http.StatusOK || got.Body.String() != "ADMIN-ENTRY" {
		t.Errorf("admin /admin/settings = %d %q; want the new page", got.Code, got.Body.String())
	}
	h.srv.ConsoleFS = nil
	// The old pages are gone: a form gets the 404, never the page.
	for _, p := range []string{TicketsPagePath, TicketsPagePath + "/o/r/1", EntryPagePath, EntryConnPath, ChatPagePath, "/usage", AppPrefix + "/config"} {
		if got := consoleDo(hd, http.MethodPost, p, user); got.Code != http.StatusNotFound {
			t.Errorf("POST %s = %d; want 404", p, got.Code)
		}
	}
	// The paths a person typed for the keys page, and its pictures, land on 设备.
	for _, p := range []string{"/fleet/key", "/keys", EntryPagePath + "/", EntryPagePath + "/img/step1.png"} {
		if got := consoleDo(hd, http.MethodGet, p, user); got.Code != http.StatusMovedPermanently || got.Header().Get("Location") != AppPrefix+devicesPagePath+"?tab=phone" {
			t.Errorf("GET %s = %d → %q; want 301 → /app/devices?tab=phone", p, got.Code, got.Header().Get("Location"))
		}
	}
}

// The table and the routes speak of the same pages: every admin-side new
// address is an admin route, a member-side one a console page, and a
// member's /v1/me lists no admin page (the menu never shows one). The old
// addresses are no routes any more (claude-fleet#3939): appMount answers them.
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
		case strings.HasPrefix(np, AppPrefix):
			if !isAppPage(strings.TrimPrefix(np, AppPrefix)) && np != AppPrefix {
				t.Errorf("row %s goes to %s, no console page", c.owner, np)
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
// /app/usage; a stranger is asked to sign in; and a hub with no console
// build has no page to show.
func TestConsoleMemberSide(t *testing.T) {
	h, admin, user := rolesHarness(t)
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
	// 我的会话 is the console's own page (claude-fleet#3927, C4); the old
	// /sessions moves there in one hop
	if got := consoleDo(hd, http.MethodGet, AppPrefix+"/sessions", user); got.Code != http.StatusOK || got.Body.String() != "APP-ENTRY" {
		t.Errorf("GET /app/sessions = %d %.60q; want the console's page", got.Code, got.Body.String())
	}
	if got := consoleDo(hd, http.MethodGet, "/sessions", user); got.Code != http.StatusMovedPermanently || got.Header().Get("Location") != AppPrefix+"/sessions" {
		t.Errorf("GET /sessions = %d → %q; want 301 /app/sessions", got.Code, got.Header().Get("Location"))
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
	// no build: nothing to show — the old overview is gone (claude-fleet#3939)
	h.srv.ConsoleFS = nil
	for _, p := range []string{AppPrefix, AppPrefix + mePagePath, AppPrefix + "/usage"} {
		if got := consoleDo(hd, http.MethodGet, p, user); got.Code != http.StatusNotFound {
			t.Errorf("no console build: GET %s = %d; want 404", p, got.Code)
		}
	}
}

// 设备 (claude-fleet#3930, C7): /app/devices is the console's page; the four
// old addresses it took over — 设备与 SSH, 从手机连, 我的连接, 我的机器 — are
// one 301 to its tab, query kept; a member's one machine goes to its 我的机器
// tab while an admin's goes to the admin side (C11).
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
	// an admin's one machine is the admin side's (C11)
	if got := consoleDo(hd, http.MethodGet, AppPrefix+"/machines/x", admin); got.Code != http.StatusMovedPermanently || got.Header().Get("Location") != AdminPrefix+"/machines/x" {
		t.Errorf("admin GET /app/machines/x = %d → %q; want 301 → /admin/machines/x", got.Code, got.Header().Get("Location"))
	}
	if got := consoleDo(hd, http.MethodGet, AppPrefix+"/connect", admin); got.Header().Get("Location") != AppPrefix+"/devices" {
		t.Errorf("admin GET /app/connect → %q; want /app/devices", got.Header().Get("Location"))
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
