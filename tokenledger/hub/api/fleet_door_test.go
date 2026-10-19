package api

import (
	"context"
	"encoding/json"
	"net/http"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/dns"
	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

// The cluster's one door (claude-fleet#3549, EPIC #3500 C4).

func doorRoutes(t *testing.T, h *harness, tok string) (int, control.EntryRouteList, string) {
	t.Helper()
	code, raw := entryCall(t, h, http.MethodGet, control.EntryRoutesNodePath, asNode(tok), nil)
	var out control.EntryRouteList
	_ = json.Unmarshal([]byte(raw), &out)
	return code, out, raw
}

func doorHome(t *testing.T, h *harness, person, machine, login string) {
	t.Helper()
	if _, err := h.srv.Store.SetEntryHome(store.EntryHome{Person: person, Machine: machine, Login: login, SetBy: "t", SetAt: time.Now()}); err != nil {
		t.Fatal(err)
	}
}

// The completion criterion's hub half: the door's table holds every person
// whose home is a pod — that person's login, their keys alone, their pod
// alone — and nothing else; only the door reads it; a login two pods claim
// goes nowhere (BREAK-IT door-wrong-pod); a change to a person on a pod
// reaches the door.
func TestDoorRoutesEachLoginToItsOwnPod(t *testing.T) {
	h := entryHarness(t)
	_, tokA := rootNode(t, h, "rootA", "home-a", control.CapEntryKeys)

	// No door named: the table is not there.
	_, dtok0 := rootNode(t, h, "door0", "fleet-door0", control.CapEntryKeys)
	if code, _, raw := doorRoutes(t, h, dtok0); code != http.StatusNotFound {
		t.Fatalf("no %s: HTTP %d %s, want 404", DoorKey, code, raw)
	}

	if err := h.srv.Store.SetFleetSetting(DoorKey, "fleet-door", time.Now()); err != nil {
		t.Fatal(err)
	}
	door, dtok := rootNode(t, h, "door", "fleet-door", control.CapEntryKeys)
	doorHome(t, h, pAlice, "u-alice1", "alice")
	doorHome(t, h, pBob, "u-bob123", "bob")

	// Alice's key: her pod moved, so the door hears it.
	line := entryKeyLine(t, "alice-phone")
	if code, raw := entryCall(t, h, http.MethodPost, control.EntryKeysPath, asSession(pAlice), map[string]any{"public_key": line}); code != http.StatusCreated {
		t.Fatalf("Alice adds a key: HTTP %d %s", code, raw)
	}
	v, _ := h.srv.Store.EntryVersion()
	nextEntry(t, door, v, "the door after a key of a person on a pod")

	code, list, raw := doorRoutes(t, h, dtok)
	if code != 200 || list.Version != v || len(list.Routes) != 2 ||
		list.Routes[0] != (control.EntryRoute{Login: "alice", Principal: pAlice, Service: "u-alice1"}) ||
		list.Routes[1] != (control.EntryRoute{Login: "bob", Principal: pBob, Service: "u-bob123"}) {
		t.Fatalf("the door's table: HTTP %d %s", code, raw)
	}
	if l := list.Logins["alice"]; l.Person != pAlice || len(l.Keys) != 1 || !strings.Contains(line, l.Keys[0].B64) {
		t.Fatalf("alice's keys at the door: %s", raw)
	}
	if l := list.Logins["bob"]; l.Person != pBob || len(l.Keys) != 0 {
		t.Fatalf("bob holds keys at the door he never added: %s", raw)
	}

	// Only the door reads it: another machine → 403.
	for name, tok := range map[string]string{"another machine": tokA, "a door not named": dtok0} {
		if code, _, raw := doorRoutes(t, h, tok); code != http.StatusForbidden {
			t.Fatalf("%s reads the door's table: HTTP %d %s, want 403", name, code, raw)
		}
	}
	if code, _, _ := doorRoutes(t, h, ""); code != http.StatusUnauthorized {
		t.Fatalf("no token: HTTP %d, want 401", code)
	}

	// A home on a machine is that machine's, never the door's.
	doorHome(t, h, pAlice, "home-a", "alice")
	if _, list, raw := doorRoutes(t, h, dtok); len(list.Routes) != 1 || list.Routes[0].Login != "bob" || len(list.Logins) != 1 {
		t.Fatalf("a home on a machine at the door: %s", raw)
	}

	// door-wrong-pod: two pods claim one login ⇒ the door routes neither.
	doorHome(t, h, pAlice, "u-alice1", "bob")
	if _, list, raw := doorRoutes(t, h, dtok); len(list.Routes) != 0 || len(list.Logins) != 0 {
		t.Fatalf("a login two pods claim is routed: %s", raw)
	}
}

func TestDoorSettingIsMachineNames(t *testing.T) {
	for v, want := range map[string]string{
		" fleet-door , door2 ": "fleet-door,door2",
		"":                     "",
	} {
		if got, why := doorCheck(nil, v); why != "" || got != want {
			t.Fatalf("doorCheck(%q) = %q %q, want %q", v, got, why, want)
		}
	}
	for _, v := range []string{"u-k3x9q2", "door,u-abcd", "bad name"} {
		if _, why := doorCheck(nil, v); why == "" {
			t.Fatalf("doorCheck(%q) took it", v)
		}
	}
}

// A person's name points at the door's address, not their pod's.
func TestDoorDNSPointsPodHomesAtTheDoor(t *testing.T) {
	h := entryHarness(t)
	f := dns.NewFake()
	h.srv.EntryDNS = NewEntryDNS(f, "cf")
	ctx := context.Background()
	now := time.Now().UTC()
	if _, err := h.srv.Store.SetEntryName(pAlice, "alice", now); err != nil {
		t.Fatal(err)
	}
	doorHome(t, h, pAlice, "u-alice1", "alice")

	// No door: a pod has no address, the name is held (as any unreachable home).
	h.srv.EntryDNSTick(ctx, now)
	if got := dnsZone(f); got != "" {
		t.Fatalf("no door: %s", got)
	}

	if err := h.srv.Store.SetFleetSetting(DoorKey, "fleet-door", now); err != nil {
		t.Fatal(err)
	}
	dnsReach(t, h, "fleet-door", now, true, "203.0.113.10")
	h.srv.EntryDNSTick(ctx, now.Add(time.Minute))
	if got, want := dnsZone(f), "A alice.cf 203.0.113.10"; got != want {
		t.Fatalf("zone: %s\nwant %s", got, want)
	}
	if p := h.srv.entryPublicPort("u-alice1", now); p != entryPort {
		t.Fatalf("the pod's public port %d, want the door's %d", p, entryPort)
	}
	// Any other home is still its own.
	if m := h.srv.entryAddrMachine("home-a", now); m != "home-a" {
		t.Fatalf("home-a is reached at %s", m)
	}
}

// A person's pod is reached through the door in the route list too
// (claude-fleet#3985): its `entry` route is the door's reachable address, with
// the home entry port on or off, and it is offered no relay — the relay dials
// the agent's loopback :22, which a pod's sshd (its own port, the door's key
// alone) never answers. Any other home, and a pod with no door, as before.
func TestDoorRouteListSendsPodsThroughTheDoor(t *testing.T) {
	h := entryHarness(t)
	now := time.Now().UTC()
	pod := FleetMachine{Hostname: "u-alice1"}
	routes := func(m FleetMachine) string {
		var rs []string
		for _, r := range h.srv.withEntryReach(m, now).Routes {
			rs = append(rs, r.Name+"="+r.Host+":"+strconv.Itoa(r.Port))
		}
		return strings.Join(rs, ",")
	}

	// No door: a pod is any machine, and nothing knows an address for it.
	if h.srv.podBehindDoor("u-alice1") {
		t.Fatal("no door: u-alice1 is behind no door")
	}
	if got := routes(pod); got != "" {
		t.Fatalf("no door: %s", got)
	}

	if err := h.srv.Store.SetFleetSetting(DoorKey, "fleet-door", now); err != nil {
		t.Fatal(err)
	}
	if !h.srv.podBehindDoor("u-alice1") || h.srv.podBehindDoor("home-a") || h.srv.podBehindDoor("fleet-door") {
		t.Fatal("podBehindDoor: only a u-<nonce> pod is behind the door")
	}
	// The door not reached yet: no route (the person sees why on /entry).
	if got := routes(pod); got != "" {
		t.Fatalf("door unreached: %s", got)
	}
	dnsReach(t, h, "fleet-door", now, true, "203.0.113.10")
	if got, want := routes(pod), "entry=203.0.113.10:"+strconv.Itoa(entryPort); got != want {
		t.Fatalf("pod: %s, want %s", got, want)
	}
	// A home that is not a pod gets nothing from the door's reach.
	if got := routes(FleetMachine{Hostname: "home-a"}); got != "" {
		t.Fatalf("home-a took the door's address: %s", got)
	}
	// A node that names its own entry= keeps it alone.
	own := FleetMachine{Hostname: "u-alice1", Routes: []FleetRoute{{Name: "entry", Host: "door.example.com", Port: 22022}}}
	if got := routes(own); got != "entry=door.example.com:22022" {
		t.Fatalf("own entry=: %s", got)
	}
	// The home entry port off: the pod still goes through the door.
	if err := h.srv.Store.SetFleetSetting(EntryKey, "off", now); err != nil {
		t.Fatal(err)
	}
	if got, want := routes(pod), "entry=203.0.113.10:"+strconv.Itoa(entryPort); got != want {
		t.Fatalf("entry port off: %s, want %s", got, want)
	}
}

// The door ends a person's ssh itself (fleet-door.sh), so the host key their
// ssh meets under fleet-<pod> is the DOOR's (claude-fleet#4127): a pod behind
// the door is listed with the door's entry key, never the keys its own image
// carried — those sent a person into 「REMOTE HOST IDENTIFICATION HAS CHANGED」
// on every connect. No door key known yet ⇒ none listed (ssh asks once). A
// home that is not a pod keeps its own keys.
func TestDoorRouteListHandsOutTheDoorsHostKey(t *testing.T) {
	h := entryHarness(t)
	now := time.Now().UTC()
	baked := "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAAAgQC7"
	door := reachKeyLine(reachKey(t))
	pod := FleetMachine{Hostname: "u-alice1", HostKeys: []string{baked}}
	if err := h.srv.Store.SetFleetSetting(DoorKey, "fleet-door", now); err != nil {
		t.Fatal(err)
	}
	dnsReach(t, h, "fleet-door", now, true, "203.0.113.10")
	if got := h.srv.withEntryReach(pod, now).HostKeys; len(got) != 0 {
		t.Fatalf("no door key known: %v, want none", got)
	}
	if err := h.srv.Store.SetEntryHostKey("fleet-door", door, now); err != nil {
		t.Fatal(err)
	}
	if got := h.srv.withEntryReach(pod, now).HostKeys; len(got) != 1 || got[0] != door {
		t.Fatalf("pod host keys %v, want the door's %q alone", got, door)
	}
	home := FleetMachine{Hostname: "home-a", HostKeys: []string{baked}}
	if got := h.srv.withEntryReach(home, now).HostKeys; len(got) != 1 || got[0] != baked {
		t.Fatalf("home-a host keys %v, want its own", got)
	}
}

// `fleet` with no machine named connects off the home answer, and its route
// list is the route list's (claude-fleet#4112): a pod behind the door gets the
// door's entry route and no relay there too — before, the home answer still
// carried the relay and the pod's unreachable LAN line alone.
func TestHomeAnswerSendsPodsThroughTheDoor(t *testing.T) {
	h := entryHarness(t)
	now := time.Now().UTC()
	h.srv.FleetRoutes = []FleetMachine{{Hostname: "u-alice1", Routes: []FleetRoute{{Name: "lan", Host: "198.51.100.9", Port: 22}}}}
	if err := h.srv.Store.SetFleetSetting(DoorKey, "fleet-door", now); err != nil {
		t.Fatal(err)
	}
	dnsReach(t, h, "fleet-door", now, true, "203.0.113.10")
	out, err := h.srv.homePick("", "", now)
	if err != nil {
		t.Fatal(err)
	}
	var pod *RouteMachine
	for i := range out.Machines {
		if out.Machines[i].Hostname == "u-alice1" {
			pod = &out.Machines[i]
		}
	}
	if pod == nil {
		t.Fatalf("u-alice1 missing from the home answer: %+v", out.Machines)
	}
	var rs []string
	for _, r := range pod.Routes {
		rs = append(rs, r.Name+"="+r.Host+":"+strconv.Itoa(r.Port))
	}
	if got, want := strings.Join(rs, ","), "lan=198.51.100.9:22,entry=203.0.113.10:"+strconv.Itoa(entryPort); got != want {
		t.Fatalf("home answer routes: %s, want %s", got, want)
	}
	if pod.Relay {
		t.Fatal("home answer offers a pod behind the door the relay")
	}
}
