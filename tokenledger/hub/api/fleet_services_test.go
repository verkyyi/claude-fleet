package api

import (
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

// claude-fleet#2526: the machine link's beat carries the register; the roster
// hands each entry to whoever may see its (machine, login); a failed entry is
// a service_failed alert — on the summary too — until a beat says it is not.
func TestMachineLinkServicesReachTheRosterAndAlert(t *testing.T) {
	h, n := machineRig(t)
	h.srv.serviceHold.setHold(-1) // this test is about the road; the hold has its own below
	for _, l := range []string{"alpha", "beta"} {
		n.beat(l, control.Heartbeat{Hostname: "mac-c", OSUser: l, NCPU: 10, ObservedAt: time.Now()})
	}
	rc := 1
	started := time.Now().Add(-time.Hour).UTC()
	next := time.Now().Add(time.Minute).UTC()
	n.beat("", control.Heartbeat{Hostname: "mac-c", OSUser: "root", NCPU: 10, ObservedAt: time.Now(),
		Services: []control.ServiceStatus{
			{Name: "sms-watch", Kind: "service", Login: "alpha", State: "running", StartedAt: &started, LastRun: &started, LastLogLine: "sent 3"},
			{Name: "daily-report", Kind: "service", Login: "alpha", State: "down", LastRC: &rc, NextRun: &next, LastLogLine: "give up"},
			{Name: "beta-thing", Kind: "service", Login: "beta", State: "invalid", Why: "bad exec"},
		}})
	waitFor(t, 3*time.Second, "mac-c carries its register", func() bool {
		ms := roster(t, h).Machines
		return len(ms) == 1 && len(ms[0].Services) == 3
	})
	m := roster(t, h).Machines[0]
	if m.ServicesAt == nil || m.Services[1].LastLogLine != "give up" || m.Services[1].NextRun == nil {
		t.Fatalf("mac-c's register = %+v at %v", m.Services, m.ServicesAt)
	}

	// A person who holds alpha on mac-c sees alpha's entries only — though the
	// beat came on the link's own (root) row they never see.
	alphaOnly := func(host, login string) bool { return host == "mac-c" && login == "alpha" }
	snap, err := h.srv.nodesWhere(time.Now(), alphaOnly)
	if err != nil {
		t.Fatal(err)
	}
	if len(snap.Machines) != 1 || len(snap.Machines[0].Services) != 2 {
		t.Fatalf("alpha's view of mac-c = %+v", snap.Machines)
	}
	for _, sv := range snap.Machines[0].Services {
		if sv.Login != "alpha" {
			t.Fatalf("alpha sees %s's entry %s", sv.Login, sv.Name)
		}
	}
	// Someone with no login on mac-c sees no mac-c at all.
	if snap, _ := h.srv.nodesWhere(time.Now(), func(string, string) bool { return false }); len(snap.Machines) != 0 {
		t.Fatalf("a stranger sees %+v", snap.Machines)
	}

	// The two failed entries are alerts; the running one is not.
	open := openAlerts(t, h, store.AlertServiceFailed)
	subjects := map[string]bool{}
	for _, a := range open {
		subjects[a.Subject] = true
	}
	if len(open) != 2 || !subjects["mac-c/alpha/daily-report"] || !subjects["mac-c/beta/beta-thing"] {
		t.Fatalf("service_failed = %+v", open)
	}
	// alpha's alert reads: theirs only, on the alerts read and on the summary.
	seen := h.srv.alertsSeenBy(fleetPrincipal{scope: alphaOnly}, open)
	if len(seen) != 1 || seen[0].Subject != "mac-c/alpha/daily-report" || !strings.Contains(seen[0].Detail, `"last_log_line":"give up"`) {
		t.Fatalf("alpha's alerts = %+v", seen)
	}
	if got := h.srv.openServiceAlerts(alphaOnly); len(got) != 1 || got[0].Subject != "mac-c/alpha/daily-report" {
		t.Fatalf("alpha's summary alerts = %+v", got)
	}
	if got := h.srv.openServiceAlerts(nil); len(got) != 2 {
		t.Fatalf("the operator's summary alerts = %+v", got)
	}

	// Raising again is a no-op; a beat with the entry back up clears it, and
	// a removed entry's alert clears too.
	n.beat("", control.Heartbeat{Hostname: "mac-c", OSUser: "root", NCPU: 10, ObservedAt: time.Now(),
		Services: []control.ServiceStatus{
			{Name: "sms-watch", Kind: "service", Login: "alpha", State: "running"},
			{Name: "daily-report", Kind: "service", Login: "alpha", State: "running"},
		}})
	waitFor(t, 3*time.Second, "both alerts cleared", func() bool {
		return len(openAlerts(t, h, store.AlertServiceFailed)) == 0
	})
	// An empty register (nil on the wire) leaves the roster without one.
	n.beat("", control.Heartbeat{Hostname: "mac-c", OSUser: "root", NCPU: 10, ObservedAt: time.Now()})
	waitFor(t, 3*time.Second, "mac-c's register gone", func() bool {
		ms := roster(t, h).Machines
		return len(ms) == 1 && ms[0].Services == nil
	})
}

// A login's own beat cannot write the register or raise an alert: only the machine link speaks for the
// register.
func TestLoginBeatCarriesNoServiceAlert(t *testing.T) {
	h, n := machineRig(t)
	h.srv.serviceHold.setHold(-1)
	n.beat("alpha", control.Heartbeat{Hostname: "mac-c", OSUser: "alpha", NCPU: 10, ObservedAt: time.Now(),
		Services: []control.ServiceStatus{{Name: "x", Kind: "service", Login: "beta", State: "down"}}})
	waitFor(t, 3*time.Second, "alpha online", func() bool {
		for _, v := range roster(t, h).Nodes {
			if v.OSUser == "alpha" && v.Status == "online" {
				return true
			}
		}
		return false
	})
	time.Sleep(100 * time.Millisecond)
	if ms := roster(t, h).Machines; len(ms) != 1 || ms[0].Services != nil {
		t.Fatalf("a login's beat wrote the register: %+v", ms)
	}
	if open := openAlerts(t, h, store.AlertServiceFailed); len(open) != 0 {
		t.Fatalf("a login's beat raised %+v", open)
	}
}

// Task CVC4: a service the daemon restarts every few minutes (down, running,
// down…) rose and fell an alert per restart — 7 and 7 in 37 minutes. An
// alert now rises only after 10 minutes of failed beats and falls only after
// 10 minutes of well ones: half an hour of failing and recovering is no alert,
// and a real outage is one rise and one fall.
func TestServiceAlertHoldsTenMinutes(t *testing.T) {
	h := newFleetHarness(t)
	s := h.srv
	down := []control.ServiceStatus{{Name: "webchat", Kind: "service", Login: "alpha", State: "down"}}
	up := []control.ServiceStatus{{Name: "webchat", Kind: "service", Login: "alpha", State: "running"}}
	t0 := time.Now().Add(-2 * time.Hour)
	at := func(m int) time.Time { return t0.Add(time.Duration(m) * time.Minute) }
	count := func() (open, all int) {
		rows, err := s.Store.FleetAlerts(200)
		if err != nil {
			t.Fatal(err)
		}
		for _, a := range rows {
			if a.Kind == store.AlertServiceFailed {
				all++
				if a.ClearedAt == nil {
					open++
				}
			}
		}
		return
	}

	// 30 minutes: 4 minutes down, 2 up, a beat a minute ⇒ no alert at all.
	for m := 0; m < 30; m++ {
		svcs := down
		if m%6 >= 4 {
			svcs = up
		}
		s.serviceAlerts("mac-c", svcs, at(m))
	}
	if open, all := count(); open != 0 || all != 0 {
		t.Fatalf("failing and recovering for 30 min raised %d (%d open)", all, open)
	}

	// Down for good: nothing at 9 minutes, one alert at 10.
	for m := 30; m <= 39; m++ {
		s.serviceAlerts("mac-c", down, at(m))
	}
	if open, _ := count(); open != 0 {
		t.Fatalf("raised after 9 min down")
	}
	for m := 40; m <= 50; m++ {
		s.serviceAlerts("mac-c", down, at(m))
	}
	if open, all := count(); open != 1 || all != 1 {
		t.Fatalf("10+ min down: %d alerts, %d open — want one", all, open)
	}

	// Up again, with one failed beat in between: the alert stays open until
	// 10 well minutes in a row, then clears once.
	for m := 51; m <= 55; m++ {
		s.serviceAlerts("mac-c", up, at(m))
	}
	s.serviceAlerts("mac-c", down, at(56))
	for m := 57; m <= 66; m++ {
		s.serviceAlerts("mac-c", up, at(m))
	}
	if open, _ := count(); open != 1 {
		t.Fatalf("cleared before 10 well minutes in a row")
	}
	for m := 67; m <= 70; m++ {
		s.serviceAlerts("mac-c", up, at(m))
	}
	if open, all := count(); open != 0 || all != 1 {
		t.Fatalf("after 10 well minutes: %d alerts, %d open — want one, cleared", all, open)
	}

	// A removed entry counts as well; a fresh failure starts from nought.
	for m := 71; m <= 79; m++ {
		s.serviceAlerts("mac-c", down, at(m))
	}
	s.serviceAlerts("mac-c", nil, at(80))
	for m := 81; m <= 89; m++ {
		s.serviceAlerts("mac-c", down, at(m))
	}
	if open, all := count(); open != 0 || all != 1 {
		t.Fatalf("a run broken by a removed entry raised: %d alerts, %d open", all, open)
	}
}
