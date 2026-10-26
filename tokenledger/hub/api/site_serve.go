package api

import (
	"bytes"
	"compress/gzip"
	"io/fs"
	"net/http"
	"path"
	"strings"
)

// The public website's own paths (claude-fleet#3584, EPIC #3569 C14).
//
// bin/site-build.sh writes the site — / in 中文, /en/ in English — and
// bin/docs-build.sh the documentation; both are embedded (web.Site, web.Docs)
// and served only while the site is on (CCQUOTA_SITE=on, our own hub). With it
// off — a self-hoster's default — none of these paths is answered here and
// each falls through exactly as before.
//
//	/            the 中文 page for someone signed out (serveSite, app_mount.go)
//	/en/         the English page (/en → 301 /en/)
//	/site/<f>    its assets: fonts, share cards, icons
//	/terms /privacy /en/terms /en/privacy   the user agreement and the privacy
//	             policy (T883), <p>/index.html of the build
//	/favicon.ico /favicon.svg /apple-touch-icon.png   what a browser asks the root for
//	/docs/<p>    docs zh/<p>.html (<p>/ → <p>/index.html, <p>.md → the Markdown)
//	/en/docs/<p> the same in English
//	/robots.txt /sitemap.xml /llms.txt /llms-zh.txt /llms-full.txt
//	             for search engines and AI assistants (claude-fleet#3585, C15),
//	             each with this hub's address filled in like a page
//
// With CCQUOTA_SITE=sandbox (task PNWW) / and /zh/ are the sandbox edition's
// front pages instead and /en/ is sent on to / — see SiteEditionSandbox.
//
// With fleet.trial off (claude-fleet#4269) a page and an llms file are the
// build's apply/ copy — the same with no trial in it, every 「立即体验」 a
// 「申请使用」 — when the build has one; on, the page as it always was.
//
// A page's absolute addresses (canonical, hreflang, og:url, JSON-LD) are built
// with the placeholder siteOrigin and become this hub's address (hubURL) as
// the page is served, so no hub's address is written in the repo. The
// replay's address bar says siteHost: the same address without its scheme.

const (
	siteOrigin = "__ORIGIN__"
	siteHost   = "__HOST__"
)

// The sandbox edition (task PNWW, CCQUOTA_SITE=sandbox): another front page,
// the Claude Code sandbox runtime — the build's sandbox/index.html (English)
// at /, sandbox/zh/index.html (中文) at /zh/, and /en/ sent on to /. Every
// other path of the site is the same as the default edition's.
const (
	SiteEditionSandbox = "sandbox"
	siteSandboxDir     = "sandbox/"
)

// siteSandbox: r's edition is the sandbox one — CCQUOTA_SITE_HOSTS's for its
// host, else CCQUOTA_SITE's (edge.go).
func (s *Server) siteSandbox(r *http.Request) bool { return s.siteEditionFor(r) == SiteEditionSandbox }

// siteFront is the build's front page for "/" and its language.
func (s *Server) siteFront(r *http.Request) (name, lang string) {
	if s.siteSandbox(r) {
		if s.portalHost(r) && localeOfPage(r) == "zh-CN" {
			return siteSandboxDir + "zh/index.html", "zh-CN"
		}
		return siteSandboxDir + "index.html", "en"
	}
	return "index.html", "zh-CN"
}

// siteFill puts this hub's address where the build left its placeholders.
func (s *Server) siteFill(r *http.Request, b []byte) []byte {
	o := s.hubURL(r)
	b = bytes.ReplaceAll(b, []byte(siteOrigin), []byte(o))
	if i := strings.Index(o, "://"); i >= 0 {
		o = o[i+3:]
	}
	return bytes.ReplaceAll(b, []byte(siteHost), []byte(o))
}

// siteCSP: the pages load nothing from anywhere else.
const siteCSP = "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; connect-src 'self'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'"

var siteTypes = map[string]string{
	".woff2": "font/woff2",
	".png":   "image/png",
	".ico":   "image/x-icon",
	".svg":   "image/svg+xml",
	".txt":   "text/plain; charset=utf-8",
	".md":    "text/markdown; charset=utf-8",
	".html":  "text/html; charset=utf-8",
	".xml":   "application/xml; charset=utf-8",
}

