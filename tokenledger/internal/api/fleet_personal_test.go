package api

import (
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

// A person's own computer runs only what that person opened on it
// (claude-fleet#1721, EPIC #1718 C3).

// beatPersonal is beatLoad with the heartbeat's Personal set.
func (n *writeNode) beatPersonal(host, user, machine string, load1 float64, personal bool, fleets ...control.Fleet) {
	beat(n.t, n.conn, control.Proto, control.Heartbeat{Hostname: host, OSUser: user, MachineID: machine,
		Load1: load1, NCPU: 10, MemFreeBytes: 8 << 30, MemTotalBytes: 16 << 30, Sessions: 1,
		Fleets: fleets, Personal: personal, ObservedAt: time.Now()})
}

// personalM4 is twoNodes with mac-c — the better machine — personal.
func personalM4(t *testing.T) (*harness, *writeNode, *writeNode, control.Fleet, control.Fleet) {
	t.Helper()
	h, macD, macC, f5, f4 := twoNodes(t)
	macD.beatLoad("mac-d", "frank", machineA, 5, 1, f5)
	waitLoad(t, h, "mac-d", 5)
	macC.beatPersonal("mac-c", "frank", machineB, 0.5, true, f4)
	waitFor(t, 3*time.Second, "mac-c reports personal", func() bool {
		hb, _, _ := h.srv.nodeStatusOf("ep_mac-c", time.Now())
		return hb.Personal
	})
	return h, macD, macC, f5, f4
}

// The degenerate case: no login says personal — the roster carries no
// personal key and placement is what it always was.
func TestPersonalUnsetAddsNothing(t *testing.T) {
	h, _, _, _, _ := twoNodes(t)
	machines, nodes := nodeStatuses(t, h)
	for _, host := range []string{"mac-d", "mac-c"} {
		if _, has := machines[host]["personal"]; has {
			t.Fatalf("%s machine carries personal with nothing set: %v", host, machines[host])
		}
		if _, has := nodes[host]["personal"]; has {
			t.Fatalf("%s node carries personal with nothing set: %v", host, nodes[host])
		}
	}
	if pl, err := h.srv.PickNode("", writeRepo); err != nil || pl.Machine != "mac-c" {
		t.Fatalf("placement with nothing set: %q %v; want mac-c", pl.Machine, err)
	}
}

// A personal login is never an auto candidate for a start asked from another
// machine, nor a named one; the roster says personal.
func TestPersonalNodeNotPlacedFromElsewhere(t *testing.T) {
	h, _, macC, f5, _ := personalM4(t)

	// The hub's own auto (no client lease anywhere): mac-d, mac-c personal.
	pl, err := h.srv.PickNode("", writeRepo)
	if err != nil || pl.Machine != "mac-d" || !strings.Contains(pl.Reason, "mac-c excluded: "+excludedPersonal) {
		t.Fatalf("auto placement = %q %q %v; want mac-d with mac-c excluded as personal", pl.Machine, pl.Reason, err)
	}
	// mac-d's dispatch asking auto: placed on mac-d itself.
	st, out := placeCall(t, h, h.tokens["mac-d"], map[string]any{"repo": writeRepo, "issue": 51,
		"worker_id": issueWID(f5.FleetID, 51)})
	if st != 200 || out["local"] != true {
		t.Fatalf("auto place from mac-d = %d %v; want local on mac-d", st, out)
	}
	// mac-d naming mac-c: refused, nothing sent.
	st, out = placeCall(t, h, h.tokens["mac-d"], map[string]any{"repo": writeRepo, "issue": 52,
		"worker_id": issueWID(f5.FleetID, 52), "node": "mac-c"})
	e, _ := out["error"].(map[string]any)
	if st != 503 || e["code"] != "NO_ELIGIBLE_NODE" || !strings.Contains(e["message"].(string), excludedPersonal) {
		t.Fatalf("named place on mac-c from mac-d = %d %v; want NO_ELIGIBLE_NODE naming personal", st, out)
	}
	if macC.count() != 0 {
		t.Fatalf("mac-c got %d writes; want none", macC.count())
	}
	machines, nodes := nodeStatuses(t, h)
	if nodes["mac-c"]["personal"] != true || machines["mac-c"]["personal"] != true {
		t.Fatalf("roster: machine %v node %v; want personal on mac-c", machines["mac-c"], nodes["mac-c"])
	}
	if _, has := nodes["mac-d"]["personal"]; has {
		t.Fatalf("mac-d node carries personal: %v", nodes["mac-d"])
	}
}

// A start asked from the personal machine itself — its own fleet's place,
// or the person's client running on it — is placed there as before.
func TestPersonalNodeTakesItsOwnClientsStart(t *testing.T) {
	h, _, macC, f5, f4 := personalM4(t)

	// mac-c's own fleet asking auto: mac-c is a candidate again (and the best).
	st, out := placeCall(t, h, h.tokens["mac-c"], map[string]any{"repo": writeRepo, "issue": 61,
		"worker_id": issueWID(f4.FleetID, 61)})
	if st != 200 || out["local"] != true {
		t.Fatalf("auto place from mac-c = %d %v; want local on mac-c", st, out)
	}

	// The operator's door with the operator's client on mac-c: auto lands on mac-c.
	now := time.Now()
	h.srv.clientLeases.acquire("operator", ClientLeaseRequest{Device: "MacBook", Host: "mac-c"}, now)
	if pl, err := h.srv.PickNode("", writeRepo); err != nil || pl.Machine != "mac-c" {
		t.Fatalf("auto with the client on mac-c = %q %q %v; want mac-c", pl.Machine, pl.Reason, err)
	}
	op := postFleet(t, h, "worker_start", map[string]any{"repo": writeRepo, "issue": float64(62),
		"node": "auto", "idempotency_key": "personal-own-62"}, 200)
	if op["fleet_id"] != f4.FleetID || macC.count() != 1 {
		t.Fatalf("worker_start from mac-c's client = %v (mac-c writes %d); want it on mac-c's fleet", op, macC.count())
	}

	// The client moves to another device (a lease on mac-d): mac-c is out again,
	// for auto and for a start naming mac-c's fleet directly.
	h.srv.clientLeases.acquire("operator", ClientLeaseRequest{Device: "mini", Host: "mac-d"}, now.Add(time.Second))
	if pl, err := h.srv.PickNode("", writeRepo); err != nil || pl.Machine != "mac-d" {
		t.Fatalf("auto with the client on mac-d = %q %v; want mac-d", pl.Machine, err)
	}
	out = postFleet(t, h, "worker_start", map[string]any{"fleet_id": f4.FleetID, "repo": writeRepo,
		"issue": float64(63), "idempotency_key": "personal-direct-63"}, http.StatusServiceUnavailable)
	if e, _ := out["error"].(map[string]any); e["code"] != "NO_ELIGIBLE_NODE" || macC.count() != 1 {
		t.Fatalf("direct start on mac-c's fleet from mac-d's client = %v (mac-c writes %d); want NO_ELIGIBLE_NODE, nothing sent", out, macC.count())
	}
	_ = f5
}

// The sleep flag: a personal machine enters 维护中 with reason sleep and
// clears it on waking — but a wake never ends the operator's maintenance.
func TestPersonalSleepMaintenance(t *testing.T) {
	h, _, _, _, _ := personalM4(t)
	tok := h.tokens["mac-c"]
	st, out := maintCall(t, h, tok, http.MethodPost, map[string]any{"action": "enter", "reason": SleepReason})
	if st != 200 || out["status"] != "maintenance" {
		t.Fatalf("sleep enter = %d %v; want maintenance", st, out)
	}
	if pl, err := h.srv.PickNode("", writeRepo); err != nil || pl.Machine != "mac-d" {
		t.Fatalf("placement while mac-c sleeps = %q %v; want mac-d", pl.Machine, err)
	}
	st, out = maintCall(t, h, tok, http.MethodPost, map[string]any{"action": "leave", "if_reason": SleepReason})
	if st != 200 || out["status"] != "online" || out["maintenance"] != nil {
		t.Fatalf("wake leave = %d %v; want online", st, out)
	}

	// The operator's maintenance survives the machine's wake.
	putSetting(t, h, NodeMaintenancePrefix+"mac-c", "disk swap", 200)
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
