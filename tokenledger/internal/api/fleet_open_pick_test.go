package api

import (
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
)

// claude-fleet#3294: C9's 23rd drill — the hub opened a newcomer's login on
// linux-b (load 5.36 on 4 cores, its node program restarted a minute
// before, never opened a login) over mac-f (3.05 on 10 cores, idle). A create
// goes to a machine that can finish it, and among those by placement's score.

// openPickRig is linux-b's machine link opening its own logins, loaded,
// with no session — the old order's favourite.
func openPickRig(t *testing.T) (*harness, *machNode) {
	t.Helper()
	h := newFleetHarness(t)
	h.srv.FleetAdmins = []string{"ivan"}
	h.enroll(t, "linux")
	h.enroll(t, "fleet")
	identify(t, h, "fleet", "linux-b", "fleet")
	lin := dialMachineCaps(t, h, h.tokens["linux"], control.CapLoginJoin)
	lin.beat("", control.Heartbeat{OS: "linux", Hostname: "linux-b", OSUser: "root", NCPU: 4, Load1: 5.36, ObservedAt: time.Now()})
	if r := lin.login("fleet", h.tokens["fleet"], false, control.CapRead, control.CapWrite); r.Type != control.TypeWelcome {
		t.Fatalf("fleet's hello answered %+v", r)
	}
	lin.beat("fleet", control.Heartbeat{OS: "linux", Hostname: "linux-b", OSUser: "fleet", NCPU: 4, Load1: 5.36, ObservedAt: time.Now()})
	waitFor(t, 3*time.Second, "linux-b online with its opener", func() bool {
		_, ok := h.srv.nodes.openerFor("linux-b")
		for _, m := range roster(t, h).Machines {
			if m.Hostname == "linux-b" {
				return ok && m.Status == "online"
			}
		}
		return false
	})
	return h, lin
}

func TestOpenPickPrefersTheIdleMacOverALoadedLinux(t *testing.T) {
	h, _ := openPickRig(t)
	setHubSetting(t, h.srv, trustKey("linux-b"), TrustTrusted)
	waitFor(t, 3*time.Second, "linux-b a candidate on its own", func() bool {
		return h.srv.leastBusyMachine(time.Now()) == "linux-b"
	})
	mac := connectNode(t, h, "mac-f-op", "mac-f", "ivan", true)
	beat(t, mac.c, control.Proto, control.Heartbeat{Hostname: "mac-f", OSUser: "ivan", Sessions: 3, NCPU: 10, Load1: 3.05})
	waitFor(t, 3*time.Second, "mac-f picked by score, more sessions or not", func() bool {
		return h.srv.leastBusyMachine(time.Now()) == "mac-f"
	})
}

// Its node program opens the login and ends by fetching the relay credential:
// a machine the relay does not trust cannot finish, so it is never picked.
func TestOpenPickSkipsAnUntrustedMachineOpener(t *testing.T) {
	h, _ := openPickRig(t)
	setHubSetting(t, h.srv, trustKey("linux-b"), TrustUntrusted)
	if got := h.srv.leastBusyMachine(time.Now()); got != "" {
		t.Fatalf("picked %q; want none — an untrusted Linux opener cannot fetch the relay credential", got)
	}
}

// An opener whose link came up a minute ago (a restarting pod) waits behind
// one that has stayed up, whatever their load.
func TestOpenPickPrefersASettledOpener(t *testing.T) {
	h := newFleetHarness(t)
	enablePeople(t, h)
	h.srv.FleetAdmins = []string{"ivan"}
	for _, m := range []struct {
		host string
		load float64
	}{{"mac-c", 0}, {"mac-d", 6}} {
		n := connectNode(t, h, m.host+"-op", m.host, "ivan", true)
		beat(t, n.c, control.Proto, control.Heartbeat{Hostname: m.host, OSUser: "ivan", NCPU: 8, Load1: m.load})
	}
	waitFor(t, 3*time.Second, "both fresh: the idle mac-c", func() bool {
		return h.srv.leastBusyMachine(time.Now()) == "mac-c"
	})
	// mac-d's opener has stayed up openerSettle; mac-c's (as of then) just came up.
	id, _ := h.srv.nodes.openerFor("mac-d")
	h.srv.nodes.mu.Lock()
	h.srv.nodes.conns[id].helloAt = time.Now().Add(-openerSettle - time.Minute)
	h.srv.nodes.mu.Unlock()
	if got := h.srv.leastBusyMachine(time.Now()); got != "mac-d" {
		t.Fatalf("picked %q; want mac-d, whose opener has stayed up", got)
	}
}

