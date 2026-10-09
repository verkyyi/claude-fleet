package api

import (
	"encoding/json"
	"log"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// A machine's login-level register (claude-fleet#2526, EPIC #2524 C2): the
// machine link's beat carries services[] (control.ServiceStatus), the roster
// hands each entry to whoever may see its (machine, login), and a failed entry
// is a service_failed alert until a beat says it is not.

// serviceAlerts raises service_failed for every entry of hostname's register
// that wants a person, and clears the open ones a beat no longer lists as
// failed — a removed entry included.
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
	for _, sub := range open {
		if failing[sub] {
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
