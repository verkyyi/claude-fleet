package api

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// A cluster's spare pods (claude-fleet#3553, EPIC #3500 C8).
//
// In a cluster a newcomer is handed a whole pod: one person's, started ahead
// of time, its login opened and checked, so their first sign-in only binds it
// to them — a database write and two pushes, not a pod start. A cluster is one
// place to keep spares in, like a machine (fleet_spare.go):
//
//   - Which: the clusters fleet.clusters names, each reached through its ops
//     link (fleet-ops, a node whose hello lists control.CapClusterOps and whose
//     hostname is the cluster's name). Nothing else ever gets a ticket.
//   - How many: fleet.spare_max.<cluster>, else fleet.spare_max (default 2),
//     never more than fleet.node_user_cap.<cluster> (default 10) − the pods
//     already people's.
//   - Refill: a spare pod is three records (spare:<cluster>:<nonce> · its
//     login fleetu<N> pending on u-<nonce> · the pod row) and one signed
//     create-user-pod ticket carrying the pod's one-time machine join code,
//     which the provisioner writes into the pod's join Secret. The pod's own
//     node joins with it and is sent the login's create like any machine's;
//     ready = that create came back credential-separated (applyAccountResult
//     fails a spare that did not). A pod not ready within clusterPodJoinWait,
//     or failed, is destroyed, its row left failed until the operator forgets
//     it — and its cluster gets no more until then.
//   - Claim: the first move of placement and of the operator's assign naming
//     the cluster, for a person holding no pod there: the oldest ready one is
//     theirs (the machine spare's own claim, store.ClaimSpare/ClaimSpareFor,
//     audited spare.claim), its pod row says so, it becomes their 家 (so the
//     door's table and their name in DNS follow at once), and a bind-user-pod
//     ticket writes the pod's fleet/principal label (+ set-limits when they
//     have a ceiling of their own). No ready pod: a pod of their own is
//     started — the pool's 「现开」, slower, never refused.
//   - Remove: never a wash (共同约定 5). The hub takes its own half of the
//     person off first (recycleClear: node tokens, passes, relay credential,
//     leases, 家, join codes), then a destroy-user-pod ticket deletes the
//     Deployment, Service, PVC and join Secret; the login is removed, the pod
//     row gone, spare.destroy audited, and the pool refilled with a NEW pod.
//
// Off — spares off, no fleet.clusters, no account key (the tickets' signer),
// or no ops link up — nothing is created, claimed or sent, and every answer is
// byte for byte what it was (TestSparePodsOffAddsNothing). A pod the hub
// already made is still destroyed by its remove while the key and the link are
// there.

// The cluster settings' keys.
const (
	ClustersKey    = "fleet.clusters"
	SpareMaxPrefix = "fleet.spare_max."
)

// clusterPodJoinWait is how long a spare pod may take from its create ticket
// to a ready login. A variable so tests can move it.
var clusterPodJoinWait = 15 * time.Minute

// clusterOpWait bounds one ticket's round trip through the ops link
// (the agent's own POST is clusterOpTimeout, 60s).
var clusterOpWait = 75 * time.Second

// clusterNameRE is the provisioner ticket's cluster grammar
// (bin/fleet_cluster_ticket.py GRAMMAR).
var clusterNameRE = regexp.MustCompile(`^[a-z0-9][a-z0-9.-]{0,62}$`)

func checkClusters(_ *Server, v string) (string, string) {
	var out []string
	for _, c := range strings.Split(v, ",") {
		c = strings.ToLower(strings.TrimSpace(c))
		if c == "" {
			continue
		}
		if !clusterNameRE.MatchString(c) || isUserPodName(c) {
			return "", fmt.Sprintf("%s: %q is not a cluster name (a-z 0-9 . -, the name its fleet-ops reports)", ClustersKey, c)
		}
		out = append(out, c)
	}
	if len(out) == 0 {
		return "", ClustersKey + " is cluster names, comma-separated, or \"\" for none"
	}
	return strings.Join(out, ","), ""
}

