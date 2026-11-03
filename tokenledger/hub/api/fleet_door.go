package api

import (
	"fmt"
	"log"
	"net/http"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
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

// DoorClusterPrefix + <door> names the cluster a door stands in (task P0D4):
// a door reaches the pods of its own cluster only (it dials
// u-<nonce>.<ns>.svc.cluster.local), so a pod goes through a door of the
// cluster its fleet_cluster_pods row says it is in. The operator's word on
// the hub, never the door's own: the door is the one part facing the
// internet, and must not choose whom it lets in. No door named with a
// cluster ⇒ every pod through every door, byte for byte as before.
const DoorClusterPrefix = "fleet.door_cluster."

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

// doorSettings is the settings table for the door's per-cluster reading;
// nil when it cannot be read (every door then reads as no cluster said).
func (s *Server) doorSettings() map[string]string {
	if s.Store == nil {
		return nil
	}
	settings, err := s.Store.FleetSettings()
	if err != nil {
		return nil
	}
	return settings
}

// doorClusterOf is the cluster fleet.door_cluster.<door> names, "" = none.
func doorClusterOf(settings map[string]string, door string) string {
	return strings.ToLower(strings.TrimSpace(settings[DoorClusterPrefix+strings.ToLower(firstLabel(door))]))
}

// podDoors is the doors that may carry pod, in fleet.door's order: its own
// cluster's doors when some door names that cluster, else every door (the
// old rule) — why says why it fell back, "" when no door names a cluster at
// all (byte for byte as before) or the pod has its cluster's doors.
func (s *Server) podDoors(settings map[string]string, doors []string, pod string) (out []string, cluster, why string) {
	labeled := false
	for _, d := range doors {
		if doorClusterOf(settings, d) != "" {
			labeled = true
			break
		}
	}
	if !labeled {
		return doors, "", ""
	}
	cluster = s.podCluster(settings, pod)
	if cluster == "" {
		return doors, "", "its cluster is not known (no fleet_cluster_pods row): any door"
	}
	for _, d := range doors {
		if doorClusterOf(settings, d) == cluster {
			out = append(out, d)
		}
	}
	if len(out) == 0 {
		return doors, cluster, "no door names cluster " + cluster + " (" + DoorClusterPrefix + "<door>): any door"
	}
	return out, cluster, ""
}

// doorPickWhy is the last reason logged per pod (noteDoorPick).
var doorPickWhy sync.Map

// noteDoorPick logs why pod's door is not a reachable door of its own
// cluster — once per pod until the reason changes.
func noteDoorPick(pod, door, why string) {
	if prev, loaded := doorPickWhy.Swap(pod, why); (loaded && prev == why) || (!loaded && why == "") {
		return
	}
	if why == "" {
		log.Printf("door: %s through %s, a reachable door of its own cluster", pod, door)
		return
	}
	log.Printf("door: %s through %s: %s", pod, door, why)
}

// entryAddrMachine is the machine whose address a home is reached at: a
// person's pod is reached through a door of its own cluster (podDoors; the
// first one the outside can reach, else the first named); any other home is
// its own.
func (s *Server) entryAddrMachine(machine string, now time.Time) string {
	if !isUserPodName(machine) {
		return machine
	}
	doors := s.doorMachines()
	if len(doors) == 0 {
		return machine
	}
	doors, cluster, why := s.podDoors(s.doorSettings(), doors, machine)
	for _, d := range doors {
		if reach, err := s.EntryReachable(d, now); err == nil && len(reach) > 0 {
			if cluster != "" || why != "" {
				noteDoorPick(machine, d, why)
			}
			return d
		}
	}
	if cluster != "" && why == "" {
		// another cluster's door cannot reach it: its own, though down for now
		why = "no door of cluster " + cluster + " is reachable from outside lately: its first named"
	}
	if why != "" {
		noteDoorPick(machine, doors[0], why)
	}
	return doors[0]
}

// podBehindDoor says whether machine is a person's pod reached through this
// hub's door. Such a pod's sshd takes the door's key alone and listens on the
// pod's own port, so the relay through the hub (which dials the agent's
// loopback :22) can never reach it: the route list offers the door's `entry`
// route and no relay (claude-fleet#3985).
func (s *Server) podBehindDoor(machine string) bool {
	return isUserPodName(machine) && len(s.doorMachines()) > 0
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
	// its pull is the one beat every door has: keep its reach fresh (#4149)
	s.doorReachKeep(host, time.Now())
	s.noteJump(r, host, true, time.Now())
	out, err := s.entryRouteListFor(host)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	// the way home (A5SQ): only to a door that says it carries it
	if s.noteDoorHome(r, host, time.Now()) {
		if out.Homes, err = s.doorHomeRoutes(); err != nil {
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
	}
	writeJSON(w, http.StatusOK, out)
}

// entryRouteList is the doors' table: every person whose home is a pod —
// never a fleet admin's login. A login two pods claim goes to NEITHER (the
// door must never guess whose pod a name is): the table drops it and says so.
func (s *Server) entryRouteList() (control.EntryRouteList, error) {
	return s.entryRouteListFor("")
}

// entryRouteListFor is door's own table (task P0D4): entryRouteList's routes
// whose pod podDoors may send through door — never another cluster's pod.
// door "" (or no door naming a cluster) = every route.
func (s *Server) entryRouteListFor(door string) (control.EntryRouteList, error) {
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
	// A person's second pod (claude-fleet#3562): <login>.<repo> beside their
	// own name — a name both claim routes neither.
	for n, rs := range s.splitRoutes() {
		byLogin[n] = append(byLogin[n], rs...)
	}
	logins := make([]string, 0, len(byLogin))
	for l := range byLogin {
		logins = append(logins, l)
	}
	sort.Strings(logins)
	var settings map[string]string
	var doors []string
	if door != "" {
		settings, doors = s.doorSettings(), s.doorMachines()
	}
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
		if door != "" && !s.doorCarries(settings, doors, door, r.Service) {
			continue
		}
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

// doorCarries says door is one podDoors may send pod through.
func (s *Server) doorCarries(settings map[string]string, doors []string, door, pod string) bool {
	may, _, _ := s.podDoors(settings, doors, pod)
	for _, d := range may {
		if sameMachine(door, d) || sameMachine(d, door) {
			return true
		}
	}
	return false
}