// A machine with a login up there already wins over one that never opened
// one, whatever their load: the newcomer's first minute is not the test.
func TestOpenPickPrefersAMachineThatOpenedOne(t *testing.T) {
	h := newFleetHarness(t)
	enablePeople(t, h)
	h.srv.FleetAdmins = []string{"ivan"}
	for _, m := range []struct {
		host string
		load float64
	}{{"mac-c", 0}, {"mac-d", 6}} {
		n := connectNode(t, h, m.host+"-op", m.host, "ivan", true)
		beat(t, n.c, control.Proto, control.Heartbeat{Hostname: m.host, OSUser: "ivan", NCPU: 8, Load1: m.load})
	}
	waitFor(t, 3*time.Second, "neither opened one: the idle mac-c", func() bool {
		return h.srv.leastBusyMachine(time.Now()) == "mac-c"
	})
	p, err := h.srv.Store.EnsurePrincipal("gh:3294", "Old", control.MaxLoginLen, control.ValidLogin, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if err := h.srv.Store.AdoptAccount(p, "mac-d", time.Now()); err != nil {
		t.Fatal(err)
	}
	if got := h.srv.leastBusyMachine(time.Now()); got != "mac-d" {
		t.Fatalf("picked %q; want mac-d, which has opened a login", got)
	}
}

// claude-fleet#3312: C9's 24th drill — the hub opened the newcomer's login on
// linux-b, whose egress is CN, and the login's first lease was refused
// compute_off. A create asks placement's compute rule of the machine's probe:
// a region the providers do not serve is never a candidate, the Mac is.
func TestOpenPickSkipsAMachineWhoseRegionClosesCompute(t *testing.T) {
	h, lin := openPickRig(t)
	setHubSetting(t, h.srv, trustKey("linux-b"), TrustTrusted)
	cn := &control.NodeProbe{Loc: "CN", Anthropic: control.ProbeUnsupportedRegion, Verdict: control.ProbeUnsupportedRegion, TS: time.Now()}
	// The machine link says it; the login it carries is compute on, no probe.
	lin.beat("", control.Heartbeat{OS: "linux", Hostname: "linux-b", OSUser: "root", NCPU: 4, Probe: cn, ObservedAt: time.Now()})
	waitFor(t, 3*time.Second, "linux-b dropped for its region", func() bool {
		return h.srv.leastBusyMachine(time.Now()) == ""
	})
	mac := connectNode(t, h, "mac-f-op", "mac-f", "ivan", true)
	beat(t, mac.c, control.Proto, control.Heartbeat{Hostname: "mac-f", OSUser: "ivan", Sessions: 3, NCPU: 10, Load1: 3.05,
		Probe: &control.NodeProbe{Loc: "US", Verdict: control.ProbeOK, TS: time.Now()}})
	waitFor(t, 3*time.Second, "mac-f picked over the CN machine", func() bool {
		return h.srv.leastBusyMachine(time.Now()) == "mac-f"
	})
	// Even unloaded and idle, the CN machine stays out.
	lin.beat("", control.Heartbeat{OS: "linux", Hostname: "linux-b", OSUser: "root", NCPU: 4, Probe: cn, ObservedAt: time.Now()})
	if got := h.srv.leastBusyMachine(time.Now(), "mac-f"); got != "" {
		t.Fatalf("with mac-f skipped the pick is %q, want none (linux-b's egress is CN)", got)
	}
}

// A login's own probe says it just as well (an older machine with no link).
func TestNewLoginComputeReadsTheNewestProbe(t *testing.T) {
	now := time.Now()
	snap := NodesSnapshot{Nodes: []NodeView{
		{Hostname: "box", Status: "online", Probe: &control.NodeProbe{Verdict: control.ProbeOK, TS: now.Add(-time.Hour)}},
		{Hostname: "box", Status: "online", Probe: &control.NodeProbe{Loc: "CN", Verdict: control.ProbeUnsupportedRegion, TS: now}},
		{Hostname: "other", Status: "online"},
	}}
	if cv := newLoginCompute(snap, "box", nil, now); !cv.Off {
		t.Fatalf("box: %+v, want off for its CN egress", cv)
	}
	if cv := newLoginCompute(snap, "other", nil, now); cv.Off {
		t.Fatalf("other (no probe): %+v, want open", cv)
	}
}

// claude-fleet#3426: C9's 27th drill. /v1/nodes then: linux-b's old
// logins egress SG via the relay (local CN), load 39–44 on 4 cores, no admit
// verdict; mac-f US, 2.4 on 10 cores, admit=true. The hub opened the newcomer
// on linux-b — settled, opened before — and its login probed CN.
func TestOpenPickDrill27SnapshotPicksMini2(t *testing.T) {
	h, lin := openPickRig(t)
	setHubSetting(t, h.srv, trustKey("linux-b"), TrustTrusted)
	relay := &control.NodeProbe{Loc: "SG", Route: "relay", LocLocal: "CN", Anthropic: control.ProbeOK, Verdict: control.ProbeOK, TS: time.Now()}
	lin.beat("", control.Heartbeat{OS: "linux", Hostname: "linux-b", OSUser: "root", NCPU: 4, Load1: 39, ObservedAt: time.Now()})
	lin.beat("fleet", control.Heartbeat{OS: "linux", Hostname: "linux-b", OSUser: "fleet", NCPU: 4, Load1: 44, Probe: relay, ObservedAt: time.Now()})
	// The tiers that won it then: its opener has stayed up, it opened one.
	id, _ := h.srv.nodes.openerFor("linux-b")
	h.srv.nodes.mu.Lock()
	h.srv.nodes.conns[id].helloAt = time.Now().Add(-openerSettle - time.Minute)
	h.srv.nodes.mu.Unlock()
	p, err := h.srv.Store.EnsurePrincipal("gh:3426", "Old", control.MaxLoginLen, control.ValidLogin, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if err := h.srv.Store.AdoptAccount(p, "linux-b", time.Now()); err != nil {
		t.Fatal(err)
	}
	mac := connectNode(t, h, "mac-f-op", "mac-f", "ivan", true)
	beat(t, mac.c, control.Proto, control.Heartbeat{Hostname: "mac-f", OSUser: "ivan", Sessions: 3, NCPU: 10, Load1: 2.4,
		Admit: boolp(true), Probe: &control.NodeProbe{Loc: "US", Verdict: control.ProbeOK, TS: time.Now()}})
	waitFor(t, 3*time.Second, "mac-f picked over linux-b", func() bool {
		return h.srv.leastBusyMachine(time.Now()) == "mac-f"
	})
	// The relay probe rides the login's beat: wait for it to land.
	waitFor(t, 3*time.Second, "no pick with mac-f skipped (a new login on linux-b egresses CN)", func() bool {
		return h.srv.leastBusyMachine(time.Now(), "mac-f") == ""
	})
}

// The score's inputs count on their own: a machine past placement's CPU
// ceiling ranks behind one with room, however settled or experienced it is.
func TestOpenPickLoadOutranksTheOpenerTiers(t *testing.T) {
	h, lin := openPickRig(t)
	setHubSetting(t, h.srv, trustKey("linux-b"), TrustTrusted)
	lin.beat("", control.Heartbeat{OS: "linux", Hostname: "linux-b", OSUser: "root", NCPU: 4, Load1: 39, ObservedAt: time.Now()})
	id, _ := h.srv.nodes.openerFor("linux-b")
	h.srv.nodes.mu.Lock()
	h.srv.nodes.conns[id].helloAt = time.Now().Add(-openerSettle - time.Minute)
	h.srv.nodes.mu.Unlock()
	mac := connectNode(t, h, "mac-f-op", "mac-f", "ivan", true)
	beat(t, mac.c, control.Proto, control.Heartbeat{Hostname: "mac-f", OSUser: "ivan", NCPU: 10, Load1: 2.4})
	waitFor(t, 3*time.Second, "the unsettled but idle mac-f picked", func() bool {
		return h.srv.leastBusyMachine(time.Now()) == "mac-f"
	})
	// mac-f's login holding new sessions takes its room away.
	beat(t, mac.c, control.Proto, control.Heartbeat{Hostname: "mac-f", OSUser: "ivan", NCPU: 10, Load1: 2.4, Admit: boolp(false), AdmitWhy: "paused"})
	waitFor(t, 3*time.Second, "the settled Linux back once mac-f holds new sessions", func() bool {
		return h.srv.leastBusyMachine(time.Now()) == "linux-b"
	})
}

func TestDirectProbeDropsTheRelayRoad(t *testing.T) {
	now := time.Now()
	snap := NodesSnapshot{Nodes: []NodeView{
		{Hostname: "box", Status: "online", Probe: &control.NodeProbe{Loc: "SG", Route: "relay", LocLocal: "CN", Verdict: control.ProbeOK, TS: now}},
		{Hostname: "us", Status: "online", Probe: &control.NodeProbe{Loc: "US", Verdict: control.ProbeOK, TS: now}},
	}}
	cv := newLoginCompute(snap, "box", nil, now)
	if !cv.Off || cv.Probe == nil || cv.Probe.Loc != "CN" {
		t.Fatalf("box: %+v, want off for a new login's own CN egress", cv)
	}
	if cv := newLoginCompute(snap, "us", nil, now); cv.Off {
		t.Fatalf("us: %+v, want open", cv)
	}
}
