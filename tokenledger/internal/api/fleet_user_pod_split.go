package api

import (
	"fmt"
	"log"
	"regexp"
	"sort"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

// One person's second pod (claude-fleet#3562, EPIC #3500 R1).
//
// A pod's ceiling only goes so far, and two big repos in one pod slow each
// other down. The hub setting fleet.user_pod_split.<principal> = owner/name,…
// gives that person a SECOND pod in the cluster where they already have one:
//
//   - Made: once their first pod's login is ready, a pod of their own under
//     the same principal and the same login, a new u-<nonce> (the pool's
//     「现开」 road, CreateClusterPodSplit), its row's split = the list. One
//     second pod per person per cluster; a changed list moves the row's, an
//     emptied setting makes nothing go — removing the pod is the operator's
//     (fleet hub accounts remove … --host u-<nonce>), as for any pod.
//   - Placement: a start for a listed repo lands on the second pod when it can
//     take it (else where it always would — never refused for this); the
//     second pod takes nothing else on auto. Naming the pod still asks it.
//   - The door: each listed repo is one more name, <login>.<repo>, routed to
//     the second pod and logged in there as <login> (EntryRoute.PodLogin).
//     The person's own name stays their first pod.
//   - The list: both pods are the same person's accounts, so the panel and
//     every list already show both (scopeFor) — nothing to add.
//
// No such setting and no split row — byte for byte as before
// (TestUserPodSplitOffAddsNothing).

// UserPodSplitPrefix keys a person's second-pod repo list.
const UserPodSplitPrefix = "fleet.user_pod_split."

// userPodSplitMax bounds one list: a pod for a few big repos, not a fleet.
const userPodSplitMax = 8

var splitRepoRE = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_.-]{0,38}/[A-Za-z0-9_.-]{1,100}$`)

// ParseUserPodSplit checks a list (owner/name, comma-separated) and spells it
// back: trimmed, each repo once (GitHub's names are case-blind), in its order.
func ParseUserPodSplit(text string) (string, error) {
	var out []string
	seen := map[string]bool{}
	for _, r := range strings.Split(text, ",") {
		r = strings.TrimSpace(r)
		if r == "" {
			continue
		}
		if !splitRepoRE.MatchString(r) || strings.Contains(r, "..") {
			return "", fmt.Errorf("%s<principal>: %q is not owner/name", UserPodSplitPrefix, r)
		}
		if k := strings.ToLower(r); !seen[k] {
			seen[k] = true
			out = append(out, r)
		}
	}
	if len(out) == 0 {
		return "", fmt.Errorf("%s<principal> is repos (owner/name), comma-separated, or \"\" for none", UserPodSplitPrefix)
	}
	if len(out) > userPodSplitMax {
		return "", fmt.Errorf("%s<principal>: at most %d repos (%d given)", UserPodSplitPrefix, userPodSplitMax, len(out))
	}
	return strings.Join(out, ","), nil
}

// splitList is a stored list's repos.
func splitList(v string) []string {
	var out []string
	for _, r := range strings.Split(v, ",") {
		if r = strings.TrimSpace(r); r != "" {
			out = append(out, r)
		}
	}
	return out
}

// splitTakes says a second pod whose list is split takes repo (any spelling
// repoNamed accepts: owner/name, slug, bare name).
func splitTakes(split, repo string) bool {
	if repo == "" {
		return false
	}
	for _, r := range splitList(split) {
		if repoNamed(r, repo) || strings.EqualFold(r, repo) {
			return true
		}
	}
	return false
}

// splitPods is every second pod still standing, by its lower-cased name.
// Empty (and no error) on a hub that never made one.
func (s *Server) splitPods() map[string]store.ClusterPod {
	out := map[string]store.ClusterPod{}
	if s.Store == nil || !s.Fleet {
		return out
	}
	pods, err := s.Store.ClusterPods("")
	if err != nil {
		log.Printf("fleet: second pods: %v", err)
		return out
	}
	for _, p := range pods {
		if p.Split != "" && p.Held() {
			out[strings.ToLower(p.Pod)] = p
		}
	}
	return out
}

// ensureSplitPods starts the second pod of every person whose setting asks
// for one in cluster and who has none, and moves a standing one's list to the
// setting's. Runs under spareMu from replenishClusterSpares; reports whether
// it queued a pod.
func (s *Server) ensureSplitPods(cluster string, pic *clusterPodPicture, settings map[string]string, now time.Time) bool {
	queued := false
	used := pic.used
	keys := make([]string, 0)
	for k := range settings {
		if strings.HasPrefix(k, UserPodSplitPrefix) {
			keys = append(keys, k)
		}
	}
	sort.Strings(keys)
	for _, k := range keys {
		principal := k[len(UserPodSplitPrefix):]
		want, err := ParseUserPodSplit(settings[k])
		if err != nil || principal == "" || store.IsSparePrincipal(principal) {
			continue
		}
		var first, second *store.ClusterPod
		failed := false
		for i := range pic.all {
			p := &pic.all[i]
			if !strings.EqualFold(p.PrincipalID, principal) {
				continue
			}
			switch {
			case p.Split == "" && p.Held():
				first = p
			case p.Split != "" && p.Held():
				second = p
			case p.Split != "" && p.State == store.PodFailed:
				if a := pic.acct[p.Pod]; a != nil && a.State == store.AccountFailed {
					failed = true // the operator looks at why first (fleet hub accounts)
				}
			}
		}
		if second != nil {
			if second.Split != want {
				if err := s.Store.SetClusterPodSplit(second.Pod, want, now); err != nil {
					log.Printf("fleet: %s's second pod %s: %v", principal, second.Pod, err)
				} else {
					log.Printf("fleet: %s's second pod %s now takes %s", principal, second.Pod, want)
				}
			}
			continue
		}
		if first == nil || failed {
			continue
		}
		a := pic.acct[first.Pod]
		if a == nil || a.State != store.AccountActive || a.Login == "" {
			continue // their first pod is not ready yet: the second waits for it
		}
		if used >= nodeUserCap(cluster, settings) {
			log.Printf("fleet: %s's second pod on %s: the cluster holds its cap of people's pods (%d)", principal, cluster, used)
			continue
		}
		na, err := s.Store.CreateClusterPodSplit(cluster, &store.Principal{ID: a.PrincipalID}, a.Login, want, now)
		if err != nil {
			log.Printf("fleet: %s's second pod on %s: %v", principal, cluster, err)
			continue
		}
		used++
		queued = true
		log.Printf("fleet: %s: starting their second pod %s (%s) on %s for %s", principal, na.Hostname, na.Login, cluster, want)
		go s.startOwnClusterPod(cluster, *na, a.PrincipalID)
	}
	return queued
}

// splitDoorName is the door's name for repo on login's second pod:
// <login>.<repo's name>, the name lower-cased to a-z 0-9 -, the whole within
// a Linux login's 32. "" when nothing of the name is left.
func splitDoorName(login, repo string) string {
	name := repo
	if i := strings.LastIndex(name, "/"); i >= 0 {
		name = name[i+1:]
	}
	var b strings.Builder
	for _, c := range strings.ToLower(name) {
		switch {
		case c >= 'a' && c <= 'z', c >= '0' && c <= '9':
			b.WriteRune(c)
		case c == '-' || c == '_' || c == '.':
			b.WriteByte('-')
		}
	}
	n := strings.Trim(b.String(), "-")
	room := 32 - len(login) - 1
	if room < 1 || n == "" {
		return ""
	}
	if len(n) > room {
		n = strings.TrimRight(n[:room], "-")
	}
	if n == "" {
		return ""
	}
	return login + "." + n
}

// splitRoutes are the door's rows for every live second pod: one per listed
// repo, <login>.<repo> → the pod, logged in there as login. Keyed by the
// door's name, so a name two rows (or a first pod's login) claim routes none.
func (s *Server) splitRoutes() map[string][]control.EntryRoute {
	out := map[string][]control.EntryRoute{}
	pods := s.splitPods()
	if len(pods) == 0 {
		return out
	}
	accts, err := s.Store.FleetAccounts("")
	if err != nil {
		log.Printf("door: second pods: %v", err)
		return out
	}
	for _, a := range accts {
		p, ok := pods[strings.ToLower(a.Hostname)]
		if !ok || p.State != store.PodLive || a.State != store.AccountActive ||
			!strings.EqualFold(a.PrincipalID, p.PrincipalID) || s.isFleetAdmin(a.Login) || !control.ValidExistingLogin(a.Login) {
			continue
		}
		for _, r := range splitList(p.Split) {
			n := splitDoorName(a.Login, r)
			if n == "" {
				continue
			}
			out[n] = append(out[n], control.EntryRoute{Login: n, Principal: a.PrincipalID,
				Service: strings.ToLower(p.Pod), PodLogin: a.Login})
		}
	}
	return out
}
