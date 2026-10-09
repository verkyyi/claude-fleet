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
	{"config.html", "config.js", "config"},
	{"subscriptions.html", "subscriptions.js", "subscriptions"},
	{"nodes.html", "nodes.js", "machines"},
	{"users.html", "users.js", "people"},
	{"settings.html", "settings.js", "settings"},
	{"audit.html", "audit.js", "audit"},
}

func TestAssets_AppPagesAreEmbedded(t *testing.T) {
	assets := Assets()
	if assets == nil {
		t.Fatal("no dashboard embedded: web/dist/index.html is missing from this checkout")
	}
	for _, name := range []string{"app.css", "app-shell.js", "lib/shell.js", "lib/pages.js", "lib/admin.js"} {
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
		if !strings.Contains(js, `from './app-shell.js'`) {
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
		"/": "index.html", "/sessions": "sessions.html", "/machines": "machines.html", "/connect": "connect.html", "/config": "config.html",
		"/quota":         "quota.html",
		"/subscriptions": "subscriptions.html", "/nodes": "nodes.html", "/admin/users": "users.html",
		"/admin/settings": "settings.html", "/admin/audit": "audit.html",
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