// siteCrawlFiles are the build's files a crawler asks the root for
// (bin/site-build.sh writes them, claude-fleet#3585); each is answered at
// /<name> only, never under /site/.
var siteCrawlFiles = map[string]bool{
	"robots.txt": true, "sitemap.xml": true,
	"llms.txt": true, "llms-zh.txt": true, "llms-full.txt": true,
}

// siteLegalPages are the legal pages' paths (T883) and each one's language.
var siteLegalPages = map[string]string{
	"/terms": "zh", "/privacy": "zh", "/en/terms": "en", "/en/privacy": "en",
}

// serveSitePath answers the site's paths above (true), or leaves r alone
// (false): the site is off, the method is not a read, or the path is not one
// of them.
func (s *Server) serveSitePath(w http.ResponseWriter, r *http.Request) bool {
	if !s.Site || (r.Method != http.MethodGet && r.Method != http.MethodHead) {
		return false
	}
	p := r.URL.Path
	switch {
	case p == "/architecture" || p == "/zh/architecture" || p == "/en/architecture":
		lang, name := "zh-CN", "architecture/index.html"
		if s.siteSandbox(r) {
			lang, name = "en", "sandbox/architecture/index.html"
			if p == "/zh/architecture" {
				lang, name = "zh-CN", "sandbox/zh/architecture/index.html"
			} else if p == "/en/architecture" {
				http.Redirect(w, r, withQuery("/architecture", r), http.StatusMovedPermanently)
				return true
			}
		} else if p == "/en/architecture" {
			lang, name = "en", "en/architecture/index.html"
		} else if p == "/zh/architecture" {
			http.Redirect(w, r, withQuery("/architecture", r), http.StatusMovedPermanently)
			return true
		}
		if !s.sitePage(w, r, name, lang) {
			http.NotFound(w, r)
		}
	case s.siteSandbox(r) && (p == "/en" || p == "/en/"):
		// the sandbox page is English at / itself
		http.Redirect(w, r, withQuery("/", r), http.StatusMovedPermanently)
	case s.siteSandbox(r) && p == "/zh":
		http.Redirect(w, r, withQuery("/zh/", r), http.StatusMovedPermanently)
	case s.siteSandbox(r) && p == "/zh/":
		if s.portalHost(r) {
			setLangCookie(w, r, "zh-CN")
		}
		if !s.sitePage(w, r, siteSandboxDir+"zh/index.html", "zh-CN") {
			http.NotFound(w, r)
		}
	case p == "/en" || p == "/docs" || p == "/en/docs":
		http.Redirect(w, r, withQuery(p+"/", r), http.StatusMovedPermanently)
	case p == "/en/":
		if !s.sitePage(w, r, "en/index.html", "en") {
			http.NotFound(w, r)
		}
	case siteLegalPages[p] != "":
		if !s.sitePage(w, r, strings.TrimPrefix(p, "/")+"/index.html", siteLegalPages[p]) {
			http.NotFound(w, r)
		}
	case p == "/favicon.ico" || p == "/apple-touch-icon.png":
		s.siteIcon(w, r, strings.TrimPrefix(p, "/"))
	case siteCrawlFiles[strings.TrimPrefix(p, "/")]:
		s.siteCrawlFile(w, r, strings.TrimPrefix(p, "/"))
	case p == "/favicon.svg":
		s.siteIcon(w, r, "logo.svg")
	case strings.HasPrefix(p, "/site/"):
		s.siteAsset(w, r, strings.TrimPrefix(p, "/site/"))
	case strings.HasPrefix(p, "/docs/"):
		s.serveDoc(w, r, "zh", strings.TrimPrefix(p, "/docs/"))
	case strings.HasPrefix(p, "/en/docs/"):
		s.serveDoc(w, r, "en", strings.TrimPrefix(p, "/en/docs/"))
	default:
		return false
	}
	return true
}

