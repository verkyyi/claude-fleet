package api

import (
	"fmt"
	"log"
	"net/http"
	"regexp"
	"sort"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
)

// The cluster's one public door (claude-fleet#3549, EPIC #3500 C4).
//
// Every person whose home is their own pod (u-<nonce>, #3550) is reached
// through ONE load balancer: the door's sshd lets a login in with that
// person's own keys only (the same list a home machine's entry port takes),
// and its ForceCommand hands the connection to the pod the table names —
// never another. The door is a machine to the hub, named in the setting
// fleet.door; it reads its table at EntryRoutesNodePath with its token, and a
// person's name in DNS points at the door's address, not the pod's (a pod has
// no address outside the cluster). No setting = no door: the endpoint answers
// 404, DNS and the push are byte for byte as before.

// DoorKey names the door's machines (comma-separated; its replicas share one).
const DoorKey = "fleet.door"

// userPodNameRE is render.py's USER_POD_RE: a person's pod is named
// u-<nonce>, a generic name, never the person's.
var userPodNameRE = regexp.MustCompile(`^u-[a-z0-9]{4,20}$`)

// isUserPodName says whether a home machine is one person's pod — by its name
// alone, so a pod that is down still has its route (the door says it is down).
func isUserPodName(machine string) bool {
	return userPodNameRE.MatchString(strings.ToLower(firstLabel(machine)))
}

func doorCheck(_ *Server, v string) (string, string) {
	var hosts []string
	for _, h := range strings.Split(v, ",") {
		h = strings.TrimSpace(h)
		if h == "" {
			continue
		}
		if !nodeNameRE.MatchString(h) {
			return "", fmt.Sprintf("%s: %q is not a machine name", DoorKey, h)
		}
		if isUserPodName(h) {
			return "", fmt.Sprintf("%s: %q is a person's pod, not a door", DoorKey, h)
		}
		hosts = append(hosts, h)
	}
	return strings.Join(hosts, ","), ""
}

// doorMachines is the setting's list.
func (s *Server) doorMachines() []string {
	var out []string
	for _, h := range strings.Split(s.setting(DoorKey), ",") {
		if h = strings.TrimSpace(h); h != "" {
			out = append(out, h)
		}
	}
	return out
}

func (s *Server) isDoor(host string) bool {
	for _, d := range s.doorMachines() {
		if sameMachine(host, d) || sameMachine(d, host) {
			return true
		}
	}
	return false
}

// entryAddrMachine is the machine whose address a home is reached at: a
// person's pod is reached through the door (the first one the outside can
// reach, else the first named); any other home is its own.
func (s *Server) entryAddrMachine(machine string, now time.Time) string {
	if !isUserPodName(machine) {
		return machine
	}
	doors := s.doorMachines()
	if len(doors) == 0 {
		return machine
	}
	for _, d := range doors {
		if reach, err := s.EntryReachable(d, now); err == nil && len(reach) > 0 {
			return d
		}
	}
	return doors[0]
}

// withDoors adds the doors to a push aimed at a person's pod: the door's
// table changes with it.
func (s *Server) withDoors(hosts []string) []string {
	for _, h := range hosts {
		if isUserPodName(h) {
			return append(append([]string{}, hosts...), s.doorMachines()...)
		}
	}
	return hosts
}

// handleNodeEntryRoutes serves EntryRoutesNodePath: the door's own token only.
func (s *Server) handleNodeEntryRoutes(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", "GET")
		httpError(w, http.StatusMethodNotAllowed, "GET")
		return
	}
	if len(s.doorMachines()) == 0 {
		w.Header().Set("Cache-Control", "no-store")
		httpError(w, http.StatusNotFound, "this hub has no door ("+DoorKey+")")
		return
	}
	host := s.entryMachineOf(w, r)
	if host == "" {
		return
	}
	if !s.isDoor(host) {
		httpError(w, http.StatusForbidden, host+" is not this hub's door ("+DoorKey+")")
		return
	}
	out, err := s.entryRouteList()
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, out)
}

// entryRouteList is the door's table: every person whose home is a pod —
// never a fleet admin's login. A login two pods claim goes to NEITHER (the
// door must never guess whose pod a name is): the table drops it and says so.
func (s *Server) entryRouteList() (control.EntryRouteList, error) {
	out := control.EntryRouteList{Routes: []control.EntryRoute{}, Logins: map[string]control.EntryNodeLogin{}}
	v, err := s.Store.EntryVersion()
	if err != nil {
		return out, err
	}
	out.Version = v
	homes, err := s.Store.EntryHomes()
	if err != nil {
		return out, err
	}
	byLogin := map[string][]control.EntryRoute{}
	for _, h := range homes {
		if !isUserPodName(h.Machine) {
			continue
		}
		if s.isFleetAdmin(h.Login) || !control.ValidExistingLogin(h.Login) {
			continue
		}
		byLogin[h.Login] = append(byLogin[h.Login], control.EntryRoute{
			Login: h.Login, Principal: h.Person, Service: strings.ToLower(firstLabel(h.Machine))})
	}
	logins := make([]string, 0, len(byLogin))
	for l := range byLogin {
		logins = append(logins, l)
	}
	sort.Strings(logins)
	for _, l := range logins {
		rs := byLogin[l]
		if len(rs) > 1 {
			var who []string
			for _, r := range rs {
				who = append(who, r.Principal+"→"+r.Service)
			}
			log.Printf("door: login %s is home to %s; routing none of them", l, strings.Join(who, ", "))
			continue
		}
		r := rs[0]
		keys, err := s.Store.EntryKeys(r.Principal, false)
		if err != nil {
			return out, err
		}
		nl := control.EntryNodeLogin{Person: r.Principal, Keys: []control.EntryNodeKey{}}
		for _, k := range keys {
			nl.Keys = append(nl.Keys, control.EntryNodeKey{FP: k.FP, Type: k.Type, B64: k.B64, Name: k.Name})
		}
		out.Routes = append(out.Routes, r)
		out.Logins[l] = nl
	}
	return out, nil
}
