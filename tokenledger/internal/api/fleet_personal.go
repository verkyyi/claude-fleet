package api

import (
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
)

// A person's own computer runs only what that person opened on it
// (claude-fleet#1721, EPIC #1718 C3).
//
// A login that opened compute with `fleet node compute on --personal` — a
// laptop's default — says personal in its hello and every beat
// (CCQUOTA_FLEET_PERSONAL=1 in node.env). Placement then treats it unlike a
// machine that is always on:
//
//   - it is no candidate for a start asked from ANYWHERE ELSE — auto or named.
//     m5's dispatch daemon, a worker on m4 spawning a child, a rebalance: none
//     of them ever lands on the MacBook, which can close its lid at any time;
//   - a start asked FROM it is placed as before: its own fleet asking
//     (/v1/node/place, a session or the client attached there), or its
//     person's client running on it right now (the C5 client lease's host,
//     claude-fleet#1715) when the request comes through a person's door.
//
// The client on a personal machine opens its sessions there to begin with
// (FLEET_SPAWN_NODE defaults to local, bin/fleet-lib.sh fleet_spawn_node), so
// the hub only sees its auto when the person asked for one.
//
// Sleep: the node's agent flags its machine 维护中 with reason "sleep" just
// before the machine sleeps and clears it on waking — but only that flag:
// /v1/node/maintenance's leave with if_reason leaves an operator's own
// maintenance alone (fleet_maintenance.go).
//
// No personal login anywhere ⇒ nothing here changes a placement
// (TestPersonalUnsetAddsNothing).

// excludedPersonal is placement's word for a personal login asked from
// elsewhere.
const excludedPersonal = "personal (只跑本机客户端开的会话)"

// SleepReason is the maintenance reason a sleeping personal machine sets.
const SleepReason = "sleep"

// personalOf is one login's word: its newest beat when there is one, else
// its live link's hello.
func (s *Server) personalOf(endpointID string, hb control.Heartbeat) bool {
	if !hb.ObservedAt.IsZero() {
		return hb.Personal
	}
	if c := s.nodes.get(endpointID); c != nil {
		return c.personal
	}
	return false
}

// askedFrom is the machine a placement is asked from: the asking node's own
// (p.From), else the machine the person's client runs on right now.
func (s *Server) askedFrom(p fleetPrincipal, now time.Time) string {
	if p.From != "" {
		return p.From
	}
	if l, ok := s.ClientLeaseOf(p.Person, now); ok {
		return l.Host
	}
	return ""
}

// isMachine matches a roster hostname against a name a caller or client
// gave — the whole name, a first label, or the machine's alias.
func (s *Server) isMachine(hostname, name string) bool {
	if name == "" || hostname == "" {
		return false
	}
	return sameMachine(hostname, name) || sameMachine(name, firstLabel(hostname)) ||
		strings.EqualFold(s.nodeMachineLabel(hostname), firstLabel(name))
}
