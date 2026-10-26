package api

import (
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
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
// advertise. A machine's alias is the admin's fleet.machine_names when it
// names it (claude-fleet#1706 — the hub's one place to set the short name
// every client shows), else what the route lists gave.
func (s *Server) fleetMachines() []FleetMachine {
	out := s.fleetMachinesRaw()
	if names := s.machineNames(); len(names) > 0 {
		for i := range out {
			if a := machineAlias(out[i].Hostname, names); a != "" {
				out[i].Alias = a
			}
		}
	}
	return out
}

func (s *Server) fleetMachinesRaw() []FleetMachine {
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
			out[i].HostKeys = append(append([]string(nil), out[i].HostKeys...), m.HostKeys...)
			continue
		}
		m.Routes = append([]FleetRoute(nil), m.Routes...)
		idx[m.Hostname] = len(out)
		out = append(out, m)
	}
	if s.Store == nil {
		return withHostKeys(out, nil)
	}
	rows, err := s.Store.Nodes()
	if err != nil {
		log.Printf("fleet routes: read the node roster: %v", err)
		return withHostKeys(out, nil)
	}
	// A machine's host keys are its NEWEST heartbeat's (claude-fleet#2983):
	// several logins report the same machine, and a login that stopped
	// beating before the machine's keys changed must not keep the old ones
	// trusted.
	keys := map[string][]string{}
	keysAt := map[string]time.Time{}
	for _, n := range rows {
		var hb struct {
			Routes   []control.NodeRoute `json:"routes"`
			HostKeys []string            `json:"host_keys"`
		}
		if json.Unmarshal([]byte(n.StatusJSON), &hb) != nil || !sshToken(n.Hostname) {
			continue
		}
		if hk := control.HostKeys(hb.HostKeys); len(hk) > 0 && n.LastHeartbeat != nil && !n.LastHeartbeat.Before(keysAt[n.Hostname]) {
			keys[n.Hostname], keysAt[n.Hostname] = hk, *n.LastHeartbeat
		}
		if len(hb.Routes) == 0 {
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
			fr := FleetRoute{Name: r.Name, Host: r.Host, Port: r.Port}
			if r.Prefix > 0 && r.Prefix <= 128 {
				fr.Prefix = r.Prefix
			}
			out[i].Routes = append(out[i].Routes, fr)
		}
	}
	return withHostKeys(out, keys)
}

// withHostKeys sets each machine's HostKeys: what the operator's lists gave,
// then what the machine reported (byHost), each held to control.HostKey —
// they end up in a known_hosts file.
func withHostKeys(ms []FleetMachine, byHost map[string][]string) []FleetMachine {
	for i := range ms {
		ms[i].HostKeys = control.HostKeys(append(append([]string(nil), ms[i].HostKeys...), byHost[ms[i].Hostname]...))
	}
	return ms
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
	// Login is the login THIS machine is entered as (claude-fleet#3049):
	// homeLoginFor's answer — the person's login there that has a live fleet,
	// else their account's. Empty for the operator, who brings their own; an
	// older client ignores it and takes RoutesResponse.Login.
	Login string `json:"login,omitempty"`
	// Status and SeenAt are the machine's life as the roster has it (task KEA0:
	// `fleet shell --list`): online · maintenance · lost, and the newest heartbeat
	// of an agent there — the person's own login's when one answers. Empty when
	// the roster has no agent of that machine; an older client ignores both.
	Status string     `json:"status,omitempty"`
	SeenAt *time.Time `json:"seen_at,omitempty"`
}

// RoutesResponse is the body of control.RoutesPath.
type RoutesResponse struct {
	Hub string `json:"hub"`
	// Login is the person's login on their machines ("" for the operator,
	// who brings their own).
	Login    string         `json:"login,omitempty"`
	Machines []RouteMachine `json:"machines"`
	// Disabled are machines where the person keeps a login that their
	// machine allowlist leaves out (claude-fleet#3824): never a route, only
	// the reason a client names when the person asks for one.
	Disabled []DisabledMachine `json:"disabled,omitempty"`
}

// handleFleetRoutes serves control.RoutesPath: the machines the caller may
// reach and every way in. Admitted like the relay: the operator's doors or a
// GitHub session over HTTP (GET or POST), or a connection certificate proven by
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
	loginOn := func(string) (string, bool) { return "", false }
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
		if loginOn, err = s.homeLogins(id.Principal); err != nil {
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
		if out.Disabled, err = s.disabledMachinesOf(id.Principal); err != nil {
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
	}
	relayReady := s.sshRelayReadiness()
	now := time.Now()
	for _, m := range s.fleetMachines() {
		if hosts != nil && !hosts[m.Hostname] {
			continue
		}
		lg, _ := loginOn(m.Hostname)
		out.Machines = append(out.Machines, s.routeMachine(m, relayReady, lg, now))
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, out)
}

// routeMachine is one machine of a route list — the route list's and the home
// answer's alike (claude-fleet#4112: `fleet` with no machine connects off the
// home answer, which carried the pod's relay and no door route long after
// #3985 fixed the route list): the door's entry route, and no relay for a pod
// behind the door — unless its agent says its relay reaches the pod's own
// sshd (CapPodRelay, claude-fleet#4149): then the relay is the way in when the
// door is not, and the pod's own host key rides beside the door's.
func (s *Server) routeMachine(m FleetMachine, relayReady func(string) bool, login string, now time.Time) RouteMachine {
	relay := relayReady(m.Hostname)
	if relay && s.podBehindDoor(m.Hostname) {
		relay = s.podRelayReady(m.Hostname)
	}
	rm := RouteMachine{FleetMachine: s.withEntryReachRelay(m, now, relay), Relay: relay, Login: login}
	rm.HostCA = s.hostCAKeys()
	if nodes, err := s.Store.Nodes(); err == nil {
		settings, _ := s.Store.FleetSettings()
		rm.Status, rm.SeenAt = machineLife(nodes, settings, m.Hostname, login, now)
	}
	return rm
}

// machineLife is one machine's status and newest heartbeat off the roster: the
// agent of login there when one answers, else the newest agent of the machine.
func machineLife(nodes []store.Node, settings map[string]string, hostname, login string, now time.Time) (string, *time.Time) {
	var best *store.Node
	for i := range nodes {
		n := &nodes[i]
		if !sameMachine(n.Hostname, hostname) && !sameMachine(hostname, n.Hostname) {
			continue
		}
		mine := login != "" && n.OSUser == login
		bestMine := best != nil && login != "" && best.OSUser == login
		switch {
		case best == nil, mine && !bestMine:
			best = n
		case mine == bestMine && n.LastHeartbeat != nil &&
			(best.LastHeartbeat == nil || n.LastHeartbeat.After(*best.LastHeartbeat)):
			best = n
		}
	}
	if best == nil {
		return "", nil
	}
	return nodeAvail(best.Hostname, best.LastHeartbeat, best.HeartbeatMS, settings, now), best.LastHeartbeat
}
