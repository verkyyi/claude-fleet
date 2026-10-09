package api

import (
	"context"
	"encoding/json"
	"log"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// Node-lost and lease-conflict alerts (claude-fleet#1630). The hub going away
// or a node dropping off must not leave the operator guessing what ran and
// what stopped, nor let two workers quietly work one issue — so the hub
// writes down what it saw, in store.fleet_alerts, and changes nothing else:
//
//   - node_lost: a node silent for NodeLostAfter (FLEET_NODE_LOST_ALERT_SECS,
//     120 s). Raised by the sweeper (RunNodeAlerts), cleared by the node's
//     next heartbeat — the row's raised_at / cleared_at are the outage.
//   - lease_conflict: a node's FIRST beat after (re)connecting shows a session
//     on an issue whose live lease another worker holds (it was handed on, or
//     re-taken, while the node was away). Both sides are named; neither lease
//     nor session is touched. Cleared by the sweeper once the two sides agree
//     again (the lease is gone, or back with the reporter, or the reporter
//     stopped showing that session).
//
// Read back through the fleet_alerts tool (GET /v1/fleet/fleet_alerts).

// defaultNodeLostAfter is FLEET_NODE_LOST_ALERT_SECS's default.
const defaultNodeLostAfter = 120 * time.Second

// nodeAlertTick is the sweeper's period: well inside the 120 s threshold, so
// an alert is raised at most this long after it is due.
const nodeAlertTick = 15 * time.Second

// nodeLostHorizon bounds which nodes can raise node_lost: one silent for longer
// than this is gone, not lost (a retired login, a re-enrolled machine), and
// alerting on it forever would bury the live ones.
const nodeLostHorizon = 7 * 24 * time.Hour

// fleetAlertKeep is how long a cleared alert is kept.
const fleetAlertKeep = 30 * 24 * time.Hour

// NodeLostAfterFromEnv reads FLEET_NODE_LOST_ALERT_SECS: unset, empty or not a
// positive integer → the 120 s default.
func NodeLostAfterFromEnv() time.Duration {
	if n, err := strconv.Atoi(strings.TrimSpace(os.Getenv("FLEET_NODE_LOST_ALERT_SECS"))); err == nil && n > 0 {
		return time.Duration(n) * time.Second
	}
	return defaultNodeLostAfter
}

func (s *Server) nodeLostAfter() time.Duration {
	if s.NodeLostAfter > 0 {
		return s.NodeLostAfter
	}
	return defaultNodeLostAfter
}

// RunNodeAlerts sweeps on nodeAlertTick until ctx ends, on the replica that
// leads "alerts".
func (s *Server) RunNodeAlerts(ctx context.Context) {
	start := time.Now()
	t := time.NewTicker(nodeAlertTick)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case now := <-t.C:
			// One replica sweeps (claude-fleet#2123): two would raise and
			// prune every alert twice.
			if !s.Elector.Leader(ctx, "alerts") {
				continue
			}
			s.NodeAlertTick(start, now)
			s.SweepDrills(now) // a drill person past its life (claude-fleet#2010)
		}
	}
}

// NodeAlertTick is one sweep at now. since is when this hub started watching:
// a node is only silent from then — a hub that was itself down for three
// minutes must not greet every node with node_lost the moment it is back.
func (s *Server) NodeAlertTick(since, now time.Time) {
	nodes, err := s.Store.Nodes()
	if err != nil {
		log.Printf("fleet alerts: read nodes: %v", err)
		return
	}
	settings, _ := s.Store.FleetSettings()
	after := s.nodeLostAfter()
	for _, n := range nodes {
		if n.LastHeartbeat == nil || now.Sub(*n.LastHeartbeat) > nodeLostHorizon {
			continue
		}
		// A machine the operator took down on purpose (claude-fleet#1427)
		// is expected to be silent.
		if _, ok := maintenanceOf(n.Hostname, settings); ok {
			continue
		}
		silent := *n.LastHeartbeat
		if silent.Before(since) {
			silent = since
		}
		if now.Sub(silent) <= after {
			continue
		}
		detail, _ := json.Marshal(map[string]any{
			"endpoint_id": n.EndpointID, "hostname": n.Hostname, "os_user": n.OSUser,
			"last_heartbeat": n.LastHeartbeat.UTC(), "after_secs": int(after / time.Second),
		})
		raised, err := s.Store.RaiseFleetAlert(store.AlertNodeLost, n.EndpointID, string(detail), now)
		if err != nil {
			log.Printf("fleet alerts: raise node_lost %s: %v", n.EndpointID, err)
		} else if raised {
			log.Printf("fleet alert: node_lost %s@%s (%s) — no heartbeat since %s",
				n.OSUser, nodeLabel(n.Hostname), n.EndpointID, n.LastHeartbeat.UTC().Format(time.RFC3339))
		}
	}
	s.clearSettledConflicts(now)
	if err := s.Store.PruneFleetAlerts(now.Add(-fleetAlertKeep)); err != nil {
		log.Printf("fleet alerts: prune: %v", err)
	}
}

