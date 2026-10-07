package api

import (
	"encoding/json"
	"errors"
	"io"
	"log"
	"net/http"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// 从入口移掉一台电脑 (claude-fleet#1928, EPIC #2140 C6).
//
// The operator's revoke (#1403, fleet_node_revoke.go) kills a machine's
// token, but leaves its roster row: the machine stays on /nodes as lost
// forever, which is right for a machine that may come back and wrong for one
// whose person changed computers, left, or was a drill's. Before this the
// only way to drop it was `ccquota endpoint retire` inside the hub's pod.
// Two roads now end in the same retire — the revoke's, plus the roster row:
//
//   - POST /v1/fleet/nodes/retire {endpoint_id[, reason]} — an admin (or the
//     operator's door) retires any machine; a user only one FleetScope says
//     is theirs, anything else is 403 (not found included, so the answer never
//     says what exists). The machines page's 「移除」 calls it.
//   - POST /v1/node/leave [{reason}] — a node retires ITSELF with its own
//     enrollment token: `fleet node leave` (bin/fleet-node-leave.sh), which
//     then stops the agent and deletes node.env.
//
// Both write the revoke's one fleet_audit row (node_revoke, endpoint:<id>)
// under who asked; a second call answers already=true and records nothing.

// NodeRetirePath is the person's (and admin's) route; NodeLeavePath a node's.
const (
	NodeRetirePath = "/v1/fleet/nodes/retire"
	NodeLeavePath  = "/v1/node/leave"
)

// NodeRetireResponse is NodeRevokeResponse plus whether the roster row went.
type NodeRetireResponse struct {
	NodeRevokeResponse
	// Removed: the machine's roster row was dropped — it is off /nodes.
	Removed bool `json:"removed"`
}

// retireNode is the one retire both roads run: the token, its passes, its
// open link and relay credential (the revoke's), then the roster row.
func (s *Server) retireNode(ep *store.Endpoint, actor, reason string, now time.Time) (NodeRetireResponse, error) {
	out := NodeRetireResponse{NodeRevokeResponse: NodeRevokeResponse{EndpointID: ep.ID, Label: ep.Label}}
	// Identity first: the roster row it reads from is about to go.
	out.Hostname, out.OSUser = s.nodeIdentity(ep)
	res, err := s.Store.RetireEndpointAs(ep.ID, actor, reason, now)
	if err != nil {
		return out, err
	}
	out.Already, out.Passes = !res.Retired, res.Passes
	out.Relay, out.LinkClosed = s.revokeNodeRest(ep, now, true)
	if s.nodeRow(ep.ID) != nil {
		if err := s.Store.DeleteNode(ep.ID); err != nil {
			log.Printf("node %s: retire: drop roster row: %v", ep.ID, err)
		} else {
			out.Removed = true
		}
	}
	return out, nil
}

func (s *Server) handleNodeRetire(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		httpError(w, http.StatusMethodNotAllowed, "POST only")
		return
	}
	var req NodeRevokeRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 16<<10)).Decode(&req); err != nil {
		httpError(w, http.StatusBadRequest, "malformed request: "+err.Error())
		return
	}
	req.EndpointID = strings.TrimSpace(req.EndpointID)
	if req.EndpointID == "" {
		httpError(w, http.StatusBadRequest, "endpoint_id is required")
		return
	}
	if len(req.Reason) > 200 {
		httpError(w, http.StatusBadRequest, "reason is at most 200 bytes")
		return
	}
	p, err := s.FleetPrincipal(r)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	mine := seesAll(r)
	ep, err := s.Store.EndpointByID(req.EndpointID)
	if errors.Is(err, store.ErrNoSuchEndpoint) {
		if mine {
			httpError(w, http.StatusNotFound, "no such endpoint")
		} else {
			httpError(w, http.StatusForbidden, "不是你的电脑（not your machine）")
		}
		return
	}
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if !mine {
		host, osUser := s.nodeIdentity(ep)
		mine = osUser != "" && p.sees(host, osUser)
	}
	if !mine {
		httpError(w, http.StatusForbidden, "不是你的电脑（not your machine）")
		return
	}
	out, err := s.retireNode(ep, p.Actor, req.Reason, time.Now())
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleNodeLeave(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		httpError(w, http.StatusMethodNotAllowed, "POST only")
		return
	}
	ep, ok := s.nodeEndpoint(w, r)
	if !ok {
		return
	}
	var req struct {
		Reason string `json:"reason"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4<<10)).Decode(&req); err != nil && !errors.Is(err, io.EOF) {
		httpError(w, http.StatusBadRequest, "the body must be one JSON object")
		return
	}
	reason := strings.TrimSpace(req.Reason)
	if len(reason) > 200 {
		httpError(w, http.StatusBadRequest, "reason is at most 200 bytes")
		return
	}
	host, osUser := s.nodeIdentity(ep)
	actor := "node:" + ep.ID
	if osUser != "" && host != "" {
		actor = "node:" + osUser + "@" + firstLabel(host)
	}
	out, err := s.retireNode(ep, actor, reason, time.Now())
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, out)
}
