package api

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

func TestDoorJumpReadinessAcrossReplicas(t *testing.T) {
	first, second := newReplicaPair(t)
	now := time.Now()
	first.srv.noteJump(httptest.NewRequest(http.MethodGet, "/?jump=1&ns=fleet-workers", nil), "fleet-door", true, now)
	second.srv.noteJump(httptest.NewRequest(http.MethodGet, "/?jump=1", nil), "u-alice1", false, now)
	for _, replica := range []*harness{first, second} {
		if got := replica.srv.jumpTarget("u-alice1", "fleet-door", now); got != "u-alice1.fleet-workers.svc.cluster.local" {
			t.Errorf("%s: jump target = %q", replica.srv.Replica.Name, got)
		}
		if got := replica.srv.jumpTarget("u-alice1", "fleet-door", now.Add(jumpFresh+time.Second)); got != "" {
			t.Errorf("%s: expired readiness still routes to %q", replica.srv.Replica.Name, got)
		}
	}
	restarted := &Server{Store: first.srv.Store}
	if got := restarted.jumpTarget("u-alice1", "fleet-door", now); got != "u-alice1.fleet-workers.svc.cluster.local" {
		t.Fatalf("restarted replica lost readiness: %q", got)
	}
	pod := FleetMachine{Hostname: "u-alice1", Routes: []FleetRoute{{Name: "entry", Host: "door.example", Port: 22022}}}
	for _, replica := range []*harness{first, second} {
		route := replica.srv.withJump(pod, "fleet-door", []string{"pod-host-key"}, now)
		if route.Routes[0].Jump != doorJumpUser || route.Routes[0].Target != "u-alice1.fleet-workers.svc.cluster.local" || len(route.TargetHostKeys) != 1 {
			t.Errorf("%s: incomplete jump route: %+v", replica.srv.Replica.Name, route)
		}
	}
}

func TestEntryMachineAuthorizationAcrossReplicas(t *testing.T) {
	first, second := newReplicaPair(t)
	if err := first.srv.Store.SetFleetSetting(EntryKey, "on", time.Now()); err != nil {
		t.Fatal(err)
	}
	for _, machine := range []bool{true, false} {
		label := "ordinary-login"
		caps := []string{control.CapEntryKeys}
		want := http.StatusForbidden
		if machine {
			label = "pod-machine"
			caps = append(caps, control.CapMachine)
			want = http.StatusOK
		}
		token := first.enroll(t, label)
		connection := teamNode(t, first, token, caps...)
		beat(t, connection, control.Proto, control.Heartbeat{Hostname: "u-alice1", OSUser: "alice"})
		waitFor(t, 3*time.Second, "pod identity recorded", func() bool {
			row := first.srv.nodeRow("ep_" + label)
			return row != nil && row.Hostname == "u-alice1" && row.OSUser == "alice" && holder(t, first, "ep_"+label) == first.srv.Replica.Name
		})
		for _, replica := range []*harness{first, second} {
			code, raw := entryCall(t, replica, http.MethodGet, control.EntryKeysNodePath+"?jump=1", asNode(token), nil)
			if code != want {
				t.Errorf("%s, machine=%v: HTTP %d, want %d: %s", replica.srv.Replica.Name, machine, code, want, raw)
			}
		}
	}
	// The pod's pull through the replica that does NOT hold its link said it
	// is ready, and both replicas know it (claude-fleet#4317).
	for _, replica := range []*harness{first, second} {
		if w, ok := replica.srv.jumpWordOf("u-alice1", time.Now()); !ok {
			t.Errorf("%s: the pod's readiness is not seen: %+v", replica.srv.Replica.Name, w)
		}
	}
}

func TestDoorJumpSaysWhichEndIsMissing(t *testing.T) {
	first, _ := newReplicaPair(t)
	now := time.Now()
	why := func() string { _, w := first.srv.jumpTargetWhy("u-alice1", "fleet-door", now); return w }
	if w := why(); !strings.Contains(w, "door fleet-door never said") {
		t.Fatalf("no door word: %q", w)
	}
	first.srv.noteJump(httptest.NewRequest(http.MethodGet, "/?jump=1&ns=fleet-workers", nil), "fleet-door", true, now.Add(-jumpFresh-time.Second))
	if w := why(); !strings.Contains(w, "door fleet-door last said") {
		t.Fatalf("stale door word: %q", w)
	}
	first.srv.noteJump(httptest.NewRequest(http.MethodGet, "/?jump=1&ns=fleet-workers", nil), "fleet-door", true, now)
	if w := why(); !strings.Contains(w, "pod never said") {
		t.Fatalf("no pod word: %q", w)
	}
	first.srv.noteJump(httptest.NewRequest(http.MethodGet, "/?jump=1", nil), "u-alice1", false, now)
	if w := why(); w != "" {
		t.Fatalf("both said so, still: %q", w)
	}
	pod := FleetMachine{Hostname: "u-alice1", Routes: []FleetRoute{{Name: "entry", Host: "door.example", Port: 22022}}}
	if got := first.srv.withJump(pod, "fleet-door", nil, now); got.Routes[0].Jump != "" {
		t.Fatalf("a jump with the pod's own host keys unknown: %+v", got.Routes[0])
	}
}
