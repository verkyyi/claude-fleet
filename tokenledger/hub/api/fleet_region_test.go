package api

import (
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/credvault"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

// regionRig is a hub with a pod of ack-sz recorded: the pod's name.
func regionRig(t *testing.T) (*harness, string) {
	t.Helper()
	h, _, _ := policyRig(t)
	now := time.Now()
	p, err := h.srv.Store.EnsurePrincipal("gh:7001", "sz", control.MaxLoginLen, control.ValidLogin, now)
	if err != nil {
		t.Fatal(err)
	}
	a, err := h.srv.Store.CreateClusterPodFor(testCluster, p, now)
	if err != nil {
		t.Fatal(err)
	}
	return h, a.Hostname
}

func setRegion(t *testing.T, h *harness, kv ...string) map[string]string {
	t.Helper()
	for i := 0; i+1 < len(kv); i += 2 {
		if err := h.srv.Store.SetFleetSetting(kv[i], kv[i+1], time.Now()); err != nil {
			t.Fatal(err)
		}
	}
	settings, err := h.srv.Store.FleetSettings()
	if err != nil {
		t.Fatal(err)
	}
	return settings
}

// task J7BN P1: a cn machine runs deepseek only; a global machine refuses
// deepseek only while a cn cluster is listed; with none, nothing changes.
func TestRegionPlacementRules(t *testing.T) {
	h, pod := regionRig(t)
	s := h.srv
	providers := []string{"", credvault.Claude, credvault.Codex, credvault.DeepSeek}

	// No region set at all (P0): every provider anywhere, no lookup.
	settings := setRegion(t, h, ClustersKey, testCluster)
	for _, m := range []string{pod, "mac-c"} {
		for _, pr := range providers {
			if why := s.regionWhy(settings, m, pr); why != "" {
				t.Fatalf("no cn cluster: %s %q refused: %s", m, pr, why)
			}
		}
	}
	if s.regionOf(settings, pod) != regionGlobal {
		t.Fatal("a pod of a cluster with no region is global")
	}

	// ack-sz is cn but not listed: still off.
	settings = setRegion(t, h, ClustersKey, "ack-sg", ClusterRegionPrefix+testCluster, regionCN)
	if cnListed(settings) || s.regionWhy(settings, "mac-c", credvault.DeepSeek) != "" {
		t.Fatal("a cn cluster fleet.clusters does not list turned the region on")
	}

	// Listed: the rules.
	settings = setRegion(t, h, ClustersKey, "ack-sg,"+testCluster)
	if s.regionOf(settings, pod) != regionCN || s.regionOf(settings, testCluster) != regionCN || s.regionOf(settings, "mac-c") != regionGlobal {
		t.Fatalf("regions: pod %s · cluster %s · mac-c %s", s.regionOf(settings, pod), s.regionOf(settings, testCluster), s.regionOf(settings, "mac-c"))
	}
	for _, pr := range providers {
		why := s.regionWhy(settings, pod, pr)
		if (why == "") != (pr == credvault.DeepSeek) {
			t.Fatalf("cn pod, provider %q: why %q", pr, why)
		}
		if pr != credvault.DeepSeek && !strings.Contains(why, "deepseek only") {
			t.Fatalf("cn refusal unreadable: %q", why)
		}
		why = s.regionWhy(settings, "mac-c", pr)
		if (why == "") != (pr != credvault.DeepSeek) {
			t.Fatalf("global mac-c, provider %q: why %q", pr, why)
		}
	}
	if why := s.regionWhy(settings, "mac-c", credvault.DeepSeek); !strings.Contains(why, "mainland region only") {
		t.Fatalf("global refusal unreadable: %q", why)
	}

	// computeFor carries it, as placement's one rule.
	on := true
	now := time.Now()
	hb := control.Heartbeat{Compute: &on}
	setRegion(t, h, CredPodProvidersPrefix+testCluster, "*")
	settings, _ = s.Store.FleetSettings()
	if cv := s.computeFor("", pod, hb, settings, credvault.Claude, now); !cv.Off || !strings.Contains(cv.Why, "compute off for claude") {
		t.Fatalf("computeFor(cn pod, claude) = %+v", cv)
	}
	if cv := s.computeFor("", pod, hb, settings, "", now); !cv.Off {
		t.Fatalf("computeFor(cn pod, default agent) = %+v; want off", cv)
	}
	if cv := s.computeFor("", pod, hb, settings, credvault.DeepSeek, now); cv.Off {
		t.Fatalf("computeFor(cn pod, deepseek) = %+v", cv)
	}
	if cv := s.computeFor("", "mac-c", hb, settings, credvault.DeepSeek, now); !cv.Off {
		t.Fatalf("computeFor(mac-c, deepseek) = %+v; want off", cv)
	}
	if cv := s.computeFor("", "mac-c", hb, settings, credvault.Claude, now); cv.Off {
		t.Fatalf("computeFor(mac-c, claude) = %+v", cv)
	}
	// A mainland egress closes Claude / OpenAI only: deepseek on a cn pod
	// whose probe says unsupported region still runs.
	cn := probe("CN", control.ProbeUnsupportedRegion)
	cn.TS = now
	if cv := s.computeFor("", pod, control.Heartbeat{Compute: &on, Probe: cn}, settings, credvault.DeepSeek, now); cv.Off {
		t.Fatalf("computeFor(cn pod with CN egress, deepseek) = %+v", cv)
	}
}

func TestProviderForAndStartModel(t *testing.T) {
	for _, tc := range []struct{ agent, model, want string }{
		{"", "", ""}, {"claude", "", "claude"}, {"codex", "", "codex"},
		{"", "deepseek", "deepseek"}, {"claude", "DeepSeek-Pro", "deepseek"},
	} {
		if got := providerFor(tc.agent, tc.model); got != tc.want {
			t.Fatalf("providerFor(%q, %q) = %q; want %q", tc.agent, tc.model, got, tc.want)
		}
	}
	for _, tc := range []struct {
		model, agent, want string
		bad                bool
	}{
		{"", "", "", false}, {"deepseek", "", "deepseek", false}, {" DeepSeek-Pro ", "claude", "deepseek-pro", false},
		{"gpt-5", "", "", true}, {"opus", "claude", "", true}, {"deepseek", "codex", "", true},
	} {
		got, why := checkStartModel(tc.model, tc.agent)
		if (why != "") != tc.bad || got != tc.want {
			t.Fatalf("checkStartModel(%q, %q) = %q %q", tc.model, tc.agent, got, why)
		}
	}
	// worker_start carries it to the node (params.model), agent claude implied.
	w, _, err := parseWrite("worker_start", map[string]any{"idempotency_key": "m1", "issue": float64(3),
		"repo": writeRepo, "model": "deepseek"})
	if err != nil || w.params["model"] != "deepseek" || w.params["agent"] != credvault.Claude || w.provider() != credvault.DeepSeek {
		t.Fatalf("parseWrite model: %v %v", w.params, err)
	}
	for _, args := range []map[string]any{
		{"idempotency_key": "m2", "issue": float64(3), "repo": writeRepo, "model": "bogus"},
		{"idempotency_key": "m3", "issue": float64(3), "repo": writeRepo, "model": "deepseek", "agent": "codex"},
		{"idempotency_key": "k4", "issue": float64(3), "repo": writeRepo, "model": 7},
	} {
		if _, _, err := parseWrite("worker_start", args); err == nil || errorObject(err)["code"] != "INVALID_ARGUMENT" {
			t.Fatalf("parseWrite(%v) = %v; want INVALID_ARGUMENT", args, err)
		}
	}
}

// The trial gate: a deepseek start while a cn cluster is listed, by someone
// not on fleet.region_cn.people, is refused; empty = nobody, * = everyone.
func TestRegionPeopleGate(t *testing.T) {
	base := map[string]string{ClustersKey: testCluster, ClusterRegionPrefix + testCluster: regionCN}
	with := func(people string) map[string]string {
		out := map[string]string{RegionCNPeopleKey: people}
		for k, v := range base {
			out[k] = v
		}
		return out
	}
	if why := regionStartWhy(with(""), "gh:1", credvault.DeepSeek); !strings.Contains(why, RegionCNPeopleKey) {
		t.Fatalf("empty list let gh:1 in: %q", why)
	}
	if regionStartWhy(with("gh:2, gh:1"), "gh:1", credvault.DeepSeek) != "" || regionStartWhy(with("*"), "gh:9", credvault.DeepSeek) != "" {
		t.Fatal("a listed principal / * was refused")
	}
	if regionStartWhy(with("gh:2"), "gh:1", credvault.DeepSeek) == "" {
		t.Fatal("an unlisted principal passed")
	}
	if regionStartWhy(with(""), "gh:1", credvault.Claude) != "" || regionStartWhy(with(""), "", credvault.DeepSeek) != "" {
		t.Fatal("the gate touched a non-deepseek start or the operator's door")
	}
	if regionStartWhy(map[string]string{}, "gh:1", credvault.DeepSeek) != "" {
		t.Fatal("no cn cluster: deepseek is P0's, ungated")
	}
	if startPrincipal(fleetPrincipal{Actor: "node:frank@mac-d"}) != "node:frank@mac-d" || startPrincipal(fleetPrincipal{Actor: "operator"}) != "" ||
		startPrincipal(fleetPrincipal{Actor: "x", Person: "gh:1", TaskOwner: "gh:2"}) != "gh:1" {
		t.Fatal("startPrincipal")
	}
	if _, why := checkRegionCNPeople(nil, "gh:1, has space"); why == "" {
		t.Fatal("a principal with a space was stored")
	}
	if v, why := checkRegionCNPeople(nil, " gh:1 ,p:abc "); why != "" || v != "gh:1,p:abc" {
		t.Fatalf("checkRegionCNPeople = %q %q", v, why)
	}
}

// The node's /v1/node/place: model checked (400), the gate (403), and the
// eligibility rule on the same start.
func TestRegionNodePlace(t *testing.T) {
	h, _, _, f5, _ := twoNodes(t)
	place := func(issue int, body map[string]any) (int, map[string]any) {
		b := map[string]any{"repo": writeRepo, "issue": issue, "worker_id": issueWID(f5.FleetID, issue), "node": "mac-c", "wait": 0}
		for k, v := range body {
			b[k] = v
		}
		return placeCall(t, h, h.tokens["mac-d"], b)
	}
	if st, _ := place(81, map[string]any{"model": "gpt-5"}); st != http.StatusBadRequest {
		t.Fatalf("model gpt-5 = %d; want 400", st)
	}
	if st, _ := place(82, map[string]any{"model": "deepseek", "agent": "codex"}); st != http.StatusBadRequest {
		t.Fatalf("deepseek with codex = %d; want 400", st)
	}
	// No cn cluster: deepseek on mac-c as P0.
	if st, out := place(83, map[string]any{"model": "deepseek"}); st != http.StatusOK {
		t.Fatalf("P0 deepseek on mac-c = %d %v", st, out)
	}
	setRegion(t, h, ClustersKey, testCluster, ClusterRegionPrefix+testCluster, regionCN)
	if st, out := place(84, map[string]any{"model": "deepseek"}); st != http.StatusForbidden ||
		!strings.Contains(out["error"].(map[string]any)["message"].(string), RegionCNPeopleKey) {
		t.Fatalf("unlisted deepseek start = %d %v; want 403", st, out)
	}
	setRegion(t, h, RegionCNPeopleKey, "*")
	if st, out := place(85, map[string]any{"model": "deepseek"}); st != http.StatusServiceUnavailable ||
		out["error"].(map[string]any)["code"] != "NO_ELIGIBLE_NODE" {
		t.Fatalf("deepseek on global mac-c with a cn cluster = %d %v; want NO_ELIGIBLE_NODE", st, out)
	}
	if st, out := place(86, map[string]any{"agent": "claude"}); st != http.StatusOK {
		t.Fatalf("claude on global mac-c = %d %v", st, out)
	}
}

// A newcomer's automatic roads never pick a cn cluster or its pods.
func TestRegionNewcomerSkipsCN(t *testing.T) {
	h, pod := regionRig(t)
	s := h.srv
	setRegion(t, h, ClustersKey, testCluster, AutoAssignKey, testCluster+",mac-c,"+pod)
	if got := s.autoAssign(); len(got) != 3 {
		t.Fatalf("no cn region: autoAssign = %v; want all three", got)
	}
	settings := setRegion(t, h, ClusterRegionPrefix+testCluster, regionCN)
	if got := s.autoAssign(); len(got) != 1 || got[0] != "mac-c" {
		t.Fatalf("autoAssign = %v; want only mac-c", got)
	}
	if !s.cnHost(settings, testCluster) || !s.cnHost(settings, pod) || s.cnHost(settings, "mac-c") {
		t.Fatal("cnHost")
	}
}

// least-busy (and so the invite, the failed-create retry and the trial's
// pick) never lands on a cn cluster's machine.
func TestRegionLeastBusySkipsCN(t *testing.T) {
	h := newFleetHarness(t)
	enablePeople(t, h)
	leastBusyFleet(t, h)
	sz := connectNode(t, h, "sz-op", testCluster, "ivan", true)
	beatCount(t, sz, testCluster, "ivan", 0)
	waitFor(t, 3*time.Second, "ack-sz on the roster", func() bool {
		snap, err := h.srv.Nodes(time.Now())
		if err != nil {
			return false
		}
		for _, m := range snap.Machines {
			if m.Hostname == testCluster && m.Status == "online" && m.Sessions != nil {
				return true
			}
		}
		return false
	})
	setRegion(t, h, ClustersKey, testCluster)
	if got := h.srv.leastBusyMachine(time.Now(), "mac-d", "mac-c"); got != testCluster {
		t.Fatalf("global ack-sz: least busy = %q; want ack-sz", got)
	}
	setRegion(t, h, ClusterRegionPrefix+testCluster, regionCN)
	if got := h.srv.leastBusyMachine(time.Now(), "mac-d", "mac-c"); got != "" {
		t.Fatalf("cn ack-sz: least busy = %q; want none", got)
	}
}

// fleet.cred_pod_providers.<cluster> overrides the fleet-wide value for that
// cluster's pods; a cn cluster with none reads deepseek.
func TestClusterPodProviders(t *testing.T) {
	h, pod := regionRig(t)
	s := h.srv
	only := func(p map[string]bool, want ...string) bool {
		if len(p) != len(want) {
			return false
		}
		for _, w := range want {
			if !p[w] {
				return false
			}
		}
		return true
	}
	settings := setRegion(t, h, ClustersKey, testCluster)
	if p := s.podProvidersFor(settings, pod); !only(p, credvault.Codex) {
		t.Fatalf("default: %v", p)
	}
	settings = setRegion(t, h, CredPodProvidersKey, "codex,claude")
	if p := s.podProvidersFor(settings, pod); !only(p, credvault.Codex, credvault.Claude) {
		t.Fatalf("fleet-wide: %v", p)
	}
	settings = setRegion(t, h, CredPodProvidersPrefix+testCluster, "deepseek")
	if p := s.podProvidersFor(settings, pod); !only(p, credvault.DeepSeek) {
		t.Fatalf("per-cluster: %v", p)
	}
	if p := s.podProvidersFor(settings, "plain-worker-0"); !only(p, credvault.Codex, credvault.Claude) {
		t.Fatalf("a pod of no known cluster keeps the fleet-wide value: %v", p)
	}
	if p := podProvidersIn(settings, pod, "ack-sg"); !only(p, credvault.Codex, credvault.Claude) {
		t.Fatalf("another cluster: %v", p)
	}
	settings = setRegion(t, h, CredPodProvidersPrefix+testCluster, "", ClusterRegionPrefix+testCluster, regionCN)
	if p := s.podProvidersFor(settings, pod); !only(p, credvault.DeepSeek) {
		t.Fatalf("cn cluster default: %v", p)
	}
	// The settings door checks both per-cluster keys.
	for _, kv := range [][2]string{{ClusterRegionPrefix + testCluster, "mars"}, {CredPodProvidersPrefix + testCluster, "gemini"}, {RegionCNPeopleKey, "has space"}} {
		if code, out := h.post(t, "/v1/fleet/settings", map[string]string{"key": kv[0], "value": kv[1]}); code != http.StatusBadRequest {
			t.Fatalf("%s=%s: %d %v; want 400", kv[0], kv[1], code, out)
		}
	}
	for _, kv := range [][2]string{{ClusterRegionPrefix + testCluster, "CN"}, {CredPodProvidersPrefix + testCluster, "deepseek,codex"}, {RegionCNPeopleKey, "gh:1,gh:2"}} {
		if code, out := h.post(t, "/v1/fleet/settings", map[string]string{"key": kv[0], "value": kv[1]}); code != http.StatusOK {
			t.Fatalf("%s=%s: %d %v", kv[0], kv[1], code, out)
		}
	}
	settings, _ = s.Store.FleetSettings()
	if settings[ClusterRegionPrefix+testCluster] != regionCN || settings[CredPodProvidersPrefix+testCluster] != "codex,deepseek" {
		t.Fatalf("stored: %q %q", settings[ClusterRegionPrefix+testCluster], settings[CredPodProvidersPrefix+testCluster])
	}
}
