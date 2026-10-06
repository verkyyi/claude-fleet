package api

import (
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
)

// A person's own computer runs only what that person opened on it
// (claude-fleet#1721, EPIC #1718 C3).

// beatPersonal is beatLoad with the heartbeat's Personal set.
func (n *writeNode) beatPersonal(host, user, machine string, load1 float64, personal bool, fleets ...control.Fleet) {
	beat(n.t, n.conn, control.Proto, control.Heartbeat{Hostname: host, OSUser: user, MachineID: machine,
		Load1: load1, NCPU: 10, MemFreeBytes: 8 << 30, MemTotalBytes: 16 << 30, Sessions: 1,
		Fleets: fleets, Personal: personal, ObservedAt: time.Now()})
}

// personalM4 is twoNodes with m4 — the better machine — personal.
func personalM4(t *testing.T) (*harness, *writeNode, *writeNode, control.Fleet, control.Fleet) {
	t.Helper()
	h, m5, m4, f5, f4 := twoNodes(t)
	m5.beatLoad("m5", "verk", machineA, 5, 1, f5)
	m4.beatPersonal("m4", "verk", machineB, 0.5, true, f4)
	waitFor(t, 3*time.Second, "m4 reports personal", func() bool {
		hb, _, _ := h.srv.nodeStatusOf("ep_m4", time.Now())
		return hb.Personal
	})
	return h, m5, m4, f5, f4
}

// The degenerate case: no login says personal — the roster carries no
// personal key and placement is what it always was.
func TestPersonalUnsetAddsNothing(t *testing.T) {
	h, _, _, _, _ := twoNodes(t)
	machines, nodes := nodeStatuses(t, h)
	for _, host := range []string{"m5", "m4"} {
		if _, has := machines[host]["personal"]; has {
			t.Fatalf("%s machine carries personal with nothing set: %v", host, machines[host])
		}
		if _, has := nodes[host]["personal"]; has {
			t.Fatalf("%s node carries personal with nothing set: %v", host, nodes[host])
		}
	}
	if pl, err := h.srv.PickNode("", writeRepo); err != nil || pl.Machine != "m4" {
		t.Fatalf("placement with nothing set: %q %v; want m4", pl.Machine, err)
	}
}

// A personal login is never an auto candidate for a start asked from another
// machine, nor a named one; the roster says personal.
func TestPersonalNodeNotPlacedFromElsewhere(t *testing.T) {
	h, _, m4, f5, _ := personalM4(t)

	// The hub's own auto (no client lease anywhere): m5, m4 personal.
	pl, err := h.srv.PickNode("", writeRepo)
	if err != nil || pl.Machine != "m5" || !strings.Contains(pl.Reason, "m4 excluded: "+excludedPersonal) {
		t.Fatalf("auto placement = %q %q %v; want m5 with m4 excluded as personal", pl.Machine, pl.Reason, err)
	}
	// m5's dispatch asking auto: placed on m5 itself.
	st, out := placeCall(t, h, h.tokens["m5"], map[string]any{"repo": writeRepo, "issue": 51,
		"worker_id": issueWID(f5.FleetID, 51)})
	if st != 200 || out["local"] != true {
		t.Fatalf("auto place from m5 = %d %v; want local on m5", st, out)
	}
	// m5 naming m4: refused, nothing sent.
	st, out = placeCall(t, h, h.tokens["m5"], map[string]any{"repo": writeRepo, "issue": 52,
		"worker_id": issueWID(f5.FleetID, 52), "node": "m4"})
	e, _ := out["error"].(map[string]any)
	if st != 503 || e["code"] != "NO_ELIGIBLE_NODE" || !strings.Contains(e["message"].(string), excludedPersonal) {
		t.Fatalf("named place on m4 from m5 = %d %v; want NO_ELIGIBLE_NODE naming personal", st, out)
	}
	if m4.count() != 0 {
		t.Fatalf("m4 got %d writes; want none", m4.count())
	}
	machines, nodes := nodeStatuses(t, h)
	if nodes["m4"]["personal"] != true || machines["m4"]["personal"] != true {
		t.Fatalf("roster: machine %v node %v; want personal on m4", machines["m4"], nodes["m4"])
	}
	if _, has := nodes["m5"]["personal"]; has {
		t.Fatalf("m5 node carries personal: %v", nodes["m5"])
	}
}

