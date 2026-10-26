package api

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"testing/fstest"
)

// The sandbox edition (task PNWW, CCQUOTA_SITE=sandbox): "/" is the build's
// sandbox/index.html (English), /zh/ its 中文 page, /en/ sent on to /, the
// pages' files are never served as assets — and every other path of the site
// is what the default edition answers. With the edition unset, / and /en/ are
// the default pages, byte for byte.
func TestSiteSandboxEdition(t *testing.T) {
	h, admin, _ := rolesHarness(t)
	h.srv.Site = true
	site, docs := siteFixture()
	sb := func(lang, word string) *fstest.MapFile {
		return &fstest.MapFile{Data: []byte(`<html lang="` + lang + `"><link rel="canonical" href="__ORIGIN__/"><b>` + word + `</b></html>`)}
	}
	site["sandbox/index.html"] = sb("en", "SANDBOX-EN")
	site["sandbox/zh/index.html"] = sb("zh-CN", "SANDBOX-ZH")
	h.srv.SiteFS, h.srv.DocsFS = site, docs
	h.srv.FleetPublicURL = "https://core.example.com/"
	do := func(p string, sess *http.Cookie) *httptest.ResponseRecorder {
		req := httptest.NewRequest(http.MethodGet, p, nil)
		if sess != nil {
			req.AddCookie(sess)
		}
		rec := httptest.NewRecorder()
		h.srv.Handler().ServeHTTP(rec, req)
		return rec
	}

	// the default edition: / and /en/ are the default pages, no sandbox anywhere
	for p, want := range map[string]string{"/": `<html lang="zh-CN">`, "/en/": `<html lang="en">`} {
		if rec := do(p, nil); rec.Code != http.StatusOK || !strings.HasPrefix(rec.Body.String(), want) || strings.Contains(rec.Body.String(), "SANDBOX") {
			t.Errorf("default GET %s = %d %q; want the default page", p, rec.Code, rec.Body.String())
		}
	}
	if rec := do("/zh/", nil); strings.Contains(rec.Body.String(), "SANDBOX") {
		t.Errorf("default GET /zh/ served the sandbox page")
	}
	others := []string{"/terms", "/en/privacy", "/docs/faq", "/en/docs/", "/robots.txt", "/llms.txt", "/site/og/cover-zh.png", "/favicon.svg"}
	before := map[string]string{}
	for _, p := range others {
		before[p] = do(p, nil).Body.String()
	}

	h.srv.SiteEdition = SiteEditionSandbox
	for _, c := range []struct{ path, lang, word string }{{"/", "en", "SANDBOX-EN"}, {"/zh/", "zh-CN", "SANDBOX-ZH"}} {
		rec := do(c.path, nil)
		if rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), c.word) || rec.Header().Get("Content-Language") != c.lang ||
			rec.Header().Get("Content-Security-Policy") != siteCSP || !strings.Contains(rec.Body.String(), `href="https://core.example.com/"`) {
			t.Errorf("sandbox GET %s = %d %q (lang %q); want 200, %s, the address filled in", c.path, rec.Code, rec.Body.String(), rec.Header().Get("Content-Language"), c.word)
		}
	}
	// signed in, / is still the page (its nav then says Open console)
	if rec := do("/", admin); rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), "SANDBOX-EN") {
		t.Errorf("sandbox signed-in / = %d; want 200 and the sandbox page", rec.Code)
	}
	for p, to := range map[string]string{"/en/": "/", "/en": "/", "/en/?x=1": "/?x=1", "/zh": "/zh/"} {
		if rec := do(p, nil); rec.Code != http.StatusMovedPermanently || rec.Header().Get("Location") != to {
			t.Errorf("sandbox GET %s = %d → %q; want 301 → %s", p, rec.Code, rec.Header().Get("Location"), to)
		}
	}
	for _, p := range []string{"/site/sandbox/index.html", "/site/sandbox/zh/index.html", "/site/sandbox/x.png"} {
		if rec := do(p, nil); rec.Code != http.StatusNotFound {
			t.Errorf("sandbox GET %s = %d; want 404", p, rec.Code)
		}
	}
	for _, p := range others {
		if got := do(p, nil).Body.String(); got != before[p] {
			t.Errorf("sandbox GET %s = %.80q; want what the default edition answers %.80q", p, got, before[p])
		}
	}
	// a build with no sandbox page: / never falls back to the default (China) page
	delete(site, "sandbox/index.html")
	if rec := do("/", nil); rec.Code == http.StatusOK && strings.Contains(rec.Body.String(), `lang="zh-CN"`) {
		t.Errorf("sandbox with no sandbox page: / served the default page")
	}
}

// Architecture follows the host edition; docs retain their established languages.
func TestSiteArchitecture(t *testing.T) {
	h, _, _ := rolesHarness(t)
	h.srv.Site = true
	site, docs := siteFixture()
	for name, text := range map[string]string{
		"architecture/index.html":            "ARCH-ZH",
		"en/architecture/index.html":         "ARCH-EN",
		"sandbox/architecture/index.html":    "SANDBOX-ARCH-EN",
		"sandbox/zh/architecture/index.html": "SANDBOX-ARCH-ZH",
	} {
		site[name] = &fstest.MapFile{Data: []byte(text)}
	}
	docs["zh/assets/architecture.svg"] = &fstest.MapFile{Data: []byte("<svg><title>Architecture</title></svg>")}
	h.srv.SiteFS, h.srv.DocsFS = site, docs
	for _, c := range []struct{ edition, path, text, lang string }{
		{"", "/architecture", "ARCH-ZH", "zh-CN"},
		{"", "/en/architecture", "ARCH-EN", "en"},
		{SiteEditionSandbox, "/architecture", "SANDBOX-ARCH-EN", "en"},
		{SiteEditionSandbox, "/zh/architecture", "SANDBOX-ARCH-ZH", "zh-CN"},
		{SiteEditionSandbox, "/docs/assets/architecture.svg", "<svg>", "zh"},
	} {
		h.srv.SiteEdition = c.edition
		rec := httptest.NewRecorder()
		h.srv.Handler().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, c.path, nil))
		if rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), c.text) || rec.Header().Get("Content-Language") != c.lang {
			t.Errorf("%s %s: %d %q (%s)", c.edition, c.path, rec.Code, rec.Body.String(), rec.Header().Get("Content-Language"))
		}
		if strings.HasSuffix(c.path, ".svg") && rec.Header().Get("Content-Type") != "image/svg+xml" {
			t.Error("diagram must be served as SVG")
		}
	}
	// A portal changes only its front pages, not the blueprint's asset path.
	h.srv.PortalURL = "https://portal.example.com"
	for _, path := range []string{"/architecture", "/zh/architecture"} {
		rec := httptest.NewRecorder()
		h.srv.Handler().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, h.srv.PortalURL+path, nil))
		if rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), "SANDBOX-ARCH-") {
			t.Errorf("portal %s: %d %q; want the architecture page", path, rec.Code, rec.Body.String())
		}
	}
	delete(site, "sandbox/architecture/index.html")
	rec := httptest.NewRecorder()
	h.srv.Handler().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/architecture", nil))
	if rec.Code != http.StatusNotFound {
		t.Errorf("missing sandbox architecture: %d, want 404", rec.Code)
	}
}