// nodeBack clears a node's node_lost: called on every heartbeat.
func (s *Server) nodeBack(ep store.Endpoint, at time.Time) {
	cleared, err := s.Store.ClearFleetAlert(store.AlertNodeLost, ep.ID, at)
	if err != nil {
		log.Printf("fleet alerts: clear node_lost %s: %v", ep.ID, err)
	} else if cleared {
		log.Printf("fleet alert cleared: node_lost %s@%s (%s) is back", ep.OSUser, nodeLabel(ep.Hostname), ep.ID)
	}
}

// leaseConflict is one lease_conflict's detail: the holder the hub's lease
// names, and the node that came back still showing the session.
type leaseConflict struct {
	Repo     string            `json:"repo"`
	Issue    int               `json:"issue"`
	Holder   leaseConflictSide `json:"holder"`
	Reporter leaseConflictSide `json:"reporter"`
}

type leaseConflictSide struct {
	EndpointID string `json:"endpoint_id"`
	Node       string `json:"node"`
	WorkerID   string `json:"worker_id"`
	FleetID    string `json:"fleet_id"`
}

func conflictSubject(repo string, issue int) string {
	return store.NormRepo(repo) + "#" + strconv.Itoa(issue)
}

// sameHolder is AcquireLease's "mine": the same worker, or — whatever key
// spelling the worker_id carries — the same fleet.
func sameHolder(l store.Lease, workerID, fleetID string) bool {
	return l.WorkerID == workerID || (l.FleetID != "" && l.FleetID == fleetID)
}

// checkLeaseConflicts compares a reconnecting node's sessions with the live
// leases and raises lease_conflict for each issue another worker holds.
func (s *Server) checkLeaseConflicts(ep store.Endpoint, host, user string, sessions []store.LeaseSession, at time.Time) {
	var mine []store.LeaseSession
	for _, ss := range sessions {
		if ss.Issue > 0 && ss.Repo != "" {
			mine = append(mine, ss)
		}
	}
	if len(mine) == 0 {
		return
	}
	leases, err := s.Store.Leases(at)
	if err != nil {
		log.Printf("fleet alerts: read leases: %v", err)
		return
	}
	byKey := map[string]store.Lease{}
	for _, l := range leases {
		byKey[conflictSubject(l.Repo, l.Issue)] = l
	}
	for _, ss := range mine {
		key := conflictSubject(ss.Repo, ss.Issue)
		l, ok := byKey[key]
		if !ok || l.EndpointID == ep.ID || sameHolder(l, ss.WorkerID, ss.FleetID) {
			continue
		}
		c := leaseConflict{
			Repo: l.Repo, Issue: l.Issue,
			Holder: leaseConflictSide{EndpointID: l.EndpointID, Node: l.OSUser + "@" + nodeLabel(l.Hostname),
				WorkerID: l.WorkerID, FleetID: l.FleetID},
			Reporter: leaseConflictSide{EndpointID: ep.ID, Node: user + "@" + nodeLabel(host),
				WorkerID: ss.WorkerID, FleetID: ss.FleetID},
		}
		detail, _ := json.Marshal(c)
		raised, err := s.Store.RaiseFleetAlert(store.AlertLeaseConflict, key, string(detail), at)
		if err != nil {
			log.Printf("fleet alerts: raise lease_conflict %s: %v", key, err)
		} else if raised {
			log.Printf("fleet alert: lease_conflict %s — lease held by %s (%s), %s came back still running %s; neither side changed",
				key, c.Holder.Node, c.Holder.WorkerID, c.Reporter.Node, c.Reporter.WorkerID)
		}
	}
}

// clearSettledConflicts closes each open lease_conflict whose two sides agree
// again: no live lease, the lease back with the reporter, or the reporter's
// fleets no longer showing a session on that issue.
func (s *Server) clearSettledConflicts(now time.Time) {
	alerts, err := s.Store.FleetAlerts(0)
	if err != nil {
		return
	}
	var open []store.FleetAlert
	for _, a := range alerts {
		if a.Kind == store.AlertLeaseConflict && a.ClearedAt == nil {
			open = append(open, a)
		}
	}
	if len(open) == 0 {
		return
	}
	leases, err := s.Store.Leases(now)
	if err != nil {
		return
	}
	fleets, err := s.Store.Fleets()
	if err != nil {
		return
	}
	for _, a := range open {
		var c leaseConflict
		if json.Unmarshal([]byte(a.Detail), &c) != nil {
			continue
		}
		settled := true
		for _, l := range leases {
			if conflictSubject(l.Repo, l.Issue) == a.Subject {
				settled = l.EndpointID == c.Reporter.EndpointID || sameHolder(l, c.Reporter.WorkerID, c.Reporter.FleetID)
				break
			}
		}
		if !settled && !reporterShows(fleets, c) {
			settled = true
		}
		if !settled {
			continue
		}
		if ok, err := s.Store.ClearFleetAlert(store.AlertLeaseConflict, a.Subject, now); err == nil && ok {
			log.Printf("fleet alert cleared: lease_conflict %s settled", a.Subject)
		}
	}
}