// A start asked from the personal machine itself — its own fleet's place,
// or the person's client running on it — is placed there as before.
func TestPersonalNodeTakesItsOwnClientsStart(t *testing.T) {
	h, _, m4, f5, f4 := personalM4(t)

	// m4's own fleet asking auto: m4 is a candidate again (and the best).
	st, out := placeCall(t, h, h.tokens["m4"], map[string]any{"repo": writeRepo, "issue": 61,
		"worker_id": issueWID(f4.FleetID, 61)})
	if st != 200 || out["local"] != true {
		t.Fatalf("auto place from m4 = %d %v; want local on m4", st, out)
	}

	// The operator's door with the operator's client on m4: auto lands on m4.
	now := time.Now()
	h.srv.clientLeases.acquire("operator", ClientLeaseRequest{Device: "MacBook", Host: "m4"}, now)
	if pl, err := h.srv.PickNode("", writeRepo); err != nil || pl.Machine != "m4" {
		t.Fatalf("auto with the client on m4 = %q %q %v; want m4", pl.Machine, pl.Reason, err)
	}
	op := postFleet(t, h, "worker_start", map[string]any{"repo": writeRepo, "issue": float64(62),
		"node": "auto", "idempotency_key": "personal-own-62"}, 200)
	if op["fleet_id"] != f4.FleetID || m4.count() != 1 {
		t.Fatalf("worker_start from m4's client = %v (m4 writes %d); want it on m4's fleet", op, m4.count())
	}

	// The client moves to another device (a lease on m5): m4 is out again,
	// for auto and for a start naming m4's fleet directly.
	h.srv.clientLeases.acquire("operator", ClientLeaseRequest{Device: "mini", Host: "m5"}, now.Add(time.Second))
	if pl, err := h.srv.PickNode("", writeRepo); err != nil || pl.Machine != "m5" {
		t.Fatalf("auto with the client on m5 = %q %v; want m5", pl.Machine, err)
	}
	out = postFleet(t, h, "worker_start", map[string]any{"fleet_id": f4.FleetID, "repo": writeRepo,
		"issue": float64(63), "idempotency_key": "personal-direct-63"}, http.StatusServiceUnavailable)
	if e, _ := out["error"].(map[string]any); e["code"] != "NO_ELIGIBLE_NODE" || m4.count() != 1 {
		t.Fatalf("direct start on m4's fleet from m5's client = %v (m4 writes %d); want NO_ELIGIBLE_NODE, nothing sent", out, m4.count())
	}
	_ = f5
}

// The sleep flag: a personal machine enters 维护中 with reason sleep and
// clears it on waking — but a wake never ends the operator's maintenance.
func TestPersonalSleepMaintenance(t *testing.T) {
	h, _, _, _, _ := personalM4(t)
	tok := h.tokens["m4"]
	st, out := maintCall(t, h, tok, http.MethodPost, map[string]any{"action": "enter", "reason": SleepReason})
	if st != 200 || out["status"] != "maintenance" {
		t.Fatalf("sleep enter = %d %v; want maintenance", st, out)
	}
	if pl, err := h.srv.PickNode("", writeRepo); err != nil || pl.Machine != "m5" {
		t.Fatalf("placement while m4 sleeps = %q %v; want m5", pl.Machine, err)
	}
	st, out = maintCall(t, h, tok, http.MethodPost, map[string]any{"action": "leave", "if_reason": SleepReason})
	if st != 200 || out["status"] != "online" || out["maintenance"] != nil {
		t.Fatalf("wake leave = %d %v; want online", st, out)
	}

	// The operator's maintenance survives the machine's wake.
	putSetting(t, h, NodeMaintenancePrefix+"m4", "disk swap", 200)
	st, out = maintCall(t, h, tok, http.MethodPost, map[string]any{"action": "leave", "if_reason": SleepReason})
	m, _ := out["maintenance"].(map[string]any)
	if st != 200 || out["status"] != "maintenance" || m["reason"] != "disk swap" {
		t.Fatalf("wake over the operator's flag = %d %v; want it kept", st, out)
	}
	// A plain leave still clears anything, as before.
	if st, out = maintCall(t, h, tok, http.MethodPost, map[string]any{"action": "leave"}); st != 200 || out["maintenance"] != nil {
		t.Fatalf("plain leave = %d %v", st, out)
	}
}
