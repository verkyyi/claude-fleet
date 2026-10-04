package api

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// 维护中 — a machine the operator is about to take down (claude-fleet#1427,
// EPIC #1419 C8).
//
// A node's status was online | lost, both read off its heartbeats. A planned
// outage needs a third word that the heartbeats cannot say: the machine is up
// and will stay up for a while, and nothing new should start on it, so that
// `fleet-move.sh --rebalance` on it finds every idle session a better home and
// the sessions still working there finish on their own. That word is
// `maintenance`, and it is the operator's, never the heartbeat's:
//
//   - stored as the fleet setting `fleet.node_maintenance.<machine>` (the same
//     table as the per-machine caps and the SPOT weight; no new schema), so it
//     survives the outage itself and a hub restart, and the machine comes back
//     as 维护中 until someone says it is done — not as a placement target the
//     moment its agent reconnects;
//   - set from the machine itself (`POST /v1/node/maintenance`, the node's own
//     token — what bin/fleet-node-maintenance.sh calls from a pane on it) or
//     by the operator for any machine (`PUT /v1/fleet/settings`, the /nodes
//     page's button);
//   - read wherever a status is surfaced: the roster (/v1/nodes), the fleet
//     views and the sidebar's machine line (fleet_sessions), placement (judge:
//     excluded, auto or named), and `fleet connect`'s home pick (last choice).
//
// Lost still wins: a flagged machine whose heartbeats stop reads `lost`, and
// its leases lapse on the 30-minute TTL like any other — 维护中 changes what the
// hub SENDS to a machine, never what it believes about one it cannot hear.
//
// No setting ⇒ nothing here runs: maintenanceOf answers false from an empty
// map and every reader keeps today's two words (TestMaintenanceOffAddsNothing).

// NodeMaintenancePrefix names the per-machine 维护中 setting.
const NodeMaintenancePrefix = "fleet.node_maintenance."

// Maintenance is the record behind one flag: who set it, when, and why.
type Maintenance struct {
	Machine string    `json:"machine"`
	Reason  string    `json:"reason,omitempty"`
	Since   time.Time `json:"since"`
	By      string    `json:"by,omitempty"`
}

// maintenanceOf is hostname's record from the settings, ok false when the
// machine is not flagged. The key's machine name matches like a placement
// target does (sameMachine: the whole name or its first label).
func maintenanceOf(hostname string, settings map[string]string) (Maintenance, bool) {
	for k, v := range settings {
		if !strings.HasPrefix(k, NodeMaintenancePrefix) || v == "" {
			continue
		}
		name := k[len(NodeMaintenancePrefix):]
		if !sameMachine(hostname, name) && !strings.EqualFold(hostname, name) {
			continue
		}
		return parseMaintenance(name, v), true
	}
	return Maintenance{}, false
}

// parseMaintenance reads a stored value: the JSON record, or — a value set by
// hand through the settings route — a bare reason with no clock.
func parseMaintenance(machine, v string) Maintenance {
	m := Maintenance{Machine: machine}
	if strings.HasPrefix(v, "{") && json.Unmarshal([]byte(v), &m) == nil {
		m.Machine = machine
		return m
	}
	m.Reason = v
	return m
}

// nodeAvail layers the flag over the heartbeat judgement: lost | maintenance |
// online. Lost first — the flag says nothing about a machine the hub cannot hear.
func nodeAvail(hostname string, last *time.Time, heartbeatMS int, settings map[string]string, now time.Time) string {
	st := NodeStatus(last, heartbeatMS, now)
	if st != "online" {
		return st
	}
	if _, ok := maintenanceOf(hostname, settings); ok {
		return "maintenance"
	}
	return st
}

// maintenanceKey is the setting key for a machine name as given.
func maintenanceKey(machine string) string {
	return NodeMaintenancePrefix + strings.ToLower(firstLabel(machine))
}

func firstLabel(hostname string) string {
	if i := strings.IndexByte(hostname, '.'); i > 0 {
		return hostname[:i]
	}
	return hostname
}

// enterMaintenance flags machine. A second enter keeps the first record's
// clock (the outage started when it started) and refreshes the reason.
func (s *Server) enterMaintenance(machine, reason, by string, now time.Time) (Maintenance, bool, error) {
	settings, err := s.Store.FleetSettings()
	if err != nil {
		return Maintenance{}, false, err
	}
	m := Maintenance{Machine: strings.ToLower(firstLabel(machine)), Reason: reason, Since: now.UTC(), By: by}
	already := false
	if cur, ok := maintenanceOf(machine, settings); ok {
		already = true
		if !cur.Since.IsZero() {
			m.Since = cur.Since
		}
		if reason == "" {
			m.Reason = cur.Reason
		}
	}
	raw, _ := json.Marshal(m)
	if err := s.Store.SetFleetSetting(maintenanceKey(machine), string(raw), now); err != nil {
		return Maintenance{}, false, err
	}
	return m, already, nil
}

