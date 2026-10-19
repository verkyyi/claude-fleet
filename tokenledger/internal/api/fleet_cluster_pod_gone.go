package api

import (
	"errors"
	"fmt"
	"log"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// A cluster pod that is gone takes its machine off the hub (claude-fleet#4887).
//
// A person's or a test pod (u-<nonce>) lives as long as its Deployment: once
// that is deleted or scaled to 0, the pod's endpoints stay on the roster as
// lost, and their fleet rows, starts and leases keep holding a repo switch
// until somebody retires them by hand (#4830: Arvin's pod, ep_1791893593702723695,
// 83 starts and 447 passes). The cluster already says which pods stand: with
// every readings message fleet-ops lists every user pod object it sees
// (ClusterReadings.Listed / Present — any phase, so a pod restarting or being
// patched onto a new image is still there). So:
//
//   - Gone: a pod with endpoints on the roster that its cluster's list has not
//     named for podGoneGrace (30 min, past a Recreate roll or an image patch),
//     the list arriving without a gap longer than podGoneGap — a fleet-ops
//     that went quiet restarts every clock, it never reads as «all gone».
//   - Its cluster: the one fleet_cluster_pods puts it in; a pod the hub never
//     made (moved in by hand) only when this cluster is the only one listing.
//   - Never while it lives: any of its endpoints connected (to any replica) or
//     heard from within podGoneGrace leaves the pod alone.
//   - Only pods: a machine not named u-<nonce> — a Mac mini, a client, the
//     cluster's own ops link — is never looked at here (a mini that drops off
//     is node_lost's alert, not a retire).
//
// The retire is the machines page's own (retireNode): the endpoint's token,
// passes, starts, leases and roster row, audited actor=system with reason
// «cluster pod gone/scaled to 0». It touches nothing in the cluster — no
// destroy, the home PVC stays — and scaled back to 1 the pod joins again the
// normal way (a fresh machine join code in u-<nonce>-join). Each retire tells
// the operator which pod and which login (s.notify).
//
// fleet.cluster_pod_retire off, or a fleet-ops older than the list ⇒ nothing
// is retired (TestClusterPodGoneOffAddsNothing).

// ClusterPodRetireKey turns the automatic retire off.
const ClusterPodRetireKey = "fleet.cluster_pod_retire"

// clusterPodGoneReason is the audit row's reason.
const clusterPodGoneReason = "cluster pod gone/scaled to 0"

// podGoneGrace is how long a pod must be missing (and its endpoints silent)
// before it is retired; podGoneGap is the longest gap between two lists that
// still counts as watching. Variables so tests can move them.
var (
	podGoneGrace = 30 * time.Minute
	podGoneGap   = 5 * time.Minute
)

// podGoneBook is the hub's memory of missing pods: in memory only, so a
// restart (or the ops link moving to the other replica) starts every clock
// again — later, never sooner.
type podGoneBook struct {
	mu         sync.Mutex
	lastListed map[string]time.Time // cluster → its last list
	missing    map[string]podMissing
	running    atomic.Bool
}

type podMissing struct {
	cluster string
	since   time.Time
}

// podGoneRetired is one pod retired by observeClusterPods.
type podGoneRetired struct {
	Pod       string
	Endpoints []string // "<login> (<endpoint>)"
}

// observeClusterPods takes one cluster's list of standing pods and retires the
// endpoints of every pod that has been missing from it for podGoneGrace.
func (s *Server) observeClusterPods(cluster string, present []string, now time.Time) []podGoneRetired {
	if s.Store == nil || s.setting(ClusterPodRetireKey) == "off" {
		return nil
	}
	cluster = strings.ToLower(cluster)
	standing := map[string]bool{}
	for _, p := range present {
		standing[strings.ToLower(p)] = true
	}
	rows, err := s.Store.Nodes()
	if err != nil {
		log.Printf("cluster %s: pod gone: roster: %v", cluster, err)
		return nil
	}
	pods := map[string][]store.Node{}
	for _, n := range rows {
		if isUserPodName(n.Hostname) {
			k := podKey(n.Hostname)
			pods[k] = append(pods[k], n)
		}
	}

	b := &s.podGone
	b.mu.Lock()
	if b.lastListed == nil {
		b.lastListed, b.missing = map[string]time.Time{}, map[string]podMissing{}
	}
	if last, ok := b.lastListed[cluster]; !ok || now.Sub(last) > podGoneGap {
		for p, m := range b.missing {
			if m.cluster == cluster {
				delete(b.missing, p) // not watched in between: start again
			}
		}
	}
	b.lastListed[cluster] = now
	sole := true
	for c, at := range b.lastListed {
		if c != cluster && now.Sub(at) <= podGoneGap {
			sole = false
		}
	}
	for p, m := range b.missing {
		if _, still := pods[p]; m.cluster == cluster && (!still || standing[p]) {
			delete(b.missing, p)
		}
	}
	var due []string
	for p := range pods {
		if standing[p] {
			continue
		}
		cp, err := s.Store.ClusterPodOf(p)
		switch {
		case err == nil && !sameMachine(cluster, cp.Cluster):
			continue // another cluster's pod: that cluster's list says
		case errors.Is(err, store.ErrNoClusterPod) && !sole:
			continue // made by hand, and another cluster could hold it
		case err != nil && !errors.Is(err, store.ErrNoClusterPod):
			continue
		}
		m, ok := b.missing[p]
		if !ok || m.cluster != cluster { // a clock is its own cluster's
			b.missing[p] = podMissing{cluster: cluster, since: now}
			continue
		}
		if now.Sub(m.since) >= podGoneGrace {
			due = append(due, p)
		}
	}
	b.mu.Unlock()
	if len(due) == 0 {
		return nil
	}
	sort.Strings(due)

	peers := s.peerConns()
	var out []podGoneRetired
	for _, p := range due {
		if live := s.podStillHeard(pods[p], peers, now); live != "" {
			continue
		}
		r := podGoneRetired{Pod: p}
		for _, n := range pods[p] {
			ep, err := s.Store.EndpointByID(n.EndpointID)
			if err != nil {
				log.Printf("cluster %s: pod %s gone: endpoint %s: %v", cluster, p, n.EndpointID, err)
				continue
			}
			res, err := s.retireNode(ep, "system", clusterPodGoneReason, now)
			if err != nil {
				log.Printf("cluster %s: pod %s gone: retire %s: %v", cluster, p, n.EndpointID, err)
				continue
			}
			if res.Already && !res.Removed {
				continue
			}
			who := n.OSUser
			if who == "" {
				who = "?"
			}
			r.Endpoints = append(r.Endpoints, fmt.Sprintf("%s (%s, starts %d, passes %d)", who, n.EndpointID, res.Starts, res.Passes))
		}
		b.mu.Lock()
		delete(b.missing, p)
		b.mu.Unlock()
		if len(r.Endpoints) == 0 {
			continue
		}
		out = append(out, r)
		line := strings.Join(r.Endpoints, "; ")
		log.Printf("cluster %s: pod %s gone/scaled to 0 for %s: retired %s", cluster, p, podGoneGrace, line)
		s.notify(fmt.Sprintf("集群 %s 的 pod %s 已删除或缩到 0 超过 %s，入口已自动退役它的节点：%s。PVC 未动；扩回 1 后用新的加入码重新加入。",
			cluster, p, podGoneGrace, line))
	}
	return out
}

// clusterPodsListed runs observeClusterPods off the link's reader, one pass at
// a time: a list arriving while one runs waits for the next (15 s later).
func (s *Server) clusterPodsListed(cluster string, present []string) {
	if !s.podGone.running.CompareAndSwap(false, true) {
		return
	}
	go func() {
		defer s.podGone.running.Store(false)
		s.observeClusterPods(cluster, present, time.Now())
	}()
}

// podStillHeard names an endpoint of the pod that is connected or was heard
// within podGoneGrace; "" when none is.
func (s *Server) podStillHeard(eps []store.Node, peers map[string]store.NodeConn, now time.Time) string {
	for _, n := range eps {
		if s.nodes.get(n.EndpointID) != nil {
			return n.EndpointID
		}
		if _, ok := peers[n.EndpointID]; ok {
			return n.EndpointID
		}
		if n.LastHeartbeat != nil && now.Sub(*n.LastHeartbeat) < podGoneGrace {
			return n.EndpointID
		}
	}
	return ""
}
