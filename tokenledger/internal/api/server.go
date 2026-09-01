// Package api serves the hub: endpoint ingest, the dashboard's query API, the
// dashboard itself, and the MCP endpoint.
//
// All four live in one process on one port so a self-hoster deploys one thing.
package api

import (
	"io/fs"
	"log"
	"net/http"
	"strings"
	"time"

	"github.com/verkyyi/ccquota/internal/store"
)

// Server is the hub's HTTP surface.
type Server struct {
	Store   *store.Store
	Pricing *Pricing

	// ViewerToken guards the dashboard, the query API and MCP. Endpoint
	// ingest uses per-endpoint enrollment tokens instead.
	ViewerToken string

	// LimitsPollIntervalS is echoed to agents so a noisy fleet can be backed
	// off centrally without touching every machine.
	LimitsPollIntervalS int

	// UI is the built dashboard, or nil when the binary was built without one.
	UI fs.FS

	// MCP handles /mcp when wired up.
	MCP http.Handler

	// LiveStore holds the seconds-scale view of running sessions. In memory
	// only: it describes this minute, and a restart legitimately knows nothing
	// until the agents report again.
	LiveStore *Live
}

// Handler builds the router.
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()

	// Ingest authenticates per endpoint, so it is deliberately outside the
	// viewer-token gate.
	mux.HandleFunc("/v1/ingest", s.handleIngest)
	// Live reports authenticate per endpoint, like ingest.
	mux.HandleFunc("/v1/live/report", s.handleLiveReport)

	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	})

	mux.Handle("/v1/accounts", s.viewerOnly(http.HandlerFunc(s.handleAccounts)))
	mux.Handle("/v1/limits", s.viewerOnly(http.HandlerFunc(s.handleLimits)))
	mux.Handle("/v1/endpoints", s.viewerOnly(http.HandlerFunc(s.handleEndpoints)))
	mux.Handle("/v1/usage", s.viewerOnly(http.HandlerFunc(s.handleUsage)))
	mux.Handle("/v1/history", s.viewerOnly(http.HandlerFunc(s.handleHistory)))
	mux.Handle("/v1/account-switches", s.viewerOnly(http.HandlerFunc(s.handleSwitches)))
	mux.Handle("/v1/endpoint-accounts", s.viewerOnly(http.HandlerFunc(s.handleEndpointAccounts)))
	mux.Handle("/v1/accounts/label", s.viewerOnly(http.HandlerFunc(s.handleAccountLabel)))
	mux.Handle("/v1/live", s.viewerOnly(http.HandlerFunc(s.handleLiveSnapshot)))
	mux.Handle("/v1/live/stream", s.viewerOnly(http.HandlerFunc(s.handleLiveStream)))

	if s.MCP != nil {
		mux.Handle("/mcp", s.viewerOnly(s.MCP))
	}

	mux.Handle("/", s.viewerOnly(http.HandlerFunc(s.serveUI)))

	return logRequests(mux)
}

// viewerOnly gates a handler behind the viewer token.
//
// The token may arrive as a bearer header (API and MCP clients) or as a
// `ccquota_token` cookie, which is what lets a browser follow ?token=... once
// and then navigate normally.
func (s *Server) viewerOnly(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if s.ViewerToken == "" {
			// An unset viewer token means the operator explicitly opted out
			// (see the hub's --no-auth flag, which refuses a public bind).
			next.ServeHTTP(w, r)
			return
		}

		if tok := r.URL.Query().Get("token"); tok != "" && constantTimeEqual(tok, s.ViewerToken) {
			// Move the secret out of the URL bar and into a cookie so it stops
			// appearing in browser history, referrers and screenshots.
			http.SetCookie(w, &http.Cookie{
				Name: "ccquota_token", Value: tok, Path: "/",
				HttpOnly: true, SameSite: http.SameSiteLaxMode,
				Secure: r.TLS != nil || strings.EqualFold(r.Header.Get("X-Forwarded-Proto"), "https"),
				MaxAge: 30 * 24 * 3600,
			})
			http.Redirect(w, r, stripToken(r), http.StatusFound)
			return
		}
		if constantTimeEqual(bearer(r), s.ViewerToken) {
			next.ServeHTTP(w, r)
			return
		}
		if c, err := r.Cookie("ccquota_token"); err == nil && constantTimeEqual(c.Value, s.ViewerToken) {
			next.ServeHTTP(w, r)
			return
		}

		w.Header().Set("WWW-Authenticate", `Bearer realm="ccquota"`)
		httpError(w, http.StatusUnauthorized, "a viewer token is required")
	})
}

func stripToken(r *http.Request) string {
	u := *r.URL
	q := u.Query()
	q.Del("token")
	u.RawQuery = q.Encode()
	if u.Path == "" {
		u.Path = "/"
	}
	return u.RequestURI()
}

// serveUI serves the embedded dashboard, falling back to index.html so the SPA
// owns its own routing.
func (s *Server) serveUI(w http.ResponseWriter, r *http.Request) {
	if s.UI == nil {
		writeJSON(w, http.StatusOK, map[string]string{
			"service": "ccquota hub",
			"note":    "this binary was built without the dashboard; the API is at /v1/",
		})
		return
	}

	path := strings.TrimPrefix(r.URL.Path, "/")
	if path == "" {
		path = "index.html"
	}
	f, err := s.UI.Open(path)
	if err != nil {
		f, err = s.UI.Open("index.html")
		if err != nil {
			http.NotFound(w, r)
			return
		}
		path = "index.html"
	}
	defer f.Close()

	st, err := f.Stat()
	if err != nil || st.IsDir() {
		http.NotFound(w, r)
		return
	}
	rs, ok := f.(interface {
		Read([]byte) (int, error)
		Seek(int64, int) (int64, error)
	})
	if !ok {
		http.Error(w, "unreadable asset", http.StatusInternalServerError)
		return
	}
	http.ServeContent(w, r, path, st.ModTime(), rs)
}

// logRequests logs method, path and duration. Query strings are omitted: they
// can carry the viewer token.
func logRequests(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		sw := &statusWriter{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(sw, r)
		log.Printf("%s %s %d %s", r.Method, r.URL.Path, sw.status, time.Since(start).Round(time.Millisecond))
	})
}

type statusWriter struct {
	http.ResponseWriter
	status int
}

func (w *statusWriter) WriteHeader(code int) {
	w.status = code
	w.ResponseWriter.WriteHeader(code)
}

// Flush lets streaming handlers (MCP) work through the wrapper.
func (w *statusWriter) Flush() {
	if f, ok := w.ResponseWriter.(http.Flusher); ok {
		f.Flush()
	}
}
