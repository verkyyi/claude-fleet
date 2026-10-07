package api

import (
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
)

// The route list `fleet connect` measures (claude-fleet#1414).
//
// A machine's ways in come from two places: CCQUOTA_FLEET_ROUTES, the
// operator's static list, and each node's heartbeat (control.Heartbeat.Routes
// — its tailnet name, the public port the gateway forwards to it). The static
// list is read first, so the operator's default stays first and a name it
// gives wins over the same name a node advertises; a node's routes add to it,
// and a machine the static list never mentions appears as soon as it says
// how to reach it. The relay (#1413) is not a route here — it is a flag per
// machine, true while an agent there can carry one.

// routesClockSkew is how far a signed request's timestamp may be from the
// hub's clock. Replaying one inside that window only re-reads the signer's own
// route list.
const routesClockSkew = 5 * time.Minute

// fleetMachines is the merged machine list: CCQUOTA_FLEET_ROUTES, then the
// admin's fleet.routes_extra (claude-fleet#1986), then what the nodes
// advertise.
func (s *Server) fleetMachines() []FleetMachine {
	out := make([]FleetMachine, 0, len(s.FleetRoutes))
	idx := map[string]int{}
	for _, m := range append(append([]FleetMachine(nil), s.FleetRoutes...), s.routesExtra()...) {
		if i, ok := idx[m.Hostname]; ok {
			// The same machine again: its new routes join, by name.
			have := map[string]bool{}
			for _, r := range out[i].Routes {
				have[r.Name] = true
			}
			for _, r := range m.Routes {
				if !have[r.Name] {
					out[i].Routes = append(out[i].Routes, r)
				}
			}
			if out[i].Alias == "" {
				out[i].Alias = m.Alias
			}
			continue
		}
		m.Routes = append([]FleetRoute(nil), m.Routes...)
		idx[m.Hostname] = len(out)
		out = append(out, m)
	}
	if s.Store == nil {
		return out
	}
	rows, err := s.Store.Nodes()
	if err != nil {
		log.Printf("fleet routes: read the node roster: %v", err)
		return out
	}
	for _, n := range rows {
		var hb struct {
			Routes []control.NodeRoute `json:"routes"`
		}
		if json.Unmarshal([]byte(n.StatusJSON), &hb) != nil || len(hb.Routes) == 0 || !sshToken(n.Hostname) {
			continue
		}
		i, ok := idx[n.Hostname]
		if !ok {
			i = len(out)
			idx[n.Hostname] = i
			out = append(out, FleetMachine{Hostname: n.Hostname})
		}
		have := map[string]bool{}
		for _, r := range out[i].Routes {
			have[r.Name] = true
		}
		for _, r := range hb.Routes {
			// A heartbeat is the node's word, not the operator's: it goes
			// into ssh configs, so it is held to the same tokens.
			if have[r.Name] || !sshToken(r.Name) || !sshToken(r.Host) || r.Port < 0 || r.Port > 65535 {
				continue
			}
			have[r.Name] = true
			out[i].Routes = append(out[i].Routes, FleetRoute{Name: r.Name, Host: r.Host, Port: r.Port})
		}
	}
	return out
}

// sshRelayReady reports whether a relay to host could be carried right now.
func (s *Server) sshRelayReady(host string) bool {
	s.nodes.mu.Lock()
	defer s.nodes.mu.Unlock()
	for _, c := range s.nodes.conns {
		if c.canSSHRelay && c.hostname() == host && control.Compatible(int(c.proto.Load())) {
			return true
		}
	}
	return false
}

// RoutesRequest proves a connection certificate: Sig is `ssh-keygen -Y sign
// -n fleet-routes@claude-fleet` over control.RoutesSigMessage(TS) by the
// certificate's key.
type RoutesRequest struct {
	Cert string `json:"cert"`
	Sig  string `json:"sig"`
	TS   int64  `json:"ts"`
}

// RouteMachine is one machine in the route list.
type RouteMachine struct {
	FleetMachine
	// Relay is true while an agent there can carry a relay through the hub.
	Relay bool `json:"relay"`
}

// RoutesResponse is the body of control.RoutesPath.
type RoutesResponse struct {
	Hub string `json:"hub"`
	// Login is the person's login on their machines ("" for the operator,
	// who brings their own).
	Login    string         `json:"login,omitempty"`
	Machines []RouteMachine `json:"machines"`
}

// handleFleetRoutes serves control.RoutesPath: the machines the caller may
// reach and every way in. Admitted like the relay: the operator's doors or a
// WeCom session over HTTP (GET or POST), or a connection certificate proven by
// a signed timestamp (POST RoutesRequest) — the one `fleet connect` holds.
func (s *Server) handleFleetRoutes(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodPost {
		w.Header().Set("Allow", "GET, POST")
		httpError(w, http.StatusMethodNotAllowed, "GET or POST")
		return
	}
	id, ok := s.sshRelayHTTPIdentity(r)
	if !ok {
		var req RoutesRequest
		if r.Method == http.MethodPost {
			_ = json.NewDecoder(http.MaxBytesReader(w, r.Body, 64<<10)).Decode(&req)
		}
		if req.Cert == "" || req.Sig == "" {
			w.Header().Set("WWW-Authenticate", `Bearer realm="ccquota"`)
			httpError(w, http.StatusUnauthorized, "a session, a viewer token or a connection certificate is required")
			return
		}
		now := time.Now()
		if d := now.Sub(time.Unix(req.TS, 0)); d > routesClockSkew || d < -routesClockSkew {
			httpError(w, http.StatusUnauthorized, "the signed timestamp is too far from the hub's clock — check this computer's time")
			return
		}
		var err error
		if id, err = s.verifySSHRelayCert(req.Cert, req.Sig, control.RoutesSigMessage(req.TS), control.RoutesSigNamespace, now); err != nil {
			var re *sshRelayError
			if errors.As(err, &re) {
				httpError(w, http.StatusUnauthorized, re.msg)
				return
			}
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
	}
	out := RoutesResponse{Hub: s.hubURL(r), Machines: []RouteMachine{}}
	var hosts map[string]bool
	if !id.Operator {
		p, _, h, err := s.fleetLoginsOf(id.Principal)
		switch {
		case errors.Is(err, errNoAccount):
			httpError(w, http.StatusForbidden, err.Error())
			return
		case err != nil:
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
		out.Login, hosts = p.Login, h
	}
	for _, m := range s.fleetMachines() {
		if hosts != nil && !hosts[m.Hostname] {
			continue
		}
		out.Machines = append(out.Machines, RouteMachine{FleetMachine: m, Relay: s.sshRelayReady(m.Hostname)})
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, out)
}
