package api

import "net/http"

// ApplyPath is where a person not on the list asks to be let in
// (claude-fleet#4049, EPIC #4048). Until its page lands (C3) it is a stub:
// signed out it sends the person to sign in first, with ?next=/apply so the
// page says so; signed in it sends a member to the console.
const ApplyPath = "/apply"

// applyNext is the one ?next= the sign-in page recognises: a fixed match,
// so the page never reflects a query string.
const applyNext = ApplyPath

// toApply: /signin was reached on the way to apply.
func toApply(r *http.Request) bool { return r.URL.Query().Get("next") == applyNext }

// handleApply is /apply's stub. Public: a signed-out person must reach it.
func (s *Server) handleApply(w http.ResponseWriter, r *http.Request) {
	if !s.signinOn() {
		http.NotFound(w, r)
		return
	}
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Allow", "GET")
		httpError(w, http.StatusMethodNotAllowed, "GET only")
		return
	}
	if _, pid, ok := s.personSession(r); ok {
		if role, err := s.personRole(pid); err == nil && role != "" {
			http.Redirect(w, r, AppPrefix, http.StatusFound)
			return
		}
	}
	http.Redirect(w, r, appURL("/signin")+"?next="+applyNext, http.StatusFound)
}
