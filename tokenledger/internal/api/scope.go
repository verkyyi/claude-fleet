// internal/api/scope.go
package api

import (
	"net/http"
	"time"

	"github.com/verkyyi/ccquota/internal/store"
)

// scope resolves the subscription, the range and the drill-down chips of a
// Review request. Malformed times are a 400: silently substituting a default
// range for a typo is how a dashboard shows the wrong week with confidence.
//
// The range is widened to whole hours because the rollup cannot split one.
func (s *Server) scope(w http.ResponseWriter, r *http.Request) (store.Filter, bool) {
	if _, ok := querySource(w, r); !ok {
		return store.Filter{}, false
	}
	account, ok := s.requireAccount(w, r)
	if !ok {
		return store.Filter{}, false
	}
	q := r.URL.Query()
	now := time.Now().UTC()
	end := now
	if v := q.Get("until"); v != "" {
		t, ok := parseWhen(v, now)
		if !ok {
			httpError(w, http.StatusBadRequest, "until: want RFC3339 or a relative duration like 7d")
			return store.Filter{}, false
		}
		end = t
	}
	start := end.Add(-defaultRange)
	if v := q.Get("since"); v != "" {
		t, ok := parseWhen(v, now)
		if !ok {
			httpError(w, http.StatusBadRequest, "since: want RFC3339 or a relative duration like 7d")
			return store.Filter{}, false
		}
		start = t
	}
	if !start.Before(end) {
		httpError(w, http.StatusBadRequest, "since must be before until")
		return store.Filter{}, false
	}
	f := store.Filter{
		Account: account, Start: start, End: end,
		Endpoint: q.Get("endpoint"), OSUser: q.Get("user"), CWD: q.Get("project"),
		Model: q.Get("model"), Branch: q.Get("branch"), Team: q.Get("team"), Session: q.Get("session"),
		Source: q.Get("source"),
	}
	return f.AlignHours(), true
}

func wantsCompare(r *http.Request) bool { return r.URL.Query().Get("compare") == "1" }
