package api

import (
	"context"
	"encoding/json"
	"log"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/fleetid"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// One progress stream per parent (claude-fleet#1648, EPIC #1645 C5).
//
// What a parent hears about a child the hub placed on another machine is
// appended to fleet_progress under the parent's worker_id: every change of
// the worker_start operation (accepted → running → done | refused | failed)
// and every child_report relay (WAITING with its PR, MERGED, REAPED, …). The
// parent's machine pulls it (GET /v1/node/progress) into its children
// ledger, so a placement never stays «accepted» there and a report the push
// missed still lands — the hub's copy is the one both machines agree on.
//
//	GET /v1/node/progress?since=<seq>[&ops=<op id>,…]
//	  → {"events": [{seq, rid, parent, kind, state, event}], "seq": <last>}
//
// A node reads only the streams of the fleets it reports. `ops` names the
// placements its ledger still holds open (accepted / running / unknown): the
// hub asks their machine once more, so a start nobody waited on — an --async
// spawn — reaches its final state, and that state is in the same answer.

const (
	progressPullLimit = 500
	progressMaxOps    = 50
	// progressOpsWait bounds the reconciles one pull may do.
	progressOpsWait = 8 * time.Second
)

var progressOpRE = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)

// progressAppend stores one event, logging (never failing the caller) when
// the store refuses.
func (s *Server) progressAppend(parent, kind, state, rid string, ev map[string]any, at time.Time) {
	fid, _, err := fleetid.ParseWorkerID(parent)
	if err != nil {
		return
	}
	ev["rid"] = rid
	b, _ := json.Marshal(ev)
	if _, err := s.Store.AppendFleetProgress(store.FleetProgress{RID: rid, Parent: parent, FleetID: fid,
		Kind: kind, State: state, Body: string(b), Created: at}); err != nil {
		log.Printf("fleet progress %s: %v", rid, err)
	}
}

// progressReport appends a child_report relay to its parent's stream: the
// report as the parent's ledger row reads it, minus the envelope.
func (s *Server) progressReport(r store.FleetRelay) {
	if r.Kind != control.RelayChildReport {
		return
	}
	var p map[string]any
	if json.Unmarshal([]byte(r.Payload), &p) != nil {
		return
	}
	ev := map[string]any{"child_wid": r.FromWID}
	for _, k := range []string{"child", "state", "pr", "verdict", "summary", "title", "tier"} {
		if v, ok := p[k].(string); ok {
			ev[k] = v
		}
	}
	if from, err := s.Store.Fleet(fleetOf(r.FromWID)); err == nil {
		ev["node"] = shortNode(from.Hostname)
	}
	st, _ := ev["state"].(string)
	s.progressAppend(r.ToWID, store.ProgressReport, strings.ToUpper(st), r.ID, ev, r.Created)
}

// progressOp appends a worker_start operation's state to the stream of the
// worker that asked for it (its origin_wid). A start with no parent, and the
// states that say nothing yet (pending, an unacknowledged unknown), add
// nothing.
func (s *Server) progressOp(o store.FleetOperation) {
	if o.Action != "worker_start" {
		return
	}
	var req struct {
		Params map[string]any `json:"params"`
	}
	if json.Unmarshal([]byte(o.Request), &req) != nil {
		return
	}
	parent, _ := req.Params["origin_wid"].(string)
	if parent == "" {
		return
	}
	node := ""
	if f, err := s.Store.Fleet(o.FleetID); err == nil {
		node = nodeLabel(f.Hostname)
	}
	ev := map[string]any{"op": o.ID, "node": node}
	if repo, ok := req.Params["repo"].(string); ok {
		ev["repo"] = repo
	}
	switch n := req.Params["issue"].(type) {
	case float64:
		ev["issue"] = strconv.Itoa(int(n))
	case string:
		ev["issue"] = n
	}
	if k, _ := req.Params["kind"].(string); k == "scratch" {
		ev["kind"] = "scratch"
	}
	var state string
	switch o.Status {
	case "accepted", "running":
		state = o.Status
	case "succeeded", "failed":
		oc := outcomeOf(operationView(o), node)
		state = oc.State
		if oc.Window != "" {
			ev["window"] = oc.Window
		}
		if oc.Exit != nil {
			ev["exit"] = *oc.Exit
		}
		if oc.Stderr != "" {
			ev["line"] = clip(oc.Stderr, 200)
		}
	default:
		return
	}
	ev["state"] = state
	s.progressAppend(parent, store.ProgressDispatch, state, "op:"+o.ID+":"+state, ev, o.Updated)
}

// handleNodeProgress serves GET /v1/node/progress.
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
	mine := map[string]bool{}
	var fleets []string
	for _, f := range rows {
		if f.EndpointID == ep.ID {
			mine[f.FleetID] = true
			fleets = append(fleets, f.FleetID)
		}
	}
	if ops := q.Get("ops"); ops != "" {
		s.progressReconcile(r.Context(), strings.Split(ops, ","), mine)
	}
	now := time.Now()
	if n, err := s.Store.ExpireFleetProgress(store.FleetProgressTTL, now); err == nil && n > 0 {
		log.Printf("fleet progress: %d expired after %s", n, store.FleetProgressTTL)
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

// progressReconcile asks the target machine of each named placement for its
// state once more — only a placement asked for by one of the asking node's
// fleets, only while it is not final — and appends whatever changed. A
// final one is appended as it stands, so a ledger that missed it catches up.
func (s *Server) progressReconcile(ctx context.Context, ids []string, mine map[string]bool) {
	ctx, cancel := context.WithTimeout(ctx, progressOpsWait)
	defer cancel()
	for i, id := range ids {
		if i >= progressMaxOps || ctx.Err() != nil {
			return
		}
		if !progressOpRE.MatchString(id) {
			continue
		}
		o, err := s.Store.FleetOperation(id)
		if err != nil || o.Action != "worker_start" {
			continue
		}
		var req struct {
			Params map[string]any `json:"params"`
		}
		_ = json.Unmarshal([]byte(o.Request), &req)
		parent, _ := req.Params["origin_wid"].(string)
		if !mine[fleetOf(parent)] {
			continue
		}
		if o.Status != "succeeded" && o.Status != "failed" {
			if err := s.reconcileOperation(ctx, &o); err != nil {
				continue
			}
		}
		s.progressOp(o)
	}
}
