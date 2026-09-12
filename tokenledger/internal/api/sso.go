package api

import (
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/verkyyi/ccquota/internal/authz"
)

// SSO connects this hub to the company's existing WeCom single sign-on.
//
// # Why a ticket rather than an OAuth client here
//
// The WeCom self-built app allows exactly ONE web-authorization callback
// domain for the whole corp, and it does not cover subdomains. That domain is
// ai.24haowan.com. So this host cannot run the OAuth dance itself, and putting
// a proxy in front of it changes nothing — a callback domain is not something a
// proxy gets to move. The platform's answer, already in production for three
// other sites: OAuth completes on ai., a 90-second ticket crosses to this host,
// and this host mints its own host-only cookie.
//
// Zero value (nil *SSO) means "not wired up": /enter answers 404 and nothing
// else changes, so a hub that never configures this behaves exactly as before.
type SSO struct {
	// AppID is our `aud`. A ticket signed for another downstream is refused.
	AppID string
	// Slug is the tenant the gate should enter us as. Attribution only.
	Slug string
	// TicketSecret verifies the authorization service's signature. One key per
	// app, never the session key — the two have different blast radii and
	// different rotation rhythms.
	TicketSecret string
	// SessionSecret signs our own cookie.
	SessionSecret string
	// EnterURL is the authorization endpoint a signed-out browser is sent to.
	EnterURL string
	// TTL is how long our session lasts, unrelated to the ticket's 90 seconds:
	// the ticket's job ends the moment it is exchanged.
	TTL time.Duration
}

func (c *SSO) ready() bool {
	return c != nil && c.AppID != "" && c.TicketSecret != "" && c.SessionSecret != "" && c.EnterURL != ""
}

// ttl falls back to a working day rather than to zero, because a zero TTL would
// mint a cookie that is already expired — a login loop, not a locked door.
func (c *SSO) ttl() time.Duration {
	if c.TTL <= 0 {
		return 8 * time.Hour
	}
	return c.TTL
}

// handleEnter exchanges a ticket for this hub's session cookie.
//
// It is deliberately OUTSIDE viewerOnly: it is the way in. It is also the only
// route that looks at a ticket at all — everywhere else a ticket is just an
// unknown string, which is what keeps its 90-second life meaningful.
//
// There is no `rd` parameter and so no open-redirect surface: the authorization
// service's landing URL is `<origin>/enter?ticket=…` with no destination in it,
// and we send the browser to "/" afterwards.
func (s *Server) handleEnter(w http.ResponseWriter, r *http.Request) {
	if !s.SSO.ready() {
		// A hub that has not configured SSO should look like a hub without the
		// feature, not like one guarding it: 401 would tell a prober there is a
		// login here worth pushing on.
		http.NotFound(w, r)
		return
	}
	p, err := authz.Verify(r.URL.Query().Get("ticket"), s.SSO.TicketSecret, s.SSO.AppID, time.Now())
	if err != nil {
		// One message for every failure. A caller that can tell "wrong key"
		// from "expired" hands that distinction to whoever is probing it.
		httpError(w, http.StatusUnauthorized, "ticket rejected")
		return
	}
	http.SetCookie(w, &http.Cookie{
		Name:  authz.CookieName,
		Value: authz.SignSession(p.Sub, s.SSO.SessionSecret, time.Now(), s.SSO.ttl()),
		Path:  "/",
		// ★ No Domain: host-only. A cookie scoped to the parent domain is a
		// cookie handed to every preview environment and every other app on
		// *.24haowan.com.
		HttpOnly: true,
		SameSite: http.SameSiteLaxMode,
		Secure:   isHTTPS(r),
		MaxAge:   int(s.SSO.ttl().Seconds()),
	})
	http.Redirect(w, r, "/", http.StatusFound)
}

// ssoViewer reports the signed-in human behind this request, if any.
func (s *Server) ssoViewer(r *http.Request) (string, bool) {
	if !s.SSO.ready() {
		return "", false
	}
	c, err := r.Cookie(authz.CookieName)
	if err != nil {
		return "", false
	}
	sess, err := authz.VerifySession(c.Value, s.SSO.SessionSecret, time.Now())
	if err != nil {
		return "", false
	}
	return sess.Sub, true
}

// ssoSignInURL is where a signed-out BROWSER should be sent.
//
// Browsers only. An API or MCP client cannot follow a login redirect, and
// handing it a 302 to a WeCom page replaces a clear "you sent no credential"
// with a page it cannot read. Those callers keep getting 401.
func (s *Server) ssoSignInURL(r *http.Request) (string, bool) {
	if !s.SSO.ready() || !wantsHTML(r) {
		return "", false
	}
	u, err := url.Parse(s.SSO.EnterURL)
	if err != nil {
		return "", false
	}
	q := u.Query()
	q.Set("app", s.SSO.AppID)
	if s.SSO.Slug != "" {
		q.Set("to", s.SSO.Slug)
	}
	u.RawQuery = q.Encode()
	return u.String(), true
}

// wantsHTML distinguishes a browser navigation from an API call.
//
// Navigations send an Accept that prefers HTML; fetch/XHR from our own
// dashboard asks for JSON and would rather have the 401 (it can then show a
// sign-in prompt itself instead of trying to render a login page into a table).
func wantsHTML(r *http.Request) bool {
	if r.Header.Get("X-Requested-With") != "" {
		return false
	}
	return strings.Contains(r.Header.Get("Accept"), "text/html")
}

func isHTTPS(r *http.Request) bool {
	return r.TLS != nil || strings.EqualFold(r.Header.Get("X-Forwarded-Proto"), "https")
}
