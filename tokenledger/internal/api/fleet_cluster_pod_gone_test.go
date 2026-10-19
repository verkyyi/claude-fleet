package api

import (
	"context"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/coder/websocket/wsjson"

	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

// A cluster pod that is gone takes its machine off the hub (claude-fleet#4887).

type podGoneFixture struct {
	h     *harness
	t0    time.Time
	mu    sync.Mutex
	notes []string
}

func newPodGoneFixture(t *testing.T) *podGoneFixture {
	t.Helper()
	f := &podGoneFixture{h: newFleetHarness(t), t0: time.Now().Add(-2 * time.Hour)}
	f.h.srv.Notify = func(m string) { f.mu.Lock(); f.notes = append(f.notes, m); f.mu.Unlock() }
	return f
}

// node puts endpoint ep_<label> on the roster as (host, login), last heard at.
func (f *podGoneFixture) node(t *testing.T, label, host, login string, at time.Time) string {
	t.Helper()
	f.h.enroll(t, label)
	id := "ep_" + label
	must(t, f.h.srv.Store.NodeConnected(id, host, login, "test", control.Proto, 5000, at))
	must(t, f.h.srv.Store.NodeHeartbeat(id, host, login, "", control.Proto, `{}`, at))
	return id
}

// list sends cluster's list every 4 minutes from start through end.
func (f *podGoneFixture) list(cluster string, present []string, start, end time.Time) []podGoneRetired {
	var out []podGoneRetired
	for at := start; !at.After(end); at = at.Add(4 * time.Minute) {
		out = append(out, f.h.srv.observeClusterPods(cluster, present, at)...)
	}
	return out
}

func (f *podGoneFixture) onRoster(t *testing.T, id string) bool {
	t.Helper()
	rows, err := f.h.srv.Store.Nodes()
	must(t, err)
	for _, n := range rows {
		if n.EndpointID == id {
			return true
		}
	}
	return false
}

// Scaled to 0 past the grace ⇒ retired (system, the operator told); back
// within the grace ⇒ untouched; a machine that is not a pod, another
// cluster's pod and a pod still heard from ⇒ never.
func TestClusterPodGoneRetires(t *testing.T) {
	f := newPodGoneFixture(t)
	ok := func(string) bool { return true }
	gone, err := f.h.srv.Store.CreateClusterSpare("ack", ok, f.t0)
	must(t, err)
	back, err := f.h.srv.Store.CreateClusterSpare("ack", ok, f.t0)
	must(t, err)
	heard, err := f.h.srv.Store.CreateClusterSpare("ack", ok, f.t0)
	must(t, err)
	other, err := f.h.srv.Store.CreateClusterSpare("other", ok, f.t0)
	must(t, err)

	now := time.Now()
	epGone := f.node(t, "gone", gone.Hostname, "fleetu1", f.t0)
	epBack := f.node(t, "back", back.Hostname, "fleetu2", f.t0)
	epHeard := f.node(t, "heard", heard.Hostname, "fleetu3", now.Add(20*time.Minute)) // heard during the watch
	epOther := f.node(t, "other", other.Hostname, "fleetu4", f.t0)
	epMini := f.node(t, "mini", "mac-mini.local", "verky", f.t0)

	// 20 minutes missing, then «back» stands again: its clock is dropped.
	f.list("ack", nil, now, now.Add(20*time.Minute))
	f.list("ack", []string{back.Hostname}, now.Add(24*time.Minute), now.Add(24*time.Minute))
	if len(f.notes) != 0 {
		t.Fatalf("retired inside the grace: %v", f.notes)
	}
	// Past 30 minutes since «gone» went missing: retired, «back» is not
	// (missing only 4 minutes again), «heard» was heard, the rest are not
	// this cluster's pods.
	got := f.list("ack", nil, now.Add(28*time.Minute), now.Add(36*time.Minute))
	if len(got) != 1 || got[0].Pod != gone.Hostname || !strings.Contains(got[0].Endpoints[0], "fleetu1") {
		t.Fatalf("retired = %+v; want only %s", got, gone.Hostname)
	}
	if f.onRoster(t, epGone) {
		t.Fatal("the gone pod's endpoint is still on the roster")
	}
	for _, id := range []string{epBack, epHeard, epOther, epMini} {
		if !f.onRoster(t, id) {
			t.Fatalf("%s was retired", id)
		}
	}
	if len(f.notes) != 1 || !strings.Contains(f.notes[0], gone.Hostname) || !strings.Contains(f.notes[0], "fleetu1") {
		t.Fatalf("notes = %v; want one naming the pod and its login", f.notes)
	}
	audit, err := f.h.srv.Store.FleetAuditLog(20)
	must(t, err)
	found := false
	for _, a := range audit {
		if a.Action == "node_revoke" && a.FleetID == "endpoint:"+epGone && a.Actor == "system" {
			found = true
		}
	}
	if !found {
		t.Fatalf("no system node_revoke for %s in %+v", epGone, audit)
	}
	if _, err := f.h.srv.Store.EndpointByTokenHash(HashToken(f.h.tokens["gone"])); err == nil {
		t.Fatal("the gone pod's token still works")
	}

	// Long after: still nothing else is retired (the mini never, the other
	// cluster's pod never by ack's list).
	f.list("ack", []string{back.Hostname, heard.Hostname}, now.Add(40*time.Minute), now.Add(3*time.Hour))
	if !f.onRoster(t, epMini) || !f.onRoster(t, epOther) || len(f.notes) != 1 {
		t.Fatalf("retired more: notes %v", f.notes)
	}
}

// A pod the hub never made is retired only while its cluster is the only one
// listing; a fleet-ops that went quiet longer than podGoneGap restarts the clock.
func TestClusterPodGoneHandMadeAndGaps(t *testing.T) {
	f := newPodGoneFixture(t)
	now := time.Now()
	ep := f.node(t, "hand", "u-handmade1", "arvin", f.t0)

	// Another cluster lists too: a hand-made pod could be its.
	for at := now; !at.After(now.Add(40 * time.Minute)); at = at.Add(4 * time.Minute) {
		f.h.srv.observeClusterPods("other", nil, at)
		f.h.srv.observeClusterPods("ack", nil, at.Add(time.Minute))
	}
	if !f.onRoster(t, ep) {
		t.Fatal("hand-made pod retired while two clusters list")
	}

	// A gap: ack silent 10 minutes ⇒ the clock starts again.
	start := now.Add(3 * time.Hour) // «other» long quiet: ack is the only one
	f.list("ack", nil, start, start.Add(20*time.Minute))
	f.list("ack", nil, start.Add(31*time.Minute), start.Add(47*time.Minute))
	if !f.onRoster(t, ep) {
		t.Fatal("retired across a gap in the lists")
	}
	f.list("ack", nil, start.Add(51*time.Minute), start.Add(63*time.Minute))
	if f.onRoster(t, ep) {
		t.Fatal("hand-made pod missing 32 min, ack the only cluster: not retired")
	}
}

// TestClusterPodGoneOffAddsNothing: the setting off, or no list from fleet-ops
// (an older one) ⇒ nothing is retired.
func TestClusterPodGoneOffAddsNothing(t *testing.T) {
	f := newPodGoneFixture(t)
	sp, err := f.h.srv.Store.CreateClusterSpare("ack", func(string) bool { return true }, f.t0)
	must(t, err)
	ep := f.node(t, "p", sp.Hostname, "fleetu1", f.t0)
	must(t, f.h.srv.Store.SetFleetSetting(ClusterPodRetireKey, "off", time.Now()))
	now := time.Now()
	f.list("ack", nil, now, now.Add(2*time.Hour))
	if !f.onRoster(t, ep) || len(f.notes) != 0 {
		t.Fatal("retired with fleet.cluster_pod_retire off")
	}
	must(t, f.h.srv.Store.SetFleetSetting(ClusterPodRetireKey, "on", time.Now()))

	// Over the wire: readings with no list start no clock; a listed one does.
	ops := teamNode(t, f.h, f.h.enroll(t, "ops"), control.CapClusterOps)
	beat(t, ops, control.Proto, control.Heartbeat{Hostname: "bck", OSUser: "fleet-ops"})
	write := func(cr control.ClusterReadings) {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		m, _ := control.New(control.TypeClusterReadings, cr)
		must(t, wsjson.Write(ctx, ops, m))
	}
	listed := func() bool {
		f.h.srv.podGone.mu.Lock()
		defer f.h.srv.podGone.mu.Unlock()
		_, ok := f.h.srv.podGone.lastListed["bck"]
		return ok
	}
	write(control.ClusterReadings{})
	time.Sleep(300 * time.Millisecond)
	if listed() {
		t.Fatal("an older fleet-ops' readings (no list) were taken as a list")
	}
	write(control.ClusterReadings{Listed: true, Present: []string{}})
	waitFor(t, 5*time.Second, "the list observed", listed)
	if !f.onRoster(t, ep) {
		t.Fatal("one list retired a pod")
	}
}
