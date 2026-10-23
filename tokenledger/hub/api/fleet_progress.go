package api

import (
	"encoding/json"
	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"net/http"
	"strconv"
)

const progressPullLimit = 500

// compat-1v: 下一批删 — old internal callers may finish, without creating
// parent progress streams. Historical records remain available through GET.
func (s *Server) progressReport(store.FleetRelay) {}
func (s *Server) progressOp(store.FleetOperation) {}

// handleNodeProgress serves authenticated historical data only. The legacy
// ops query is ignored; a read cannot reconcile operations or expire records.
func (s *Server) handleNodeProgress(w http.ResponseWriter, r *http.Request) {
	ep, ok := s.nodeEndpoint(w, r)
	if !ok {
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", "GET")
		httpError(w, http.StatusMethodNotAllowed, "GET")
		return
	}
	q := r.URL.Query()
	since, _ := strconv.ParseInt(q.Get("since"), 10, 64)
	rows, err := s.Store.Fleets()
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	var fleets []string
	for _, f := range rows {
		if f.EndpointID == ep.ID {
			fleets = append(fleets, f.FleetID)
		}
	}
	evs, err := s.Store.FleetProgressSince(fleets, since, progressPullLimit)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	out := make([]map[string]any, 0, len(evs))
	last := since
	for _, e := range evs {
		out = append(out, map[string]any{"seq": e.Seq, "rid": e.RID, "parent": e.Parent, "kind": e.Kind,
			"state": e.State, "event": json.RawMessage(e.Body)})
		last = e.Seq
	}
	writeJSON(w, http.StatusOK, map[string]any{"events": out, "seq": last})
}
