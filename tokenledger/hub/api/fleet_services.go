package api

import (
	"encoding/json"
	"log"
	"strings"
	"sync"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

// A machine's login-level register (claude-fleet#2526, EPIC #2524 C2): the
// machine link's beat carries services[] (control.ServiceStatus), the roster
// hands each entry to whoever may see its (machine, login), and a failed entry
// is a service_failed alert until a beat says it is not.

// serviceAlertHold is how long an entry stays failed — every beat in between
// saying so — before it is an alert, and how long it stays well before its
// alert clears (task CVC4): a service the daemon restarts every few minutes
// rose and fell 7 times in 37 minutes, one alert each way per restart.
const serviceAlertHold = 10 * time.Minute

// serviceHoldBook is each subject's run: since when its beats said failed
// (failed) or, with an alert open, said well (well). In memory: a restarted
// hub starts each run again, an open alert staying open meanwhile.
type serviceHoldBook struct {
	mu     sync.Mutex
	hold   time.Duration // 0 = serviceAlertHold; < 0 = on the first beat (tests)
	failed map[string]time.Time
	well   map[string]time.Time
}

func (b *serviceHoldBook) setHold(d time.Duration) {
	b.mu.Lock()
	b.hold = d
	b.mu.Unlock()
}

// held marks sub's run (book: failed or well, the other one ended) and says
// whether it has lasted the hold.
func (b *serviceHoldBook) held(sub string, isFailed bool, now time.Time) bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.failed == nil {
		b.failed, b.well = map[string]time.Time{}, map[string]time.Time{}
	}
	book, other := b.failed, b.well
	if !isFailed {
		book, other = b.well, b.failed
	}
	delete(other, sub)
	since, ok := book[sub]
	if !ok {
		since = now
		book[sub] = now
	}
	hold := b.hold
	if hold == 0 {
		hold = serviceAlertHold
	}
	return hold < 0 || now.Sub(since) >= hold
}

// forget drops what the book holds under prefix for subjects keep says no to.
func (b *serviceHoldBook) forget(prefix string, keep func(sub string) bool) {
	b.mu.Lock()
	defer b.mu.Unlock()
	for _, m := range []map[string]time.Time{b.failed, b.well} {
		for sub := range m {
			if strings.HasPrefix(sub, prefix) && !keep(sub) {
				delete(m, sub)
			}
		}
	}
}

// serviceAlerts raises service_failed for every entry of hostname's register
// that has wanted a person for serviceAlertHold, and clears the open ones a
// beat has no longer listed as failed — a removed entry included — for as long.
func (s *Server) serviceAlerts(hostname string, svcs []control.ServiceStatus, now time.Time) {
	if hostname == "" {
		return
	}
	prefix := hostname + "/"
	failing := map[string]bool{}
	for _, sv := range svcs {
		if !sv.Failed() {
			continue
		}
		sub := prefix + sv.Login + "/" + sv.Name
		failing[sub] = true
		if !s.serviceHold.held(sub, true, now) {
			continue
		}
		detail, _ := json.Marshal(map[string]any{
			"hostname": hostname, "os_user": sv.Login, "name": sv.Name, "kind": sv.Kind,
			"state": sv.State, "last_rc": sv.LastRC, "why": sv.Why, "last_log_line": sv.LastLogLine,
		})
		raised, err := s.Store.RaiseFleetAlert(store.AlertServiceFailed, sub, string(detail), now)
		if err != nil {
			log.Printf("fleet alerts: raise service_failed %s: %v", sub, err)
		} else if raised {
			log.Printf("fleet alert: service_failed %s — %s", sub, sv.State)
		}
	}
	open, err := s.Store.OpenFleetAlertSubjects(store.AlertServiceFailed, prefix)
	if err != nil {
		log.Printf("fleet alerts: read service_failed %s: %v", hostname, err)
		return
	}
	isOpen := map[string]bool{}
	for _, sub := range open {
		isOpen[sub] = true
	}
	// a run that ended with nothing to clear is forgotten: well again before
	// the hold, the next failure starts from nought
	s.serviceHold.forget(prefix, func(sub string) bool { return failing[sub] || isOpen[sub] })
	for _, sub := range open {
		if failing[sub] || !s.serviceHold.held(sub, false, now) {
			continue
		}
		if cleared, err := s.Store.ClearFleetAlert(store.AlertServiceFailed, sub, now); err != nil {
			log.Printf("fleet alerts: clear service_failed %s: %v", sub, err)
		} else if cleared {
			log.Printf("fleet alert cleared: service_failed %s", sub)
		}
	}
}

// machineServices is one machine link's register as last heard.
type machineServices struct {
	at       *time.Time
	services []control.ServiceStatus
}

// visibleServices narrows a register to the entries visible (nil: all) lets
// the reader see — the same (machine, login) rule as the roster's rows.
func visibleServices(hostname string, ms machineServices, visible func(hostname, osUser string) bool) []control.ServiceStatus {
	var out []control.ServiceStatus
	for _, sv := range ms.services {
		if visible == nil || visible(hostname, sv.Login) {
			out = append(out, sv)
		}
	}
	return out
}

// openServiceAlerts is the open service_failed rows the reader may see.
func (s *Server) openServiceAlerts(visible func(hostname, osUser string) bool) []store.FleetAlert {
	rows, err := s.Store.FleetAlerts(200)
	if err != nil {
		return nil
	}
	out := []store.FleetAlert{}
	for _, a := range rows {
		if a.Kind != store.AlertServiceFailed || a.ClearedAt != nil {
			continue
		}
		var d struct {
			Hostname string `json:"hostname"`
			OSUser   string `json:"os_user"`
		}
		if json.Unmarshal([]byte(a.Detail), &d) != nil || d.OSUser == "" {
			continue
		}
		if visible == nil || visible(d.Hostname, d.OSUser) {
			out = append(out, a)
		}
	}
	return out
}
