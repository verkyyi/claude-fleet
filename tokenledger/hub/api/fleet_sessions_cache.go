package api

import "net/http"

// FleetSessions always builds from current state. A database revision alone
// cannot invalidate time-based availability or every external scope input.
// Keep the indexed history lookup, without delaying actions or status changes
// behind a response TTL. Authentication and scope resolution run on every read.
func (s *Server) FleetSessions(req *http.Request) (map[string]any, error) {
	p, err := s.FleetPrincipal(req)
	if err != nil {
		return nil, err
	}
	return s.buildFleetSessions(req, p)
}
