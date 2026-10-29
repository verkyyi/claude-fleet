package api

import (
	"net/http"
	"strings"
)

// Empty by default. Use immutable principals, never a display name or role.
const StudioPrincipalsKey = "fleet.studio.principals"

func init() {
	hubSettings[StudioPrincipalsKey] = hubSetting{def: "", help: "LivePage studio: comma-separated principal allowlist; empty disables it", check: func(_ *Server, v string) (string, string) {
		return strings.TrimSpace(v), ""
	}}
}

func (s *Server) studioAllowed(r *http.Request) bool {
	if viewAsAsked(r) != "" || viewAsOf(r.Context()) != nil {
		return false
	}
	if sess := sessionOf(r.Context()); sess != nil && sess.RO {
		return false
	}
	p, _, code, _ := s.chatPerson(r)
	if code != "" || p == "" {
		return false
	}
	for _, allowed := range strings.Split(s.setting(StudioPrincipalsKey), ",") {
		if strings.TrimSpace(allowed) == p {
			return true
		}
	}
	return false
}
