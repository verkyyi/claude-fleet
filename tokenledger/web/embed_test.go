package web

import (
	"io/fs"
	"regexp"
	"strings"
	"testing"
)

// The dashboard is embedded, so a missing web/dist is not a cosmetic problem:
// go:embed fails the BUILD. An unanchored `dist/` in .gitignore once kept the
// whole directory out of every commit, and a fresh clone could not compile.

// appPages are the four everyday pages (claude-fleet#1989) and the five
// admin pages (claude-fleet#1990): each a thin HTML file that links the one
// stylesheet and mounts its script into the shell under the page id /v1/me
// lists.
var appPages = []struct{ html, script, id string }{
	{"index.html", "overview.js", "overview"},
	{"sessions.html", "sessions-page.js", "sessions"},
	{"machines.html", "machines.js", "mymachines"},
	{"connect.html", "connect.js", "devices"},
	{"quota.html", "quota.js", "quota"},
	{"usage.html", "usage.js", "usage"},
	{"config.html", "config.js", "config"},
	{"admin/subscriptions.html", "admin/subscriptions.js", "subscriptions"},
	{"admin/nodes.html", "admin/nodes.js", "machines"},
	{"admin/users.html", "admin/users.js", "people"},
	{"admin/settings.html", "admin/settings.js", "settings"},
	{"admin/audit.html", "admin/audit.js", "audit"},
	// The whole hub an admin's daily pages used to show (claude-fleet#2515).
	{"admin/sessions.html", "admin/sessions.js", "all-sessions"},
	{"admin/overview.html", "admin/overview.js", "by-person"},
	{"admin/devices.html", "admin/devices.js", "all-devices"},
}

func TestAssets_AppPagesAreEmbedded(t *testing.T) {
	assets := Assets()
	if assets == nil {
		t.Fatal("no dashboard embedded: web/dist/index.html is missing from this checkout")
	}
	for _, name := range []string{"app.css", "app-shell.js", "app.html", "app-start.js", "lib/router.js", "lib/stream.js", "lib/shell.js", "lib/pages.js", "lib/admin.js", "lib/sessions-view.js", "lib/devices-view.js"} {
		if _, err := fs.Stat(assets, name); err != nil {
			t.Fatalf("%s is not embedded: %v", name, err)
		}
	}
	for _, p := range appPages {
		html := string(mustRead(t, assets, p.html))
		for _, want := range []string{"<title>", `href="/app.css"`, `<script type="module" src="/` + p.script + `"`} {
			if !strings.Contains(html, want) {
				t.Errorf("%s is missing %s", p.html, want)
			}
		}
		js := string(mustRead(t, assets, p.script))
		if !strings.Contains(js, `from './app-shell.js'`) && !strings.Contains(js, `from '../app-shell.js'`) {
			t.Errorf("%s does not mount through app-shell.js", p.script)
		}
		if !strings.Contains(js, "Shell.mount('"+p.id+"'") {
			t.Errorf("%s does not mount as page %q -- the id the menu and the page gate read", p.script, p.id)
		}
	}
}

// Every page the menu links is embedded: lib/shell.js's PAGES hrefs are the
// four app pages and the five admin pages.
func TestAssets_MenuLinksResolve(t *testing.T) {
	assets := Assets()
	src := string(mustRead(t, assets, "lib/shell.js"))
	route := map[string]string{
		"/": "index.html", "/sessions": "sessions.html", "/machines": "machines.html", "/machines/": "machines.html", "/connect": "connect.html", "/config": "config.html",
		"/quota": "quota.html", "/usage": "usage.html",
		"/subscriptions": "admin/subscriptions.html", "/nodes": "admin/nodes.html", "/admin/users": "admin/users.html",
		"/admin/settings": "admin/settings.html", "/admin/audit": "admin/audit.html",
		"/admin/sessions": "admin/sessions.html", "/admin/overview": "admin/overview.html", "/admin/devices": "admin/devices.html",
	}
	hrefs := regexp.MustCompile(`href: '([^']+)'`).FindAllStringSubmatch(src, -1)
	if len(hrefs) < 4 {
		t.Fatalf("found %d menu hrefs in lib/shell.js; the PAGES table moved", len(hrefs))
	}
	for _, m := range hrefs {
		file, ok := route[m[1]]
		if !ok {
			t.Errorf("menu links %s, which no embedded page serves", m[1])
			continue
		}
		if _, err := fs.Stat(assets, file); err != nil {
			t.Errorf("menu links %s but %s is not embedded", m[1], file)
		}
	}
}

// One document, many pages (claude-fleet#2793): app.html starts the shell,
// and every PAGES entry names the module the shell import()s for it —
// embedded, and registering itself under that id as its default export.
func TestAssets_AppDocumentRoutesEveryPage(t *testing.T) {
	assets := Assets()
	html := string(mustRead(t, assets, "app.html"))
	if !strings.Contains(html, `<script type="module" src="/app-start.js"`) || !strings.Contains(html, `href="/app.css"`) {
		t.Errorf("app.html does not start the shell: %q", html)
	}
	if !strings.Contains(string(mustRead(t, assets, "app-start.js")), "Shell.start()") {
		t.Error("app-start.js does not start the shell")
	}
	src := string(mustRead(t, assets, "lib/shell.js"))
	rows := regexp.MustCompile(`\{ id: '([^']+)'[^}]*href: '([^']+)', module: '/([^']+)' \}`).FindAllStringSubmatch(src, -1)
	if len(rows) != len(appPages) {
		t.Fatalf("%d PAGES rows carry a module; want %d (one per page)", len(rows), len(appPages))
	}
	for _, m := range rows {
		js := string(mustRead(t, assets, m[3]))
		if !strings.Contains(js, "export default Shell.mount('"+m[1]+"'") {
			t.Errorf("%s (the module for %s) does not export its page as %q", m[3], m[2], m[1])
		}
	}
}

// The old dashboard is gone, not hidden (claude-fleet#1989 ⑥): its pages and
// the module set they booted are no longer in the build.
func TestAssets_OldDashboardIsGone(t *testing.T) {
	assets := Assets()
	// The older admin pages and their shared header went with claude-fleet#1990.
	for _, name := range []string{"user.html", "styles.css", "app.js", "now.js", "review.js", "lib/sessions.js",
		"credentials.html", "access.html", "whoami.js", "whoami.css", "lib/whoami.js"} {
		if _, err := fs.Stat(assets, name); err == nil {
			t.Errorf("%s is still embedded; the old page it belongs to was removed", name)
		}
	}
	for _, p := range appPages {
		if strings.Contains(string(mustRead(t, assets, p.html)), "whoami.js") {
			t.Errorf("%s still loads the old header; the shell draws who is signed in", p.html)
		}
	}
}

func mustRead(t *testing.T, assets fs.FS, name string) []byte {
	t.Helper()
	b, err := fs.ReadFile(assets, name)
	if err != nil {
		t.Fatalf("%s unreadable: %v", name, err)
	}
	return b
}
