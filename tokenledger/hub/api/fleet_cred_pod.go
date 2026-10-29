package api

import (
	"sort"
	"strings"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/credvault"
)

// Cluster pods are one provider's (claude-fleet#4601). The operator's rule:
// every pod of the cluster — a person's pod u-<nonce> (drill pods included),
// the shared ACK worker fleet-linux-* — uses only Codex subscriptions. A person's pod reads its owner's own allowance as the
// machine's (userPodNodeAllow, #4290), so an owner opened to "*" handed every
// new pod Claude too. The machine layer of a cluster pod therefore passes ONE
// hub setting's providers before any list is read:
//
//	fleet.cred_pod_providers   codex (the default): only Codex on a cluster
//	                           pod — an owner's "*" reads as every Codex
//	                           subscription, an owner's list as its Codex
//	                           entries; providers comma-separated
//	                           (codex,claude,deepseek); * : no provider gate.
//
// A list written for the pod itself still applies, under the same gate. Every
// resolver reads it through credPolicyOf: the lease, the pool manifest, the
// central proxy and the effective view. GitHub tokens are not subscriptions.
const CredPodProvidersKey = "fleet.cred_pod_providers"

// credPodProvidersDef is the setting's default.
const credPodProvidersDef = credvault.Codex

// clusterPodPrefixes are the names a cluster pod joins as besides u-<nonce>:
// the shared ACK worker's StatefulSet replicas (the hub's SPOT pods,
// ccquota-spot-*, went with the SPOT nodes — claude-fleet#4797).
var clusterPodPrefixes = []string{"fleet-linux-"}

// isClusterPodMachine says whether a machine is one of the cluster's pods.
func isClusterPodMachine(machine string) bool {
	if isUserPodName(machine) {
		return true
	}
	m := strings.ToLower(firstLabel(machine))
	for _, p := range clusterPodPrefixes {
		if strings.HasPrefix(m, p) && len(m) > len(p) {
			return true
		}
	}
	return false
}

// checkCredPodProviders is the setting's checker: "*" or providers
// comma-separated, stored sorted.
func checkCredPodProviders(_ *Server, v string) (string, string) {
	v = strings.ToLower(strings.TrimSpace(v))
	if v == "*" {
		return v, ""
	}
	seen := map[string]bool{}
	for _, p := range strings.Split(v, ",") {
		p = strings.TrimSpace(p)
		if p != credvault.Codex && p != credvault.Claude && p != credvault.DeepSeek {
			return "", CredPodProvidersKey + ` is providers comma-separated (codex, claude, deepseek), * for every one, or "" for the default (codex)`
		}
		seen[p] = true
	}
	out := make([]string, 0, len(seen))
	for p := range seen {
		out = append(out, p)
	}
	sort.Strings(out)
	return strings.Join(out, ","), ""
}

// podProvidersOf is the providers a cluster pod machine may use; nil = no
// provider gate (not a cluster pod, or the setting is *). A stored value that
// does not parse reads as the default: a broken setting never widens it.
func podProvidersOf(settings map[string]string, machine string) map[string]bool {
	return podProvidersIn(settings, machine, "")
}

// podProvidersIn is podProvidersOf for a pod of cluster ("" = not known):
// fleet.cred_pod_providers.<cluster> over fleet.cred_pod_providers (task
// J7BN); a cn cluster without its own key reads deepseek, the only provider
// its region runs. A broken value reads as that cluster's default, never
// wider.
func podProvidersIn(settings map[string]string, machine, cluster string) map[string]bool {
	if machine == "" || !isClusterPodMachine(machine) {
		return nil
	}
	def := credPodProvidersDef
	v := strings.TrimSpace(settings[CredPodProvidersKey])
	if cluster != "" {
		if clusterRegion(settings, cluster) == regionCN {
			def, v = credvault.DeepSeek, ""
		}
		if own := strings.TrimSpace(settings[CredPodProvidersPrefix+cluster]); own != "" {
			v = own
		}
	}
	if v == "" {
		v = def
	}
	norm, bad := checkCredPodProviders(nil, v)
	if bad != "" {
		norm = def
	}
	if norm == "*" {
		return nil
	}
	out := map[string]bool{}
	for _, p := range strings.Split(norm, ",") {
		out[p] = true
	}
	return out
}

// podProviderWhy is why provider is refused on this policy's cluster pod, ""
// when it may be used there.
func (p credPolicy) podProviderWhy(provider string) string {
	if p.PodProviders == nil || p.PodProviders[provider] {
		return ""
	}
	ps := make([]string, 0, len(p.PodProviders))
	for k := range p.PodProviders {
		ps = append(ps, k)
	}
	sort.Strings(ps)
	only := strings.Join(ps, ",")
	label := only
	switch only {
	case credvault.Codex:
		label = "Codex"
	case credvault.Claude:
		label = "Claude"
	case "":
		label = "nothing"
	}
	return "cluster pods are " + label + "-only (" + CredPodProvidersKey + "=" + only + "): machine " + p.Machine + " may not use a " + provider + " subscription"
}

// podProvidersFor is podProvidersIn for machine's own cluster: the cluster is
// looked up only when a per-cluster key or a cn cluster could change the
// answer, so with neither it is podProvidersOf exactly.
func (s *Server) podProvidersFor(settings map[string]string, machine string) map[string]bool {
	if machine == "" || !isClusterPodMachine(machine) {
		return nil
	}
	cluster := ""
	if clusterProvidersMatter(settings) {
		cluster = s.podCluster(settings, machine)
	}
	return podProvidersIn(settings, machine, cluster)
}

// clusterProvidersMatter says a pod's cluster may change its providers.
func clusterProvidersMatter(settings map[string]string) bool {
	if cnListed(settings) {
		return true
	}
	for k, v := range settings {
		if strings.HasPrefix(k, CredPodProvidersPrefix) && strings.TrimSpace(v) != "" {
			return true
		}
	}
	return false
}
