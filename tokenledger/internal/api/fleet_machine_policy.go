package api

import (
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"sort"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// Machine allowlists (claude-fleet#3824): which MACHINES a person may use, on
// top of everything that already decides it. The subscription allowlists
// (fleet_cred_policy.go) narrow what a session may spend; this narrows where
// it may run at all — a login the person has on a machine off their list
// stays (its home, its worktrees, its sessions' history), it just cannot be
// used until the list lets it back.
//
// Stored as one setting family, written ONLY through PUT /v1/fleet/machine-policy
// (admin; every write a settings audit row) — the generic settings PUT refuses it:
//
//	fleet.machine_allow.user.<principal>   principal = the stable principal ID (gh:<id>)
//
// The value:
//
//   - no key        every machine (the default — nothing changes);
//   - `"*"`         every machine, said explicitly;
//   - `[]`          no machine at all;
//   - a list        only these machines: the first label, lowercased, of the
//     name the endpoint JOINED as (endpoints.enrolled_host — never the name a
//     heartbeat reports now), else of its hostname; a login (no endpoint) by
//     its account's machine;
//   - unparsable    no machine (the reason names it) — a broken restriction
//     never reads as no restriction.
//
// Enforced by ONE reader (machineDenied) wherever a person meets a machine:
// placement (place_start / spawn / task — out for auto AND for a start that
// names it), the entry door's key list (a home off the list gets none of the
// person's keys), the node's credential lease and the session pass (mint,
// and every verify: a session already open stops at its next check, within
// the pass cache, not at its 4 h expiry), the relay's credential, and the
// session list a person sees («已停用（管理员限制）»).
//
// The operator (no person) is never narrowed; a list names a person.

const (
	MachineAllowUserPrefix = "fleet.machine_allow.user."
	// MachinePolicyPath is the admin route.
	MachinePolicyPath = "/v1/fleet/machine-policy"
	// machinePolicyMax bounds one list.
	machinePolicyMax = 256
	// MachineDisabledWord is what a person reads on a session on a machine
	// off their list.
	MachineDisabledWord = "已停用（管理员限制）"
	// MachineAvailDisabled is a session's / machine's availability in a
	// person's list while their allowlist leaves the machine out.
	MachineAvailDisabled = "disabled"
)

// machineAllow is one person's allowance.
type machineAllow struct {
	Set   bool            // a list applies
	All   bool            // explicitly every machine
	Bad   string          // the value does not parse: no machine
	Names map[string]bool // lowercased first labels
}

func machineAllowKey(principal string) string { return MachineAllowUserPrefix + principal }

// normMachine is a machine name as compared.
func normMachine(name string) string { return strings.ToLower(firstLabel(strings.TrimSpace(name))) }

// parseMachineAllow reads one stored list.
func parseMachineAllow(raw string) (map[string]bool, error) {
	var names []string
	if err := json.Unmarshal([]byte(raw), &names); err != nil {
		return nil, fmt.Errorf("not a JSON list of machine names: %v", err)
	}
	if names == nil {
		return nil, errors.New("null is not a list (use [] for no machine)")
	}
	if len(names) > machinePolicyMax {
		return nil, fmt.Errorf("%d entries, at most %d", len(names), machinePolicyMax)
	}
	out := map[string]bool{}
	for _, n := range names {
		m := normMachine(n)
		if !nodeNameRE.MatchString(m) {
			return nil, fmt.Errorf("%q is not a machine name", n)
		}
		out[m] = true
	}
	return out, nil
}

// machineAllowOf is principal's allowance from the settings.
func machineAllowOf(settings map[string]string, principal string) machineAllow {
	if principal == "" {
		return machineAllow{}
	}
	raw, ok := settings[machineAllowKey(principal)]
	if !ok || raw == "" {
		return machineAllow{}
	}
	if raw == `"*"` {
		return machineAllow{Set: true, All: true}
	}
	names, err := parseMachineAllow(raw)
	if err != nil {
		return machineAllow{Set: true, Bad: err.Error()}
	}
	return machineAllow{Set: true, Names: names}
}

// anyMachinePolicy says whether some person has a list — when none does,
// nothing here runs and every reader answers as before.
func anyMachinePolicy(settings map[string]string) bool {
	for k := range settings {
		if strings.HasPrefix(k, MachineAllowUserPrefix) {
			return true
		}
	}
	return false
}

// deny is "" when machine is allowed, else why not (the person's words).
func (a machineAllow) deny(machine string) string {
	if !a.Set || a.All {
		return ""
	}
	m := normMachine(machine)
	switch {
	case a.Bad != "":
		return "这个人的机器白名单写坏了（" + a.Bad + "）：暂不开放任何机器"
	case len(a.Names) == 0:
		return "管理员暂未给你开放任何机器"
	case m == "" || !a.Names[m]:
		return "这台机器暂未对你开放，可用：" + strings.Join(a.list(), "、")
	}
	return ""
}

// list is the allowed machines, sorted.
func (a machineAllow) list() []string {
	out := make([]string, 0, len(a.Names))
	for n := range a.Names {
		out = append(out, n)
	}
	sort.Strings(out)
	return out
}

// machineDenied is "" when principal may use machine, else why not. The
// operator ("" principal) is never narrowed.
func machineDenied(settings map[string]string, machine, principal string) string {
	return machineAllowOf(settings, principal).deny(machine)
}

// endpointMachine is the name an endpoint's machine is listed by: the name
// it joined as, else its hostname's first label.
func (s *Server) endpointMachine(endpointID, hostname string) string {
	if endpointID != "" {
		if m := s.policyMachine(endpointID); m != "" {
			return m
		}
	}
	return normMachine(hostname)
}

// denyEndpoint is "" when a lets the endpoint's machine through, judged by
// the name it JOINED as — never the hostname a heartbeat reports now, which
// the login on it could choose — and by hostname only for an endpoint that
// never named one.
func (s *Server) denyEndpoint(a machineAllow, endpointID, hostname string) string {
	if !a.Set || a.All {
		return ""
	}
	return a.deny(s.endpointMachine(endpointID, hostname))
}

// machineDeniedFor reads the settings: "" when principal may use the
// endpoint's machine. A settings read error is an error, never "allowed".
func (s *Server) machineDeniedFor(endpointID, hostname, principal string) (string, error) {
	if principal == "" {
		return "", nil
	}
	settings, err := s.Store.FleetSettings()
	if err != nil {
		return "", err
	}
	if !anyMachinePolicy(settings) {
		return "", nil
	}
	return s.denyEndpoint(machineAllowOf(settings, principal), endpointID, hostname), nil
}

// machineAllowFor is principal's allowance, read once for a loop over
// machines; the zero value (no list) when nothing applies.
func (s *Server) machineAllowFor(principal string) (machineAllow, error) {
	if principal == "" {
		return machineAllow{}, nil
	}
	settings, err := s.Store.FleetSettings()
	if err != nil {
		return machineAllow{}, err
	}
	return machineAllowOf(settings, principal), nil
}

// DisabledMachine is a machine where a person has a login the hub keeps, but
// their machine allowlist leaves out: listed so a client can say why instead
// of «no such machine».
type DisabledMachine struct {
	Hostname string `json:"hostname"`
	Alias    string `json:"alias,omitempty"`
	Login    string `json:"login,omitempty"`
	Reason   string `json:"reason"`
}

// errMachineOff: every login a person has is on a machine their list leaves
// out. It reads as errNoAccount to every caller that only asks «any login?»
// (a certificate, the routes), and as itself to the one that would otherwise
// open them a new login (the home pick).
var errMachineOff = errors.New(MachineDisabledWord)

type machineOffErr struct{ why string }

func (e *machineOffErr) Error() string { return e.why }
func (e *machineOffErr) Is(target error) bool {
	return target == errMachineOff || target == errNoAccount
}

// disabledMachinesOf is pid's machines with an active managed login that the
// list leaves out, with why.
func (s *Server) disabledMachinesOf(pid string) ([]DisabledMachine, error) {
	a, err := s.machineAllowFor(pid)
	if err != nil || !a.Set || a.All {
		return nil, err
	}
	accts, err := s.Store.FleetAccounts(pid)
	if err != nil {
		return nil, err
	}
	var out []DisabledMachine
	seen := map[string]bool{}
	for _, ac := range accts {
		if ac.State != store.AccountActive || !ac.Managed() {
			continue
		}
		why := a.deny(ac.Hostname)
		if why == "" || seen[strings.ToLower(ac.Hostname)] {
			continue
		}
		seen[strings.ToLower(ac.Hostname)] = true
		out = append(out, DisabledMachine{Hostname: ac.Hostname, Alias: normMachine(ac.Hostname), Login: ac.Login, Reason: MachineDisabledWord + "：" + why})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Hostname < out[j].Hostname })
	return out, nil
}

