package api

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/release"
)

// A person's pod rolls to the new image (claude-fleet#4174).
//
// A person's pod runs the IMAGE's runtime (FLEET_NODE_UPDATE_OWNER=image): it
// runs no update task, so a fix that lands in a release reaches only the pods
// made after it — #4172 was a pod still carrying the egress bug #4116 fixed.
// So once stable moves, the hub rolls the pods still on an older runtime:
//
//   - Which: every pod fleet_cluster_pods holds in a cluster fleet.clusters
//     names whose ops link this replica holds, whose machine beat last named a
//     runtime (Versions.Runtime) other than stable's — a pod that never said
//     is never guessed at.
//   - How: one roll-user-pod ticket each; the provisioner patches the pod's
//     Deployment onto its template's user_pod.image (the image is the
//     cluster's word, never the hub's), Recreate, and the sessions come back
//     through restore. A pod already on that image is answered «already on»,
//     nothing sent.
//   - Pace: at most fleet.user_pod_roll_batch pods (default 2) every
//     podRollEvery (10 min), one after the other — never the whole cluster at
//     once — and a pod with a session working or asking a person (somebody
//     typing there) waits for the next batch.
//   - Once per release: a pod is asked once per stable sha; a failed roll is
//     asked again after podRollRetry, and it holds back nobody else's.
//
// fleet.user_pod_roll off, no account key, no clusters, no ops link or no
// stable ⇒ nothing is sent (TestUserPodRollOffAddsNothing). The node page
// shows each pod's runtime, how many releases behind stable it is and its
// last roll (podRollView).

const (
	UserPodRollKey      = "fleet.user_pod_roll"
	UserPodRollBatchKey = "fleet.user_pod_roll_batch"
	// UserPodRollWindowKey (task APVZ): "HH-HH", UTC hours a roll may start in
	// (09-14 = 02:00–07:00 PDT, nobody at work), across midnight when the first is
	// later ("22-05"); "" = any time, as before.
	UserPodRollWindowKey = "fleet.user_pod_roll_window"
)

// parseRollWindow is "HH-HH" → (from, to) hours, ok false when malformed.
func parseRollWindow(v string) (int, int, bool) {
	a, b, found := strings.Cut(strings.TrimSpace(v), "-")
	if !found {
		return 0, 0, false
	}
	from, err1 := strconv.Atoi(strings.TrimSpace(a))
	to, err2 := strconv.Atoi(strings.TrimSpace(b))
	if err1 != nil || err2 != nil || from < 0 || from > 23 || to < 0 || to > 24 || from == to {
		return 0, 0, false
	}
	return from, to, true
}

// inRollWindow says whether now (UTC) is inside window; "" or malformed = yes.
func inRollWindow(window string, now time.Time) bool {
	from, to, ok := parseRollWindow(window)
	if !ok {
		return true
	}
	h := now.UTC().Hour()
	if from < to {
		return h >= from && h < to
	}
	return h >= from || h < to
}

func checkRollWindow(_ *Server, v string) (string, string) {
	if strings.TrimSpace(v) == "" {
		return "", ""
	}
	from, to, ok := parseRollWindow(v)
	if !ok {
		return "", UserPodRollWindowKey + " is \"HH-HH\" in UTC hours (e.g. 09-14), or \"\" for any time"
	}
	return fmt.Sprintf("%02d-%02d", from, to), ""
}

// podRollEvery spaces two batches; podRollRetry is how long a failed roll
// waits before it is asked again; podRuntimeFresh is how old a runtime
// reading may be and still be acted on. Variables so tests can move them.
var (
	podRollEvery    = 10 * time.Minute
	podRollRetry    = time.Hour
	podRuntimeFresh = time.Hour
)

// podRuntime is the runtime a pod's machine beat last named.
type podRuntime struct {
	SHA string
	At  time.Time
}

// podRollTry is the last roll asked of a pod.
type podRollTry struct {
	Stable  string    `json:"stable"`
	At      time.Time `json:"at"`
	Done    bool      `json:"done"` // answered (rc 0)
	Pending bool      `json:"pending,omitempty"`
	Result  string    `json:"result,omitempty"`
}

