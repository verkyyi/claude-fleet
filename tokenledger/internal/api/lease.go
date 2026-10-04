package api

import (
	"encoding/json"
	"net/http"
	"strings"
	"sync"
	"time"
)

type quotaLease struct {
	Owner string
	Until time.Time
}
type quotaLeases struct {
	mu     sync.Mutex
	values map[string]quotaLease
}

// A short lease suppresses duplicate active polling across machines. Passive
// transcript observations remain independent. A hub restart just forgets leases.
func (s *Server) handleQuotaLease(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		httpError(w, 405, "POST required")
		return
	}
	ep, err := s.Store.EndpointByTokenHash(HashToken(bearer(r)))
	if bearer(r) == "" || err != nil {
		httpError(w, 401, "unrecognised enrollment token")
		return
	}
	var body struct {
		Account string `json:"account_uuid"`
		Profile string `json:"profile_id"`
		Seconds int    `json:"seconds"`
	}
	if json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&body) != nil || !strings.HasPrefix(body.Account, "codex:account:") || body.Profile == "" {
		httpError(w, 400, "Codex account and profile required")
		return
	}
	now := time.Now()
	owner := ep.ID + "/" + body.Profile
	s.quotaLeases.mu.Lock()
	defer s.quotaLeases.mu.Unlock()
	if s.quotaLeases.values == nil {
		s.quotaLeases.values = map[string]quotaLease{}
	}
	for k, v := range s.quotaLeases.values {
		if !v.Until.After(now) {
			delete(s.quotaLeases.values, k)
		}
	}
	prev := s.quotaLeases.values[body.Account]
	granted := prev.Owner == "" || prev.Owner == owner
	if granted {
		s.quotaLeases.values[body.Account] = quotaLease{Owner: owner, Until: now.Add(time.Duration(min(max(body.Seconds, 180), 900)) * time.Second)}
	}
	writeJSON(w, 200, map[string]any{"granted": granted})
}
