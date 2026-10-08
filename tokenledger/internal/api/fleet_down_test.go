package api

import (
	"strings"
	"testing"
	"time"
)

// A fleet whose tmux server is not running (claude-fleet#2477) is reported
// `down` by its node; placement never sends a start there.

// The other login's old fleet is down: however idle that login is, the
// start goes to the live fleet, and the down one's verdict says why.
func TestPlacementSkipsDownFleet(t *testing.T) {
	h := newFleetHarness(t)
	old := connectWriteNode(t, h, "m5-verkyyi")
	nu := connectWriteNode(t, h, "m5-verky")
	fo := fakeFleet(t, machineA, "fleet-24haowan-monorepo", writeRepo, "/Users/verkyyi/24haowan")
	fo.State, fo.Workers, fo.Count = fleetStateDown, nil, 0
	fn := fakeFleet(t, machineB, "fleet", writeRepo, "/Users/verky/claude-fleet", 2)
	old.beatLoad("m5", "verkyyi", machineA, 0, 0, fo)
	nu.beatLoad("m5", "verky", machineB, 6, 3, fn)
	waitFor(t, 3*time.Second, "both logins' fleets registered", func() bool {
		return len(getFleet(t, h, "/v1/fleet/fleet_list", 200)["fleets"].([]any)) == 2
	})
	pl, err := h.srv.PickNode("", writeRepo)
	if err != nil || pl.FleetID != fn.FleetID {
		t.Fatalf("placed %+v (%v); want verky's live fleet", pl, err)
	}
	var why string
	for _, c := range pl.Candidates {
		if c.FleetID == fo.FleetID {
			why = c.Excluded
		}
	}
	if why != excludedDown || excludedForFullness(why) {
		t.Fatalf("down fleet's verdict = %q; want %q, not a fullness word", why, excludedDown)
	}
	// Only the down fleet left: no machine, and the reason names it.
	nu.beatLoad("m5", "verky", machineB, 6, 3)
	waitFor(t, 3*time.Second, "verky's fleet gone", func() bool {
		_, err := h.srv.PickNode("", writeRepo)
		return err != nil
	})
	if _, err := h.srv.PickNode("", writeRepo); err == nil || !strings.Contains(err.Error(), excludedDown) {
		t.Fatalf("only a down fleet: %v; want a refusal naming %q", err, excludedDown)
	}
}

// One login, two fleets: the first by name is down, the second is up — the
// live one stands for the login (before, "first by name" picked the dead one).
func TestPlacementSameLoginPrefersLiveFleet(t *testing.T) {
	h := newFleetHarness(t)
	n := connectWriteNode(t, h, "m5")
	fd := fakeFleet(t, machineA, "a-old", writeRepo, "/Users/verky/old")
	fd.State, fd.Workers, fd.Count = fleetStateDown, nil, 0
	fu := fakeFleet(t, machineA, "b-live", writeRepo, "/Users/verky/claude-fleet", 1)
	n.beatLoad("m5", "verky", machineA, 1, 1, fd, fu)
	waitFor(t, 3*time.Second, "both fleets registered", func() bool {
		return len(getFleet(t, h, "/v1/fleet/fleet_list", 200)["fleets"].([]any)) == 2
	})
	pl, err := h.srv.PickNode("", writeRepo)
	if err != nil || pl.FleetID != fu.FleetID {
		t.Fatalf("placed %+v (%v); want the live fleet b-live", pl, err)
	}
}

// A start the node declines because the fleet's server is gone (the adapter's
// exit 8, UNAVAILABLE — nothing opened) is tried on the next machine, as any
// decline is (claude-fleet#1610), never answered UNKNOWN.
func TestClientPlaceServerDownTriesNextMachine(t *testing.T) {
	h, _, m4, m3, _, _, f3 := threeNodes(t)
	lease, key := clientLeaseFor(t, h)
	line := "start: fleet fleet-m4 has no running tmux server — nothing opened"
	m4.setOpGet(declines(8, line))
	m3.setOpGet(finished("succeeded", map[string]any{"exit": 0, "window": "@61",
		"workers": []map[string]any{{"window_id": "@61", "worker_id": f3.FleetID + "/scratch-1"}}}))
	st, out := clientPlace(t, h, lease, key, map[string]any{"repo": writeRepo, "kind": "scratch", "wait": 5})
	if st != 200 || out.Exit != 0 || out.Machine != "m3" || len(out.Attempts) != 1 ||
		!strings.Contains(out.Attempts[0].Why, "no running tmux server") {
		t.Fatalf("place = %d %+v; want done on m3 after m4's server-down decline", st, out)
	}
}