// clusters is fleet.clusters, lower-cased.
func (s *Server) clusters() []string {
	var out []string
	for _, c := range strings.Split(s.setting(ClustersKey), ",") {
		if c = strings.ToLower(strings.TrimSpace(c)); c != "" {
			out = append(out, c)
		}
	}
	return out
}

// isCluster says host is a cluster fleet.clusters names.
func (s *Server) isCluster(host string) bool {
	for _, c := range s.clusters() {
		if strings.EqualFold(c, strings.TrimSpace(host)) {
			return true
		}
	}
	return false
}

// clusterPoolOn says spare pods may be made and claimed at all.
func (s *Server) clusterPoolOn() bool {
	return s.Fleet && s.Store != nil && s.sparesOn() && s.accountKey != nil && len(s.clusters()) > 0
}

// clusterSpareMax is fleet.spare_max.<cluster>, else fleet.spare_max.
func (s *Server) clusterSpareMax(cluster string, settings map[string]string) int {
	if v, ok := settings[SpareMaxPrefix+cluster]; ok {
		if n, err := strconv.Atoi(strings.TrimSpace(v)); err == nil && n >= 0 {
			if n > spareMaxCeiling {
				n = spareMaxCeiling
			}
			return n
		}
	}
	return s.spareMax()
}

// errNoOpsLink: the cluster's fleet-ops is not connected to this replica.
var errNoOpsLink = errors.New("the cluster's ops link is not connected")

// clusterOp signs t for cluster and carries it down the cluster's ops link,
// returning the provisioner's answer. A fresh nonce every call (a re-ask is a
// new ticket) unless t brings one — a Job is named after its nonce, so its
// caller mints it first (claude-fleet#3552).
func (s *Server) clusterOp(ctx context.Context, cluster string, t control.ClusterTicket) (control.ClusterOpResult, error) {
	var res control.ClusterOpResult
	_, c := s.nodes.opsFor(cluster)
	if c == nil {
		return res, errNoOpsLink
	}
	if t.Nonce == "" {
		var nb [16]byte
		if _, err := rand.Read(nb[:]); err != nil {
			return res, err
		}
		t.Nonce = hex.EncodeToString(nb[:])
	}
	t.Cluster, t.Exp = cluster, time.Now().Add(control.ClusterTicketTTL).Unix()
	tk, err := control.SignClusterTicket(s.accountKey, t)
	if err != nil {
		return res, err
	}
	msg, err := control.New(control.TypeClusterOp, control.ClusterOp{Ticket: tk})
	if err != nil {
		return res, err
	}
	ch := c.pending.add(msg.OpID)
	defer c.pending.remove(msg.OpID)
	ctx, cancel := context.WithTimeout(ctx, clusterOpWait)
	defer cancel()
	if err := c.wire.write(ctx, msg); err != nil {
		return res, fmt.Errorf("write to %s's ops link: %w", cluster, err)
	}
	select {
	case <-ctx.Done():
		return res, fmt.Errorf("%s's ops link did not answer %s %s within %s", cluster, t.Op, t.Pod, clusterOpWait)
	case reply := <-ch:
		if reply.Type == control.TypeError {
			why := "refused"
			if reply.Error != nil {
				why = reply.Error.Code + ": " + reply.Error.Message
			}
			return res, fmt.Errorf("%s's ops link refused %s: %s", cluster, t.Op, why)
		}
		if err := json.Unmarshal(reply.Payload, &res); err != nil {
			return res, fmt.Errorf("%s's ops link answered %s with a malformed result", cluster, t.Op)
		}
		if res.Error != "" {
			return res, fmt.Errorf("%s's provisioner unreachable: %s", cluster, res.Error)
		}
		return res, nil
	}
}

// clusterPodPicture is one cluster's pods, split.
type clusterPodPicture struct {
	cluster string
	all     []store.ClusterPod             // every pod the hub made there
	used    int                            // pods held by people
	spares  []store.ClusterPod             // spare pods still standing
	ready   []store.ClusterPod             // …of which the login is ready
	failed  bool                           // a spare that failed and is not forgotten
	acct    map[string]*store.FleetAccount // pod → its account row
}

