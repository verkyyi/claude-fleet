package api

import (
	"encoding/json"
	"log"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/findings"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// Can this machine run sessions? (claude-fleet#1720, EPIC #1718 C2)
//
// A login's compute has three inputs, and this file is the one place they meet:
//
//   - its own word (#1719): CCQUOTA_FLEET_COMPUTE in node.env, written by
//     `fleet node join` (0 on a first join) and `fleet node compute on|off`,
//     carried by the hello and every heartbeat;
//   - its probe: bin/fleet-node-probe.sh's verdict on the egress region and
//     whether Anthropic's and OpenAI's APIs answer from here, run at install
//     and daily, carried the same way;
//   - the team policy `fleet.compute_auto` (default off): on opens a login
//     whose fresh probe is ok, even though its own word is off.
//
// The probe wins over the login's word in one direction only: an egress
// region the providers do not serve closes the login (it is never placed on,
// never leased an account) and raises the compute_region finding, unless the
// person forced it on (`--force`, audited). An unreachable API refuses
// `fleet node compute on` and the auto-open but never closes a running login:
// a network outage during the daily probe is weather, a region is a rule.
//
// No probe and no setting ⇒ exactly #1719: the login's word alone.

// ComputeAutoKey is the team policy: "on" opens a login whose probe is ok.
const ComputeAutoKey = "fleet.compute_auto"

// probeFreshFor bounds how old a probe may be and still open a login by
// policy: the probe runs daily, so two days is one missed run.
const probeFreshFor = 48 * time.Hour

// excludedComputeOff is placement's word for a login that only coordinates.
const excludedComputeOff = "compute off (只协调: CCQUOTA_FLEET_COMPUTE=0)"

// computeVerdict is one login's compute, decided.
type computeVerdict struct {
	Off bool
	// Why is placement's word when Off.
	Why string
	// Auto: open only because the team policy opened it.
	Auto bool
	// Closed: the login asked to run and its probe's region closed it — the
	// compute_region finding.
	Closed bool
	Probe  *control.NodeProbe
}

func computeAutoOn(settings map[string]string) bool {
	switch strings.ToLower(strings.TrimSpace(settings[ComputeAutoKey])) {
	case "on", "1", "true", "yes":
		return true
	}
	return false
}

// decideCompute is the rule above, pure.
func decideCompute(claimOn, force bool, p *control.NodeProbe, auto bool, now time.Time) computeVerdict {
	v := computeVerdict{Probe: p}
	if p != nil && p.Verdict == control.ProbeUnsupportedRegion && !force {
		v.Off, v.Closed = true, claimOn
		v.Why = "compute off (出口地区 " + orUnknown(p.Loc) + " 不在 Claude / OpenAI 支持范围)"
		return v
	}
	if claimOn {
		return v
	}
	if auto && p != nil && p.Verdict == control.ProbeOK && now.Sub(p.TS) <= probeFreshFor {
		v.Auto = true
		return v
	}
	v.Off, v.Why = true, excludedComputeOff
	return v
}

func orUnknown(s string) string {
	if s == "" {
		return "未知"
	}
	return s
}

// computeOf decides one login's compute from its live link (the hello) and
// its newest heartbeat (the roster row). Off when the hello said off and no
// beat since said on (#1719), or the newest beat says off.
func (s *Server) computeOf(endpointID string, hb control.Heartbeat, settings map[string]string, now time.Time) computeVerdict {
	claimOn := control.ComputeOn(hb.Compute)
	force, probe := hb.ComputeForce, hb.Probe
	if c := s.nodes.get(endpointID); c != nil {
		if c.machineLink {
			// A machine's own link carries logins; it is never one to run
			// sessions on (claude-fleet#2333), whatever the team policy says.
			return computeVerdict{Off: true, Why: "machine link"}
		}
		if c.computeOff && !c.beatSaidOn.Load() {
			claimOn = false
		}
		if hb.ObservedAt.IsZero() {
			force = c.computeForce
		}
		if probe == nil {
			probe = c.probe
		}
	}
	return decideCompute(claimOn, force, probe, computeAutoOn(settings), now)
}

// auditComputeForce writes a forced compute into fleet_audit once per link:
// the person overrode a probe that said this machine does not suit running
// sessions (claude-fleet#1720).
func (s *Server) auditComputeForce(ep store.Endpoint, nc *nodeConn, force bool, p *control.NodeProbe, now time.Time) {
	if !force {
		nc.forceAudited.Store(false)
		return
	}
	if nc.forceAudited.Swap(true) {
		return
	}
	outcome := "compute forced on"
	if p != nil {
		outcome += " over probe verdict " + p.Verdict + " (loc " + orUnknown(p.Loc) + ")"
		if p.Reason != "" {
			outcome += ": " + p.Reason
		}
	}
	if err := s.Store.FleetAudit("node:"+ep.OSUser+"@"+ep.Hostname, "compute_force", "node:"+ep.ID, outcome, "", now); err != nil {
		log.Printf("fleet audit: %v", err)
	}
}

// computeClosed lists the online logins whose egress region closed them — the
// compute_region finding's input. Empty on a hub with no node or no probe.
func (s *Server) computeClosed(now time.Time) []findings.ComputeClosed {
	rows, err := s.Store.Nodes()
	if err != nil || len(rows) == 0 {
		return nil
	}
	settings, _ := s.Store.FleetSettings()
	var out []findings.ComputeClosed
	for _, n := range rows {
		if NodeStatus(n.LastHeartbeat, n.HeartbeatMS, now) != "online" {
			continue
		}
		var hb control.Heartbeat
		_ = json.Unmarshal([]byte(n.StatusJSON), &hb)
		cv := s.computeOf(n.EndpointID, hb, settings, now)
		if !cv.Closed || cv.Probe == nil {
			continue
		}
		out = append(out, findings.ComputeClosed{EndpointID: n.EndpointID, Hostname: n.Hostname,
			OSUser: n.OSUser, Loc: cv.Probe.Loc, Reason: cv.Probe.Reason})
	}
	return out
}

// computeAutoAudit records the team policy changing hands.
func (s *Server) computeAutoAudit(value string, now time.Time) {
	if value == "" {
		value = "default (off)"
	}
	if err := s.Store.FleetAudit("operator", "compute_auto", "hub", ComputeAutoKey+" = "+value, "", now); err != nil {
		log.Printf("fleet audit: %v", err)
	}
}
