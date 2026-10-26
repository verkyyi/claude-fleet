package api

import (
	"net/http"
	"sync"
	"time"
)

const sessionListTTL = 3 * time.Second

type sessionListKey struct {
	actor, person, role string
	own, all            bool
}
type sessionListEntry struct {
	sync.Mutex
	revision int64
	until    time.Time
	body     map[string]any
}
type sessionListCache struct {
	sync.Mutex
	entries map[sessionListKey]*sessionListEntry
}

// FleetSessions authenticates on every request. The cache is per person AND
// view/scope; an administrator's own list never shares everyone's answer.
func (s *Server) FleetSessions(req *http.Request) (map[string]any, error) {
	// Read before resolving account scope too: a grant revoked between the
	// scope read and the build must not be cached under the newer revision.
	before, err := s.Store.FleetSessionsRevision()
	if err != nil {
		return nil, err
	}
	p, err := s.FleetPrincipal(req)
	if err != nil {
		return nil, err
	}
	// Custom scope providers may depend on request fields outside this key.
	if s.fleetScopeHook != nil {
		return s.buildFleetSessions(req, p)
	}
	key := sessionListKey{p.Actor, p.Person, string(roleOf(req.Context())), isOwnView(req.Context()), p.All()}
	c := &s.sessionListCache
	c.Lock()
	if c.entries == nil {
		c.entries = make(map[sessionListKey]*sessionListEntry)
	}
	entry := c.entries[key]
	if entry == nil {
		// Bounded even if many one-off principals visit. In-flight readers retain
		// their entry pointer; eviction cannot race with their build.
		if len(c.entries) >= 256 {
			clear(c.entries)
		}
		entry = &sessionListEntry{}
		c.entries[key] = entry
	}
	c.Unlock()
	entry.Lock()
	defer entry.Unlock() // collapse simultaneous tabs/streams
	revision, err := s.Store.FleetSessionsRevision()
	if err != nil {
		return nil, err
	}
	if entry.body != nil && entry.revision == revision && time.Now().Before(entry.until) {
		return copySessionList(entry.body), nil
	}
	body, err := s.buildFleetSessions(req, p)
	if err != nil {
		return nil, err
	}
	after, err := s.Store.FleetSessionsRevision()
	if err != nil {
		return nil, err
	}
	// Never cache a build that straddled a committed write, or an incomplete board.
	_, boardExpected := boardOwner(req.Context(), p)
	_, boardPresent := body["board"]
	if before == revision && after == revision && (!boardExpected || boardPresent) {
		entry.body = body
		entry.revision = revision
		entry.until = time.Now().Add(sessionListTTL)
	}
	return copySessionList(body), nil
}

// Nested rows are read-only snapshots. Give callers their own outer envelope
// so adding response metadata does not alter the cached answer.
func copySessionList(body map[string]any) map[string]any {
	out := make(map[string]any, len(body))
	for k, v := range body {
		out[k] = v
	}
	return out
}
