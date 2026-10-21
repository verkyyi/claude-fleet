package api

import (
	"net/http"
	"sort"
	"strings"

	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

// 试用账号出网 (claude-fleet WACK C3): off by default — a trial login reaches
// what any login does. fleet.trial.egress = log | block makes every machine
// hold the logins a trial person has there to conf/trial-egress.allow (block:
// refused past it, mail ports always; log: only written down), through ONE pf
// anchor `fleet-trial` the machine rebuilds each minute from
// GET /v1/node/trial-egress. Members and admins are never on the list.

// TrialEgressKey is the setting.
const TrialEgressKey = "fleet.trial.egress"

// trialEgressModes are its values.
var trialEgressModes = []string{"off", "log", "block"}

func checkTrialEgress(_ *Server, v string) (string, string) {
	v = strings.ToLower(strings.TrimSpace(v))
	for _, m := range trialEgressModes {
		if v == m {
			return v, ""
		}
	}
	return "", TrialEgressKey + " is off | log | block, or \"\" for the default (off)"
}

// trialEgressMode is the setting, off when unreadable.
func (s *Server) trialEgressMode() string {
	if v, why := checkTrialEgress(s, s.setting(TrialEgressKey)); why == "" {
		return v
	}
	return "off"
}

// trialIdentity is THE one answer to «is pid a trial person» (WACK 共同约定 2):
// they came in through the trial road and were not converted since
// (trialPerson, role trial), or they are a member whose limits
// (fleet.member_limits.<pid>) carry an end — 转正 clears the key.
func (s *Server) trialIdentity(settings map[string]string, pid string) bool {
	if pid == "" {
		return false
	}
	if s.trialPerson(pid) {
		return true
	}
	l, ok := memberLimitsOf(settings, pid)
	return ok && !l.Until.IsZero()
}

// trialEgressLogins is every login on host whose home is a trial person's —
// never a fleet admin's.
func (s *Server) trialEgressLogins(host string) ([]string, error) {
	homes, err := s.Store.EntryHomes()
	if err != nil {
		return nil, err
	}
	settings, err := s.Store.FleetSettings()
	if err != nil {
		return nil, err
	}
	seen := map[string]bool{}
	out := []string{}
	for _, h := range homes {
		if !sameMachine(host, h.Machine) && !sameMachine(h.Machine, host) {
			continue
		}
		if seen[h.Login] || s.isFleetAdmin(h.Login) || !control.ValidExistingLogin(h.Login) {
			continue
		}
		if s.trialIdentity(settings, h.Person) {
			seen[h.Login] = true
			out = append(out, h.Login)
		}
	}
	sort.Strings(out)
	return out, nil
}

// handleNodeTrialEgress serves TrialEgressNodePath.
func (s *Server) handleNodeTrialEgress(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", "GET")
		httpError(w, http.StatusMethodNotAllowed, "GET")
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	ep, _, ok := s.nodeEndpointOr(w, r, "the machine's node token is required", "unrecognised node token")
	if !ok {
		return
	}
	host := s.nodeMachineHost(w, r, ep)
	if host == "" {
		return
	}
	out := control.TrialEgress{Mode: s.trialEgressMode(), Logins: []string{}}
	if out.Mode != "off" {
		l, err := s.trialEgressLogins(host)
		if err != nil {
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
		out.Logins = l
	}

	writeJSON(w, http.StatusOK, out)
}
