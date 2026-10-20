package api

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

// jumpReady has the door and each pod say on their pulls that they are ready
// for the jump (the door's pods in fleet-workers).
func jumpReady(h *harness, now time.Time, door string, pods ...string) {
	h.srv.noteJump(httptest.NewRequest(http.MethodGet, "/x?jump=1&ns=fleet-workers", nil), door, true, now)
	for _, p := range pods {
		h.srv.noteJump(httptest.NewRequest(http.MethodGet, "/x?jump=1", nil), p, false, now)
	}
}

// The door lets jumps through (claude-fleet#4193): a pod's entry route carries
// the jump only while the door AND the pod said lately they are ready, and the
// pod's own host keys are known — otherwise the pod gets no entry route at all
// (T643: the door's per-login account the bare route led to is retired).
func TestDoorJumpRouteOnlyWhenBothSaidSo(t *testing.T) {
	h := entryHarness(t)
	now := time.Now().UTC()
	own := "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAAAgQC7"
	door := reachKeyLine(reachKey(t))
	pod := FleetMachine{Hostname: "u-alice1", HostKeys: []string{own},
		Routes: []FleetRoute{{Name: "lan", Host: "198.51.100.9", Port: 22}}}
	if err := h.srv.Store.SetFleetSetting(DoorKey, "fleet-door", now); err != nil {
		t.Fatal(err)
	}
	dnsReach(t, h, "fleet-door", now, true, "203.0.113.10")
	if err := h.srv.Store.SetEntryHostKey("fleet-door", door, now); err != nil {
		t.Fatal(err)
	}
	before, _ := json.Marshal(h.srv.withEntryReach(pod, now))
	if strings.Contains(string(before), "jump") || strings.Contains(string(before), "target") ||
		strings.Contains(string(before), `"entry`) {
		t.Fatalf("no word from anyone, yet the pod has a door route: %s", before)
	}
	word := func(host, q string, isDoor bool, at time.Time) {
		h.srv.noteJump(httptest.NewRequest(http.MethodGet, "/x?"+q, nil), host, isDoor, at)
	}
	same := func(why string) {
		t.Helper()
		if got, _ := json.Marshal(h.srv.withEntryReach(pod, now)); string(got) != string(before) {
			t.Fatalf("%s: %s, want as before %s", why, got, before)
		}
	}
	word("fleet-door", "jump=1&ns=Bad_NS", true, now)
	word("u-alice1", "jump=1", false, now)
	same("a door namespace that is not a name")
	word("u-alice1", "jump=1", false, now.Add(-jumpFresh-time.Second))
	word("fleet-door", "jump=1&ns=fleet-workers", true, now)
	same("the door alone")
	word("u-alice1", "", false, now)
	same("a pod pull that did not ask ?jump=1")
	word("u-alice1", "jump=1", false, now.Add(-jumpFresh-time.Second))
	same("the pod's word gone stale")

	word("u-alice1", "jump=1", false, now)
	got := h.srv.withEntryReach(pod, now)
	var entry, lan *FleetRoute
	for i := range got.Routes {
		switch got.Routes[i].Name {
		case "entry":
			entry = &got.Routes[i]
		case "lan":
			lan = &got.Routes[i]
		}
	}
	if entry == nil || entry.Jump != doorJumpUser || entry.Target != "u-alice1.fleet-workers.svc.cluster.local" ||
		entry.TargetPort != 22 || len(got.TargetHostKeys) != 1 || got.TargetHostKeys[0] != own ||
		entry.Host != "203.0.113.10" || entry.Port != entryPort {
		t.Fatalf("the jump route: %+v", got.Routes)
	}
	if lan == nil || lan.Jump != "" || lan.Target != "" {
		t.Fatalf("a route that is not the door's got the jump: %+v", lan)
	}
	if len(got.HostKeys) != 1 || got.HostKeys[0] != door {
		t.Fatalf("the door's route keeps the door's key under fleet-<pod>: %v", got.HostKeys)
	}
	// the pod's own keys unknown ⇒ no jump (never TOFU)
	bare := pod
	bare.HostKeys = nil
	for _, r := range h.srv.withEntryReach(bare, now).Routes {
		if r.Jump != "" || r.Name == "entry" {
			t.Fatalf("a door route with no pod host key: %+v", r)
		}
	}
	// a home machine never jumps
	home := FleetMachine{Hostname: "home-a", HostKeys: []string{own}}
	word("home-a", "jump=1", false, now)
	for _, r := range h.srv.withEntryReach(home, now).Routes {
		if r.Jump != "" {
			t.Fatalf("home-a got a jump: %+v", r)
		}
	}
}

// The door's word arrives on its own pull, with its own token only.
func TestDoorJumpWordRidesTheDoorsPull(t *testing.T) {
	h := entryHarness(t)
	now := time.Now()
	if err := h.srv.Store.SetFleetSetting(DoorKey, "fleet-door", now); err != nil {
		t.Fatal(err)
	}
	_, dtok := rootNode(t, h, "door", "fleet-door", control.CapEntryKeys)
	_, otok := rootNode(t, h, "rootA", "home-a", control.CapEntryKeys)
	if code, raw := entryCall(t, h, http.MethodGet, control.EntryRoutesNodePath+"?jump=1&ns=fleet-workers", asNode(otok), nil); code != http.StatusForbidden {
		t.Fatalf("another machine's pull: HTTP %d %s", code, raw)
	}
	if _, ok := h.srv.jumpWordOf("home-a", now); ok {
		t.Fatal("a refused pull left a word")
	}
	if code, raw := entryCall(t, h, http.MethodGet, control.EntryRoutesNodePath+"?jump=1&ns=fleet-workers", asNode(dtok), nil); code != 200 {
		t.Fatalf("the door's pull: HTTP %d %s", code, raw)
	}
	if w, ok := h.srv.jumpWordOf("fleet-door", now); !ok || w.ns != "fleet-workers" {
		t.Fatalf("the door's word: %+v %v", w, ok)
	}
}

func TestEntryJumpLine(t *testing.T) {
	for _, c := range []struct {
		host       string
		port       int
		login, tgt string
		want       string
	}{
		{"alice.fleet.example", 22022, "alice", "u-alice1.fleet-workers.svc.cluster.local",
			"ssh -J fleet-jump@alice.fleet.example:22022 alice@u-alice1.fleet-workers.svc.cluster.local"},
		{"2001:db8::1", 22, "alice", "u-a.ns.svc.cluster.local", "ssh -J fleet-jump@[2001:db8::1] alice@u-a.ns.svc.cluster.local"},
		{"alice.fleet.example", 22022, "alice", "", ""},
	} {
		if got := entryJumpLine(c.host, c.port, c.login, c.tgt); got != c.want {
			t.Fatalf("entryJumpLine(%q,%d,%q,%q) = %q, want %q", c.host, c.port, c.login, c.tgt, got, c.want)
		}
	}
}
