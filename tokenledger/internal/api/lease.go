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
	// Since is when Owner took the lease; Good the last complete account read
	// (app_server) it delivered. A holder that delivers none for
	// quotaLeaseFailAfter is not renewed (claude-fleet#2169).
	Since time.Time
	Good  time.Time
}
type quotaLeases struct {
	mu     sync.Mutex
	values map[string]quotaLease
	// benched: account → owner → until. A collector that kept failing is
	// not granted that account's lease again before then.
	benched map[string]map[string]time.Time
}

const (
	// quotaLeaseFailures is how many failed reads in a row a collector
	// reports before it gives its lease up (the agent sends the count).
	quotaLeaseFailures = 3
	// quotaLeaseFailAfter: a holder whose lease delivered no complete read
	// for this long (or two lease terms, if longer) is not renewed — an older agent that cannot say it is
	// failing (a protocol error -32603 every poll) still lets go.
	quotaLeaseFailAfter = 15 * time.Minute
	// quotaLeaseBench is how long a dropped holder waits before it may hold
	// that account's lease again.
	quotaLeaseBench = 30 * time.Minute
)

// A short lease suppresses duplicate active polling across machines. Passive
// transcript observations remain independent. A hub restart just forgets leases.
//
// A holder that keeps failing does not keep it (claude-fleet#2169): one that
// reports `failures` ≥ quotaLeaseFailures, or delivered no complete read for
// quotaLeaseFailAfter, loses the lease and is benched for quotaLeaseBench, so
// another online collector takes the account over.
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
		Account  string `json:"account_uuid"`
		Profile  string `json:"profile_id"`
		Seconds  int    `json:"seconds"`
		Failures int    `json:"failures"`
	}
	if json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&body) != nil || !strings.HasPrefix(body.Account, "codex:account:") || body.Profile == "" {
		httpError(w, 400, "Codex account and profile required")
		return
	}
	granted := s.quotaLeaseGrant(body.Account, ep.ID+"/"+body.Profile, body.Seconds, body.Failures, time.Now())
	writeJSON(w, 200, map[string]any{"granted": granted})
}

func (s *Server) quotaLeaseGrant(account, owner string, seconds, failures int, now time.Time) bool {
	l := &s.quotaLeases
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.values == nil {
		l.values = map[string]quotaLease{}
	}
	if l.benched == nil {
		l.benched = map[string]map[string]time.Time{}
	}
	for k, v := range l.values {
		if !v.Until.After(now) {
			delete(l.values, k)
		}
	}
	for a, m := range l.benched {
		for o, until := range m {
			if !until.After(now) {
				delete(m, o)
			}
		}
		if len(m) == 0 {
			delete(l.benched, a)
		}
	}
	dur := time.Duration(min(max(seconds, 180), 900)) * time.Second
	prev := l.values[account]
	if prev.Owner == owner {
		last := prev.Since
		if prev.Good.After(last) {
			last = prev.Good
		}
		if failures >= quotaLeaseFailures || now.Sub(last) > max(quotaLeaseFailAfter, 2*dur) {
			delete(l.values, account)
			if l.benched[account] == nil {
				l.benched[account] = map[string]time.Time{}
			}
			l.benched[account][owner] = now.Add(quotaLeaseBench)
			return false
		}
	}
	// A benched collector waits out its bench; after it, it may try again
	// (it may be the only one there is) and a further failure benches it anew.
	if !l.benched[account][owner].IsZero() {
		return false
	}
	if prev.Owner != "" && prev.Owner != owner {
		return false
	}
	next := quotaLease{Owner: owner, Until: now.Add(dur), Since: prev.Since, Good: prev.Good}
	if prev.Owner == "" {
		next.Since = now
	}
	l.values[account] = next
	return true
}

// quotaLeaseDelivered notes a complete account read an endpoint delivered,
// so its lease of that account counts as working.
func (s *Server) quotaLeaseDelivered(account, endpoint string, at time.Time) {
	l := &s.quotaLeases
	l.mu.Lock()
	defer l.mu.Unlock()
	v, ok := l.values[account]
	if !ok || !strings.HasPrefix(v.Owner, endpoint+"/") {
		return
	}
	if at.After(v.Good) {
		v.Good = at
		l.values[account] = v
	}
}
