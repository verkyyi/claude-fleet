package api

import (
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
)

// claude-fleet#3294: C9's 23rd drill — the hub opened a newcomer's login on
// fleet-linux-0 (load 5.36 on 4 cores, its node program restarted a minute
// before, never opened a login) over mini2 (3.05 on 10 cores, idle). A create
// goes to a machine that can finish it, and among those by placement's score.

// openPickRig is fleet-linux-0's machine link opening its own logins, loaded,
// with no session — the old order's favourite.
func openPickRig(t *testing.T) (*harness, *machNode) {
	t.Helper()
	h := newFleetHarness(t)
	h.srv.FleetAdmins = []string{"verkyyi"}
	h.enroll(t, "linux")
	h.enroll(t, "fleet")
	identify(t, h, "fleet", "fleet-linux-0", "fleet")
	lin := dialMachineCaps(t, h, h.tokens["linux"], control.CapLoginJoin)
	lin.beat("", control.Heartbeat{OS: "linux", Hostname: "fleet-linux-0", OSUser: "root", NCPU: 4, Load1: 5.36, ObservedAt: time.Now()})
	if r := lin.login("fleet", h.tokens["fleet"], false, control.CapRead, control.CapWrite); r.Type != control.TypeWelcome {
		t.Fatalf("fleet's hello answered %+v", r)
	}
	lin.beat("fleet", control.Heartbeat{OS: "linux", Hostname: "fleet-linux-0", OSUser: "fleet", NCPU: 4, Load1: 5.36, ObservedAt: time.Now()})
	waitFor(t, 3*time.Second, "fleet-linux-0 online with its opener", func() bool {
		_, ok := h.srv.nodes.openerFor("fleet-linux-0")
		for _, m := range roster(t, h).Machines {
			if m.Hostname == "fleet-linux-0" {
				return ok && m.Status == "online"
			}
		}
		return false
	})
	return h, lin
}

func TestOpenPickPrefersTheIdleMacOverALoadedLinux(t *testing.T) {
	h, _ := openPickRig(t)
	setHubSetting(t, h.srv, trustKey("fleet-linux-0"), TrustTrusted)
	waitFor(t, 3*time.Second, "fleet-linux-0 a candidate on its own", func() bool {
		return h.srv.leastBusyMachine(time.Now()) == "fleet-linux-0"
	})
	mac := connectNode(t, h, "mini2-op", "mini2", "verkyyi", true)
	beat(t, mac.c, control.Proto, control.Heartbeat{Hostname: "mini2", OSUser: "verkyyi", Sessions: 3, NCPU: 10, Load1: 3.05})
	waitFor(t, 3*time.Second, "mini2 picked by score, more sessions or not", func() bool {
		return h.srv.leastBusyMachine(time.Now()) == "mini2"
	})
}

// Its node program opens the login and ends by fetching the relay credential:
// a machine the relay does not trust cannot finish, so it is never picked.
func TestOpenPickSkipsAnUntrustedMachineOpener(t *testing.T) {
	h, _ := openPickRig(t)
	setHubSetting(t, h.srv, trustKey("fleet-linux-0"), TrustUntrusted)
	if got := h.srv.leastBusyMachine(time.Now()); got != "" {
		t.Fatalf("picked %q; want none — an untrusted Linux opener cannot fetch the relay credential", got)
	}
}

// An opener whose link came up a minute ago (a restarting pod) waits behind
// one that has stayed up, whatever their load.
func TestOpenPickPrefersASettledOpener(t *testing.T) {
	h := newFleetHarness(t)
	enablePeople(t, h)
	h.srv.FleetAdmins = []string{"verkyyi"}
	for _, m := range []struct {
		host string
		load float64
	}{{"m4", 0}, {"m5", 6}} {
		n := connectNode(t, h, m.host+"-op", m.host, "verkyyi", true)
		beat(t, n.c, control.Proto, control.Heartbeat{Hostname: m.host, OSUser: "verkyyi", NCPU: 8, Load1: m.load})
	}
	waitFor(t, 3*time.Second, "both fresh: the idle m4", func() bool {
		return h.srv.leastBusyMachine(time.Now()) == "m4"
	})
	// m5's opener has stayed up openerSettle; m4's (as of then) just came up.
	id, _ := h.srv.nodes.openerFor("m5")
	h.srv.nodes.mu.Lock()
	h.srv.nodes.conns[id].helloAt = time.Now().Add(-openerSettle - time.Minute)
	h.srv.nodes.mu.Unlock()
	if got := h.srv.leastBusyMachine(time.Now()); got != "m5" {
		t.Fatalf("picked %q; want m5, whose opener has stayed up", got)
	}
}

// A machine with a login up there already wins over one that never opened
// one, whatever their load: the newcomer's first minute is not the test.
func TestOpenPickPrefersAMachineThatOpenedOne(t *testing.T) {
	h := newFleetHarness(t)
	enablePeople(t, h)
	h.srv.FleetAdmins = []string{"verkyyi"}
	for _, m := range []struct {
		host string
		load float64
	}{{"m4", 0}, {"m5", 6}} {
		n := connectNode(t, h, m.host+"-op", m.host, "verkyyi", true)
		beat(t, n.c, control.Proto, control.Heartbeat{Hostname: m.host, OSUser: "verkyyi", NCPU: 8, Load1: m.load})
	}
	waitFor(t, 3*time.Second, "neither opened one: the idle m4", func() bool {
		return h.srv.leastBusyMachine(time.Now()) == "m4"
	})
	p, err := h.srv.Store.EnsurePrincipal("gh:3294", "Old", control.MaxLoginLen, control.ValidLogin, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if err := h.srv.Store.AdoptAccount(p, "m5", time.Now()); err != nil {
		t.Fatal(err)
	}
	if got := h.srv.leastBusyMachine(time.Now()); got != "m5" {
		t.Fatalf("picked %q; want m5, which has opened a login", got)
	}
}
