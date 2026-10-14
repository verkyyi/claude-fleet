package api

import (
	"context"
	"net/http"
	"net/netip"
	"testing"
	"time"

	"golang.org/x/crypto/ssh"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
)

// claude-fleet#4149: a door whose image reports `entry reach` only at its
// start kept a pod's door route for EntryReachFresh, then none. Its pull is
// the beat: a pulling door's stale check is re-dialled by the hub (the
// addresses it reported, its own host key) — reachable again while its sshd
// answers, not once it does not.
func TestDoorPullKeepsItsReachFresh(t *testing.T) {
	h := entryHarness(t)
	oldD, oldA := entryDialable, doorReachAsync
	entryDialable = func(a netip.Addr) bool { return a.IsLoopback() || entryPublicAddr(a) }
	doorReachAsync = false
	t.Cleanup(func() { entryDialable, doorReachAsync = oldD, oldA })
	if err := h.srv.Store.SetFleetSetting(DoorKey, "fleet-door", time.Now()); err != nil {
		t.Fatal(err)
	}
	_, dtok := rootNode(t, h, "door", "fleet-door", control.CapEntryKeys)
	port, key := reachSSHD(t)
	rep := control.EntryReachReport{Port: port, HostKey: reachKeyLine(key), Listening: true}
	if code, v, raw := reachPost(t, h, dtok, rep, ""); code != 200 || len(v.Addrs) != 1 || !v.Addrs[0].Reachable {
		t.Fatalf("the door's one report: HTTP %d %s", code, raw)
	}

	// 20 minutes on, no second report: the check has lapsed.
	stale := func() {
		rows, err := h.srv.entryReachRows("fleet-door")
		if err != nil {
			t.Fatal(err)
		}
		for i := range rows {
			rows[i].CheckedAt = time.Now().Add(-20 * time.Minute)
		}
		if _, err := h.srv.Store.SetEntryReach("fleet-door", rows); err != nil {
			t.Fatal(err)
		}
		h.srv.entryReachAt.Delete("fleet-door")
	}
	stale()
	if r, _ := h.srv.EntryReachable("fleet-door", time.Now()); len(r) != 0 {
		t.Fatalf("a 20-minute-old check still counts: %+v", r)
	}
	// the door pulls its table: the hub re-checks it, the route is back
	if code, _, raw := doorRoutes(t, h, dtok); code != http.StatusOK {
		t.Fatalf("door pull: HTTP %d %s", code, raw)
	}
	if r, _ := h.srv.EntryReachable("fleet-door", time.Now()); len(r) != 1 || r[0].Port != port {
		t.Fatalf("after the pull: %+v, want 127.0.0.1:%d", r, port)
	}

	// a pull inside doorReachEvery dials nothing (the check is fresh)
	n := 0
	oldP := entryProbe
	entryProbe = func(ctx context.Context, addr string, p int, want ssh.PublicKey) string {
		n++
		return oldP(ctx, addr, p, want)
	}
	t.Cleanup(func() { entryProbe = oldP })
	doorRoutes(t, h, dtok)
	if n != 0 {
		t.Fatalf("a fresh check was dialled again (%d)", n)
	}

	// another box answering there (a different host key) never counts
	other := reachKey(t)
	entryProbe = func(ctx context.Context, addr string, p int, _ ssh.PublicKey) string {
		n++
		return oldP(ctx, addr, p, other)
	}
	stale()
	doorRoutes(t, h, dtok)
	if r, _ := h.srv.EntryReachable("fleet-door", time.Now()); n != 1 || len(r) != 0 {
		t.Fatalf("held to the wrong key: dials %d, reachable %+v", n, r)
	}
}

// claude-fleet#4149, the relay half: a pod behind the door is offered the
// relay only when its agent says its relay reaches the pod's sshd
// (CapPodRelay) — an older pod's agent dials a port nothing listens on — and
// then the pod's own host key rides beside the door's, since a relayed login
// meets the pod's sshd, not the door.
func TestPodRelayOnlyWhenThePodSaysSo(t *testing.T) {
	h := entryHarness(t)
	now := time.Now().UTC()
	if err := h.srv.Store.SetFleetSetting(DoorKey, "fleet-door", now); err != nil {
		t.Fatal(err)
	}
	dnsReach(t, h, "fleet-door", now, true, "203.0.113.10")
	door, own := reachKeyLine(reachKey(t)), reachKeyLine(reachKey(t))
	if err := h.srv.Store.SetEntryHostKey("fleet-door", door, now); err != nil {
		t.Fatal(err)
	}
	pick := func(host string) RouteMachine {
		return h.srv.routeMachine(FleetMachine{Hostname: host, HostKeys: []string{own}}, h.srv.sshRelayReadiness(), "", now)
	}

	// an older pod: a relay link, no CapPodRelay ⇒ no relay, the door's key alone
	rootNode(t, h, "old", "u-old111", control.CapSSHRelay)
	if m := pick("u-old111"); m.Relay || len(m.HostKeys) != 1 || m.HostKeys[0] != door {
		t.Fatalf("an older pod: relay %v, keys %v — want none and the door's alone", m.Relay, m.HostKeys)
	}
	// a pod whose relay reaches its sshd: the relay, the door's key and its own
	rootNode(t, h, "new", "u-new111", control.CapSSHRelay, control.CapPodRelay)
	m := pick("u-new111")
	if !m.Relay || len(m.HostKeys) != 2 || m.HostKeys[0] != door || m.HostKeys[1] != own {
		t.Fatalf("a relaying pod: relay %v, keys %v — want the relay, the door's key then its own", m.Relay, m.HostKeys)
	}
	if len(m.Routes) == 0 || m.Routes[0].Name != "entry" {
		t.Fatalf("a relaying pod keeps the door first: %+v", m.Routes)
	}
	// the door unreached: the relay alone, with the pod's own key
	h2 := entryHarness(t)
	if err := h2.srv.Store.SetFleetSetting(DoorKey, "fleet-door", now); err != nil {
		t.Fatal(err)
	}
	rootNode(t, h2, "new", "u-new111", control.CapSSHRelay, control.CapPodRelay)
	m = h2.srv.routeMachine(FleetMachine{Hostname: "u-new111", HostKeys: []string{own}}, h2.srv.sshRelayReadiness(), "", now)
	if !m.Relay || len(m.Routes) != 0 || len(m.HostKeys) != 1 || m.HostKeys[0] != own {
		t.Fatalf("door unreached: relay %v routes %+v keys %v — want the relay alone, the pod's key", m.Relay, m.Routes, m.HostKeys)
	}
}
