package api

import (
	"bytes"
	"compress/gzip"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"testing/fstest"
)

// siteFixture is a built site and docs as bin/site-build.sh / docs-build.sh
// lay them out, small.
func siteFixture() (fstest.MapFS, fstest.MapFS) {
	page := func(lang string) *fstest.MapFile {
		return &fstest.MapFile{Data: []byte(`<html lang="` + lang + `"><link rel="canonical" href="__ORIGIN__/x">` + lang + `</html>`)}
	}
	site := fstest.MapFS{
		"index.html":           page("zh-CN"),
		"en/index.html":        page("en"),
		"build.json":           {Data: []byte(`{"timed":false}`)},
		".gitkeep":             {},
		"logo.svg":             {Data: []byte("<svg/>")},
		"favicon.ico":          {Data: []byte("ICO")},
		"apple-touch-icon.png": {Data: []byte("PNG-apple")},
		"og/cover-zh.png":      {Data: []byte("PNG-zh")},
		"fonts/a-latin.woff2":  {Data: []byte("WOFF2")},
		"fonts/OFL-a.txt":      {Data: []byte("OFL")},
		"robots.txt":           {Data: []byte("User-agent: *\nDisallow: /app/\nSitemap: __ORIGIN__/sitemap.xml\n")},
		"sitemap.xml":          {Data: []byte(`<?xml version="1.0"?><urlset><url><loc>__ORIGIN__/</loc></url></urlset>`)},
		"llms.txt":             {Data: []byte("# ClaudeFleet\n- [FAQ](__ORIGIN__/en/docs/faq.md)\n")},
		"llms-zh.txt":          {Data: []byte("# ClaudeFleet\n- [常见问题](__ORIGIN__/docs/faq.md)\n")},
		"llms-full.txt":        {Data: []byte("# ClaudeFleet — full documentation\nSource: __ORIGIN__/docs/faq\n")},
	}
	docs := fstest.MapFS{
		"zh/index.html":       {Data: []byte("DOCS-ZH")},
		"zh/faq.html":         {Data: []byte("FAQ-ZH")},
		"zh/faq.md":           {Data: []byte("# 常见问题")},
		"zh/admin/index.html": {Data: []byte("ADMIN-ZH")},
		"en/index.html":       {Data: []byte("DOCS-EN")},
		"en/faq.html":         {Data: []byte("FAQ-EN")},
	}
	return site, docs
}

