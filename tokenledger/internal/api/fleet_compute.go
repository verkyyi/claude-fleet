package api

import (
	"encoding/json"
	"fmt"
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
	// Src says which report carried the login's own off and when — a beat
	// or the hello, its time and agent build — plus how often the link
	// changed hands lately (claude-fleet#2661). Empty when the off is not
	// the login's word.
	Src string
}

// Reason is Why with its source: what placement and a refused lease say.
func (v computeVerdict) Reason() string {
	if v.Src == "" {
		return v.Why
	}
	return v.Why + " · " + v.Src
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
		v.Why = "compute off (出口地区 " + p.Where() + " 不在 Claude / OpenAI 支持范围)"
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

// probeLoc is the compute_region finding's region: the probe's own, with
// its route when the sessions go through the relay (claude-fleet#3364).
func probeLoc(p *control.NodeProbe) string {
	if p.Route != "relay" {
		return p.Loc
	}
	return p.Where()
}

// computeOf decides one login's compute from its live link (the hello) and
// its newest heartbeat (the roster row). Off when the hello said off and no
// beat since said on (#1719), or the newest beat says off.
func (s *Server) computeOf(endpointID string, hb control.Heartbeat, settings map[string]string, now time.Time) computeVerdict {
	claimOn := control.ComputeOn(hb.Compute)
	force, probe := hb.ComputeForce, hb.Probe
	var src string
	if !claimOn {
		src = reportedBy("heartbeat", hb.ObservedAt, hb.AgentVersion)
	}
	c := s.nodes.get(endpointID)
	if c != nil {
		if c.machineLink {
			// A machine's own link carries logins; it is never one to run
			// sessions on (claude-fleet#2333), whatever the team policy says.
			// Its probe is the machine's egress all the same: a create reads
			// it (newLoginCompute, claude-fleet#3312).
			if probe == nil {
				probe = c.probe
			}
			return computeVerdict{Off: true, Why: "machine link", Probe: probe}
		}
		if c.computeOff && !c.beatSaidOn.Load() {
			if claimOn {
				src = reportedBy("hello", c.helloAt, c.agentVersion)
			}
			claimOn = false
		}
		if hb.ObservedAt.IsZero() {
			force = c.computeForce
		}
		if probe == nil {
			probe = c.probe
		}
	}
	v := decideCompute(claimOn, force, probe, computeAutoOn(settings), now)
	if v.Off && v.Why == excludedComputeOff {
		v.Src = src
		if k := s.nodes.supersededSince(endpointID, now); k > 0 {
			// Two agents of one login displace each other's link, each
			// hello with its own word: the flapping of claude-fleet#2661.
			v.Src += fmt.Sprintf(" · 链接 %d 分钟内被顶替 %d 次（同一登录多个 agent？）", int(supersedeWindow/time.Minute), k)
		}
		v.Src = strings.TrimPrefix(v.Src, " · ")
	}
	return v
}

// reportedBy is a compute word's provenance: `reported 15:11:02Z by agent
// 1.2.3 heartbeat`.
func reportedBy(kind string, at time.Time, version string) string {
	out := "reported"
	if !at.IsZero() {
		out += " " + at.UTC().Format("15:04:05Z")
	}
	if version != "" {
		out += " by agent " + version
	}
	return out + " " + kind
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
		outcome += " over probe verdict " + p.Verdict + " (loc " + p.Where() + ")"
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
			OSUser: n.OSUser, Loc: probeLoc(cv.Probe), Reason: cv.Probe.Reason})
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

// newLoginCompute is the verdict a login opened on host now would get
// (claude-fleet#3312): decideCompute for a login that asks to run, unforced,
// against the machine's newest probe from any of its heard links — its own
// node program's included — as a NEW login would see it (directProbe). The
// egress region is the machine's, so a login opened where it is unsupported
// is closed at its first lease, and a create never picks such a machine. No
// probe there ⇒ open, exactly as placement.
func newLoginCompute(snap NodesSnapshot, host string, settings map[string]string, now time.Time) computeVerdict {
	var newest *control.NodeProbe
	for _, n := range snap.Nodes {
		if n.Probe == nil || n.Status == "lost" || !strings.EqualFold(n.Hostname, host) {
			continue
		}
		if newest == nil || n.Probe.TS.After(newest.TS) {
			newest = n.Probe
		}
	}
	if !newLoginRelays(host, settings) {
		newest = directProbe(newest)
	}
	return decideCompute(true, false, newest, computeAutoOn(settings), now)
}

// newLoginRelays is true when a login opened on host now takes the relay road
// its machine's logins take (claude-fleet#3434): the hub mints a login's relay
// pass from inside its create, for a TRUSTED machine (handleNodeRelayCredential;
// relayJudge reads the machine's trust, never the account), so its proxy routes
// relay from its first request — the relay probe is its own. An untrusted
// machine's new login gets no pass and sees the machine's own egress.
func newLoginRelays(host string, settings map[string]string) bool {
	m := strings.ToLower(firstLabel(host))
	return m != "" && !nameUntrusted(m, settings) && trustOf(m, settings) == TrustTrusted
}

// directProbe is p as a login with no relay pass reads it (claude-fleet#3426;
// since #3434 only on an untrusted machine — newLoginRelays):
// a relay probe (claude-fleet#3364) is an existing login whose credential
// proxy goes through the relay BECAUSE this machine's own egress is not
// served — a new login is not given that road (EPIC #3208), so it sees the
// machine's own region, unsupported. C9's 27th drill: fleet-linux-0's old
// logins said SG via relay, the hub opened the newcomer there, and its login
// probed CN. A direct probe is returned as it is.
func directProbe(p *control.NodeProbe) *control.NodeProbe {
	if p == nil || p.Route != "relay" {
		return p
	}
	return &control.NodeProbe{Loc: p.LocLocal, Anthropic: control.ProbeUnsupportedRegion,
		Verdict: control.ProbeUnsupportedRegion, Laptop: p.Laptop, TS: p.TS,
		Reason: "a new login does not take the relay road its machine's logins take"}
}
