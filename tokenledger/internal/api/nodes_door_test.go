package api

import (
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// claude-fleet#3934 (EPIC #3923 C11): the admin's 机器与 pod says each
// machine's door off the operator's roster — open on the port the hub reached
// lately, cluster for a person's pod behind the cluster's door, off for the
// rest — and nothing at all while no entry port or door is set up.
func TestRosterDoors(t *testing.T) {
	h := newFleetHarness(t)
	for _, m := range []string{"mac-c", "mac-d", "u-ab12cd34"} {
		n := connectCaps(t, h, m+"-op", m, "ivan", true)
		beatCount(t, n, m, "ivan", 0)
	}
	waitFor(t, 3*time.Second, "three machines on the roster", func() bool {
		snap, err := h.srv.Nodes(time.Now())
		return err == nil && len(snap.Machines) == 3
	})
	doors := func() map[string]*MachineDoor {
		t.Helper()
		var snap NodesSnapshot
		h.getJSON(t, "/v1/nodes", &snap)
		out := map[string]*MachineDoor{}
		for _, m := range snap.Machines {
			out[m.Hostname] = m.Door
		}
		if len(out) != 3 {
			t.Fatalf("roster has %d machines, want 3: %+v", len(out), snap.Machines)
		}
		return out
	}
	// Degenerate: no entry port, no door — no door field anywhere.
	for m, d := range doors() {
		if d != nil {
			t.Fatalf("entry off: %s has door %+v, want none", m, d)
		}
	}
	setHubSetting(t, h.srv, EntryKey, "on")
	setHubSetting(t, h.srv, DoorKey, "door-1")
	now := time.Now()
	for m, rows := range map[string][]store.EntryReach{
		"mac-d": {{Addr: "203.0.113.5", Port: 22122, Family: "ipv4", Reachable: true, CheckedAt: now}},
		// reached once, but too long ago to count
		"mac-c": {{Addr: "203.0.113.4", Port: 22123, Family: "ipv4", Reachable: true, CheckedAt: now.Add(-time.Hour)}},
	} {
		if _, err := h.srv.Store.SetEntryReach(m, rows); err != nil {
			t.Fatal(err)
		}
	}
	got := doors()
	for m, want := range map[string]MachineDoor{
		"mac-d":      {State: "open", Port: 22122},
		"mac-c":      {State: "off"},
		"u-ab12cd34": {State: "cluster"},
	} {
		if got[m] == nil || *got[m] != want {
			t.Errorf("%s door = %+v, want %+v", m, got[m], want)
		}
	}
}