// With the site on, its paths answer from the built site and docs: each page
// with this hub's own address in it, each asset with its type, nothing else of
// the build reachable, and a bare directory sent on to its index.
func TestSitePaths(t *testing.T) {
	h, admin, _ := rolesHarness(t)
	h.srv.Site = true
	h.srv.SiteFS, h.srv.DocsFS = siteFixture()
	h.srv.FleetPublicURL = "https://hub.example.com/"
	do := func(method, p string, sess *http.Cookie) *httptest.ResponseRecorder {
		req := httptest.NewRequest(method, p, nil)
		if sess != nil {
			req.AddCookie(sess)
		}
		rec := httptest.NewRecorder()
		h.srv.Handler().ServeHTTP(rec, req)
		return rec
	}
	for _, c := range []struct{ path, body, ctype string }{
		{"/", `<html lang="zh-CN"><link rel="canonical" href="https://hub.example.com/x">`, "text/html; charset=utf-8"},
		{"/en/", `<html lang="en"><link rel="canonical" href="https://hub.example.com/x">`, "text/html; charset=utf-8"},
		{"/favicon.ico", "ICO", "image/x-icon"},
		{"/favicon.svg", "<svg/>", "image/svg+xml"},
		{"/apple-touch-icon.png", "PNG-apple", "image/png"},
		{"/site/og/cover-zh.png", "PNG-zh", "image/png"},
		{"/site/fonts/a-latin.woff2", "WOFF2", "font/woff2"},
		{"/site/fonts/OFL-a.txt", "OFL", "text/plain; charset=utf-8"},
		{"/docs/", "DOCS-ZH", "text/html; charset=utf-8"},
		{"/docs/faq", "FAQ-ZH", "text/html; charset=utf-8"},
		{"/docs/faq.md", "# 常见问题", "text/markdown; charset=utf-8"},
		{"/docs/admin/", "ADMIN-ZH", "text/html; charset=utf-8"},
		{"/en/docs/", "DOCS-EN", "text/html; charset=utf-8"},
		{"/en/docs/faq", "FAQ-EN", "text/html; charset=utf-8"},
		// for search engines and AI assistants (claude-fleet#3585), the address filled in
		{"/robots.txt", "User-agent: *\nDisallow: /app/\nSitemap: https://hub.example.com/sitemap.xml", "text/plain; charset=utf-8"},
		{"/sitemap.xml", `<?xml version="1.0"?><urlset><url><loc>https://hub.example.com/</loc>`, "application/xml; charset=utf-8"},
		{"/llms.txt", "# ClaudeFleet\n- [FAQ](https://hub.example.com/en/docs/faq.md)", "text/plain; charset=utf-8"},
		{"/llms-zh.txt", "# ClaudeFleet\n- [常见问题](https://hub.example.com/docs/faq.md)", "text/plain; charset=utf-8"},
		{"/llms-full.txt", "# ClaudeFleet — full documentation\nSource: https://hub.example.com/docs/faq", "text/plain; charset=utf-8"},
	} {
		rec := do(http.MethodGet, c.path, nil)
		if rec.Code != http.StatusOK || !strings.HasPrefix(rec.Body.String(), c.body) || rec.Header().Get("Content-Type") != c.ctype {
			t.Errorf("GET %s = %d %q %q; want 200 %q %q", c.path, rec.Code, rec.Header().Get("Content-Type"), rec.Body.String(), c.ctype, c.body)
		}
		if strings.Contains(rec.Body.String(), siteOrigin) || rec.Header().Get("X-Robots-Tag") != "" {
			t.Errorf("GET %s: placeholder left or not indexable: %q robots %q", c.path, rec.Body.String(), rec.Header().Get("X-Robots-Tag"))
		}
		if head := do(http.MethodHead, c.path, nil); head.Code != http.StatusOK || head.Body.Len() != 0 {
			t.Errorf("HEAD %s = %d, %d bytes; want 200, none", c.path, head.Code, head.Body.Len())
		}
	}
	// A browser that takes gzip gets the pages gzip'd; a font stays as it is.
	for path, want := range map[string]string{"/en/": "hub.example.com/x\">en<", "/docs/faq": "FAQ-ZH", "/site/fonts/a-latin.woff2": ""} {
		enc := ""
		if want != "" {
			enc = "gzip"
		}
		req := httptest.NewRequest(http.MethodGet, path, nil)
		req.Header.Set("Accept-Encoding", "gzip, br")
		rec := httptest.NewRecorder()
		h.srv.Handler().ServeHTTP(rec, req)
		if got := rec.Header().Get("Content-Encoding"); got != enc {
			t.Errorf("GET %s (gzip ok): Content-Encoding %q; want %q", path, got, enc)
		}
		if enc != "" {
			zr, err := gzip.NewReader(rec.Body)
			if err != nil {
				t.Fatalf("GET %s: %v", path, err)
			}
			if b, _ := io.ReadAll(zr); !bytes.Contains(b, []byte(want)) {
				t.Errorf("GET %s: gunzipped %q", path, b)
			}
		}
	}
	for path, to := range map[string]string{
		"/en": "/en/", "/docs?x=1": "/docs/?x=1", "/en/docs": "/en/docs/", "/docs/admin": "/docs/admin/",
	} {
		if rec := do(http.MethodGet, path, nil); rec.Code != http.StatusMovedPermanently || rec.Header().Get("Location") != to {
			t.Errorf("GET %s = %d → %q; want 301 → %s", path, rec.Code, rec.Header().Get("Location"), to)
		}
	}
	for _, path := range []string{
		"/site/index.html", "/site/en/index.html", "/site/build.json", "/site/.gitkeep", "/site/../index.html",
		"/site/nope.png", "/site/robots.txt", "/site/llms.txt", "/docs/nope", "/docs/nope.md", "/en/docs/admin/", "/docs/a//b",
	} {
		if rec := do(http.MethodGet, path, nil); rec.Code != http.StatusNotFound {
			t.Errorf("GET %s = %d; want 404", path, rec.Code)
		}
	}
	// Signed in: / is the console, /en/ and the docs stay readable.
	if rec := do(http.MethodGet, "/", admin); rec.Code != http.StatusFound || rec.Header().Get("Location") != AppPrefix {
		t.Errorf("signed-in / = %d → %q; want 302 → /app", rec.Code, rec.Header().Get("Location"))
	}
	if rec := do(http.MethodGet, "/en/", admin); rec.Code != http.StatusOK {
		t.Errorf("signed-in /en/ = %d; want 200", rec.Code)
	}
	// The site's try button opens the console until the try page exists (C20).
	if rec := do(http.MethodGet, AppPrefix+"/try?from=site", nil); rec.Code != http.StatusFound || rec.Header().Get("Location") != AppPrefix+"?from=site" {
		t.Errorf("GET /app/try = %d → %q; want 302 → /app?from=site", rec.Code, rec.Header().Get("Location"))
	}
}

// With the site off — a self-hoster's hub — or a write, none of the site's
// paths is answered by it: each is exactly what the hub answered before.
func TestSitePathsOffAddNothing(t *testing.T) {
	h, admin, _ := rolesHarness(t)
	h.srv.SiteFS, h.srv.DocsFS = siteFixture()
	bare := h.srv.logRequests(h.srv.readOnlyGate(h.srv.routes()))
	mounted := h.srv.Handler()
	paths := []string{"/en", "/en/", "/favicon.ico", "/favicon.svg", "/apple-touch-icon.png",
		"/site/og/cover-zh.png", "/docs", "/docs/", "/docs/faq", "/en/docs/faq",
		"/robots.txt", "/sitemap.xml", "/llms.txt", "/llms-zh.txt", "/llms-full.txt"}
	for _, site := range []bool{false, true} {
		h.srv.Site = site
		for _, p := range paths {
			for _, method := range []string{http.MethodGet, http.MethodPost} {
				if site && method == http.MethodGet {
					continue
				}
				for _, sess := range []*http.Cookie{nil, admin} {
					do := func(hd http.Handler) *httptest.ResponseRecorder {
						req := httptest.NewRequest(method, p, nil)
						if sess != nil {
							req.AddCookie(sess)
						}
						rec := httptest.NewRecorder()
						hd.ServeHTTP(rec, req)
						return rec
					}
					a, b := do(bare), do(mounted)
					if a.Code != b.Code || !bytes.Equal(sansNow(a.Body.Bytes()), sansNow(b.Body.Bytes())) || a.Header().Get("Location") != b.Header().Get("Location") {
						t.Errorf("site=%v %s %s (signed in %v): %d %.60q mounted, %d %.60q bare", site, method, p, sess != nil, b.Code, b.Body.String(), a.Code, a.Body.String())
					}
				}
			}
		}
	}
}
