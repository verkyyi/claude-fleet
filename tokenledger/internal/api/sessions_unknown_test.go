package api

import (
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// A fleet the agent could not read (claude-fleet#1465) is state "unknown"
// with Count 0. The login's session count is then unknown — never the 0 the
// heartbeat's sum says — on /v1/nodes, in fleet_sessions' machine list and in
// placement, which never prefers it to a machine known to run one session.

const unreadable = "UNAVAILABLE: fleet_status: tmux: command not found"

// unknownFleet is f as the agent reports a failed fleet_status read.
func unknownFleet(f control.Fleet) control.Fleet {
	f.State, f.Count, f.Workers, f.Error = control.FleetStateUnknown, 0, nil, unreadable
	return f
}

func sessionsIs(p *int, n int) bool { return p != nil && *p == n }

func TestUnreadableFleetSessionsAreUnknown(t *testing.T) {
	h, m5, m4, f5, f4 := twoNodes(t)
	// Same load on both; m5's fleet cannot be read, m4 runs one session.
	m5.beatLoad("m5", "verk", machineA, 1, 0, unknownFleet(f5))
	m4.beatLoad("m4", "verk", machineB, 1, 1, f4)
	var snap NodesSnapshot
	waitFor(t, 3*time.Second, "m5's unreadable beat", func() bool {
		snap = roster(t, h)
		for _, n := range snap.Nodes {
			if n.Hostname == "m5" {
				return n.Sessions == nil
			}
		}
		return false
	})

	// /v1/nodes: null, with the fleet and the reason.
	for _, n := range snap.Nodes {
		switch n.Hostname {
		case "m5":
			if len(n.SessionsUnknown) != 1 || n.SessionsUnknown[0] != "fleet-m5: "+unreadable {
				t.Fatalf("m5 sessions_unknown = %q; want the fleet and why", n.SessionsUnknown)
			}
			if len(n.Fleets) != 1 || n.Fleets[0].State != "unknown" || n.Fleets[0].Error != unreadable {
				t.Fatalf("m5 fleets = %+v", n.Fleets)
			}
		case "m4":
			if !sessionsIs(n.Sessions, 1) || n.SessionsUnknown != nil {
				t.Fatalf("m4 = %+v; a read fleet keeps its count", n)
			}
		}
	}
	for _, m := range snap.Machines {
		if m.Hostname == "m5" && (m.Sessions != nil || len(m.SessionsUnknown) != 1 || !strings.HasPrefix(m.SessionsUnknown[0], "verk/fleet-m5: ")) {
			t.Fatalf("machine m5 = %+v; one unreadable login makes the machine's count unknown", m)
		}
		if m.Hostname == "m4" && !sessionsIs(m.Sessions, 1) {
			t.Fatalf("machine m4 = %+v", m)
		}
	}

	// fleet_sessions' machine list (the status line's source): null on m5.
	nodes, _ := getFleet(t, h, "/v1/fleet/fleet_sessions", 200)["nodes"].([]any)
	seen := 0
	for _, x := range nodes {
		n := x.(map[string]any)
		switch n["machine_name"] {
		case "m5":
			seen++
			if v, ok := n["sessions"]; !ok || v != nil {
				t.Fatalf("fleet_sessions m5 = %v; want sessions null", n)
			}
		case "m4":
			seen++
			if n["sessions"] != float64(1) {
				t.Fatalf("fleet_sessions m4 = %v; want 1", n)
			}
		}
	}
	if seen != 2 {
		t.Fatalf("fleet_sessions nodes = %v", nodes)
	}

	// Placement: m5 scores no better than m4's known one session, and the
	// start goes to m4.
	op := postFleet(t, h, "worker_start", map[string]any{"issue": 21, "repo": writeRepo, "idempotency_key": "start-21"}, 200)
	pl, _ := op["placement"].(map[string]any)
	if pl["machine"] != "m4" {
		t.Fatalf("placement = %v; an unreadable machine must not win", pl)
	}
	var s5, s4 float64
	for _, x := range pl["candidates"].([]any) {
		c := x.(map[string]any)
		switch c["machine"] {
		case "m5":
			s5 = c["score"].(float64)
			if c["sessions"] != nil || !strings.Contains(c["sessions_unknown"].(string), "fleet-m5") {
				t.Fatalf("m5 candidate = %v; want sessions null with why", c)
			}
		case "m4":
			s4 = c["score"].(float64)
		}
	}
	if s5 > s4 {
		t.Fatalf("scores m5=%.3f m4=%.3f; unknown must not score above a known 1 session", s5, s4)
	}
	if m4.count() != 1 || m5.count() != 0 {
		t.Fatalf("writes: m5=%d m4=%d", m5.count(), m4.count())
	}
}

// better ranks a known count first even when the unknown one scores higher.
func TestBetterRanksKnownSessionsFirst(t *testing.T) {
	one := 1
	known := Candidate{Machine: "a", Score: 0.2, Sessions: &one}
	unknown := Candidate{Machine: "b", Score: 0.9}
	if !better(known, unknown) || better(unknown, known) {
		t.Fatal("an unknown session count outranked a known one")
	}
}

// The SPOT idle clock never runs out on a count it could not take.
func TestSpotBusyTreatsUnknownAsBusy(t *testing.T) {
	c := &SpotController{}
	idle := store.Node{StatusJSON: `{"hostname":"s","sessions":0,"fleets":[{"fleet_id":"f","name":"x","state":"running","count":0}]}`}
	unread := store.Node{StatusJSON: `{"hostname":"s","sessions":0,"fleets":[{"fleet_id":"f","name":"x","state":"unknown","count":0}]}`}
	if c.busy(idle) {
		t.Fatal("a read fleet with no session is idle")
	}
	if !c.busy(unread) {
		t.Fatal("an unreadable fleet read as idle")
	}
}

// Nothing unreadable: the count is the heartbeat's sum, as it always was.
func TestSessionsCountDegenerate(t *testing.T) {
	hb := control.Heartbeat{Sessions: 3, Fleets: []control.Fleet{{Name: "a", State: "running", Count: 3}}}
	if n := hb.SessionsCount(); !sessionsIs(n, 3) || hb.UnreadableFleets() != nil {
		t.Fatalf("count = %v unknown = %v", n, hb.UnreadableFleets())
	}
	if n := (control.Heartbeat{}).SessionsCount(); !sessionsIs(n, 0) {
		t.Fatalf("no fleets = %v; want 0", n)
	}
}

// A failed read is "could not read", never "no windows" (claude-fleet#1795):
// fleet_sessions keeps the machine's last-read rows while its fleet is
// unknown, so the sidebar on every client does not collapse to the one row it
// stands on for the seconds a node's fleet_status times out. A read that
// stands — even an empty one — replaces them as before.
func TestUnreadableFleetKeepsItsLastRows(t *testing.T) {
	h, m5, _, f5, _ := twoNodes(t)
	m5rows := func() int {
		n := 0
		for _, x := range getFleet(t, h, "/v1/fleet/fleet_sessions", 200)["sessions"].([]any) {
			if x.(map[string]any)["machine_name"] == "m5" {
				n++
			}
		}
		return n
	}
	if got := m5rows(); got != 1 {
		t.Fatalf("m5 rows before = %d; want 1", got)
	}
	m5.beatLoad("m5", "verk", machineA, 1, 0, unknownFleet(f5))
	waitFor(t, 3*time.Second, "m5's unreadable beat", func() bool {
		for _, n := range roster(t, h).Nodes {
			if n.Hostname == "m5" {
				return n.Sessions == nil
			}
		}
		return false
	})
	if got := m5rows(); got != 1 {
		t.Fatalf("m5 rows while unreadable = %d; want the last-read 1, not 0", got)
	}
	empty := fakeFleet(t, machineA, "fleet-m5", writeRepo, "/u/verk/claude-fleet")
	m5.beatLoad("m5", "verk", machineA, 1, 0, empty)
	waitFor(t, 3*time.Second, "m5's empty read", func() bool { return m5rows() == 0 })
}
