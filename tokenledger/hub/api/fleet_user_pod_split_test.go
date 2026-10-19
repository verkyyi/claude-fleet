package api

import (
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

// claude-fleet#3562 (EPIC #3500 R1): one person, a second pod for some repos.

func TestUserPodSplitGrammar(t *testing.T) {
	for in, want := range map[string]string{
		"acme/web":                       "acme/web",
		" acme/web , acme/api ,ACME/WEB": "acme/web,acme/api",
		"verkyyi/claude-fleet":           "verkyyi/claude-fleet",
	} {
		if got, err := ParseUserPodSplit(in); err != nil || got != want {
			t.Errorf("ParseUserPodSplit(%q) = %q %v; want %q", in, got, err, want)
		}
	}
	for _, bad := range []string{"", " , ", "web", "acme/", "/web", "acme/../x", "a b/c", "acme/web;rm",
		"a/1,a/2,a/3,a/4,a/5,a/6,a/7,a/8,a/9"} {
		if got, err := ParseUserPodSplit(bad); err == nil {
			t.Errorf("ParseUserPodSplit(%q) = %q; want refused", bad, got)
		}
	}
	for _, c := range []struct {
		split, repo string
		ok          bool
	}{
		{"acme/web,acme/api", "acme/web", true},
		{"acme/web,acme/api", "api", true},
		{"acme/web", "acme/api", false},
		{"acme/web", "", false},
	} {
		if splitTakes(c.split, c.repo) != c.ok {
			t.Errorf("splitTakes(%q, %q) != %v", c.split, c.repo, c.ok)
		}
	}
	for _, c := range []struct{ login, repo, want string }{
		{"frank", "acme/web", "frank.web"},
		{"frank", "acme/My_Big.Repo", "frank.my-big-repo"},
		{"fleetu7", "acme/" + strings.Repeat("x", 40), "fleetu7." + strings.Repeat("x", 24)},
		{"frank", "acme/___", ""},
	} {
		if got := splitDoorName(c.login, c.repo); got != c.want || len(got) > 32 {
			t.Errorf("splitDoorName(%q, %q) = %q; want %q", c.login, c.repo, got, c.want)
		}
	}
}

// splitRig: frank's first pod and his second pod (for acme/web) in the
// cluster, both machines up, both hosting both repos.
func splitRig(t *testing.T) (h *harness, first, second string) {
	t.Helper()
	h = newFleetHarness(t)
	now := time.Now()
	p, err := h.srv.Store.AdoptPrincipal("gh:1005", "frank", "Frank", now)
	if err != nil {
		t.Fatal(err)
	}
	a1, err := h.srv.Store.CreateClusterPodFor(testCluster, p, now)
	if err != nil {
		t.Fatal(err)
	}
	a2, err := h.srv.Store.CreateClusterPodSplit(testCluster, p, "frank", "acme/web", now)
	if err != nil {
		t.Fatal(err)
	}
	first, second = a1.Hostname, a2.Hostname
	n1, n2 := connectWriteNode(t, h, first), connectWriteNode(t, h, second)
	f1 := fakeFleet(t, machineA, "fleet", writeRepo, "/home/frank/claude-fleet", 1)
	f2 := fakeFleet(t, machineB, "fleet", writeRepo, "/home/frank/claude-fleet", 2)
	f1.Repos = []string{writeRepo, "acme/web"}
	f2.Repos = []string{writeRepo, "acme/web"}
	// the second pod the busier one: preference, not load, must pick it
	n1.beatLoad(first, "frank", machineA, 1, 1, f1)
	n2.beatLoad(second, "frank", machineB, 5, 1, f2)
	waitFor(t, 3*time.Second, "both pods registered", func() bool {
		return len(getFleet(t, h, "/v1/fleet/fleet_list", 200)["fleets"].([]any)) == 2
	})
	waitLoad(t, h, second, 5)
	return h, first, second
}

// Placement: a listed repo lands on the second pod; anything else never does
// on auto — the reason names the list — and naming the pod still asks it.
func TestUserPodSplitPlacement(t *testing.T) {
	h, first, second := splitRig(t)
	if pl, err := h.srv.PickNode("", "acme/web"); err != nil || pl.Machine != second {
		t.Fatalf("acme/web: %q %v; want the second pod %s", pl.Machine, err, second)
	}
	pl, err := h.srv.PickNode("", writeRepo)
	if err != nil || pl.Machine != first {
		t.Fatalf("%s: %q %v; want the first pod %s", writeRepo, pl.Machine, err, first)
	}
	// naming the second pod for another repo still asks it
	if _, err := h.srv.pickNode(fleetPrincipal{Actor: "operator"}, writeRepo, second, "", time.Now()); err != nil {
		t.Fatalf("naming the second pod: %v; want it asked", err)
	}
	if err := h.srv.Store.SetClusterPodSplit(second, "acme/api", time.Now()); err != nil {
		t.Fatal(err)
	}
	pl, err = h.srv.PickNode("", "acme/web")
	if err != nil || pl.Machine != first || !strings.Contains(pl.Reason, excludedSplit+"acme/api") {
		t.Fatalf("acme/web off the list: %q %q %v; want %s, the second pod excluded for its list", pl.Machine, pl.Reason, err, first)
	}
}

// The door: <login>.<repo> routes to the second pod and logs in there as the
// login; the person's own name stays their first pod. A name two rows claim
// routes neither.
func TestUserPodSplitDoorRoutes(t *testing.T) {
	h := newFleetHarness(t)
	now := time.Now()
	p, err := h.srv.Store.AdoptPrincipal("gh:1005", "frank", "Frank", now)
	if err != nil {
		t.Fatal(err)
	}
	a1, _ := h.srv.Store.CreateClusterPodFor(testCluster, p, now)
	a2, err := h.srv.Store.CreateClusterPodSplit(testCluster, p, "frank", "acme/web,other/web,acme/api", now)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := h.srv.Store.SetEntryHome(store.EntryHome{Person: p.ID, Machine: a1.Hostname, Login: "frank", SetBy: "test", SetAt: now}); err != nil {
		t.Fatal(err)
	}
	// not yet live: the door has no second-pod row
	if l, err := h.srv.entryRouteList(); err != nil || len(l.Routes) != 1 || l.Routes[0].Service != a1.Hostname {
		t.Fatalf("before the second pod is up: %+v %v", l, err)
	}
	if ok, err := h.srv.Store.MarkAccountSent(p.ID, a2.Hostname, store.AccountPending, store.AccountCreating, "op-2", "ep-2", now); err != nil || !ok {
		t.Fatalf("mark sent: %v %v", ok, err)
	}
	if _, err := h.srv.Store.FinishAccountOp("op-2", "ep-2", store.AccountActive, "", now); err != nil {
		t.Fatal(err)
	}
	if err := h.srv.Store.SetClusterPodState(a2.Hostname, store.PodLive, "", now); err != nil {
		t.Fatal(err)
	}
	l, err := h.srv.entryRouteList()
	if err != nil {
		t.Fatal(err)
	}
	got := map[string]control.EntryRoute{}
	for _, r := range l.Routes {
		got[r.Login] = r
	}
	if r := got["frank"]; r.Service != a1.Hostname || r.PodLogin != "" {
		t.Fatalf("frank: %+v; want the first pod, his own name", r)
	}
	if r := got["frank.api"]; r.Service != a2.Hostname || r.PodLogin != "frank" || r.Principal != p.ID {
		t.Fatalf("frank.api: %+v; want the second pod as frank", r)
	}
	if _, ok := got["frank.web"]; ok {
		t.Fatalf("frank.web is two repos' name and was routed: %+v", l.Routes)
	}
	if _, ok := l.Logins["frank.api"]; !ok || len(l.Routes) != 2 {
		t.Fatalf("routes %+v logins %v; want frank and frank.api", l.Routes, l.Logins)
	}
}

// Made: the setting starts the second pod once the first one's login is
// ready, under the same login; the next pass makes no third; a changed list
// moves the row's.
func TestUserPodSplitStartsSecondPod(t *testing.T) {
	h, ops := podRig(t)
	setHubSetting(t, h.srv, SpareMaxPrefix+testCluster, "0")
	setHubSetting(t, h.srv, AutoAssignKey, testCluster)
	const jia = "gh:7001"
	h.srv.placePrincipal(jia, "Jia", jia)
	own := ops.expect(control.ClusterCreateUserPod) // no spare: a pod of their own
	ops.expect(control.ClusterBindUserPod)
	setHubSetting(t, h.srv, UserPodSplitPrefix+jia, "acme/web")
	// the first pod's login is not ready: nothing yet
	h.srv.replenishSpares(time.Now(), true)
	ops.quiet(300 * time.Millisecond)

	a := podAccount(t, h, own.Pod)
	if ok, err := h.srv.Store.MarkAccountSent(jia, own.Pod, a.State, store.AccountCreating, "op-1", "ep-1", time.Now()); err != nil || !ok {
		t.Fatalf("mark sent: %v %v", ok, err)
	}
	if _, err := h.srv.Store.FinishAccountOp("op-1", "ep-1", store.AccountActive, "", time.Now()); err != nil {
		t.Fatal(err)
	}
	h.srv.replenishSpares(time.Now(), true)
	second := ops.expect(control.ClusterCreateUserPod)
	if second.Pod == own.Pod || second.Login != own.Login {
		t.Fatalf("second pod's create = %+v; want a new pod under %s", second, own.Login)
	}
	if b := ops.expect(control.ClusterBindUserPod); b.Pod != second.Pod || b.Principal != "gh.7001" {
		t.Fatalf("bind = %+v; want %s labelled gh.7001", b, second.Pod)
	}
	row, err := h.srv.Store.ClusterPodOf(second.Pod)
	if err != nil || row.PrincipalID != jia || row.Split != "acme/web" {
		t.Fatalf("second pod's row = %+v %v", row, err)
	}
	if fr, _ := h.srv.Store.ClusterPodOf(own.Pod); fr.Split != "" {
		t.Fatalf("first pod's row = %+v; want no split", fr)
	}
	// once: no third pod; the first pod still counts as theirs
	h.srv.replenishSpares(time.Now(), true)
	ops.quiet(300 * time.Millisecond)
	if !h.srv.holdsClusterPod(jia, testCluster) {
		t.Fatal("holdsClusterPod forgot the first pod")
	}
	setHubSetting(t, h.srv, UserPodSplitPrefix+jia, "acme/web,acme/api")
	h.srv.replenishSpares(time.Now(), true)
	ops.quiet(300 * time.Millisecond)
	if row, _ := h.srv.Store.ClusterPodOf(second.Pod); row.Split != "acme/web,acme/api" {
		t.Fatalf("list moved to %q; want acme/web,acme/api", row.Split)
	}
}

// Off: no setting, no split row — no second pod, placement and the door as
// they were.
func TestUserPodSplitOffAddsNothing(t *testing.T) {
	h, ops := podRig(t)
	setHubSetting(t, h.srv, SpareMaxPrefix+testCluster, "0")
	h.srv.replenishSpares(time.Now(), true)
	ops.quiet(300 * time.Millisecond)
	if len(h.srv.splitPods()) != 0 || len(h.srv.splitRoutes()) != 0 {
		t.Fatal("split pods or routes with nothing set")
	}
	if pods, _ := h.srv.Store.ClusterPods(""); len(pods) != 0 {
		t.Fatalf("pods recorded: %+v", pods)
	}
}