// siteApplyDir holds the build's pages with no trial (claude-fleet#4269).
const siteApplyDir = "apply/"

// siteRead reads a page or crawl file of the site: the apply/ copy while
// fleet.trial is off and the build has one, else the file itself.
func (s *Server) siteRead(name string) ([]byte, error) {
	if !s.trialOn() {
		if b, err := fs.ReadFile(s.SiteFS, siteApplyDir+name); err == nil {
			return b, nil
		}
	}
	return fs.ReadFile(s.SiteFS, name)
}

// sitePage serves one of the site's pages, its origin filled in; false when
// this hub carries no such page.
func (s *Server) sitePage(w http.ResponseWriter, r *http.Request, name, lang string) bool {
	if s.SiteFS == nil {
		return false
	}
	// Only the two front pages have portal-specific builds. Shared pages such
	// as architecture keep their edition paths on the portal host too.
	if s.portalHost(r) && (name == siteSandboxDir+"index.html" || name == siteSandboxDir+"zh/index.html") {
		name = "portal/" + name
	}
	b, err := s.siteRead(name)
	if err != nil {
		return false
	}
	b = s.siteFill(r, b)
	h := w.Header()
	h.Set("Content-Type", "text/html; charset=utf-8")
	h.Set("Content-Language", lang)
	h.Set("Cache-Control", "public, max-age=300")
	if s.portalHost(r) {
		h.Set("Cache-Control", "private, no-cache")
		h.Add("Vary", "Accept-Language, Cookie")
	}
	h.Set("Content-Security-Policy", siteCSP)
	h.Set("X-Content-Type-Options", "nosniff")
	writeSiteBody(w, r, b, true)
	return true
}

// siteCrawlFile serves robots.txt, sitemap.xml or an llms file with this
// hub's address in place of the placeholder; 404 when the build has none.
func (s *Server) siteCrawlFile(w http.ResponseWriter, r *http.Request, name string) {
	if s.SiteFS == nil {
		http.NotFound(w, r)
		return
	}
	b, err := s.siteRead(name)
	if err != nil {
		http.NotFound(w, r)
		return
	}
	b = s.siteFill(r, b)
	h := w.Header()
	h.Set("Content-Type", siteTypes[path.Ext(name)])
	h.Set("Cache-Control", "public, max-age=3600")
	h.Set("X-Content-Type-Options", "nosniff")
	writeSiteBody(w, r, b, true)
}

// siteAsset serves a file of the site that is not a page; anything else under
// /site/ is 404.
func (s *Server) siteAsset(w http.ResponseWriter, r *http.Request, name string) {
	ext := path.Ext(name)
	if s.SiteFS == nil || !fs.ValidPath(name) || ext == ".html" || ext == ".json" || siteCrawlFiles[name] || strings.HasPrefix(name, siteApplyDir) || strings.HasPrefix(name, siteSandboxDir) || strings.HasPrefix(name, "portal/") || strings.HasPrefix(path.Base(name), ".") {
		http.NotFound(w, r)
		return
	}
	age := "86400"
	if ext == ".woff2" {
		age = "604800"
	}
	serveFSFile(w, r, s.SiteFS, name, "public, max-age="+age)
}

// siteIcon serves a root tab icon of the site (/favicon.ico, /favicon.svg,
// /apple-touch-icon.png) with appIconCache.
func (s *Server) siteIcon(w http.ResponseWriter, r *http.Request, name string) {
	if s.SiteFS == nil {
		http.NotFound(w, r)
		return
	}
	serveFSFile(w, r, s.SiteFS, name, appIconCache(r))
}

// appIconCache: a versioned icon URL (?v=AppIconV, what every page names) never
// changes, so it is kept a year; the bare path — what a browser asks for on its
// own, Safari first among them, and keeps for good once it has it — is fetched
// again every time, so a new logo reaches it on the next visit. An icon is a
// few KB.
func appIconCache(r *http.Request) string {
	if r.URL.Query().Get("v") != "" {
		return "public, max-age=31536000, immutable"
	}
	return "no-cache"
}

