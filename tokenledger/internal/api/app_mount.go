package api

import (
	"context"
	"io/fs"
	"net/http"
	"strings"
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
//     /fleet/login*, /mcp, /badge, /embed, the app's own files — passes
//     through untouched (TestClientPathsUnchanged).

// AppPrefix is where the console is mounted.
const AppPrefix = "/app"

// appPagePaths are the console's pages, by their path under AppPrefix ("/" is
// /app itself, the overview).
var appPagePaths = map[string]bool{
	"/": true, "/usage": true, "/quota": true, "/sessions": true, TasksPagePath: true,
	"/machines": true, "/connect": true, "/config": true, "/nodes": true,
	"/subscriptions": true, "/subscriptions/settings": true,
	"/admin/users": true, "/admin/settings": true, "/admin/audit": true, feedbackPagePath: true,
	"/admin/sessions": true, "/admin/overview": true, "/admin/devices": true,
	"/signin": true, "/logout": true,
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
		switch {
		case p == AppPrefix || strings.HasPrefix(p, AppPrefix+"/"):
			w.Header().Set("X-Robots-Tag", "noindex, nofollow")
			inner := strings.TrimPrefix(p, AppPrefix)
			if inner == "" || inner == "/" {
				inner = "/"
			}
			if !isAppPage(inner) {
				http.NotFound(w, r)
				return
			}
			r2 := r.WithContext(context.WithValue(r.Context(), appMountedKey{}, true))
			u := *r.URL
			u.Path, u.RawPath = inner, ""
			r2.URL = &u
			next.ServeHTTP(w, r2)
		case p == "/":
			s.serveRoot(w, r)
		case isAppPage(p) && (r.Method == http.MethodGet || r.Method == http.MethodHead):
			http.Redirect(w, r, withQuery(AppPrefix+p, r), http.StatusMovedPermanently)
		default:
			next.ServeHTTP(w, r)
		}
	})
}

// serveRoot answers "/": the public site for someone signed out while the
// site is on, else the console. The gate decides who is signed in — a
// ?token= link is moved into its cookie on the way, as on every page, so the
// token never rides on into /app's address.
func (s *Server) serveRoot(w http.ResponseWriter, r *http.Request) {
	toApp := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, withQuery(AppPrefix, r), http.StatusFound)
	})
	signedOut := s.serveSite
	if !s.Site {
		signedOut = func(w http.ResponseWriter, r *http.Request) bool { toApp(w, r); return true }
	}
	s.withPageLang(s.viewerOr(toApp, signedOut)).ServeHTTP(w, r)
}

// serveSite is the public site's front page: SiteFS's index.html when the
// hub carries the built site (web/site, C14), else the landing page this hub
// has always drawn for a stranger. Cacheable: it holds nothing of anyone's.
func (s *Server) serveSite(w http.ResponseWriter, r *http.Request) bool {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		return false
	}
	if s.SiteFS != nil {
		if b, err := fs.ReadFile(s.SiteFS, "index.html"); err == nil {
			w.Header().Set("Content-Type", "text/html; charset=utf-8")
			w.Header().Set("Cache-Control", "public, max-age=300")
			w.Header().Add("Vary", "Cookie")
			if r.Method != http.MethodHead {
				_, _ = w.Write(b)
			}
			return true
		}
	}
	return s.serveLanding(w, r)
}