func (s *Server) clusterPicture(cluster string) (*clusterPodPicture, error) {
	pods, err := s.Store.ClusterPods(cluster)
	if err != nil {
		return nil, err
	}
	all, err := s.Store.FleetAccounts("")
	if err != nil {
		return nil, err
	}
	pic := &clusterPodPicture{cluster: cluster, all: pods, acct: map[string]*store.FleetAccount{}}
	for i := range all {
		if isUserPodName(all[i].Hostname) {
			pic.acct[strings.ToLower(all[i].Hostname)] = &all[i]
		}
	}
	for _, p := range pods {
		a := pic.acct[p.Pod]
		spare := store.IsSparePrincipal(p.PrincipalID)
		if spare && a != nil && a.State == store.AccountFailed {
			pic.failed = true
		}
		if !p.Held() {
			continue
		}
		if !spare {
			pic.used++
			continue
		}
		if a != nil && (a.State == store.AccountFailed || leaving(a.State)) {
			continue
		}
		pic.spares = append(pic.spares, p)
		if a != nil && a.State == store.AccountActive {
			pic.ready = append(pic.ready, p)
		}
	}
	// The oldest ready first: the order a claim takes them in.
	sort.SliceStable(pic.ready, func(i, j int) bool {
		return pic.acct[pic.ready[i].Pod].UpdatedAt.Before(pic.acct[pic.ready[j].Pod].UpdatedAt)
	})
	return pic, nil
}

// replenishClusterSpares brings every cluster to its spare count; runs under
// spareMu from replenishSpares. It reports whether anything was queued.
func (s *Server) replenishClusterSpares(now time.Time) bool {
	if !s.clusterPoolOn() {
		return false
	}
	settings, err := s.Store.FleetSettings()
	if err != nil {
		log.Printf("fleet: spare pods: %v", err)
		return false
	}
	queued := false
	for _, cluster := range s.clusters() {
		if _, c := s.nodes.opsFor(cluster); c == nil {
			continue
		}
		pic, err := s.clusterPicture(cluster)
		if err != nil {
			log.Printf("fleet: spare pods of %s: %v", cluster, err)
			continue
		}
		// A spare that never got ready, or failed: its pod goes.
		for _, p := range pic.all {
			a := pic.acct[p.Pod]
			switch {
			case a == nil:
			case !store.IsSparePrincipal(p.PrincipalID):
			case a.State == store.AccountFailed && p.State == store.PodLive:
				s.failSparePod(cluster, p, a, "its login failed: "+a.Detail, now)
				queued = true
			case (a.State == store.AccountPending || a.State == store.AccountCreating || a.State == store.AccountUnknown) &&
				p.Held() && now.Sub(p.CreatedAt) > clusterPodJoinWait:
				s.failSparePod(cluster, p, a, fmt.Sprintf("not ready in %s (its login is %s)", clusterPodJoinWait, a.State), now)
				pic.failed = true
				queued = true
			}
		}
		target := nodeUserCap(cluster, settings) - pic.used
		if m := s.clusterSpareMax(cluster, settings); target > m {
			target = m
		}
		if target < 0 {
			target = 0
		}
		// Over: the newest ready spares go (a pod still on its way up is
		// left to finish — its pod already stands).
		over := len(pic.spares) - target
		for i := len(pic.ready) - 1; i >= 0 && over > 0; i-- {
			p := pic.ready[i]
			if err := s.Store.RequestAccountRemoval(p.PrincipalID, p.Pod, now); err != nil {
				log.Printf("fleet: spare pods: shrink %s: %v", p.Pod, err)
				continue
			}
			log.Printf("fleet: spare pods: %s on %s is one over (%d held, %d wanted) — destroying it", p.Pod, cluster, len(pic.spares), target)
			over--
			queued = true
		}
		if pic.failed {
			continue // the operator looks at why first (fleet hub accounts)
		}
		for n := len(pic.spares); n < target; n++ {
			a, err := s.Store.CreateClusterSpare(cluster, control.ValidLogin, now)
			if err != nil {
				log.Printf("fleet: spare pods: queue one on %s: %v", cluster, err)
				break
			}
			log.Printf("fleet: spare pods: queued %s (%s) on %s", a.Hostname, a.Login, cluster)
			go s.startClusterPod(cluster, *a, "")
			queued = true
		}
	}
	return queued
}

