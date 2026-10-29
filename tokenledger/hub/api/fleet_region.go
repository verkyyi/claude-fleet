package api

import (
	"errors"
	"log"
	"regexp"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/credvault"
	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

// The mainland execution region (task J7BN, P1). A cluster may be marked as
// running in mainland China — the Shenzhen cluster ack-sz — where neither
// Claude nor OpenAI serve and the only provider a session there can use is
// DeepSeek (credvault.DeepSeek, P0). Four rules ride on one setting each:
//
//	fleet.cluster_region.<cluster>   cn | global (default global): the region
//	                                 of every pod of that cluster
//	                                 (fleet_cluster_pods) and of the cluster's
//	                                 own name. A machine that is no cluster's
//	                                 pod is global.
//	fleet.region_cn.people           who may start a deepseek session while a
//	                                 cn cluster is listed: principals
//	                                 comma-separated, or * for everyone; empty
//	                                 = nobody (the trial gate).
//	fleet.cred_pod_providers.<cluster>
//	                                 that cluster's pods' providers, over
//	                                 fleet.cred_pod_providers (fleet_cred_pod.go);
//	                                 a cn cluster with none set reads deepseek.
//
// Placement (computeFor): a cn machine takes ONLY provider deepseek; a global
// machine refuses deepseek ONLY while some cluster fleet.clusters lists is cn
// — so with no cn cluster every answer is P0's, byte for byte. A newcomer is
// never placed on a cn cluster by the automatic roads (fleet.auto_assign,
// least-busy, the trial's pick); the operator's assign naming the cluster
// still does.
const (
	ClusterRegionPrefix    = "fleet.cluster_region."
	RegionCNPeopleKey      = "fleet.region_cn.people"
	CredPodProvidersPrefix = CredPodProvidersKey + "."

	regionCN     = "cn"
	regionGlobal = "global"
)

// checkClusterRegion is fleet.cluster_region.<cluster>'s checker.
func checkClusterRegion(v string) (string, string) {
	switch v = strings.ToLower(strings.TrimSpace(v)); v {
	case "", regionCN, regionGlobal:
		return v, ""
	}
	return "", ClusterRegionPrefix + `<cluster> is cn | global, or "" for the default (global)`
}

// regionPrincipalRE is one principal of fleet.region_cn.people.
var regionPrincipalRE = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9:@._+-]{0,127}$`)

func checkRegionCNPeople(_ *Server, v string) (string, string) {
	if strings.TrimSpace(v) == "*" {
		return "*", ""
	}
	var out []string
	for _, p := range strings.Split(v, ",") {
		if p = strings.TrimSpace(p); p == "" {
			continue
		}
		if !regionPrincipalRE.MatchString(p) {
			return "", RegionCNPeopleKey + ": " + p + " is not a principal (gh:<id>, p:<uuid>, …)"
		}
		out = append(out, p)
	}
	if len(out) == 0 {
		return "", RegionCNPeopleKey + ` is principals comma-separated, * for everyone, or "" for nobody`
	}
	return strings.Join(out, ","), ""
}

// clustersOf is fleet.clusters as stored in settings, lower-cased.
func clustersOf(settings map[string]string) []string {
	var out []string
	for _, c := range strings.Split(settings[ClustersKey], ",") {
		if c = strings.ToLower(strings.TrimSpace(c)); c != "" {
			out = append(out, c)
		}
	}
	return out
}

// clusterRegion is cluster's region: cn only when said so, a broken value
// reads as global.
func clusterRegion(settings map[string]string, cluster string) string {
	if cluster != "" && strings.EqualFold(strings.TrimSpace(settings[ClusterRegionPrefix+strings.ToLower(cluster)]), regionCN) {
		return regionCN
	}
	return regionGlobal
}

// cnListed says some cluster fleet.clusters lists is cn: the switch that
// turns every region rule on.
func cnListed(settings map[string]string) bool {
	for _, c := range clustersOf(settings) {
		if clusterRegion(settings, c) == regionCN {
			return true
		}
	}
	return false
}

// podClusterEntry is one podCluster answer, cached.
type podClusterEntry struct {
	cluster string
	at      time.Time
}

// podClusterMiss is how long "no such pod" is believed: a pod's row is
// written before its node can join, so a miss is only ever a machine that is
// no pod (or a store hiccup) — a found cluster never changes.
const podClusterMiss = 30 * time.Second

// podCluster is the cluster machine is a pod of ("" = none): its
// fleet_cluster_pods row, or the cluster's own name. Cached per pod.
func (s *Server) podCluster(settings map[string]string, machine string) string {
	m := strings.ToLower(firstLabel(strings.TrimSpace(machine)))
	if m == "" {
		return ""
	}
	for _, c := range clustersOf(settings) {
		if c == m || strings.EqualFold(c, strings.TrimSpace(machine)) {
			return c
		}
	}
	if !isUserPodName(m) || s.Store == nil {
		return ""
	}
	if v, ok := s.podClusters.Load(m); ok {
		e := v.(podClusterEntry)
		if e.cluster != "" || time.Since(e.at) < podClusterMiss {
			return e.cluster
		}
	}
	cluster := ""
	if p, err := s.Store.ClusterPodOf(m); err == nil {
		cluster = strings.ToLower(p.Cluster)
	} else if !errors.Is(err, store.ErrNoClusterPod) {
		log.Printf("fleet: region: pod %s: %v", m, err)
	}
	s.podClusters.Store(m, podClusterEntry{cluster: cluster, at: time.Now()})
	return cluster
}

// regionOf is machine's region: its cluster's, global for a machine that is
// no listed cluster's pod. No cn cluster listed ⇒ global without a lookup.
func (s *Server) regionOf(settings map[string]string, machine string) string {
	if !cnListed(settings) {
		return regionGlobal
	}
	c := s.podCluster(settings, machine)
	if c == "" || !hasFold(clustersOf(settings), c) {
		return regionGlobal
	}
	return clusterRegion(settings, c)
}

// regionWhy is why a start of provider ("" = not said, the default agent)
// may not open on machine, "" when it may. Nothing while no cn cluster is
// listed.
func (s *Server) regionWhy(settings map[string]string, machine, provider string) string {
	if machine == "" || !cnListed(settings) {
		return ""
	}
	if s.regionOf(settings, machine) == regionCN {
		if provider != credvault.DeepSeek {
			label := provider
			if label == "" {
				label = "the default agent"
			}
			return "mainland region (" + ClusterRegionPrefix + s.podCluster(settings, machine) + "=cn): machine " + machine + " runs deepseek only, not " + label
		}
		return ""
	}
	if provider == credvault.DeepSeek {
		return "deepseek runs in the mainland region only while a cn cluster is listed: machine " + machine + " is global"
	}
	return ""
}

// cnHost says host is a cn cluster or one of its pods: never a newcomer's
// automatic pick.
func (s *Server) cnHost(settings map[string]string, host string) bool {
	return cnListed(settings) && s.regionOf(settings, host) == regionCN
}

// dropCNHosts is hosts without the cn ones (the automatic placement's list).
func (s *Server) dropCNHosts(settings map[string]string, hosts []string) []string {
	if !cnListed(settings) {
		return hosts
	}
	out := hosts[:0:0]
	for _, h := range hosts {
		if s.cnHost(settings, h) {
			log.Printf("fleet: auto-assign: %s skipped: a mainland (cn) cluster is never a newcomer's automatic pick — assign it by name", h)
			continue
		}
		out = append(out, h)
	}
	return out
}

// Start models (task J7BN): the one a start may ask for besides its agent's
// own default. Each is DeepSeek's, served to Claude Code.
var startModels = map[string]bool{"deepseek": true, "deepseek-pro": true}

// checkStartModel is a start's model in its stored form (lower-cased), or
// why it is refused: "", deepseek or deepseek-pro, and a deepseek model is a
// Claude Code session — never with agent codex.
func checkStartModel(model, agent string) (string, string) {
	m := strings.ToLower(strings.TrimSpace(model))
	if m == "" {
		return "", ""
	}
	if !startModels[m] {
		return "", "model must be deepseek or deepseek-pro, or absent for the agent's own"
	}
	if agent == credvault.Codex {
		return "", "model " + m + " is a Claude Code session: start it with agent claude, not codex"
	}
	return m, ""
}

// providerFor is the subscription provider a start of agent with model uses:
// deepseek for a DeepSeek model (a Claude Code session), else the agent.
func providerFor(agent, model string) string {
	if startModels[strings.ToLower(strings.TrimSpace(model))] {
		return credvault.DeepSeek
	}
	return agent
}

// provider is a worker_start's provider: providerFor its agent and model.
func (w writeRequest) provider() string {
	agent, _ := w.params["agent"].(string)
	model, _ := w.params["model"].(string)
	return providerFor(agent, model)
}

// regionStartWhy is the trial gate: why principal may not start a session of
// provider, "" when it may. Only a deepseek start while a cn cluster is
// listed is gated; the operator's door (principal "") passes.
func regionStartWhy(settings map[string]string, principal, provider string) string {
	if provider != credvault.DeepSeek || principal == "" || !cnListed(settings) {
		return ""
	}
	v := strings.TrimSpace(settings[RegionCNPeopleKey])
	if v == "*" {
		return ""
	}
	for _, p := range strings.Split(v, ",") {
		if strings.TrimSpace(p) == principal {
			return ""
		}
	}
	return "the mainland region (deepseek) is a trial: " + principal + " is not on " + RegionCNPeopleKey
}

// regionStartGate is regionStartWhy as a fault (403), reading the settings.
func (s *Server) regionStartGate(principal, provider string) error {
	if provider != credvault.DeepSeek || s.Store == nil {
		return nil
	}
	settings, err := s.Store.FleetSettings()
	if err != nil {
		return err
	}
	if why := regionStartWhy(settings, principal, provider); why != "" {
		return fault("FORBIDDEN", why)
	}
	return nil
}

// startPrincipal is who a start is the trial gate's: the person behind the
// call, else the task's owner a node placed for; "" for the operator's door.
func startPrincipal(p fleetPrincipal) string {
	switch {
	case p.Person != "":
		return p.Person
	case p.TaskOwner != "":
		return p.TaskOwner
	case strings.HasPrefix(p.Actor, "node:"):
		return p.Actor // a node login no person owns: on the list by name, or *
	}
	return ""
}
