package api

import (
	"encoding/json"
	"regexp"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// service_control (claude-fleet#2527, EPIC #2524 C3): the write half of a
// managed machine's login-level register — stop / start / restart an entry,
// run a task now, give a task a new schedule — from the client
// (`fleet service|task …` on any computer) and the hub's 我的机器 page alike.
//
// It rides the journalled-write road (idempotency, the journal, the audit
// row) but its target is no fleet: it is the (machine, login) lane the entry
// lives on. The caller must SEE that (machine, login) — a person's own
// accounts, the operator everything — else FORBIDDEN; the entry must be in
// the register that machine's link last beat (NOT_FOUND otherwise), and the
// node runs the supervisor for its lane's own login only (the agent half,
// node_service_ctl.go). The node answers final, so nothing is reconciled.

// serviceRef is the entry one service_control names.
type serviceRef struct {
	machine, login, name, action string
}

var (
	svcCtlNameRE  = regexp.MustCompile(`^[a-z0-9][a-z0-9._-]{0,47}$`)
	svcCtlLoginRE = regexp.MustCompile(`^[a-z0-9_][a-z0-9_.-]{0,31}$`)
	svcCtlAtRE    = regexp.MustCompile(`^([01]?[0-9]|2[0-3]):[0-5][0-9]$`)
	svcCtlCronRE  = regexp.MustCompile(`^[0-9*,/-]+( [0-9*,/-]+){4}$`)
	svcCtlTZRE    = regexp.MustCompile(`^[A-Za-z][A-Za-z0-9_+/-]{0,63}$`)
	svcCtlActions = map[string]bool{"start": true, "stop": true, "restart": true, "run_now": true, "set_schedule": true}
)

// parseServiceControl validates service_control's arguments into params (what
// the node is sent) and the entry it names.
func parseServiceControl(args map[string]any, params map[string]any) (*serviceRef, error) {
	if err := checkFields(args, []string{"idempotency_key", "machine", "login", "name", "action"}, "at", "cron", "tz"); err != nil {
		return nil, err
	}
	str := func(k string) string { s, _ := args[k].(string); return s }
	r := &serviceRef{machine: str("machine"), login: str("login"), name: str("name"), action: str("action")}
	switch {
	case !nodeNameRE.MatchString(r.machine):
		return nil, fault("INVALID_ARGUMENT", "machine must be a roster hostname")
	case !svcCtlLoginRE.MatchString(r.login):
		return nil, fault("INVALID_ARGUMENT", "login must be a login name")
	case !svcCtlNameRE.MatchString(r.name):
		return nil, fault("INVALID_ARGUMENT", "name must be an entry's name (a-z 0-9 . _ -, ≤ 48)")
	case !svcCtlActions[r.action]:
		return nil, fault("INVALID_ARGUMENT", "action must be start, stop, restart, run_now or set_schedule")
	}
	at, cron, tz := str("at"), str("cron"), str("tz")
	if r.action != "set_schedule" {
		if at != "" || cron != "" || tz != "" {
			return nil, fault("INVALID_ARGUMENT", "at / cron / tz belong to set_schedule")
		}
	} else {
		switch {
		case (at == "") == (cron == ""):
			return nil, fault("INVALID_ARGUMENT", "set_schedule needs at (HH:MM) or cron (five fields), not both")
		case at != "" && !svcCtlAtRE.MatchString(at):
			return nil, fault("INVALID_ARGUMENT", "at must be HH:MM")
		case cron != "" && !svcCtlCronRE.MatchString(cron):
			return nil, fault("INVALID_ARGUMENT", "cron must be five fields (m h dom mon dow)")
		case tz != "" && !svcCtlTZRE.MatchString(tz):
			return nil, fault("INVALID_ARGUMENT", "tz must be a zone name (Asia/Shanghai)")
		}
		for k, v := range map[string]string{"at": at, "cron": cron, "tz": tz} {
			if v != "" {
				params[k] = v
			}
		}
	}
	params["login"], params["name"], params["action"] = r.login, r.name, r.action
	return r, nil
}

// serviceTarget resolves a service_control to the lane it goes down: the
// login's own endpoint on that machine, once the caller may act there and
// the machine's register holds the entry.
func (s *Server) serviceTarget(p fleetPrincipal, r serviceRef) (store.FleetRow, error) {
	rows, err := s.Store.Nodes()
	if err != nil {
		return store.FleetRow{}, err
	}
	host := ""
	for _, n := range rows {
		if n.Hostname != "" && (n.Hostname == r.machine || (host == "" && sameMachine(n.Hostname, r.machine))) {
			host = n.Hostname
		}
	}
	if host == "" {
		host = r.machine
	}
	if !p.sees(host, r.login) {
		return store.FleetRow{}, fault("FORBIDDEN", "only your own services: "+r.login+" on "+host+" is not one of your accounts")
	}
	// The register: the freshest beat of the machine that carries one.
	var reg []control.ServiceStatus
	var regAt *time.Time
	var lane *store.Node
	for i, n := range rows {
		if n.Hostname != host {
			continue
		}
		var hb struct {
			Services []control.ServiceStatus `json:"services"`
		}
		if n.StatusJSON != "" && json.Unmarshal([]byte(n.StatusJSON), &hb) == nil && len(hb.Services) > 0 &&
			(regAt == nil || (n.LastHeartbeat != nil && n.LastHeartbeat.After(*regAt))) {
			reg, regAt = hb.Services, n.LastHeartbeat
		}
		if n.OSUser == r.login && (lane == nil || (n.LastHeartbeat != nil &&
			(lane.LastHeartbeat == nil || n.LastHeartbeat.After(*lane.LastHeartbeat)))) {
			lane = &rows[i]
		}
	}
	var entry *control.ServiceStatus
	for i := range reg {
		if reg[i].Login == r.login && reg[i].Name == r.name {
			entry = &reg[i]
		}
	}
	if entry == nil {
		return store.FleetRow{}, fault("NOT_FOUND", r.login+"/"+r.name+" is not in "+host+"'s register")
	}
	if (r.action == "run_now" || r.action == "set_schedule") && entry.Kind != "task" {
		return store.FleetRow{}, fault("INVALID_ARGUMENT", r.name+" is a service: "+r.action+" is a scheduled task's (restart starts a service again)")
	}
	if lane == nil {
		return store.FleetRow{}, fault("UNAVAILABLE", r.login+" on "+host+" has no node lane; nothing was sent")
	}
	return store.FleetRow{EndpointID: lane.EndpointID, Hostname: host, OSUser: r.login, Present: true}, nil
}