// failSparePod fails a spare pod's login (detail says why) and destroys the
// pod: a spare that is not ready is never handed out, and nothing of it is
// left standing. The failed row stays — the cluster gets no more spares until
// the operator forgets it.
func (s *Server) failSparePod(cluster string, p store.ClusterPod, a *store.FleetAccount, why string, now time.Time) {
	log.Printf("fleet: spare pods: %s on %s failed — %s; destroying it", p.Pod, cluster, why)
	if err := s.Store.FailClusterPodAccount(p.Pod, "spare pod: "+why, now); err != nil {
		log.Printf("fleet: spare pods: fail %s: %v", p.Pod, err)
	}
	if err := s.Store.SetClusterPodState(p.Pod, store.PodDestroying, why, now); err != nil {
		log.Printf("fleet: spare pods: %s: %v", p.Pod, err)
		return
	}
	go func() {
		res, err := s.clusterOp(context.Background(), cluster, control.ClusterTicket{Op: control.ClusterDestroyUserPod, Pod: p.Pod})
		state, detail := store.PodGone, why
		if err != nil || res.RC != 0 {
			state, detail = store.PodFailed, why+"; destroy: "+clusterOpWhy(res, err)
		}
		if err := s.Store.SetClusterPodState(p.Pod, state, truncate(detail, 1000), time.Now()); err != nil {
			log.Printf("fleet: spare pods: %s: %v", p.Pod, err)
		}
		_ = s.Store.HubAudit("hub", "spare.destroy", a.Login, map[bool]string{true: "ok", false: "failed"}[state == store.PodGone],
			fmt.Sprintf("%s on %s (%s): %s", p.Pod, cluster, p.PrincipalID, detail), time.Now())
	}()
}

func clusterOpWhy(res control.ClusterOpResult, err error) string {
	if err != nil {
		return err.Error()
	}
	return fmt.Sprintf("rc %d: %s", res.RC, res.Line)
}

// startClusterPod sends a's pod's create ticket: render.py's user pod named
// a.Hostname, built for a.Login as control.PodLoginUID (its node runs as that
// login, never root — claude-fleet#3757), the ceiling limits ("" = the
// template's), and a one-time machine
// join code minted for that pod alone, which the provisioner writes into the
// pod's join Secret. A refusal or failure fails the login and the pod row.
func (s *Server) startClusterPod(cluster string, a store.FleetAccount, limits string) {
	now := time.Now()
	code, err := MintJoinCode()
	if err == nil {
		err = s.Store.CreateJoinCodeFor(HashToken(code), "pod-"+a.Hostname, store.NodeKindFixed, TrustTrusted,
			store.NodeRoleManaged, a.Hostname, now, ManagedJoinCodeTTL)
	}
	var res control.ClusterOpResult
	if err == nil {
		_ = s.Store.FleetAudit("hub", "node_join_code", "join:pod-"+a.Hostname, "MINTED fixed trusted managed (spare pod)", "", now)
		res, err = s.clusterOp(context.Background(), cluster, control.ClusterTicket{
			Op: control.ClusterCreateUserPod, Pod: a.Hostname, Limits: limits, Login: a.Login,
			UID: control.PodLoginUID, Join: code})
	}
	if err == nil && res.RC == 0 {
		if err := s.Store.SetClusterPodState(a.Hostname, store.PodLive, truncate(res.Line, 1000), time.Now()); err != nil {
			log.Printf("fleet: spare pods: %s: %v", a.Hostname, err)
		}
		log.Printf("fleet: spare pods: %s started on %s for %s", a.Hostname, cluster, a.PrincipalID)
		return
	}
	why := "create: " + clusterOpWhy(res, err)
	log.Printf("fleet: spare pods: %s on %s: %s", a.Hostname, cluster, why)
	_, _ = s.Store.ExpireJoinCodes("pod-"+a.Hostname, a.Hostname, time.Now())
	if err := s.Store.FailClusterPodAccount(a.Hostname, truncate(why, 1000), time.Now()); err != nil {
		log.Printf("fleet: spare pods: fail %s: %v", a.Hostname, err)
	}
	if err == nil && res.RC != 3 {
		// It failed half-way (rc 1): whatever it made goes. A refusal (3)
		// made nothing.
		if dres, derr := s.clusterOp(context.Background(), cluster, control.ClusterTicket{
			Op: control.ClusterDestroyUserPod, Pod: a.Hostname}); derr != nil || dres.RC != 0 {
			why += "; clean-up: " + clusterOpWhy(dres, derr)
		}
	}
	if err := s.Store.SetClusterPodState(a.Hostname, store.PodFailed, truncate(why, 1000), time.Now()); err != nil {
		log.Printf("fleet: spare pods: %s: %v", a.Hostname, err)
	}
}

