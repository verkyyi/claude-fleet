package api

import (
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"sort"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// A node's type (claude-fleet#4886): managed — a login of a 托管 machine or a
// cluster pod, where the fleet runs tasks — or client, a person's terminal
// that only connects, looks and opens windows. The join code sets it (a 托管
// code and a login the hub opened: managed; a plain code and a device's own
// `fleet login`: client); the operator changes it here. A row from before
// #4886 holds "" until the operator writes the backfill this route proposes.
//
//	GET  /v1/fleet/nodes/role   every roster login: its role and the proposal
//	POST /v1/fleet/nodes/role   {"endpoint_id": "...", "role": "managed|client|"}
//
// Admin only; every write is one fleet_audit row (node_role, endpoint:<id>).

// NodeRolePath is the operator's route.
const NodeRolePath = "/v1/fleet/nodes/role"

// NodeRoleRow is one login on the roster with its role and what the backfill
// would write: managed when its machine runs a node program or already has a
// managed login, client otherwise.
type NodeRoleRow struct {
	EndpointID string `json:"endpoint_id"`
	Hostname   string `json:"hostname"`
	OSUser     string `json:"os_user"`
	Status     string `json:"status"`
	Role       string `json:"role"`
	Proposed   string `json:"proposed"`
	Why        string `json:"why"`
}

// proposeNodeRoles is the backfill: by fact, never by name — a machine with
// its own node program (machine link) or a login already typed managed (a 托管
// machine, a cluster pod) is managed whole; every other login is a client.
func proposeNodeRoles(nodes []NodeView) []NodeRoleRow {
	managed := map[string]string{}
	for _, n := range nodes {
		switch {
		case n.MachineLink:
			managed[n.Hostname] = "machine runs a node program"
		case n.Role == store.NodeRoleManaged && managed[n.Hostname] == "":
			managed[n.Hostname] = "a login there is managed"
		}
	}
	out := make([]NodeRoleRow, 0, len(nodes))
	for _, n := range nodes {
		row := NodeRoleRow{EndpointID: n.EndpointID, Hostname: n.Hostname, OSUser: n.OSUser,
			Status: n.Status, Role: n.Role, Proposed: store.NodeRoleClient, Why: "no node program, no managed login"}
		if why, ok := managed[n.Hostname]; ok {
			row.Proposed, row.Why = store.NodeRoleManaged, why
		}
		out = append(out, row)
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Hostname != out[j].Hostname {
			return out[i].Hostname < out[j].Hostname
		}
		return out[i].OSUser < out[j].OSUser
	})
	return out
}

func (s *Server) handleNodeRole(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	switch r.Method {
	case http.MethodGet:
		snap, err := s.Nodes(time.Now())
		if err != nil {
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"nodes": proposeNodeRoles(snap.Nodes)})
	case http.MethodPost:
		var req struct {
			EndpointID string `json:"endpoint_id"`
			Role       string `json:"role"`
		}
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4<<10)).Decode(&req); err != nil {
			httpError(w, http.StatusBadRequest, "malformed request: "+err.Error())
			return
		}
		req.EndpointID = strings.TrimSpace(req.EndpointID)
		if req.EndpointID == "" {
			httpError(w, http.StatusBadRequest, "endpoint_id is required")
			return
		}
		if !store.ValidNodeRole(req.Role) {
			httpError(w, http.StatusBadRequest, "role: managed, client or empty")
			return
		}
		old := s.endpointRole(req.EndpointID)
		if err := s.Store.SetEndpointRole(req.EndpointID, req.Role); errors.Is(err, store.ErrNoSuchEndpoint) {
			httpError(w, http.StatusNotFound, "no such live endpoint")
			return
		} else if err != nil {
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
		if old != req.Role {
			what := "ROLE " + orDash(old) + " → " + orDash(req.Role)
			if err := s.Store.FleetAudit(actorOf(r), "node_role", "endpoint:"+req.EndpointID, what, "", time.Now()); err != nil {
				log.Printf("node role audit: %v", err)
			}
		}
		writeJSON(w, http.StatusOK, map[string]any{"endpoint_id": req.EndpointID, "role": req.Role, "was": old})
	default:
		w.Header().Set("Allow", "GET, POST")
		httpError(w, http.StatusMethodNotAllowed, "GET or POST")
	}
}

func orDash(s string) string {
	if s == "" {
		return "-"
	}
	return s
}
