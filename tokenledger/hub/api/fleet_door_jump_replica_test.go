package api

import (
	"net/http"
	"net/http/httptest"
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
}