// labelValueRE is a Kubernetes label value.
var labelValueRE = regexp.MustCompile(`^[A-Za-z0-9]([A-Za-z0-9._-]{0,61}[A-Za-z0-9])?$`)

// podLabel is principal as a label value (gh:12345 → gh.12345); "" when it
// cannot be one.
func podLabel(principal string) string {
	b := []byte(principal)
	for i, c := range b {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '.' || c == '_' || c == '-') {
			b[i] = '.'
		}
	}
	v := strings.Trim(string(b), "._-")
	if len(v) > 63 {
		v = strings.TrimRight(v[:63], "._-")
	}
	if !labelValueRE.MatchString(v) {
		return ""
	}
	return v
}

// holdsClusterPod says principal already has a pod standing in cluster.
func (s *Server) holdsClusterPod(principal, cluster string) bool {
	pods, err := s.Store.ClusterPods(cluster)
	if err != nil {
		log.Printf("fleet: pods of %s: %v", cluster, err)
		return true // never hand a second one on a read that failed
	}
	for _, p := range pods {
		if p.Held() && strings.EqualFold(p.PrincipalID, principal) {
			return true
		}
	}
	return false
}

// claimClusterSpare hands principal the oldest ready spare pod in cluster —
// the machine spare's own claim on that pod's login — then makes it theirs:
// the pod row, their 家 (the door's table and their name follow), and the
// bind ticket (label, and their own ceiling when they have one). nil when it
// handed none.
func (s *Server) claimClusterSpare(principal, displayName, actor, cluster string, now time.Time) *store.FleetAccount {
	if !s.clusterPoolOn() || s.holdsClusterPod(principal, cluster) {
		return nil
	}
	pic, err := s.clusterPicture(cluster)
	if err != nil {
		log.Printf("fleet: claim a spare pod on %s for %s: %v", cluster, principal, err)
		return nil
	}
	for _, p := range pic.ready {
		a := s.claimSpareAt(principal, displayName, actor, p.Pod, now)
		if a == nil {
			continue // another claim took it: the next
		}
		if err := s.Store.ClaimClusterPod(p.Pod, a.PrincipalID, now); err != nil {
			log.Printf("fleet: claim %s for %s: pod row: %v", p.Pod, principal, err)
		}
		s.homeOnPod(a.PrincipalID, p.Pod, a.Login, now)
		go s.bindClusterPod(cluster, p.Pod, a.PrincipalID)
		log.Printf("fleet: %s: handed spare pod %s (%s) on %s", principal, p.Pod, a.Login, cluster)
		go func() {
			if s.replenishSpares(time.Now(), true) {
				s.dispatchAccounts()
			}
		}()
		return a
	}
	return nil
}

