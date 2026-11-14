package api

import (
	"mime"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/authz"
)

// cookieWriteGuard: a write that the person's session cookie would
// authenticate must come from this hub's own pages. SameSite=Lax keeps the
// cookie off a cross-site POST, but not off one from another host under the
// same registrable domain; this is the lock for those, in front of every
// route at once.
//
// It applies to a request that is not GET / HEAD / OPTIONS and carries a
// session cookie that verifies. Such a request passes when sameOrigin says
// so (which also passes a client that sends neither Origin nor Referer — the
// CLI holding a session, FLEET_HUB_SESSION), or when it is a JSON request
// the browser itself does not call cross-origin (cookieWriteJSON). A
// request authenticated otherwise — a bearer, the viewer token, a node's
// token or signature, an agent grant — carries no session cookie and is not
// looked at; another replica's hand-over was checked by the replica that
// took it first.
func (s *Server) cookieWriteGuard(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !cookieWriteOK(r) && s.carriesSession(r) && !(s.Replica != nil && s.relayHopped(r)) {
			httpError(w, http.StatusForbidden, "cross-site request refused")
			return
		}
		next.ServeHTTP(w, r)
	})
}

// carriesSession says r carries a person's session cookie that verifies
// (signature and expiry; the list and the cut-offs are the gate's).
func (s *Server) carriesSession(r *http.Request) bool {
	if !s.signinOn() {
		return false
	}
	c, err := r.Cookie(authz.CookieName)
	if err != nil || c.Value == "" {
		return false
	}
	_, err = authz.VerifySession(c.Value, s.sessionKey(), time.Now())
	return err == nil
}

// cookieWriteOK is the rule a cookie-authenticated request is held to.
func cookieWriteOK(r *http.Request) bool {
	switch r.Method {
	case http.MethodGet, http.MethodHead, http.MethodOptions:
		return true
	}
	switch r.Header.Get("Sec-Fetch-Site") {
	case "cross-site", "same-site":
		// the browser's own word: another site, or another host of this one
		return false
	}
	return sameOrigin(r) || cookieWriteJSON(r)
}

// cookieWriteJSON: a JSON body is something a page on another origin cannot
// send without asking first (CORS), and the hub grants no credentialed
// cross-origin request. Taken when the browser says the request is its own
// origin's (Sec-Fetch-Site: same-origin — so a hub behind a proxy that hands
// it another Host keeps its console's fetches), or, from a browser without
// that header, when the Origin / Referer names this host.
func cookieWriteJSON(r *http.Request) bool {
	mt, _, err := mime.ParseMediaType(r.Header.Get("Content-Type"))
	if err != nil || mt != "application/json" {
		return false
	}
	switch r.Header.Get("Sec-Fetch-Site") {
	case "same-origin":
		return true
	case "":
	default:
		return false
	}
	o := r.Header.Get("Origin")
	if o == "" || o == "null" {
		o = r.Header.Get("Referer")
	}
	if o == "" {
		return false
	}
	u, err := url.Parse(o)
	return err == nil && strings.EqualFold(u.Host, r.Host)
}