// podRollBook is the hub's memory of the rolls it asked. In memory only: after
// a restart a pod asked again for the same release is answered «already on».
// The runtimes are the roster's (every replica's beats, through the store).
type podRollBook struct {
	mu      sync.Mutex
	tried   map[string]podRollTry
	last    time.Time
	running atomic.Bool
}

func podKey(host string) string { return strings.ToLower(firstLabel(strings.TrimSpace(host))) }

// podRuntimes is every person pod's runtime as its machine link last read it
// (the roster: whichever replica the pod's beats reach).
func (s *Server) podRuntimes(now time.Time) map[string]podRuntime {
	if s.podRollRuntimes != nil {
		return s.podRollRuntimes(now)
	}
	snap, err := s.Nodes(now)
	if err != nil {
		log.Printf("fleet: pod roll: roster: %v", err)
		return nil
	}
	out := map[string]podRuntime{}
	for _, m := range snap.Machines {
		if !isUserPodName(m.Hostname) || m.Versions == nil || !release.ValidSHA(m.Versions.Runtime) {
			continue
		}
		at := m.VersionsAt
		if at == nil {
			at = m.LastHeartbeat
		}
		if at == nil {
			continue
		}
		out[podKey(m.Hostname)] = podRuntime{SHA: m.Versions.Runtime, At: *at}
	}
	return out
}

func (s *Server) podRollStableSHA() string {
	if s.podRollStable != nil {
		return s.podRollStable()
	}
	if s.Releases == nil {
		return ""
	}
	return s.Releases.StableSHA()
}

func (s *Server) podRollBatch() int {
	if n, err := strconv.Atoi(strings.TrimSpace(s.setting(UserPodRollBatchKey))); err == nil && n >= 1 && n <= 20 {
		return n
	}
	return 2
}

// podBusyStates: a session in one of these is somebody's turn in flight or a
// question waiting on a person — a roll there would cut it.
func podBusy(state string) bool {
	return state == "working" || state == "waiting" || state == "blocked" || strings.HasPrefix(state, "needs")
}

// busyPods names the pods with a session working or asking right now.
func (s *Server) busyPods() map[string]bool {
	out := map[string]bool{}
	rows, err := s.Store.Fleets()
	if err != nil {
		log.Printf("fleet: pod roll: fleets: %v", err)
		return nil // unknown: nobody is rolled
	}
	for _, r := range rows {
		if !r.Present || !isUserPodName(r.Hostname) {
			continue
		}
		var ws []struct {
			State string `json:"state"`
		}
		_ = json.Unmarshal([]byte(r.WorkersJSON), &ws)
		for _, w := range ws {
			if podBusy(w.State) {
				out[podKey(r.Hostname)] = true
			}
		}
	}
	return out
}

// podRollCandidate is one pod to roll.
type podRollCandidate struct{ cluster, pod, from string }

