package api

import (
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

// claude-fleet#4174: once stable moves, a person's pod still on an older
// runtime is rolled onto the cluster's new image — a few at a time, a batch
// every podRollEvery, never one with a session working or asking, once per
// release, and a failed one asked again later without holding back the rest.

var (
	rollOld    = strings.Repeat("b", 40)
	rollStable = strings.Repeat("a", 40)
)

// rollRig is podRig with spares off (no create tickets in the way), n pods in
// the cluster and the seams: stable is *stable, each pod's runtime runtimes[pod].
func rollRig(t *testing.T, n int) (*harness, *fakeOps, []string, map[string]podRuntime, *string) {
	t.Helper()
	h, ops := podRig(t)
	setHubSetting(t, h.srv, SparesKey, "off")
	var pods []string
	for i := 0; i < n; i++ {
		a, err := h.srv.Store.CreateClusterSpare(testCluster, func(string) bool { return true }, time.Now())
		if err != nil {
			t.Fatal(err)
		}
		pods = append(pods, strings.ToLower(a.Hostname))
	}
	sort.Strings(pods)
	stable := rollStable
	rts := map[string]podRuntime{}
	h.srv.podRollStable = func() string { return stable }
	h.srv.podRollRuntimes = func(time.Time) map[string]podRuntime {
		out := map[string]podRuntime{}
		for k, v := range rts {
			out[k] = podRuntime{SHA: v.SHA, At: time.Now()}
		}
		return out
	}
	return h, ops, pods, rts, &stable
}

// sessionOn records one fleet on pod whose one window is in state.
func sessionOn(t *testing.T, h *harness, pod, state string) {
	t.Helper()
	if _, err := h.srv.Store.RecordFleetSnapshot("ep-"+pod, pod, "fleetu1", "m-"+pod, []store.FleetReport{{
		FleetID: "f-" + pod, Name: "fleet", State: "ok", WorkerCount: 1,
		WorkersJSON: `[{"key":"issue-1","state":"` + state + `"}]`}}, time.Now()); err != nil {
		t.Fatal(err)
	}
}

func rolled(t *testing.T, ops *fakeOps, n int) []string {
	t.Helper()
	var got []string
	for i := 0; i < n; i++ {
		got = append(got, ops.expect(control.ClusterRollUserPod).Pod)
	}
	sort.Strings(got)
	return got
}

func TestUserPodRollBatchesSkipsBusyOncePerRelease(t *testing.T) {
	h, ops, pods, rts, stable := rollRig(t, 5)
	// pods[0..2] old and idle, pods[3] old with a session working, pods[4] on stable
	for _, p := range pods[:4] {
		rts[p] = podRuntime{SHA: rollOld}
	}
	rts[pods[4]] = podRuntime{SHA: rollStable}
	sessionOn(t, h, pods[3], "working")

	now := time.Now()
	if got := h.srv.PodRollTick(now, true); strings.Join(got, ",") != strings.Join(pods[:2], ",") {
		t.Fatalf("first batch = %v; want %v (batch 2, in name order)", got, pods[:2])
	}
	if got := rolled(t, ops, 2); strings.Join(got, ",") != strings.Join(pods[:2], ",") {
		t.Fatalf("tickets = %v", got)
	}
	// the next batch waits podRollEvery
	if got := h.srv.PodRollTick(now.Add(time.Minute), false); got != nil {
		t.Fatalf("a batch inside podRollEvery: %v", got)
	}
	if got := h.srv.PodRollTick(now.Add(podRollEvery), false); len(got) != 1 || got[0] != pods[2] {
		t.Fatalf("second batch = %v; want [%s]", got, pods[2])
	}
	ops.expect(control.ClusterRollUserPod)
	// the busy pod is left; one on stable is never asked; nothing twice for one release
	if got := h.srv.PodRollTick(now.Add(3*podRollEvery), true); got != nil {
		t.Fatalf("asked again: %v", got)
	}
	ops.quiet(200 * time.Millisecond)
	// a pod waiting on its person is still busy; once idle it rolls
	sessionOn(t, h, pods[3], "needs_ask")
	if got := h.srv.PodRollTick(now, true); got != nil {
		t.Fatalf("a pod asking its person was rolled: %v", got)
	}
	sessionOn(t, h, pods[3], "done")
	if got := h.srv.PodRollTick(now, true); len(got) != 1 || got[0] != pods[3] {
		t.Fatalf("the idle pod = %v", got)
	}
	ops.expect(control.ClusterRollUserPod)
	// a new stable: the old ones are asked again (their runtimes did not move)
	*stable = strings.Repeat("c", 40)
	if got := h.srv.PodRollTick(now, true); len(got) != 2 {
		t.Fatalf("after a new stable: %v", got)
	}
	rolled(t, ops, 2)
	// the node page says it
	v := h.srv.podRollFor(pods[0], rollOld, now)
	if v == nil || v.Stable != *stable || v.Last == nil || !v.Last.Done || v.Last.Stable != *stable {
		t.Fatalf("podRollFor = %+v", v)
	}
	if h.srv.podRollFor("mac-a", rollOld, now) != nil {
		t.Fatal("a machine that is not a pod has a roll view")
	}
}

func TestUserPodRollFailureRetriesAlone(t *testing.T) {
	h, ops, pods, rts, _ := rollRig(t, 2)
	for _, p := range pods {
		rts[p] = podRuntime{SHA: rollOld}
	}
	ops.mu.Lock()
	ops.rc = 1
	ops.mu.Unlock()
	now := time.Now()
	// both asked although the first fails: one failure holds back nobody
	if got := h.srv.PodRollTick(now, true); len(got) != 2 {
		t.Fatalf("asked %v; want both", got)
	}
	rolled(t, ops, 2)
	if v := h.srv.podRollFor(pods[0], rollOld, now); v.Last == nil || v.Last.Done || v.Last.Result == "" {
		t.Fatalf("the failure is not recorded: %+v", v.Last)
	}
	if got := h.srv.PodRollTick(now, true); got != nil {
		t.Fatalf("a failed roll asked again inside podRollRetry: %v", got)
	}
	old := podRollRetry
	podRollRetry = 0
	defer func() { podRollRetry = old }()
	ops.mu.Lock()
	ops.rc = 0
	ops.mu.Unlock()
	if got := h.srv.PodRollTick(now, true); len(got) != 2 {
		t.Fatalf("retry asked %v", got)
	}
	rolled(t, ops, 2)
}

func TestUserPodRollOffAddsNothing(t *testing.T) {
	for _, c := range []struct {
		name string
		set  func(h *harness, stable *string, rts map[string]podRuntime)
	}{
		{"setting off", func(h *harness, _ *string, _ map[string]podRuntime) { setHubSetting(t, h.srv, UserPodRollKey, "off") }},
		{"no clusters", func(h *harness, _ *string, _ map[string]podRuntime) { setHubSetting(t, h.srv, ClustersKey, "") }},
		{"no account key", func(h *harness, _ *string, _ map[string]podRuntime) { h.srv.SetAccountKey(nil) }},
		{"no stable", func(_ *harness, s *string, _ map[string]podRuntime) { *s = "" }},
		{"runtime unknown", func(_ *harness, _ *string, rts map[string]podRuntime) {
			for k := range rts {
				delete(rts, k)
			}
		}},
	} {
		t.Run(c.name, func(t *testing.T) {
			h, ops, pods, rts, stable := rollRig(t, 1)
			rts[pods[0]] = podRuntime{SHA: rollOld}
			c.set(h, stable, rts)
			if got := h.srv.PodRollTick(time.Now(), true); got != nil {
				t.Fatalf("asked %v", got)
			}
			ops.quiet(200 * time.Millisecond)
		})
	}
}

func TestReleasesBehind(t *testing.T) {
	h := newFleetHarness(t)
	t0 := time.Now().Add(-time.Hour)
	shas := []string{strings.Repeat("1", 40), strings.Repeat("2", 40), strings.Repeat("3", 40), strings.Repeat("4", 40)}
	for i, sha := range shas {
		if _, err := h.srv.Store.RecordReleaseTrain(store.ReleaseTrain{SHA: sha, RunID: "r", PublishedAt: t0.Add(time.Duration(i) * time.Minute), Train: "{}", Machines: "[]"}); err != nil {
			t.Fatal(err)
		}
	}
	now := time.Now()
	for _, c := range []struct {
		runtime, stable string
		want            int
		ok              bool
	}{
		{shas[0], shas[3], 3, true},
		{shas[2], shas[3], 1, true},
		{shas[3], shas[3], 0, true},
		{strings.Repeat("9", 40), shas[3], -1, true},
		{"", shas[3], 0, false},
	} {
		if n, ok := h.srv.releasesBehind(c.runtime, c.stable, now); n != c.want || ok != c.ok {
			t.Errorf("releasesBehind(%.4s, %.4s) = %d %v; want %d %v", c.runtime, c.stable, n, ok, c.want, c.ok)
		}
	}
}