// serveDoc serves the documentation page rest of lang: "" and "<dir>/" are
// that directory's index, "<p>.md" the page's Markdown, "<p>" its HTML — and a
// bare directory name is sent on to "<dir>/".
func (s *Server) serveDoc(w http.ResponseWriter, r *http.Request, lang, rest string) {
	if s.DocsFS == nil || strings.Contains(rest, "//") {
		http.NotFound(w, r)
		return
	}
	var name string
	switch {
	case rest == "" || strings.HasSuffix(rest, "/"):
		name = lang + "/" + rest + "index.html"
	case strings.HasSuffix(rest, ".md") || (strings.HasPrefix(rest, "assets/") && strings.HasSuffix(rest, ".svg")):
		name = lang + "/" + rest
	default:
		name = lang + "/" + rest + ".html"
		if _, err := fs.Stat(s.DocsFS, name); err != nil {
			if _, err := fs.Stat(s.DocsFS, lang+"/"+rest+"/index.html"); err == nil {
				http.Redirect(w, r, withQuery(r.URL.Path+"/", r), http.StatusMovedPermanently)
				return
			}
		}
	}
	if !fs.ValidPath(name) {
		http.NotFound(w, r)
		return
	}
	w.Header().Set("Content-Language", lang)
	w.Header().Set("Content-Security-Policy", siteCSP)
	serveFSFile(w, r, s.DocsFS, name, "public, max-age=300")
}

// serveFSFile writes one file of fsys with its type and cache header, or 404.
func serveFSFile(w http.ResponseWriter, r *http.Request, fsys fs.FS, name, cache string) {
	b, err := fs.ReadFile(fsys, name)
	if err != nil {
		http.NotFound(w, r)
		return
	}
	ct := siteTypes[path.Ext(name)]
	if ct == "" {
		ct = "application/octet-stream"
	}
	h := w.Header()
	h.Set("Content-Type", ct)
	h.Set("Cache-Control", cache)
	h.Set("X-Content-Type-Options", "nosniff")
	writeSiteBody(w, r, b, strings.HasPrefix(ct, "text/") || ct == "image/svg+xml")
}

// writeSiteBody writes b — gzip'd when it is text and the browser takes gzip:
// a page is a third of its size on a phone's slow link, where the first paint
// waits on it.
func writeSiteBody(w http.ResponseWriter, r *http.Request, b []byte, text bool) {
	if text {
		w.Header().Add("Vary", "Accept-Encoding")
	}
	if !text || !strings.Contains(r.Header.Get("Accept-Encoding"), "gzip") {
		if r.Method != http.MethodHead {
			_, _ = w.Write(b)
		}
		return
	}
	w.Header().Set("Content-Encoding", "gzip")
	if r.Method == http.MethodHead {
		return
	}
	zw, _ := gzip.NewWriterLevel(w, gzip.BestCompression)
	_, _ = zw.Write(b)
	_ = zw.Close()
}

// appIconPaths are what a page's <link rel="icon"> names and a browser asks
// the root for; web/dist carries each, a copy of extras/fleet-theme/logo.svg
// and site/assets
// (claude-fleet#3946, web/embed_test.go holds the copies to it).
// AppIconV is the first 8 hex of extras/fleet-theme/logo.svg's sha256, put on
// every page's icon links (`/favicon.svg?v=…`) so a browser that keys its icon
// cache by URL — Safari keeps a favicon for weeks — fetches a new icon at once.
// The paths themselves never change; TestAppIconVersion holds it to the file.
const AppIconV = "8ecf46d0"

var appIconPaths = []string{"/favicon.svg", "/favicon.ico", "/apple-touch-icon.png"}

// serveAppIcon answers one of appIconPaths from the console's own files,
// with no sign-in: an icon tells a stranger nothing.
func (s *Server) serveAppIcon(w http.ResponseWriter, r *http.Request) {
	if s.UI == nil || (r.Method != http.MethodGet && r.Method != http.MethodHead) {
		http.NotFound(w, r)
		return
	}
	serveFSFile(w, r, s.UI, strings.TrimPrefix(r.URL.Path, "/"), appIconCache(r))
}
