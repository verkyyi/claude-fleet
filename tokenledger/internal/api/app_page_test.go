package api

import (
	"io"
	"net/http"
	"os"
	"regexp"
	"strings"
	"testing"
	"testing/fstest"
)

// One document, many pages (claude-fleet#2793): every path the menu links —
// read from the route table itself, lib/shell.js's PAGES — answers the one
// app document, so the shell inside it can swap pages in place and a
// bookmark or a reload of any page lands on the same app. The gates are the
// routes' own and unchanged: a user still gets the bare 403 on an admin page,
// none of the document; an unknown path is still a 404; a build without
// app.html serves each page's own file, as before.
func TestAppPage_EveryPagePathAnswersTheAppDocument(t *testing.T) {
	src, err := os.ReadFile("../../web/dist/lib/shell.js")
	if err != nil {
		t.Fatal(err)
	}
	rows := regexp.MustCompile(`\{ id: '[^']+',[^}]*?(group: 'admin', )?href: '([^']+)'`).FindAllStringSubmatch(string(src), -1)
	if len(rows) < 10 {
		t.Fatalf("found %d PAGES rows in lib/shell.js; the table moved", len(rows))
	}
	const doc = "APP-DOCUMENT"
	ui := fstest.MapFS{
		appPage:      &fstest.MapFile{Data: []byte("<!doctype html><title>claudefleet</title>" + doc)},
		"index.html": &fstest.MapFile{Data: []byte("<title>overview</title>OWN-PAGE")},
	}
	// Each page's own file, so a path that skipped the app document shows.
	for _, f := range []string{"sessions.html", "machines.html", "connect.html", "quota.html", "usage.html", "config.html"} {
		ui[f] = &fstest.MapFile{Data: []byte("<title>" + f + "</title>OWN-PAGE")}
	}
	routes := append(adminPageRoutes, struct{ path, id, file string }{"/nodes", "machines", "admin/nodes.html"})
	for _, p := range routes {
		ui[p.file] = &fstest.MapFile{Data: []byte("<title>" + p.id + "</title>OWN-PAGE")}
	}
	h, admin, user := rolesHarness(t)
	h.srv.UI = ui
	get := func(sess *http.Cookie, path string) (int, string) {
		t.Helper()
		req, _ := http.NewRequest(http.MethodGet, h.http.URL+path, nil)
		req.Header.Set("Accept", "text/html")
		if sess != nil {
			req.AddCookie(sess)
		}
		resp, err := noFollow.Do(req)
		if err != nil {
			t.Fatalf("GET %s: %v", path, err)
		}
		defer resp.Body.Close()
		b, _ := io.ReadAll(resp.Body)
		return resp.StatusCode, string(b)
	}
	for _, m := range rows {
		path, adminOnly := m[2], m[1] != ""
		if code, body := get(admin, path); code != http.StatusOK || !strings.Contains(body, doc) {
			t.Errorf("admin GET %s = %d %q; want 200 and the app document", path, code, body)
		}
		code, body := get(user, path)
		switch {
		case adminOnly && (code != http.StatusForbidden || strings.Contains(body, doc)):
			t.Errorf("user GET %s = %d %q; want the bare 403, none of the app", path, code, body)
		case !adminOnly && (code != http.StatusOK || !strings.Contains(body, doc)):
			t.Errorf("user GET %s = %d %q; want 200 and the app document", path, code, body)
		}
	}
	// A path no page has is a 404, not the app.
	if code, body := get(admin, "/no-such-page"); code != http.StatusNotFound || strings.Contains(body, doc) {
		t.Errorf("admin GET /no-such-page = %d %q; want 404", code, body)
	}
	// One machine's page (claude-fleet#2796) is a deep link into the app, for
	// a user too: the page's read, /v1/nodes/<host>, is what cuts.
	for _, sess := range []*http.Cookie{admin, user} {
		if code, body := get(sess, "/machines/m4"); code != http.StatusOK || !strings.Contains(body, doc) {
			t.Errorf("GET /machines/m4 = %d %q; want 200 and the app document", code, body)
		}
	}
	// A build from before the app document: each page its own file.
	delete(ui, appPage)
	for _, p := range []string{"/", "/sessions", "/nodes"} {
		if code, body := get(admin, p); code != http.StatusOK || !strings.Contains(body, "OWN-PAGE") {
			t.Errorf("no app.html: admin GET %s = %d %q; want the page's own file", p, code, body)
		}
	}
}