// homeOnPod makes pod person's 家: the door routes their name there and the
// DNS name follows (fleet_door.go). Pushed at once.
func (s *Server) homeOnPod(person, pod, login string, now time.Time) {
	h := store.EntryHome{Person: person, Machine: pod, Login: login, SetBy: "spare", SetAt: now.UTC()}
	v, err := s.Store.SetEntryHome(h)
	if err != nil {
		log.Printf("fleet: %s's home on %s: %v", person, pod, err)
		return
	}
	if v > 0 {
		s.entryAudit(store.EntryAudit{At: now, Kind: "home_set", Person: person, Login: login, Machine: pod, Result: "spare", Actor: "hub"})
		if nv := s.entryEnsureName(person, now, false); nv > v {
			v = nv
		}
		s.broadcastEntry(v, pod)
	}
}

// bindClusterPod labels a claimed pod with its person, and moves its ceiling
// to theirs when they have one (fleet.user_pod_limits.<principal>).
func (s *Server) bindClusterPod(cluster, pod, principal string) {
	if l := podLabel(principal); l != "" {
		if res, err := s.clusterOp(context.Background(), cluster, control.ClusterTicket{
			Op: control.ClusterBindUserPod, Pod: pod, Principal: l}); err != nil || res.RC != 0 {
			log.Printf("fleet: bind %s to %s: %s", pod, principal, clusterOpWhy(res, err))
		}
	}
	if v := strings.TrimSpace(s.setting(UserPodLimitsPrefix + principal)); v != "" {
		if res, err := s.clusterOp(context.Background(), cluster, control.ClusterTicket{
			Op: control.ClusterSetLimits, Pod: pod, Limits: v}); err != nil || res.RC != 0 {
			log.Printf("fleet: %s's ceiling on %s: %s", principal, pod, clusterOpWhy(res, err))
		}
	}
}

// placeOnCluster starts a pod of p's own in cluster: the pool had none ready.
func (s *Server) placeOnCluster(p *store.Principal, cluster string, now time.Time) bool {
	if !s.clusterPoolOn() || s.holdsClusterPod(p.ID, cluster) {
		return false
	}
	a, err := s.Store.CreateClusterPodFor(cluster, p, now)
	if err != nil {
		log.Printf("fleet: a pod of %s's own on %s: %v", p.ID, cluster, err)
		return false
	}
	log.Printf("fleet: no spare pod ready on %s: starting %s for %s", cluster, a.Hostname, p.ID)
	go func() {
		s.startClusterPod(cluster, *a, strings.TrimSpace(s.setting(UserPodLimitsPrefix+p.ID)))
		if l := podLabel(p.ID); l != "" {
			if res, err := s.clusterOp(context.Background(), cluster, control.ClusterTicket{
				Op: control.ClusterBindUserPod, Pod: a.Hostname, Principal: l}); err != nil || res.RC != 0 {
				log.Printf("fleet: bind %s to %s: %s", a.Hostname, p.ID, clusterOpWhy(res, err))
			}
		}
		s.dispatchAccounts()
	}()
	return true
}

// clusterPodOf is the pod row behind host when host is a pod the hub made and
// still stands (or is on its way down), with the account key to sign its
// destroy; nil otherwise — any other host's remove is the old one.
func (s *Server) clusterPodOf(host string) *store.ClusterPod {
	if s.accountKey == nil || !isUserPodName(host) {
		return nil
	}
	p, err := s.Store.ClusterPodOf(firstLabel(host))
	if err != nil {
		return nil
	}
	return p
}

// sendClusterDestroy runs a remove (or a reset) of the login on a pod as the
// pod's destroy: marked sent through the cluster's ops link, then the hub's
// own half of the person cleared and the destroy ticket carried. False when
// the ops link is down (the row waits, as a remove for an offline machine
// does). Runs under accountsMu.
func (s *Server) sendClusterDestroy(a store.FleetAccount, p *store.ClusterPod, now time.Time) bool {
	epID, c := s.nodes.opsFor(p.Cluster)
	if c == nil {
		return false
	}
	opID := control.NewOpID()
	if sent, err := s.Store.MarkAccountSent(a.PrincipalID, a.Hostname, a.State, store.AccountRemoving, opID, epID, now); err != nil || !sent {
		return false
	}
	_ = s.Store.SetClusterPodState(p.Pod, store.PodDestroying, "removing "+a.Login, now)
	go s.destroyClusterPod(a, *p, opID, epID)
	return true
}

