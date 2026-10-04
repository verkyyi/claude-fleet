package api

import (
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"sort"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// Which machine to enter (claude-fleet#1470).
//
// `fleet` with no argument asks the hub, and the hub decides, in this order:
//
//  1. the machine this device used last, when it is online;
//  2. an online machine where the person has sessions (the most of them);
//  3. the least loaded online machine the person has an account on — scored
//     by the same judge node placement uses (#1425).
//
// No machine of theirs online: no pick, and the answer says so in words the
// client prints as is. The answer also carries the whole route list, so
// `fleet` goes straight to measuring the chosen machine's routes without a
// second request.
//
// Admitted like the route list: a session or the operator's token over HTTP,
// or a connection certificate proven by a signed timestamp (POST HomeRequest).
// A certificate also names the device (its key's fingerprint), which is how
// the hub remembers "last used" per computer, not per person.

// HomeRequest is the body of POST control.HomePath.
type HomeRequest struct {
	RoutesRequest
	// Last is the client's own memory of the machine it entered last — a hint;
	// the device record on the hub is used when it is empty.
	Last string `json:"last,omitempty"`
}

// HomeCandidate is one machine the pick considered.
type HomeCandidate struct {
	Machine     string   `json:"machine"`
	Alias       string   `json:"alias,omitempty"`
	Online      bool     `json:"online"`
	Sessions    int      `json:"sessions"`
	LoadPerCore *float64 `json:"load_per_core,omitempty"`
	Score       float64  `json:"score"`
	Last        bool     `json:"last,omitempty"`
	Excluded    string   `json:"excluded,omitempty"`
	// Maintenance is the 维护中 reason (claude-fleet#1427): still enterable —
	// the operator shutting it down needs in — but the pick's last choice.
	Maintenance string `json:"maintenance,omitempty"`
}

// HomeResponse is the body of control.HomePath.
type HomeResponse struct {
	RoutesResponse
	// Machine is the pick; nil when none of the person's machines is online.
	Machine *RouteMachine `json:"machine"`
	// Rule is which rule chose it: last | sessions | load | "" (none online).
	Rule string `json:"rule"`
	// Reason is one line for the terminal, in the language the person reads.
	Reason     string          `json:"reason"`
	Online     int             `json:"online"`
	Candidates []HomeCandidate `json:"candidates"`
}

// homePick decides for pid (""= the operator, who sees every machine) given
// the last-used hint. It never errs on an empty roster — that is a response.
func (s *Server) homePick(pid, last string, now time.Time) (HomeResponse, error) {
	out := HomeResponse{RoutesResponse: RoutesResponse{Machines: []RouteMachine{}}, Candidates: []HomeCandidate{}}
	var hosts map[string]bool
	var scope func(hostname, osUser string) bool
	login := ""
	if pid != "" {
		p, _, h, err := s.fleetLoginsOf(pid)
		if err != nil {
			return out, err
		}
		out.Login, hosts, login = p.Login, h, p.Login
		if scope, err = s.scopeFor(pid); err != nil {
			return out, err
		}
	}

	// The person's session count per machine, from the fleet registry.
	sessions := map[string]int{}
	if _, rows, err := s.visibleFleets(fleetPrincipal{Actor: pid, Person: pid, scope: scope}, now); err == nil {
		for _, r := range rows {
			if r.Present {
				sessions[strings.ToLower(r.Hostname)] += r.WorkerCount
			}
		}
	}
	nodes, err := s.Store.Nodes()
	if err != nil {
		return out, err
	}
	settings, _ := s.Store.FleetSettings()
	accounts := s.loginAccounts()

	for _, m := range s.fleetMachines() {
		if hosts != nil && !hosts[m.Hostname] {
			continue
		}
		out.Machines = append(out.Machines, RouteMachine{FleetMachine: m, Relay: s.sshRelayReady(m.Hostname)})
		c := HomeCandidate{Machine: m.Hostname, Alias: m.alias(), Sessions: sessions[strings.ToLower(m.Hostname)]}
		// The endpoint that speaks for this machine: the person's own login
		// when it reports, else any online one — they share the box.
		var ep *store.Node
		for i := range nodes {
			n := &nodes[i]
			if !sameMachine(n.Hostname, m.Hostname) {
				continue
			}
			online := NodeStatus(n.LastHeartbeat, n.HeartbeatMS, now) == "online"
			switch {
			case ep == nil:
				ep = n
			case online && n.OSUser == login:
				ep = n
			case online && NodeStatus(ep.LastHeartbeat, ep.HeartbeatMS, now) != "online":
				ep = n
			}
		}
		if ep == nil {
			c.Excluded = "no node has reported from it"
		} else {
			j := s.judge(store.FleetRow{Hostname: m.Hostname, OSUser: ep.OSUser, EndpointID: ep.EndpointID}, settings, accounts, now)
			c.LoadPerCore, c.Score = j.LoadPerCore, j.Score
			// Entering a machine over ssh needs it online — not a writable
			// control channel, free memory or cap headroom, which gate new
			// WORK, not a login.
			if j.Excluded == "offline" {
				c.Excluded = "offline"
			} else {
				c.Online = true
				out.Online++
				if m, flagged := maintenanceOf(m.Hostname, settings); flagged {
					c.Maintenance = m.Reason
					if c.Maintenance == "" {
						c.Maintenance = "维护中"
					}
				}
			}
		}
		if last != "" && (sameMachine(m.Hostname, last) || strings.EqualFold(m.alias(), last)) {
			c.Last = true
		}
		out.Candidates = append(out.Candidates, c)
	}

	pick := -1
	// Two passes (claude-fleet#1427): first over the machines that are not
	// 维护中, then — only when none of those is online — over all online ones,
	// so a person lands on the machine that is staying up, and the operator
	// taking the last one down can still get in.
	for _, allowMaint := range []bool{false, true} {
		up := func(c HomeCandidate) bool { return c.Online && (allowMaint || c.Maintenance == "") }
		// 1 — last used, online.
		for i, c := range out.Candidates {
			if up(c) && c.Last {
				pick, out.Rule, out.Reason = i, "last", "上次用的机器在线"
			}
		}
		// 2 — the most of the person's sessions.
		if pick < 0 {
			best := 0
			for i, c := range out.Candidates {
				if up(c) && c.Sessions > best {
					best, pick = c.Sessions, i
				}
			}
			if pick >= 0 {
				out.Rule, out.Reason = "sessions", "有你的会话"
			}
		}
		// 3 — the best placement score among the online ones.
		if pick < 0 {
			online := []int{}
			for i, c := range out.Candidates {
				if up(c) {
					online = append(online, i)
				}
			}
			sort.SliceStable(online, func(a, b int) bool {
				ca, cb := out.Candidates[online[a]], out.Candidates[online[b]]
				if ca.Score != cb.Score {
					return ca.Score > cb.Score
				}
				if ca.Sessions != cb.Sessions {
					return ca.Sessions < cb.Sessions
				}
				return ca.Machine < cb.Machine
			})
			if len(online) > 0 {
				pick, out.Rule, out.Reason = online[0], "load", "负载最低"
			}
		}
		if pick >= 0 {
			if allowMaint {
				out.Reason += "（只剩维护中的机器在线）"
			}
			break
		}
	}
	if pick < 0 {
		out.Reason = "你的机器都不在线"
		if len(out.Candidates) == 0 {
			out.Reason = "入口没有列出你能连的机器"
		}
		return out, nil
	}
	c := out.Candidates[pick]
	for i := range out.Machines {
		if out.Machines[i].Hostname == c.Machine {
			m := out.Machines[i]
			out.Machine = &m
		}
	}
	return out, nil
}

// handleFleetHome serves control.HomePath.
func (s *Server) handleFleetHome(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodPost {
		w.Header().Set("Allow", "GET, POST")
		httpError(w, http.StatusMethodNotAllowed, "GET or POST")
		return
	}
	var req HomeRequest
	if r.Method == http.MethodPost {
		_ = json.NewDecoder(http.MaxBytesReader(w, r.Body, 64<<10)).Decode(&req)
	}
	if req.Last == "" {
		req.Last = r.URL.Query().Get("last")
	}
	now := time.Now()
	id, ok := s.sshRelayHTTPIdentity(r)
	device := ""
	if !ok {
		if req.Cert == "" || req.Sig == "" {
			w.Header().Set("WWW-Authenticate", `Bearer realm="ccquota"`)
			httpError(w, http.StatusUnauthorized, "a session, a viewer token or a connection certificate is required")
			return
		}
		if d := now.Sub(time.Unix(req.TS, 0)); d > routesClockSkew || d < -routesClockSkew {
			httpError(w, http.StatusUnauthorized, "the signed timestamp is too far from the hub's clock — check this computer's time")
			return
		}
		var err error
		if id, err = s.verifySSHRelayCert(req.Cert, req.Sig, control.HomeSigMessage(req.TS), control.HomeSigNamespace, now); err != nil {
			var re *sshRelayError
			if errors.As(err, &re) {
				refuseJSON(w, http.StatusUnauthorized, certRefusalCode(re.msg), re.msg)
				return
			}
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
		device = deviceOfCert(req.Cert)
	}
	pid := id.Principal
	var dev *store.FleetDevice
	if device != "" {
		if d, err := s.Store.Device(device); err == nil && d.PrincipalID == pid {
			dev = d
			if req.Last == "" {
				req.Last = d.LastMachine
			}
		}
	}
	if !sshToken(req.Last) {
		req.Last = ""
	}
	out, err := s.homePick(pid, req.Last, now)
	out.Hub = s.hubURL(r)
	switch {
	case errors.Is(err, errNoAccount):
		httpError(w, http.StatusForbidden, err.Error())
		return
	case err != nil:
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if dev != nil {
		machine := ""
		if out.Machine != nil {
			machine = out.Machine.Hostname
		}
		if err := s.Store.TouchDevice(dev.Fingerprint, now, machine, false); err != nil {
			log.Printf("fleet: touch device %s: %v", dev.Fingerprint, err)
		}
		detail := out.Reason
		if out.Machine != nil {
			detail = out.Machine.alias() + " (" + out.Reason + ")"
		}
		s.deviceAudit(store.DeviceHome, dev.Fingerprint, pid, pid, detail, now)
	}
	w.Header().Set("Cache-Control", "no-store")
	if out.Machine == nil {
		// Honest and machine-readable: nothing to enter right now.
		writeJSON(w, http.StatusServiceUnavailable, map[string]any{"error": out.Reason, "code": "no_machine_online", "home": out})
		return
	}
	writeJSON(w, http.StatusOK, out)
}

// certRefusalCode turns a certificate refusal into the code `fleet` branches
// on: a revoked device must scan again; anything else is "try later".
func certRefusalCode(msg string) string {
	if strings.Contains(msg, "revoked") {
		return "device_revoked"
	}
	return "certificate_refused"
}
