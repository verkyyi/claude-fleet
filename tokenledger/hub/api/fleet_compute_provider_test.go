package api

import (
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

// One eligibility rule, provider-aware (claude-fleet#4707): a login its egress
// region closed (CN) is no place for a Claude start but is one for a Codex
// start, and the two roads that open a session — a node's /v1/node/place and
// the operator's worker_start named at the fleet — agree on the same
// (machine, provider).
func TestComputeRegionIsProviderAware(t *testing.T) {
	h, _, macC, f5, f4 := twoNodes(t)
	macC.beatProbe("mac-c", "frank", machineB, nil, false, probe("CN", control.ProbeUnsupportedRegion), f4)
	waitProbe(t, h, "ep_mac-c", control.ProbeUnsupportedRegion, false)
	macC.setOpGet(finished("succeeded", map[string]any{"exit": 0, "window": "@7"}))

	for _, tc := range []struct {
		provider string
		ok       bool
	}{{"claude", false}, {"codex", true}, {"", false}} {
		_, err := h.srv.pickNode(fleetPrincipal{}, writeRepo, "mac-c", tc.provider, time.Now())
		if (err == nil) != tc.ok {
			t.Fatalf("pickNode(mac-c, %q) err = %v; want eligible=%v", tc.provider, err, tc.ok)
		}
	}

	// Road 1: the node's own start through /v1/node/place.
	place := func(issue int, agent string) (int, map[string]any) {
		body := map[string]any{"repo": writeRepo, "issue": issue, "worker_id": issueWID(f5.FleetID, issue),
			"node": "mac-c", "wait": 0}
		if agent != "" {
			body["agent"] = agent
		}
		return placeCall(t, h, h.tokens["mac-d"], body)
	}
	if st, out := place(71, "claude"); st != 503 || out["error"].(map[string]any)["code"] != "NO_ELIGIBLE_NODE" {
		t.Fatalf("place claude on CN mac-c = %d %v; want NO_ELIGIBLE_NODE", st, out)
	}
	if st, out := place(72, "codex"); st != 200 || out["local"] != false {
		t.Fatalf("place codex on CN mac-c = %d %v; want the start sent to mac-c", st, out)
	}

	// Road 2: worker_start named at mac-c's fleet — the same verdicts.
	op := postFleet(t, h, "worker_start", map[string]any{"issue": 73, "fleet_id": f4.FleetID, "agent": "codex",
		"idempotency_key": "cn-codex"}, 200)
	if op["status"] != "accepted" {
		t.Fatalf("worker_start codex on CN mac-c = %v; want accepted", op)
	}
	out := postFleet(t, h, "worker_start", map[string]any{"issue": 74, "fleet_id": f4.FleetID, "agent": "claude",
		"idempotency_key": "cn-claude"}, 503)
	if e, _ := out["error"].(map[string]any); e["code"] != "NO_ELIGIBLE_NODE" || !strings.Contains(e["message"].(string), "CN") {
		t.Fatalf("worker_start claude on CN mac-c = %v; want NO_ELIGIBLE_NODE naming CN", out)
	}
}

// The waiver is the region's alone: a login whose own word is off stays off
// for Codex too, and the finding still names the closed login.
func TestComputeRegionCodexKeepsOwnOff(t *testing.T) {
	h, _, macC, _, f4 := twoNodes(t)
	macC.beatProbe("mac-c", "frank", machineB, computeOff(), false, probe("CN", control.ProbeUnsupportedRegion), f4)
	waitProbe(t, h, "ep_mac-c", control.ProbeUnsupportedRegion, false)
	if _, err := h.srv.pickNode(fleetPrincipal{}, writeRepo, "mac-c", "codex", time.Now()); err == nil {
		t.Fatal("a login that asked for no sessions took a Codex start")
	}
}
