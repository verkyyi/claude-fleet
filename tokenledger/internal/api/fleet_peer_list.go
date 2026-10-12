package api

import (
	"errors"
	"net/http"
	"sort"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// The person's other logins, for the standing connections (claude-fleet#3482).
//
// fleet-peerlink.py keeps one ssh master from each login to every OTHER login
// of the same person — the same rule /v1/node/peer-cert signs by
// (peerSameOwner): the owner's active logins on the other machines, or, for a
// login no person owns, the unowned logins of the same name. It used to dial
// a machine by its bare name, which only a tailnet resolves; a machine with
// only its entry port (a cluster machine outside the tailnet) was never
// reached. So the answer carries every way in — the machine's routes as
// `fleet connect` sees them, the entry port the hub reached included
// (withEntryReach) — and the keeper picks.

// PeerLogin is one login of the caller's person on another machine.
type PeerLogin struct {
	Hostname string       `json:"hostname"` // the roster's hostname
	Alias    string       `json:"alias,omitempty"`
	Login    string       `json:"login"`
	Routes   []FleetRoute `json:"routes"`
	// LastSeen is the login's newest heartbeat ("" when it never beat).
	LastSeen string `json:"last_seen,omitempty"`
}

// PeersResponse is the body of GET /v1/node/peers.
type PeersResponse struct {
	Hostname string      `json:"hostname"` // the caller's own machine
	Login    string      `json:"login"`
	Peers    []PeerLogin `json:"peers"`
}

// handleNodePeers serves GET /v1/node/peers, authenticated by the calling
// node's enrollment token: the same person's active logins on other machines.
func (s *Server) handleNodePeers(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", "GET")
		httpError(w, http.StatusMethodNotAllowed, "GET")
		return
	}
	ep, ok := s.nodeEndpoint(w, r)
	if !ok {
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	srcHost, srcUser := s.peerSelf(ep)
	owner, err := s.principalOnNode(ep.ID, srcHost, srcUser)
	if err != nil && !errors.Is(err, store.ErrNoPrincipal) {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	rows, err := s.Store.Nodes()
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	live, err := s.Store.ListEndpoints("")
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	active := map[string]bool{}
	for _, e := range live {
		active[e.ID] = true
	}
	now := time.Now()
	machines := map[string]FleetMachine{}
	for _, m := range s.fleetMachines() {
		machines[strings.ToLower(m.Hostname)] = m
	}
	out := PeersResponse{Hostname: srcHost, Login: srcUser, Peers: []PeerLogin{}}
	seen := map[[2]string]bool{}
	for i := range rows {
		n := &rows[i]
		if !active[n.EndpointID] || n.OSUser == "" || n.Hostname == "" || sameMachine(n.Hostname, srcHost) {
			continue
		}
		k := [2]string{strings.ToLower(n.Hostname), n.OSUser}
		if seen[k] {
			continue
		}
		mine, err := s.peerSameOwner(owner, srcUser, n)
		if err != nil {
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
		if !mine {
			continue
		}
		seen[k] = true
		p := PeerLogin{Hostname: n.Hostname, Login: n.OSUser, Routes: []FleetRoute{}}
		if m, ok := machines[strings.ToLower(n.Hostname)]; ok {
			m = s.withEntryReach(m, now)
			p.Alias = m.Alias
			p.Routes = append(p.Routes, m.Routes...)
		}
		if n.LastHeartbeat != nil {
			p.LastSeen = n.LastHeartbeat.UTC().Format(time.RFC3339)
		}
		out.Peers = append(out.Peers, p)
	}
	sort.SliceStable(out.Peers, func(i, j int) bool {
		if out.Peers[i].Hostname != out.Peers[j].Hostname {
			return out.Peers[i].Hostname < out.Peers[j].Hostname
		}
		return out.Peers[i].Login < out.Peers[j].Login
	})
	writeJSON(w, http.StatusOK, out)
}
