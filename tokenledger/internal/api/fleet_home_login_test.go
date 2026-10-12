package api

import (
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// claude-fleet#3049 (EPIC #3067 C4): the home answer names, per machine, the
// login that has a live fleet of the person's there — the #3007 drill landed
// the thin client on `verkyyi` (an old fleet on m4, none on m5) while the
// fleet ran under `verky`. A machine where none of their logins has a fleet
// is no home while another machine has one.

// homeLoginFleet is the drill's shape: one person, accounts m4 → verkyyi and
// m5 → verky (their certificate carries both), a live fleet under verky on m4
// and nothing anywhere else.
func homeLoginFleet(t *testing.T) (*harness, string, *writeNode, control.Fleet) {
	t.Helper()
	h := newFleetHarness(t)
	h.srv.FleetRoutes = []FleetMachine{
		{Hostname: "m4", Routes: []FleetRoute{{Name: "lan", Host: "10.0.0.4"}}},
		{Hostname: "m5", Routes: []FleetRoute{{Name: "lan", Host: "10.0.0.5"}}},
	}
	now := time.Now()
	p, err := h.srv.Store.AdoptPrincipal("wx-v", "verkyyi", "V", now)
	if err != nil {
		t.Fatal(err)
	}
	if err := h.srv.Store.AdoptAccount(p, "m4", now); err != nil {
		t.Fatal(err)
	}
	pv := *p
	pv.Login = "verky"
	if err := h.srv.Store.AdoptAccount(&pv, "m5", now); err != nil {
		t.Fatal(err)
	}
	m4v := connectWriteNode(t, h, "m4-verky")
	m4y := connectWriteNode(t, h, "m4-verkyyi")
	m5v := connectWriteNode(t, h, "m5-verky")
	f := fakeFleet(t, machineA, "fleet", writeRepo, "/Users/verky/claude-fleet", 1, 2)
	m4v.beatLoad("m4", "verky", machineA, 0, 2, f)
	m4y.beatLoad("m4", "verkyyi", machineC, 0, 0)
	m5v.beatLoad("m5", "verky", machineB, 0, 0)
	waitFor(t, 3*time.Second, "verky's fleet on m4 registered", func() bool {
		l, live, err := h.srv.homeLoginFor(p.ID, "m4")
		return err == nil && live && l == "verky"
	})
	// every machine's beat recorded, not only m4's (on Postgres m5's can land later — claude-fleet#3703)
	waitFor(t, 3*time.Second, "m4 and m5 reported", func() bool {
		out, err := h.srv.homePick(p.ID, "", time.Now())
		return err == nil && homeCand(out, "m4").Online && homeCand(out, "m5").Online
	})
	return h, p.ID, m4v, f
}

func homeCand(out HomeResponse, host string) HomeCandidate {
	for _, c := range out.Candidates {
		if c.Machine == host {
			return c
		}
	}
	return HomeCandidate{}
}

func TestHomeLoginIsTheOneWithALiveFleet(t *testing.T) {
	h, pid, m4v, f := homeLoginFleet(t)
	if l, live, err := h.srv.homeLoginFor(pid, "m5"); err != nil || live || l != "verky" {
		t.Fatalf("m5 = %q live=%v (%v); want its account login verky, no fleet", l, live, err)
	}

	// Last used m5, but m5 has no fleet of theirs: the home is m4, as verky.
	out, err := h.srv.homePick(pid, "m5", time.Now())
	if err != nil || out.Machine == nil || out.Machine.Hostname != "m4" || out.Machine.Login != "verky" {
		t.Fatalf("pick = %+v (%v); want m4 entered as verky", out.Machine, err)
	}
	if c := homeCand(out, "m5"); !c.NoFleet || !c.Online || !c.Last {
		t.Fatalf("m5 candidate = %+v; want online, last, no_fleet", c)
	}
	if c := homeCand(out, "m4"); c.NoFleet || c.Login != "verky" {
		t.Fatalf("m4 candidate = %+v; want login verky with a fleet", c)
	}
	for _, m := range out.Machines {
		if m.Login != "verky" {
			t.Fatalf("machine %s login = %q; want verky on both", m.Hostname, m.Login)
		}
	}

	// A fleet that is down is no fleet: nobody has one now, so the pick is
	// the old one (last used, the account's login) — a newcomer's first
	// session (#3054) still has a machine to land on.
	f.State, f.Workers, f.Count = fleetStateDown, nil, 0
	m4v.beatLoad("m4", "verky", machineA, 0, 0, f)
	waitFor(t, 3*time.Second, "verky's fleet down", func() bool {
		_, live, _ := h.srv.homeLoginFor(pid, "m4")
		return !live
	})
	if l, _, _ := h.srv.homeLoginFor(pid, "m4"); l != "verkyyi" {
		t.Fatalf("m4 with no live fleet = %q; want its account login verkyyi", l)
	}
	out, err = h.srv.homePick(pid, "m5", time.Now())
	if err != nil || out.Machine == nil || out.Machine.Hostname != "m5" || out.Rule != "last" {
		t.Fatalf("no fleet anywhere: %+v rule %q (%v); want m5 by last", out.Machine, out.Rule, err)
	}
}

// A login is the person's on a machine only where no one else holds it: their
// m5 login `verky` running a fleet on m4 under someone else's m4 account is
// not theirs to enter.
func TestHomeLoginNeverAnotherPersonsLogin(t *testing.T) {
	h, pid, _, _ := homeLoginFleet(t)
	now := time.Now()
	q, err := h.srv.Store.AdoptPrincipal("wx-q", "verky", "Q", now)
	if err != nil {
		t.Fatal(err)
	}
	if err := h.srv.Store.AdoptAccount(q, "m4", now); err != nil {
		t.Fatal(err)
	}
	if l, live, err := h.srv.homeLoginFor(pid, "m4"); err != nil || live || l != "verkyyi" {
		t.Fatalf("m4 = %q live=%v (%v); want verkyyi, no fleet of theirs", l, live, err)
	}
	if l, live, _ := h.srv.homeLoginFor(q.ID, "m4"); !live || l != "verky" {
		t.Fatalf("q on m4 = %q live=%v; want their own verky with its fleet", l, live)
	}
}

// The home is ONE setting (claude-fleet#3199): the phone's address follows
// the entry home, and `fleet` enters it first — over the device's last-used
// machine; when it cannot, another stands in and the reason says why.
func TestHomePickFollowsTheEntryHome(t *testing.T) {
	h, pid, _, _ := homeLoginFleet(t)
	setHome := func(m, login string) {
		t.Helper()
		if _, err := h.srv.Store.SetEntryHome(store.EntryHome{Person: pid, Machine: m, Login: login, SetBy: pid, SetAt: time.Now()}); err != nil {
			t.Fatal(err)
		}
	}
	setHome("m4", "verky")
	out, err := h.srv.homePick(pid, "m5", time.Now())
	if err != nil || out.Machine == nil || out.Machine.Hostname != "m4" || out.Rule != "home" || out.Reason != "你的家机器" {
		t.Fatalf("home m4, last m5: %+v rule %q %q (%v)", out.Machine, out.Rule, out.Reason, err)
	}
	// m5 has no fleet of theirs: m4 stands in, and the reason says so.
	setHome("m5", "verky")
	out, err = h.srv.homePick(pid, "m5", time.Now())
	if err != nil || out.Machine == nil || out.Machine.Hostname != "m4" || out.Rule == "home" ||
		!strings.HasPrefix(out.Reason, "家机器 m5 上没有你在用的 fleet，临时进了这台：") {
		t.Fatalf("home m5 with no fleet: %+v rule %q %q (%v)", out.Machine, out.Rule, out.Reason, err)
	}
	// No home set: the rules as before.
	other, _ := h.srv.homePick("", "m5", time.Now())
	if other.Rule == "home" {
		t.Fatal("the operator has no home")
	}
}