// leaveMaintenance clears the flag; was is whether there was one.
func (s *Server) leaveMaintenance(machine string, now time.Time) (bool, error) {
	settings, err := s.Store.FleetSettings()
	if err != nil {
		return false, err
	}
	_, was := maintenanceOf(machine, settings)
	// Clear every spelling that matches, so a key set as "m5.local" and one
	// set as "m5" cannot leave one behind.
	for k, v := range settings {
		if strings.HasPrefix(k, NodeMaintenancePrefix) && v != "" && (sameMachine(machine, k[len(NodeMaintenancePrefix):]) || sameMachine(k[len(NodeMaintenancePrefix):], machine)) {
			if err := s.Store.SetFleetSetting(k, "", now); err != nil {
				return was, err
			}
		}
	}
	return was, nil
}

// maintenanceAudit is one fleet_audit row per change: actor, node_maintenance,
// machine:<name>, ENTER <reason> | LEAVE | ALREADY | NOT_FLAGGED.
func (s *Server) maintenanceAudit(actor, machine, outcome string, at time.Time) {
	s.leaseAudit(actor, "node_maintenance", "machine:"+strings.ToLower(firstLabel(machine)), outcome, at)
}

// handleNodeMaintenance serves /v1/node/maintenance — a machine speaking for
// itself, with its node's enrollment token (like /v1/node/reclaim):
//
//	GET                                    → {"machine", "status", "maintenance": record|null}
//	POST {"action":"enter","reason":…}     → flag this machine (idempotent; keeps the first clock)
//	POST {"action":"leave"}                → clear it
//
// Only its own machine: a node has no say over another one — that is the
// operator's route (/v1/fleet/settings).
func (s *Server) handleNodeMaintenance(w http.ResponseWriter, r *http.Request) {
	ep, ok := s.nodeEndpoint(w, r)
	if !ok {
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	now := time.Now()
	// The machine is the roster's word (its heartbeats carry the hostname and
	// login), not the enrollment's: a token enrolled before the agent first
	// reported has neither.
	host, user := ep.Hostname, ep.OSUser
	n := s.nodeRow(ep.ID)
	if n != nil {
		host, user = n.Hostname, n.OSUser
	}
	if host == "" {
		httpError(w, http.StatusConflict, "this node has not reported yet — the hub does not know which machine it is")
		return
	}
	actor := "node:" + user + "@" + firstLabel(host)
	answer := func() {
		settings, err := s.Store.FleetSettings()
		if err != nil {
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
		out := map[string]any{"machine": firstLabel(host), "status": "lost", "maintenance": nil}
		if n != nil {
			out["status"] = nodeAvail(host, n.LastHeartbeat, n.HeartbeatMS, settings, now)
		}
		if m, flagged := maintenanceOf(host, settings); flagged {
			out["maintenance"] = m
		}
		writeJSON(w, http.StatusOK, out)
	}
	switch r.Method {
	case http.MethodGet:
		answer()
	case http.MethodPost:
		var req struct {
			Action string `json:"action"`
			Reason string `json:"reason"`
		}
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4<<10)).Decode(&req); err != nil && !errors.Is(err, io.EOF) {
			httpError(w, http.StatusBadRequest, "the body must be one JSON object")
			return
		}
		switch req.Action {
		case "enter":
			reason := strings.TrimSpace(req.Reason)
			if len(reason) > 200 {
				httpError(w, http.StatusBadRequest, "the reason is at most 200 characters")
				return
			}
			m, already, err := s.enterMaintenance(host, reason, actor, now)
			if err != nil {
				httpError(w, http.StatusInternalServerError, err.Error())
				return
			}
			outcome := "ENTER"
			if already {
				outcome = "ALREADY"
			}
			if m.Reason != "" {
				outcome += ": " + m.Reason
			}
			s.maintenanceAudit(actor, host, outcome, now)
			answer()
		case "leave":
			was, err := s.leaveMaintenance(host, now)
			if err != nil {
				httpError(w, http.StatusInternalServerError, err.Error())
				return
			}
			s.maintenanceAudit(actor, host, map[bool]string{true: "LEAVE", false: "NOT_FLAGGED"}[was], now)
			answer()
		default:
			httpError(w, http.StatusBadRequest, `action must be "enter" or "leave"`)
		}
	default:
		w.Header().Set("Allow", "GET, POST")
		httpError(w, http.StatusMethodNotAllowed, "GET or POST")
	}
}

// nodeRow is one endpoint's roster row, nil when it never connected.
func (s *Server) nodeRow(endpointID string) *store.Node {
	rows, err := s.Store.Nodes()
	if err != nil {
		return nil
	}
	for i := range rows {
		if rows[i].EndpointID == endpointID {
			return &rows[i]
		}
	}
	return nil
}
