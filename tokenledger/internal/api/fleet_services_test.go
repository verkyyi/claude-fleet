package api

import (
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// claude-fleet#2526: the machine link's beat carries the register; the roster
// hands each entry to whoever may see its (machine, login); a failed entry is
// a service_failed alert — on the summary too — until a beat says it is not.
func TestMachineLinkServicesReachTheRosterAndAlert(t *testing.T) {
	h, n := machineRig(t)
	for _, l := range []string{"alpha", "beta"} {
		n.beat(l, control.Heartbeat{Hostname: "m4", OSUser: l, NCPU: 10, ObservedAt: time.Now()})
	}
	rc := 1
	started := time.Now().Add(-time.Hour).UTC()
	next := time.Now().Add(time.Minute).UTC()
	n.beat("", control.Heartbeat{Hostname: "m4", OSUser: "root", NCPU: 10, ObservedAt: time.Now(),
		Services: []control.ServiceStatus{
			{Name: "sms-watch", Kind: "service", Login: "alpha", State: "running", StartedAt: &started, LastRun: &started, LastLogLine: "sent 3"},
			{Name: "daily-report", Kind: "service", Login: "alpha", State: "down", LastRC: &rc, NextRun: &next, LastLogLine: "give up"},
			{Name: "beta-thing", Kind: "service", Login: "beta", State: "invalid", Why: "bad exec"},
		}})
	waitFor(t, 3*time.Second, "m4 carries its register", func() bool {
		ms := roster(t, h).Machines
		return len(ms) == 1 && len(ms[0].Services) == 3
	})
	m := roster(t, h).Machines[0]
	if m.ServicesAt == nil || m.Services[1].LastLogLine != "give up" || m.Services[1].NextRun == nil {
		t.Fatalf("m4's register = %+v at %v", m.Services, m.ServicesAt)
	}

	// A person who holds alpha on m4 sees alpha's entries only — though the
	// beat came on the link's own (root) row they never see.
	alphaOnly := func(host, login string) bool { return host == "m4" && login == "alpha" }
	snap, err := h.srv.nodesWhere(time.Now(), alphaOnly)
	if err != nil {
		t.Fatal(err)
	}
	if len(snap.Machines) != 1 || len(snap.Machines[0].Services) != 2 {
		t.Fatalf("alpha's view of m4 = %+v", snap.Machines)
	}
	for _, sv := range snap.Machines[0].Services {
		if sv.Login != "alpha" {
			t.Fatalf("alpha sees %s's entry %s", sv.Login, sv.Name)
		}
	}
	// Someone with no login on m4 sees no m4 at all.
	if snap, _ := h.srv.nodesWhere(time.Now(), func(string, string) bool { return false }); len(snap.Machines) != 0 {
		t.Fatalf("a stranger sees %+v", snap.Machines)
	}

	// The two failed entries are alerts; the running one is not.
	open := openAlerts(t, h, store.AlertServiceFailed)
	subjects := map[string]bool{}
	for _, a := range open {
		subjects[a.Subject] = true
	}
	if len(open) != 2 || !subjects["m4/alpha/daily-report"] || !subjects["m4/beta/beta-thing"] {
		t.Fatalf("service_failed = %+v", open)
	}
	// alpha's alert reads: theirs only, on the alerts read and on the summary.
	seen := h.srv.alertsSeenBy(fleetPrincipal{scope: alphaOnly}, open)
	if len(seen) != 1 || seen[0].Subject != "m4/alpha/daily-report" || !strings.Contains(seen[0].Detail, `"last_log_line":"give up"`) {
		t.Fatalf("alpha's alerts = %+v", seen)
	}
	if got := h.srv.openServiceAlerts(alphaOnly); len(got) != 1 || got[0].Subject != "m4/alpha/daily-report" {
		t.Fatalf("alpha's summary alerts = %+v", got)
	}
	if got := h.srv.openServiceAlerts(nil); len(got) != 2 {
		t.Fatalf("the operator's summary alerts = %+v", got)
	}

	// Raising again is a no-op; a beat with the entry back up clears it, and
	// a removed entry's alert clears too.
	n.beat("", control.Heartbeat{Hostname: "m4", OSUser: "root", NCPU: 10, ObservedAt: time.Now(),
		Services: []control.ServiceStatus{
			{Name: "sms-watch", Kind: "service", Login: "alpha", State: "running"},
			{Name: "daily-report", Kind: "service", Login: "alpha", State: "running"},
		}})
	waitFor(t, 3*time.Second, "both alerts cleared", func() bool {
		return len(openAlerts(t, h, store.AlertServiceFailed)) == 0
	})
	// An empty register (nil on the wire) leaves the roster without one.
	n.beat("", control.Heartbeat{Hostname: "m4", OSUser: "root", NCPU: 10, ObservedAt: time.Now()})
	waitFor(t, 3*time.Second, "m4's register gone", func() bool {
		ms := roster(t, h).Machines
		return len(ms) == 1 && ms[0].Services == nil
	})
}

// A login's own beat cannot write the register or raise an alert: only the machine link speaks for the
// register.
func TestLoginBeatCarriesNoServiceAlert(t *testing.T) {
	h, n := machineRig(t)
	n.beat("alpha", control.Heartbeat{Hostname: "m4", OSUser: "alpha", NCPU: 10, ObservedAt: time.Now(),
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
