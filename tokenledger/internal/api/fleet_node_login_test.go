package api

import (
	"strings"
	"testing"
	"time"
)

// twoLogins is claude-fleet#2430's rig: ONE machine, m5, with two logins of
// the same person — verkyyi (the old admin account, busy) and verky (the
// ordinary account, idle) — each with its own fleet hosting the repo.
func twoLogins(t *testing.T) (*harness, *writeNode, *writeNode, string, string) {
	t.Helper()
	h := newFleetHarness(t)
	old := connectWriteNode(t, h, "m5-verkyyi")
	nu := connectWriteNode(t, h, "m5-verky")
	fo := fakeFleet(t, machineA, "fleet-old", writeRepo, "/Users/verkyyi/claude-fleet", 1)
	fn := fakeFleet(t, machineB, "fleet-new", writeRepo, "/Users/verky/claude-fleet", 2)
	old.beatLoad("m5", "verkyyi", machineA, 8, 6, fo)
	nu.beatLoad("m5", "verky", machineB, 1, 1, fn)
	waitFor(t, 3*time.Second, "both logins' fleets registered", func() bool {
		return len(getFleet(t, h, "/v1/fleet/fleet_list", 200)["fleets"].([]any)) == 2
	})
	return h, old, nu, fo.FleetID, fn.FleetID
}

// The client's place answer says WHICH login the session landed under, so the
// client connects as it (before: the far end was asked as verkyyi and answered
// "not live" for a session in verky's fleet).
func TestClientPlaceSaysTheLogin(t *testing.T) {
	h, old, nu, _, fnew := twoLogins(t)
	lease, key := clientLeaseFor(t, h)
	nu.setOpGet(finished("succeeded", map[string]any{"exit": 0, "window": "@17",
		"workers": []map[string]any{{"window_id": "@17", "worker_id": fnew + "/scratch-1"}}}))
	st, out := clientPlace(t, h, lease, key, map[string]any{"repo": writeRepo, "kind": "scratch", "node": "auto",
		"idempotency_key": "two-logins-1"})
	if st != 200 || out.State != "done" || out.Placement == nil || out.Placement.FleetID != fnew {
		t.Fatalf("place = %d %+v; want done in verky's fleet %s", st, out, fnew)
	}
	if out.Login != "verky" {
		t.Fatalf("login = %q; want verky (the login the session's fleet runs under)", out.Login)
	}
	if old.count() != 0 || nu.count() != 1 {
		t.Fatalf("writes verkyyi=%d verky=%d; want 0 and 1", old.count(), nu.count())
	}
}

// fleet.node_login.<machine> pins new sessions to one login there — whatever
// the room says — and a start named at the other login's fleet is refused.
func TestNodeLoginSettingPinsPlacement(t *testing.T) {
	h, old, nu, fold, fnew := twoLogins(t)
	pl, err := h.srv.PickNode("", writeRepo)
	if err != nil || pl.FleetID != fnew {
		t.Fatalf("no setting: placed %+v (%v); want verky's idle fleet", pl, err)
	}
	putSetting(t, h, NodeLoginPrefix+"m5", "verkyyi", 200)
	pl, err = h.srv.PickNode("", writeRepo)
	if err != nil || pl.FleetID != fold {
		t.Fatalf("node_login=verkyyi: placed %+v (%v); want verkyyi's fleet", pl, err)
	}
	var why string
	for _, c := range pl.Candidates {
		if c.OSUser == "verky" {
			why = c.Excluded
		}
	}
	if !strings.HasPrefix(why, excludedOtherLogin) || excludedForFullness(why) {
		t.Fatalf("verky's verdict = %q; want %q…, not a fullness word", why, excludedOtherLogin)
	}
	// Named straight at verky's fleet: held to the same rule.
	postFleet(t, h, "worker_start", map[string]any{"issue": 9, "repo": writeRepo, "fleet_id": fnew,
		"idempotency_key": "named-verky"}, 503)
	if nu.count() != 0 || old.count() != 0 {
		t.Fatalf("writes verkyyi=%d verky=%d; want none", old.count(), nu.count())
	}
	// A bad login is refused; "" lifts it.
	putSetting(t, h, NodeLoginPrefix+"m5", "Not A Login", 400)
	putSetting(t, h, NodeLoginPrefix+"m5", "", 200)
	if pl, err = h.srv.PickNode("", writeRepo); err != nil || pl.FleetID != fnew {
		t.Fatalf("lifted: placed %+v (%v); want verky's idle fleet again", pl, err)
	}
}

// No setting adds nothing: every candidate's verdict is what it was.
func TestNodeLoginOffAddsNothing(t *testing.T) {
	if why := otherLoginExcluded("m5", "verky", map[string]string{}); why != "" {
		t.Fatalf("no setting: %q", why)
	}
	if why := otherLoginExcluded("m4.local", "verky", map[string]string{NodeLoginPrefix + "m5": "verkyyi"}); why != "" {
		t.Fatalf("another machine's setting: %q", why)
	}
	if why := otherLoginExcluded("m5.local", "verkyyi", map[string]string{NodeLoginPrefix + "m5": "verkyyi"}); why != "" {
		t.Fatalf("the accepting login itself: %q", why)
	}
}