// reporterShows reports whether the conflict's reporter still shows a session
// on the conflict's issue.
func reporterShows(fleets []store.FleetRow, c leaseConflict) bool {
	for _, f := range fleets {
		if f.EndpointID != c.Reporter.EndpointID || !f.Present {
			continue
		}
		for _, ss := range workerSessions(f.FleetID, f.Repo, f.WorkersJSON) {
			if ss.Issue == c.Issue && store.NormRepo(ss.Repo) == store.NormRepo(c.Repo) {
				return true
			}
		}
	}
	return false
}

// workerSessions parses a fleet's workers ([{worker_id, issue, repo}]) the way
// the lease renewal does: a worker with no repo of its own is on the fleet's.
// ok is false when the JSON does not parse.
func workerSessions(fleetID, repo, workersJSON string) []store.LeaseSession {
	ss, _ := parseWorkerSessions(fleetID, repo, workersJSON)
	return ss
}

func parseWorkerSessions(fleetID, repo, workersJSON string) ([]store.LeaseSession, bool) {
	var ws []struct {
		WorkerID *string `json:"worker_id"`
		Issue    *int    `json:"issue"`
		Repo     *string `json:"repo"`
	}
	if json.Unmarshal([]byte(workersJSON), &ws) != nil {
		return nil, false
	}
	var out []store.LeaseSession
	for _, x := range ws {
		ss := store.LeaseSession{FleetID: fleetID, Repo: repo}
		if x.WorkerID != nil {
			ss.WorkerID = *x.WorkerID
		}
		if x.Issue != nil {
			ss.Issue = *x.Issue
		}
		if x.Repo != nil && *x.Repo != "" {
			ss.Repo = *x.Repo
		}
		out = append(out, ss)
	}
	return out, true
}

// FleetAlerts serves the fleet_alerts read: every open alert, then the most
// recently cleared, newest first. The operator and an admin get every row; a
// person gets only the alerts about their own (machine, login)s
// (claude-fleet#2513) — the same rows, fewer of them.
func (s *Server) FleetAlerts(req *http.Request) (any, error) {
	p, err := s.FleetPrincipal(req)
	if err != nil {
		return nil, err
	}
	rows, err := s.Store.FleetAlerts(200)
	if err != nil {
		return nil, err
	}
	if !p.All() {
		rows = s.alertsSeenBy(p, rows)
	}
	type row struct {
		store.FleetAlert
		Detail json.RawMessage `json:"detail"`
		Open   bool            `json:"open"`
	}
	out := make([]row, 0, len(rows))
	open := 0
	for _, a := range rows {
		r := row{FleetAlert: a, Detail: json.RawMessage(a.Detail), Open: a.ClearedAt == nil}
		if !json.Valid(r.Detail) {
			r.Detail = json.RawMessage("{}")
		}
		if r.Open {
			open++
		}
		out = append(out, r)
	}
	return map[string]any{"open": open, "alerts": out}, nil
}

// alertsSeenBy keeps the alerts p may see: a node_lost about one of p's
// (machine, login)s, a lease_conflict with either side on one. A row whose
// owner cannot be told — an unknown kind, a detail that does not parse, an
// endpoint the store no longer has — is dropped, never shown.
func (s *Server) alertsSeenBy(p fleetPrincipal, rows []store.FleetAlert) []store.FleetAlert {
	endpoints := map[string]bool{}
	seesEndpoint := func(id string) bool {
		if id == "" {
			return false
		}
		if v, ok := endpoints[id]; ok {
			return v
		}
		ep, err := s.Store.EndpointByID(id)
		v := err == nil && ep.OSUser != "" && p.sees(ep.Hostname, ep.OSUser)
		endpoints[id] = v
		return v
	}
	out := rows[:0:0]
	for _, a := range rows {
		mine := false
		switch a.Kind {
		case store.AlertNodeLost:
			var d struct {
				EndpointID string `json:"endpoint_id"`
				Hostname   string `json:"hostname"`
				OSUser     string `json:"os_user"`
			}
			if json.Unmarshal([]byte(a.Detail), &d) == nil && d.OSUser != "" {
				mine = p.sees(d.Hostname, d.OSUser)
			} else {
				mine = seesEndpoint(a.Subject)
			}
		case store.AlertLeaseConflict:
			var c leaseConflict
			if json.Unmarshal([]byte(a.Detail), &c) == nil {
				mine = seesEndpoint(c.Holder.EndpointID) || seesEndpoint(c.Reporter.EndpointID)
			}
		}
		if mine {
			out = append(out, a)
		}
	}
	return out
}
