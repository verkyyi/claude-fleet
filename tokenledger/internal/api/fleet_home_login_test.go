package api

import (
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

// claude-fleet#3049 (EPIC #3067 C4): the home answer names, per machine, the
// login that has a live fleet of the person's there — the #3007 drill landed
// the thin client on `ivan` (an old fleet on mac-c, none on mac-d) while the
// fleet ran under `heidi`. A machine where none of their logins has a fleet
// is no home while another machine has one.

// homeLoginFleet is the drill's shape: one person, accounts mac-c → ivan and
// mac-d → heidi (their certificate carries both), a live fleet under heidi on mac-c
// and nothing anywhere else.
func homeLoginFleet(t *testing.T) (*harness, string, *writeNode, control.Fleet) {
	t.Helper()
	h := newFleetHarness(t)
	h.srv.FleetRoutes = []FleetMachine{
		{Hostname: "mac-c", Routes: []FleetRoute{{Name: "lan", Host: "10.0.0.4"}}},
		{Hostname: "mac-d", Routes: []FleetRoute{{Name: "lan", Host: "10.0.0.5"}}},
	}
	now := time.Now()
	p, err := h.srv.Store.AdoptPrincipal("wx-v", "ivan", "V", now)
	if err != nil {
		t.Fatal(err)
	}
	if err := h.srv.Store.AdoptAccount(p, "mac-c", now); err != nil {
		t.Fatal(err)
	}
	pv := *p
	pv.Login = "heidi"
	if err := h.srv.Store.AdoptAccount(&pv, "mac-d", now); err != nil {
		t.Fatal(err)
	}
	m4v := connectWriteNode(t, h, "mac-c-heidi")
	m4y := connectWriteNode(t, h, "mac-c-ivan")
	m5v := connectWriteNode(t, h, "mac-d-heidi")
	f := fakeFleet(t, machineA, "fleet", writeRepo, "/Users/heidi/claude-fleet", 1, 2)
	m4v.beatLoad("mac-c", "heidi", machineA, 0, 2, f)
	m4y.beatLoad("mac-c", "ivan", machineC, 0, 0)
	m5v.beatLoad("mac-d", "heidi", machineB, 0, 0)
	waitFor(t, 3*time.Second, "heidi's fleet on mac-c registered", func() bool {
		l, live, err := h.srv.homeLoginFor(p.ID, "mac-c")
		return err == nil && live && l == "heidi"
	})
	// every machine's beat recorded, not only the first's (on Postgres a later one can land late — claude-fleet#3703)
	waitFor(t, 3*time.Second, "both machines reported", func() bool {
		out, err := h.srv.homePick(p.ID, "", time.Now())
		if err != nil || len(out.Candidates) < len(h.srv.FleetRoutes) {
			return false
		}
		for _, c := range out.Candidates {
			if !c.Online {
				return false
			}
		}
		return true
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
	if l, live, err := h.srv.homeLoginFor(pid, "mac-d"); err != nil || live || l != "heidi" {
		t.Fatalf("mac-d = %q live=%v (%v); want its account login heidi, no fleet", l, live, err)
	}

	// Last used mac-d, but mac-d has no fleet of theirs: the home is mac-c, as heidi.
	out, err := h.srv.homePick(pid, "mac-d", time.Now())
	if err != nil || out.Machine == nil || out.Machine.Hostname != "mac-c" || out.Machine.Login != "heidi" {
		t.Fatalf("pick = %+v (%v); want mac-c entered as heidi", out.Machine, err)
	}
	if c := homeCand(out, "mac-d"); !c.NoFleet || !c.Online || !c.Last {
		t.Fatalf("mac-d candidate = %+v; want online, last, no_fleet", c)
	}
	if c := homeCand(out, "mac-c"); c.NoFleet || c.Login != "heidi" {
		t.Fatalf("mac-c candidate = %+v; want login heidi with a fleet", c)
	}
	for _, m := range out.Machines {
		if m.Login != "heidi" {
			t.Fatalf("machine %s login = %q; want heidi on both", m.Hostname, m.Login)
		}
	}

	// A fleet that is down is no fleet: nobody has one now, so the pick is
	// the old one (last used, the account's login) — a newcomer's first
	// session (#3054) still has a machine to land on.
	f.State, f.Workers, f.Count = fleetStateDown, nil, 0
	m4v.beatLoad("mac-c", "heidi", machineA, 0, 0, f)
	waitFor(t, 3*time.Second, "heidi's fleet down", func() bool {
		_, live, _ := h.srv.homeLoginFor(pid, "mac-c")
		return !live
	})
	if l, _, _ := h.srv.homeLoginFor(pid, "mac-c"); l != "ivan" {
		t.Fatalf("mac-c with no live fleet = %q; want its account login ivan", l)
	}
	out, err = h.srv.homePick(pid, "mac-d", time.Now())
	if err != nil || out.Machine == nil || out.Machine.Hostname != "mac-d" || out.Rule != "last" {
		t.Fatalf("no fleet anywhere: %+v rule %q (%v); want mac-d by last", out.Machine, out.Rule, err)
	}
}

// A login is the person's on a machine only where no one else holds it: their
// mac-d login `heidi` running a fleet on mac-c under someone else's mac-c account is
// not theirs to enter.
func TestHomeLoginNeverAnotherPersonsLogin(t *testing.T) {
	h, pid, _, _ := homeLoginFleet(t)
	now := time.Now()
	q, err := h.srv.Store.AdoptPrincipal("wx-q", "heidi", "Q", now)
	if err != nil {
		t.Fatal(err)
	}
	if err := h.srv.Store.AdoptAccount(q, "mac-c", now); err != nil {
		t.Fatal(err)
	}
	if l, live, err := h.srv.homeLoginFor(pid, "mac-c"); err != nil || live || l != "ivan" {
		t.Fatalf("mac-c = %q live=%v (%v); want ivan, no fleet of theirs", l, live, err)
	}
	if l, live, _ := h.srv.homeLoginFor(q.ID, "mac-c"); !live || l != "heidi" {
		t.Fatalf("q on mac-c = %q live=%v; want their own heidi with its fleet", l, live)
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
	setHome("mac-c", "heidi")
	out, err := h.srv.homePick(pid, "mac-d", time.Now())
	if err != nil || out.Machine == nil || out.Machine.Hostname != "mac-c" || out.Rule != "home" || out.Reason != "你的家机器" {
		t.Fatalf("home mac-c, last mac-d: %+v rule %q %q (%v)", out.Machine, out.Rule, out.Reason, err)
	}
	// mac-d has no fleet of theirs: mac-c stands in, and the reason says so.
	setHome("mac-d", "heidi")
	out, err = h.srv.homePick(pid, "mac-d", time.Now())
	if err != nil || out.Machine == nil || out.Machine.Hostname != "mac-c" || out.Rule == "home" ||
		!strings.HasPrefix(out.Reason, "家机器 mac-d 上没有你在用的 fleet，临时进了这台：") {
		t.Fatalf("home mac-d with no fleet: %+v rule %q %q (%v)", out.Machine, out.Rule, out.Reason, err)
	}
	// No home set: the rules as before.
	other, _ := h.srv.homePick("", "mac-d", time.Now())
	if other.Rule == "home" {
		t.Fatal("the operator has no home")
	}
}