// destroyClusterPod is the destroy: the person's hub-side pieces first (the
// same list a recycled login's are, recycleLeftovers' check after), then the
// pod — Deployment, Service, home PVC and join Secret — then the records, and
// a fresh spare in its place.
func (s *Server) destroyClusterPod(a store.FleetAccount, p store.ClusterPod, opID, epID string) {
	now := time.Now()
	s.recycleClear(a, now)
	res, err := s.clusterOp(context.Background(), p.Cluster, control.ClusterTicket{Op: control.ClusterDestroyUserPod, Pod: p.Pod})
	if err != nil || res.RC != 0 {
		why := "destroy: " + clusterOpWhy(res, err)
		log.Printf("fleet: %s on %s: %s", p.Pod, p.Cluster, why)
		if _, ferr := s.Store.FinishAccountOp(opID, epID, store.AccountFailed, truncate(why, 4000), time.Now()); ferr != nil {
			log.Printf("fleet: %s: %v", p.Pod, ferr)
		}
		_ = s.Store.SetClusterPodState(p.Pod, store.PodLive, truncate(why, 1000), time.Now())
		_ = s.Store.HubAudit("hub", "spare.destroy", a.Login, "failed", fmt.Sprintf("%s on %s (%s): %s", p.Pod, p.Cluster, a.PrincipalID, why), time.Now())
		return
	}
	left := strings.Join(s.recycleLeftovers(a, time.Now()), ", ")
	detail := "pod destroyed (Deployment · Service · PVC · join Secret): " + truncate(res.Line, 500)
	if left != "" {
		detail += "; hub-side leftovers: " + left
	}
	if err := s.Store.FinishClusterPodRemoval(p.Pod, opID, truncate(detail, 4000), time.Now()); err != nil {
		log.Printf("fleet: %s: record the destroy: %v", p.Pod, err)
		return
	}
	outcome := "ok"
	if left != "" {
		outcome = "leftovers"
	}
	_ = s.Store.HubAudit("hub", "spare.destroy", a.Login, outcome,
		fmt.Sprintf("%s on %s (%s): %s", p.Pod, p.Cluster, a.PrincipalID, detail), time.Now())
	log.Printf("fleet: %s on %s destroyed (%s, %s)", p.Pod, p.Cluster, a.Login, a.PrincipalID)
	if store.IsSparePrincipal(a.PrincipalID) {
		if err := s.Store.ForgetPrincipal(a.PrincipalID, ""); err != nil {
			log.Printf("fleet: forget %s: %v", a.PrincipalID, err)
		}
	}
	if s.replenishSpares(time.Now(), true) {
		s.dispatchAccounts()
	}
}

// spareReady says a spare's create answer makes it ready: credential-
// separated, or — on one person's pod, which keeps no credential at all —
// central (claude-fleet#3757).
func spareReady(credsep string, nc *nodeConn) bool {
	return credsep == control.CredsepSeparated || (credsep == control.CredsepCentral && nc != nil && nc.userPod)
}

// podStillStands refuses to forget a login whose pod is still up: the pod
// would be left with nobody's record. Remove it first — that destroys it.
func (s *Server) podStillStands(principal, host string) error {
	as, err := s.Store.FleetAccounts(principal)
	if err != nil {
		return err
	}
	for _, a := range as {
		if host != "" && !strings.EqualFold(a.Hostname, host) {
			continue
		}
		if p := s.clusterPodOf(a.Hostname); p != nil && (p.Held() || p.State == store.PodDestroying) {
			return fmt.Errorf("%s's pod %s on %s still stands: remove it first (that destroys the pod)", principal, p.Pod, p.Cluster)
		}
	}
	return nil
}
