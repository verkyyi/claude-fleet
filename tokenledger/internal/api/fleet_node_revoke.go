package api

import (
	"database/sql"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"strings"
	"time"

	"github.com/coder/websocket"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// 收回一台机器的入场证 (claude-fleet#1403, EPIC #1967 R5).
//
// A node speaks for its machine with its enrollment token, and retiring the
// endpoint has always killed that token for every NEW request: every route
// that takes one goes through Store.EndpointByTokenHash, which filters
// retired_at. Three things outlived it, and this file is where they end:
//
//   - the control channel already open — authenticated once, at connect; the
//     node kept beating, placing and relaying on it. The operator's revoke
//     closes it at once, and every message on a link re-reads the token
//     (nodeTokenLive), so a retire from another process (`ccquota endpoint
//     retire` on the hub's database) closes it on the next beat;
//   - the session passes the node issued (claude-fleet#1969) — revoked in
//     the retire's own transaction (Store.RetireEndpointAs);
//   - its relay credential (claude-fleet#1974) — the setting's entry for this
//     login dropped, the relay check's cache reset.
//
// The revoke itself is one fleet_audit row (node_revoke, endpoint:<id>).
// A refused request after it is answered byte for byte like an unknown token
// — each route keeps its own words, the same query decides both — so the
// answer never confirms the token was ever good (internal/api/ingest.go).
// Revocation state stays OFF store.Endpoint on purpose: an authorization
// verdict riding a struct a dozen read paths share is one refactor away from
// being read from the wrong field (the reasoning #43 gave for EnrollKind).
//
// There is no un-revoke, for the reason RetireEndpoint gives: the hash is still
// on the row. Re-enroll the machine (a join code) for a new token.

// NodeRevokePath is the operator's route.
const NodeRevokePath = "/v1/fleet/nodes/revoke"

// NodeRevokeRequest is the body of POST /v1/fleet/nodes/revoke.
type NodeRevokeRequest struct {
	EndpointID string `json:"endpoint_id"`
	Reason     string `json:"reason,omitempty"`
}

// NodeRevokeResponse says what the revoke did.
type NodeRevokeResponse struct {
	EndpointID string `json:"endpoint_id"`
	Label      string `json:"label"`
	Hostname   string `json:"hostname"`
	OSUser     string `json:"os_user"`
	// Already: it was retired before this call; nothing changed.
	Already    bool `json:"already"`
	Passes     int  `json:"passes"`
	Relay      bool `json:"relay"`
	LinkClosed bool `json:"link_closed"`
}

func (s *Server) handleNodeRevoke(w http.ResponseWriter, r *http.Request) {
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
	ep, err := s.Store.EndpointByID(req.EndpointID)
	if errors.Is(err, store.ErrNoSuchEndpoint) {
		httpError(w, http.StatusNotFound, "no such endpoint")
		return
	}
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	now := time.Now()
	res, err := s.Store.RetireEndpointAs(ep.ID, "operator", req.Reason, now)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	out := NodeRevokeResponse{EndpointID: ep.ID, Label: ep.Label, Already: !res.Retired, Passes: res.Passes}
	out.Hostname, out.OSUser = s.nodeIdentity(ep)
	// Already retired: the token was dead, but a link or a relay entry may
	// still have outlived a retire made elsewhere — finishing that is safe.
	out.Relay, out.LinkClosed = s.revokeNodeRest(ep, now, true)
	writeJSON(w, http.StatusOK, out)
}

// revokeNodeRest ends what a retired endpoint left running in THIS process:
// its control link (closeLink — the link's own read loop closes itself
// instead, outside the set's lock), its relay credential, the cached verdicts
// on its passes.
func (s *Server) revokeNodeRest(ep *store.Endpoint, now time.Time, closeLink bool) (relay, linkClosed bool) {
	s.sessCred.drop("")
	host, osUser := s.nodeIdentity(ep)
	if host != "" && osUser != "" {
		if settings, err := s.Store.FleetSettings(); err != nil {
			log.Printf("node %s: revoke: read relay settings: %v", ep.ID, err)
		} else {
			key := relayKey(host)
			entries := relayEntries(settings[key])
			if _, ok := entries[osUser]; ok {
				delete(entries, osUser)
				if err := s.Store.SetFleetSetting(key, relayValue(entries), now); err != nil {
					log.Printf("node %s: revoke: drop relay credential: %v", ep.ID, err)
				} else {
					relay = true
				}
			}
		}
	}
	s.relayCacheReset()
	if closeLink && s.nodes.get(ep.ID) != nil {
		s.nodes.closeRevoked(ep.ID)
		linkClosed = true
	}
	return relay, linkClosed
}

// closeRevoked forgets an endpoint's link and closes it — in the background,
// since a close waits (up to its own timeout) on the peer's answer and the
// operator's call need not. The node's reconnect then meets the connect's 401.
func (n *nodeConns) closeRevoked(id string) {
	n.mu.Lock()
	c := n.conns[id]
	delete(n.conns, id)
	n.mu.Unlock()
	if c != nil {
		go c.conn.Close(websocket.StatusPolicyViolation, "unrecognised enrollment token")
	}
}

// nodeTokenLive re-reads the link's token: false once its endpoint is retired
// (or gone). A read error keeps the link — a busy database is not a revoke.
func (s *Server) nodeTokenLive(hash string) bool {
	_, err := s.Store.EndpointByTokenHash(hash)
	return !errors.Is(err, sql.ErrNoRows)
}
