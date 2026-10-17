package api

import (
	"sort"
	"strings"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/credvault"
)

// Cluster pods are one provider's (claude-fleet#4601). The operator's rule:
// every pod of the cluster — a person's pod u-<nonce> (drill pods included),
// the shared ACK worker fleet-linux-*, a SPOT node ccquota-spot-* — uses only
// Codex subscriptions. A person's pod reads its owner's own allowance as the
// machine's (userPodNodeAllow, #4290), so an owner opened to "*" handed every
// new pod Claude too. The machine layer of a cluster pod therefore passes ONE
// hub setting's providers before any list is read:
//
//	fleet.cred_pod_providers   codex (the default): only Codex on a cluster
//	                           pod — an owner's "*" reads as every Codex
//	                           subscription, an owner's list as its Codex
//	                           entries; providers comma-separated
//	                           (codex,claude); * : no provider gate.
//
// A list written for the pod itself still applies, under the same gate. Every
// resolver reads it through credPolicyOf: the lease, the pool manifest, the
// central proxy and the effective view. GitHub tokens are not subscriptions.
const CredPodProvidersKey = "fleet.cred_pod_providers"

// credPodProvidersDef is the setting's default.
const credPodProvidersDef = credvault.Codex

// clusterPodPrefixes are the names a cluster pod joins as besides u-<nonce>:
// the shared ACK worker's StatefulSet replicas and the hub's SPOT pods.
var clusterPodPrefixes = []string{"fleet-linux-", "ccquota-spot-"}

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
		if p != credvault.Codex && p != credvault.Claude {
			return "", CredPodProvidersKey + ` is providers comma-separated (codex, claude), * for every one, or "" for the default (codex)`
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
	if machine == "" || !isClusterPodMachine(machine) {
		return nil
	}
	v := strings.TrimSpace(settings[CredPodProvidersKey])
	if v == "" {
		v = credPodProvidersDef
	}
	norm, bad := checkCredPodProviders(nil, v)
	if bad != "" {
		norm = credPodProvidersDef
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
