package api

import (
	"encoding/json"
	"sort"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

// Current detail rows come from the exact heartbeat used by nodesWhere, not
// the independently updated fleet registry. The registry is only a last-known
// snapshot for unreadable/offline fleets, or history for an administrator.
func (s *Server) fillNodeSessions(d *NodeDetail, snap NodesSnapshot, now time.Time, visible func(string, string) bool) error {
	d.PendingSessions = []FleetSession{}
	nodes := map[string]NodeView{}
	current := map[string]bool{}
	for _, n := range snap.Nodes {
		if n.Hostname != d.Machine.Hostname || n.MachineLink {
			continue
		}
		nodes[n.EndpointID] = n
		if n.Status == "lost" || n.heartbeat == nil {
			continue
		}
		hb := n.heartbeat
		at := hb.FleetAt
		if at == nil {
			at = n.LastHeartbeat
		}
		d.SessionsAt = newer(d.SessionsAt, at)
		for _, f := range hb.Fleets {
			if f.State == control.FleetStateUnknown || hb.FleetError != "" {
				continue
			}
			current[n.EndpointID+"/"+f.FleetID] = true
			var observed time.Time
			if at != nil {
				observed = *at
			}
			d.Sessions = append(d.Sessions, nodeSessionRows(f.Workers, n.Hostname, n.OSUser, f.FleetID, f.Name, n.Status, observed, now)...)
		}
	}
	fleets, err := s.Store.Fleets()
	if err != nil {
		return err
	}
	for _, f := range fleets {
		if f.Hostname != d.Machine.Hostname || (visible != nil && !visible(f.Hostname, f.OSUser)) {
			continue
		}
		n, exists := nodes[f.EndpointID]
		// A reused login name is not the same enrollment. Never let its old rows
		// become the new tenant's current or pending sessions.
		advertised := n.heartbeat != nil && n.heartbeat.FleetError != ""
		for _, nf := range n.Fleets {
			if nf.FleetID == f.FleetID {
				advertised = true
				break
			}
		}
		if f.EndpointRetired || !f.Present || !exists || !advertised {
			if visible == nil {
				d.HistoricalSessions = append(d.HistoricalSessions, nodeSessionRows([]byte(f.WorkersJSON), f.Hostname, f.OSUser, f.FleetID, f.Name, "historical", f.ObservedAt, now)...)
			}
			continue
		}
		if current[f.EndpointID+"/"+f.FleetID] {
			continue
		}
		availability := "unknown"
		if n.Status == "lost" {
			availability = "lost"
		}
		d.PendingSessions = append(d.PendingSessions, nodeSessionRows([]byte(f.WorkersJSON), f.Hostname, f.OSUser, f.FleetID, f.Name, availability, f.ObservedAt, now)...)
	}
	for _, rows := range [][]FleetSession{d.Sessions, d.PendingSessions, d.HistoricalSessions} {
		sort.SliceStable(rows, func(i, j int) bool {
			a, b := rows[i], rows[j]
			if a.OSUser != b.OSUser {
				return a.OSUser < b.OSUser
			}
			x, _ := a.Worker["key"].(string)
			y, _ := b.Worker["key"].(string)
			return x < y
		})
	}
	return nil
}

func nodeSessionRows(raw []byte, host, login, fid, name, availability string, at, now time.Time) []FleetSession {
	var workers []map[string]any
	if json.Unmarshal(raw, &workers) != nil {
		return nil
	}
	rows := make([]FleetSession, 0, len(workers))
	for _, w := range workers {
		var id *string
		if v, ok := w["worker_id"].(string); ok && v != "" {
			id = &v
		}
		rows = append(rows, FleetSession{WorkerID: id, MachineName: host, OSUser: login, FleetID: fid, FleetName: name, Availability: availability, Worker: w, ObservedAt: at, AgeSec: now.Sub(at).Seconds()})
	}
	return rows
}