// PodRollTick is one pass at now: picks this batch and rolls it, one pod at a
// time (each a ticket through the cluster's ops link). force skips the pacing
// (tests). It returns the pods it asked.
func (s *Server) PodRollTick(now time.Time, force bool) []string {
	if !s.Fleet || s.Store == nil || s.accountKey == nil || s.setting(UserPodRollKey) == "off" {
		return nil
	}
	if !inRollWindow(s.setting(UserPodRollWindowKey), now) {
		return nil
	}
	stable := s.podRollStableSHA()
	if !release.ValidSHA(stable) {
		return nil
	}
	b := &s.podRoll
	if !b.running.CompareAndSwap(false, true) {
		return nil
	}
	defer b.running.Store(false)
	b.mu.Lock()
	if !force && now.Sub(b.last) < podRollEvery {
		b.mu.Unlock()
		return nil
	}
	b.mu.Unlock()

	var picked []podRollCandidate
	var busy, runtimes = map[string]bool(nil), map[string]podRuntime(nil)
	for _, cluster := range s.clusters() {
		if _, c := s.nodes.opsFor(cluster); c == nil {
			continue
		}
		pods, err := s.Store.ClusterPods(cluster)
		if err != nil {
			log.Printf("fleet: pod roll: %s: %v", cluster, err)
			continue
		}
		for _, p := range pods {
			if !p.Held() {
				continue
			}
			if runtimes == nil {
				if runtimes = s.podRuntimes(now); runtimes == nil {
					return nil
				}
			}
			b.mu.Lock()
			rt, tried := runtimes[p.Pod], b.tried[p.Pod]
			b.mu.Unlock()
			if rt.SHA == "" || rt.SHA == stable || now.Sub(rt.At) > podRuntimeFresh {
				continue
			}
			if tried.Stable == stable && (tried.Done || tried.Pending || now.Sub(tried.At) < podRollRetry) {
				continue
			}
			if busy == nil {
				if busy = s.busyPods(); busy == nil {
					return nil
				}
			}
			if busy[p.Pod] {
				continue
			}
			picked = append(picked, podRollCandidate{cluster: cluster, pod: p.Pod, from: rt.SHA})
		}
	}
	if len(picked) == 0 {
		return nil
	}
	sort.SliceStable(picked, func(i, j int) bool { return picked[i].pod < picked[j].pod })
	if n := s.podRollBatch(); len(picked) > n {
		picked = picked[:n]
	}
	b.mu.Lock()
	b.last = now
	if b.tried == nil {
		b.tried = map[string]podRollTry{}
	}
	for _, c := range picked {
		b.tried[c.pod] = podRollTry{Stable: stable, At: now, Pending: true}
	}
	b.mu.Unlock()

	var asked []string
	for _, c := range picked {
		res, err := s.clusterOp(context.Background(), c.cluster, control.ClusterTicket{Op: control.ClusterRollUserPod, Pod: c.pod})
		try := podRollTry{Stable: stable, At: now, Done: err == nil && res.RC == 0, Result: res.Line}
		if !try.Done {
			try.Result = clusterOpWhy(res, err)
		}
		b.mu.Lock()
		b.tried[c.pod] = try
		b.mu.Unlock()
		log.Printf("fleet: pod roll %s (%s, runtime %s → stable %s): %s", c.pod, c.cluster, short(c.from), short(stable), try.Result)
		asked = append(asked, c.pod)
	}
	return asked
}

// podRollView is what the node page shows of a person's pod's image.
type podRollView struct {
	Stable string `json:"stable,omitempty"`
	// Behind is how many releases stable is past the pod's runtime: 0 = on
	// stable, -1 = its runtime is no release the ledger knows.
	Behind *int        `json:"behind,omitempty"`
	Last   *podRollTry `json:"last,omitempty"`
}

// podRollFor is host's podRollView, or nil for a machine that is not a pod.
func (s *Server) podRollFor(host, runtime string, now time.Time) *podRollView {
	if !isUserPodName(host) {
		return nil
	}
	v := &podRollView{Stable: s.podRollStableSHA()}
	b := &s.podRoll
	b.mu.Lock()
	if t, ok := b.tried[podKey(host)]; ok {
		v.Last = &t
	}
	b.mu.Unlock()
	if n, ok := s.releasesBehind(runtime, v.Stable, now); ok {
		v.Behind = &n
	}
	return v
}

// releasesBehind counts the trains published after runtime's, up to and
// including stable's; -1 when runtime is no train the ledger has. ok false
// when there is nothing to say (no runtime, no stable, no ledger).
func (s *Server) releasesBehind(runtime, stable string, now time.Time) (int, bool) {
	if !release.ValidSHA(runtime) || !release.ValidSHA(stable) || s.Store == nil {
		return 0, false
	}
	if runtime == stable {
		return 0, true
	}
	trains, err := s.Store.ReleaseTrainsSince(now.Add(-trainStatsMaxDays * 24 * time.Hour))
	if err != nil || len(trains) == 0 {
		return 0, false
	}
	from, to := -1, -1
	for i, t := range trains {
		if t.SHA == runtime {
			from = i
		}
		if t.SHA == stable {
			to = i
		}
	}
	if from < 0 || to < 0 {
		return -1, true
	}
	if to <= from {
		return 0, true
	}
	return to - from, true
}