// MachinePolicyPut is the body of PUT /v1/fleet/machine-policy: Allow a list
// (only these; [] = none), All every machine, neither (null) = clear.
type MachinePolicyPut struct {
	Principal string    `json:"principal"`
	Allow     *[]string `json:"allow"`
	All       bool      `json:"all"`
}

// handleMachinePolicy: GET lists every person's list (with principal=, that
// person's verdict on each known machine); PUT sets or clears one. Admin only.
func (s *Server) handleMachinePolicy(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	switch r.Method {
	case http.MethodGet:
		s.machinePolicyGet(w, r)
	case http.MethodPut, http.MethodPost:
		s.machinePolicyPut(w, r)
	default:
		w.Header().Set("Allow", "GET, PUT")
		httpError(w, http.StatusMethodNotAllowed, "GET or PUT")
	}
}

func (s *Server) machinePolicyGet(w http.ResponseWriter, r *http.Request) {
	settings, err := s.Store.FleetSettings()
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	type entry struct {
		Principal string   `json:"principal"`
		Allow     []string `json:"allow"`
		All       bool     `json:"all,omitempty"`
		Error     string   `json:"error,omitempty"`
	}
	users := []entry{}
	for k := range settings {
		p, ok := strings.CutPrefix(k, MachineAllowUserPrefix)
		if !ok || settings[k] == "" {
			continue
		}
		a := machineAllowOf(settings, p)
		users = append(users, entry{Principal: p, Allow: a.list(), All: a.All, Error: a.Bad})
	}
	sort.Slice(users, func(i, j int) bool { return users[i].Principal < users[j].Principal })
	out := map[string]any{"users": users,
		"semantics": "no list = every machine; all = every machine, explicitly; [] = none; a list = only those machines (the name a machine joined as, first label); a malformed list = none",
		"enforced":  "placement (auto and named), the entry door's keys, the node credential lease, the session pass (mint and every verify), the relay credential, the session list («" + MachineDisabledWord + "»)"}
	if p := r.URL.Query().Get("principal"); p != "" {
		a := machineAllowOf(settings, p)
		// Every machine the hub knows (the roster, by the name each joined
		// as) and every one the person has a login on.
		machines := []map[string]any{}
		seen := map[string]bool{}
		add := func(m, why string) {
			if m == "" || seen[m] {
				return
			}
			seen[m] = true
			machines = append(machines, map[string]any{"machine": m, "allowed": why == "", "reason": why})
		}
		if snap, err := s.Nodes(time.Now()); err == nil {
			for _, n := range snap.Nodes {
				add(s.endpointMachine(n.EndpointID, n.Hostname), s.denyEndpoint(a, n.EndpointID, n.Hostname))
			}
		}
		if accts, err := s.Store.FleetAccounts(p); err == nil {
			for _, ac := range accts {
				add(normMachine(ac.Hostname), a.deny(ac.Hostname))
			}
		}
		sort.Slice(machines, func(i, j int) bool { return machines[i]["machine"].(string) < machines[j]["machine"].(string) })
		out["effective"] = map[string]any{"principal": p, "restricted": a.Set && !a.All, "machines": machines}
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) machinePolicyPut(w http.ResponseWriter, r *http.Request) {
	var req MachinePolicyPut
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 64<<10)).Decode(&req); err != nil {
		httpError(w, http.StatusBadRequest, "malformed request: "+err.Error())
		return
	}
	if req.All && req.Allow != nil {
		httpError(w, http.StatusBadRequest, "choose all or allow, not both")
		return
	}
	if !principalKeyRE.MatchString(req.Principal) || req.Principal == store.PoolPrincipal {
		httpError(w, http.StatusBadRequest, "principal must be a principal ID (gh:<id>)")
		return
	}
	if _, err := s.Store.Principal(req.Principal); err != nil {
		// Like the subscription lists: an invited person may be listed before
		// their first login.
		known := false
		if isPerson(req.Principal) {
			u, e := s.personRow(req.Principal)
			if e != nil {
				httpError(w, http.StatusInternalServerError, e.Error())
				return
			}
			known = u != nil
		}
		if !known {
			httpError(w, http.StatusBadRequest, "unknown principal "+req.Principal)
			return
		}
	}
	value := ""
	switch {
	case req.All:
		value = `"*"`
	case req.Allow != nil:
		norm, seen := []string{}, map[string]bool{}
		for _, n := range *req.Allow {
			m := normMachine(n)
			if !nodeNameRE.MatchString(m) {
				httpError(w, http.StatusBadRequest, fmt.Sprintf("%q is not a machine name", n))
				return
			}
			if !seen[m] {
				seen[m] = true
				norm = append(norm, m)
			}
		}
		if len(norm) > machinePolicyMax {
			httpError(w, http.StatusBadRequest, fmt.Sprintf("at most %d machines", machinePolicyMax))
			return
		}
		sort.Strings(norm)
		b, _ := json.Marshal(norm)
		value = string(b)
	}
	key := machineAllowKey(req.Principal)
	settings, err := s.Store.FleetSettings()
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	now := time.Now()
	if err := s.Store.SetFleetSetting(key, value, now); err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	s.settingAudit(actorOf(r), key, settings[key], value, now)
	s.sessCred.drop("") // every cached pass is judged again on its next verify
	s.relayCacheReset()
	s.BroadcastCreds("machine policy") // every node leases now: the copies leave at once (#3744)
	if s.entryOn() {
		// The person's home door hears it now, not at its next pull.
		if v, err := s.Store.BumpEntryVersion(); err == nil {
			s.entryPushPerson(req.Principal, v)
		} else {
			log.Printf("machine policy: entry version: %v", err)
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "key": key, "principal": req.Principal, "all": req.All,
		"allow": json.RawMessage(orNull(func() string {
			if req.All {
				return ""
			}
			return value
		}()))})
}
