package api

import (
	"context"
	"crypto/ed25519"
	"encoding/json"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/coder/websocket/wsjson"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// claude-fleet#3553 (EPIC #3500 C8): a cluster keeps spare pods. The hub
// starts them through the cluster's ops link with signed tickets, a pod is
// ready when its own node opened its login separated (or central), a newcomer
// is bound to the oldest ready one in a database write, and a remove destroys
// the pod and starts a fresh one. Everything here runs against a fake
// fleet-ops that verifies each ticket and answers like the provisioner.

const testCluster = "ack-sz"

// fakeOps is a cluster's fleet-ops on the control channel, with the
// provisioner behind it: every ticket verified with the hub's key, recorded,
// and answered rc (0 unless set).
type fakeOps struct {
	t    *testing.T
	n    *fleetNode
	pub  ed25519.PublicKey
	mu   sync.Mutex
	rc   int
	got  chan control.ClusterTicket
	seen []control.ClusterTicket
}

func startFakeOps(t *testing.T, h *harness, pub ed25519.PublicKey) *fakeOps {
	t.Helper()
	n := connectCaps(t, h, "ops", testCluster, "fleetops", false, control.CapClusterOps)
	f := &fakeOps{t: t, n: n, pub: pub, got: make(chan control.ClusterTicket, 32)}
	go func() {
		for m := range n.in {
			if m.Type != control.TypeClusterOp {
				continue
			}
			var op control.ClusterOp
			_ = json.Unmarshal(m.Payload, &op)
			res := control.ClusterOpResult{RC: 3, Line: "refused: not the hub's"}
			tk, err := control.VerifyClusterTicket(f.pub, op.Ticket, time.Now())
			if err == nil && tk.Cluster == testCluster {
				f.mu.Lock()
				res = control.ClusterOpResult{RC: f.rc, Line: tk.Op + " " + tk.Pod + ": done"}
				f.seen = append(f.seen, tk)
				f.mu.Unlock()
				f.got <- tk
			}
			out, _ := control.New(control.TypeClusterOpResult, res)
			out.OpID = m.OpID
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			_ = wsjson.Write(ctx, n.c, out)
			cancel()
		}
	}()
	waitFor(t, 3*time.Second, "the ops link named", func() bool {
		_, c := h.srv.nodes.opsFor(testCluster)
		return c != nil
	})
	return f
}

// expect is the next ticket of op.
func (f *fakeOps) expect(op string) control.ClusterTicket {
	f.t.Helper()
	select {
	case tk := <-f.got:
		if tk.Op != op {
			f.t.Fatalf("ticket = %+v; want %s", tk, op)
		}
		return tk
	case <-time.After(5 * time.Second):
		f.t.Fatalf("no %s ticket", op)
	}
	return control.ClusterTicket{}
}

// quiet says no ticket arrives within d.
func (f *fakeOps) quiet(d time.Duration) {
	f.t.Helper()
	select {
	case tk := <-f.got:
		f.t.Fatalf("unexpected ticket %+v", tk)
	case <-time.After(d):
	}
}

// podRig is a hub with spares on, the account key armed, the cluster named and
// its ops link up.
func podRig(t *testing.T) (*harness, *fakeOps) {
	t.Helper()
	h := newFleetHarness(t)
	enablePeople(t, h)
	pub, key, _ := ed25519.GenerateKey(nil)
	h.srv.SetAccountKey(key)
	ops := startFakeOps(t, h, pub)
	setHubSetting(t, h.srv, SparesKey, "on")
	setHubSetting(t, h.srv, ClustersKey, testCluster)
	return h, ops
}

// bootPod is a spare pod's own node coming up with its join code: its machine
// link (CapUserPod) is sent its login's create, answered with credsep.
func bootPod(t *testing.T, h *harness, tk control.ClusterTicket, credsep string) string {
	t.Helper()
	if !strings.HasPrefix(tk.Join, "fj_") || !isUserPodName(tk.Pod) {
		t.Fatalf("create ticket %+v: want a pod name and its join code", tk)
	}
	// the pod is built for its one login, never root (claude-fleet#3757)
	if !strings.HasPrefix(tk.Login, "fleetu") || tk.UID != control.PodLoginUID {
		t.Fatalf("create ticket %+v: want the spare's fleetu<N> as uid %d", tk, control.PodLoginUID)
	}
	h.enroll(t, tk.Pod)
	identify(t, h, tk.Pod, tk.Pod, "root")
	pod := dialMachineCaps(t, h, h.tokens[tk.Pod], control.CapLoginJoin, control.CapUserPod)
	pod.beat("", control.Heartbeat{OS: "linux", Hostname: tk.Pod, OSUser: "root", NCPU: 2, ObservedAt: time.Now()})
	waitFor(t, 3*time.Second, tk.Pod+"'s opener", func() bool {
		_, ok := h.srv.nodes.openerFor(tk.Pod)
		return ok
	})
	h.srv.dispatchAccounts()
	m, op := expectAccountOp(t, &tnode{in: pod.inbox("")})
	if op.Op != control.AccountCreate || !strings.HasPrefix(op.Login, "fleetu") || op.FullName != store.SpareFullName {
		t.Fatalf("%s was sent %+v; want its spare login's create", tk.Pod, op)
	}
	res, _ := control.New(control.TypeAccountResult, control.AccountResult{Op: control.AccountCreate, Login: op.Login,
		OK: true, Credsep: credsep})
	res.OpID = m.OpID
	pod.send("", res)
	return op.Login
}

func podAccount(t *testing.T, h *harness, pod string) *store.FleetAccount {
	t.Helper()
	all, err := h.srv.Store.FleetAccounts("")
	if err != nil {
		t.Fatal(err)
	}
	for i := range all {
		if all[i].Hostname == pod {
			return &all[i]
		}
	}
	return nil
}

func waitPodState(t *testing.T, h *harness, pod, state string) {
	t.Helper()
	waitFor(t, 5*time.Second, pod+" "+state, func() bool {
		p, err := h.srv.Store.ClusterPodOf(pod)
		return err == nil && p.State == state
	})
}

func waitAccount(t *testing.T, h *harness, pod, state string) {
	t.Helper()
	waitFor(t, 5*time.Second, pod+"'s login "+state, func() bool {
		a := podAccount(t, h, pod)
		return a != nil && a.State == state
	})
}

func audits(t *testing.T, h *harness, action string) []store.HubAuditEntry {
	t.Helper()
	log, err := h.srv.Store.HubAuditLog(200)
	if err != nil {
		t.Fatal(err)
	}
	var out []store.HubAuditEntry
	for _, e := range log {
		if e.Action == action {
			out = append(out, e)
		}
	}
	return out
}

// 怎么算成功: two pods kept ready; a newcomer is handed one in well under 10
// seconds (a write, no pod start), the pool refills; removing them destroys
// that pod (the hub's half of them gone first) and starts a NEW one; the next
// person is handed a different pod, never theirs.
func TestSparePodClaimDestroyRefill(t *testing.T) {
	h, ops := podRig(t)
	h.srv.replenishSpares(time.Now(), true)
	a1, a2 := ops.expect(control.ClusterCreateUserPod), ops.expect(control.ClusterCreateUserPod)
	ops.quiet(200 * time.Millisecond)
	if a1.Pod == a2.Pod || a1.Join == a2.Join {
		t.Fatalf("two creates share a pod or a join code: %+v %+v", a1, a2)
	}
	waitPodState(t, h, a1.Pod, store.PodLive)
	// Not ready until its own node opened the login: nobody is handed it.
	if pic, _ := h.srv.clusterPicture(testCluster); len(pic.ready) != 0 || len(pic.spares) != 2 {
		t.Fatalf("before any login: ready %d spares %d; want 0 / 2", len(pic.ready), len(pic.spares))
	}
	bootPod(t, h, a1, control.CredsepCentral)
	bootPod(t, h, a2, control.CredsepSeparated)
	waitAccount(t, h, a1.Pod, store.AccountActive)
	waitAccount(t, h, a2.Pod, store.AccountActive)

	// 甲 signs in, placed on the cluster.
	setHubSetting(t, h.srv, AutoAssignKey, testCluster)
	const jia, yi = "gh:7001", "gh:7002"
	t0 := time.Now()
	h.srv.placePrincipal(jia, "Jia", jia)
	took := time.Since(t0)
	as, _ := h.srv.Store.FleetAccounts(jia)
	if len(as) != 1 || as[0].State != store.AccountActive || (as[0].Hostname != a1.Pod && as[0].Hostname != a2.Pod) {
		t.Fatalf("甲's accounts = %+v; want one of the ready pods, active", as)
	}
	if took > 10*time.Second {
		t.Fatalf("the claim took %s; want ≤ 10s", took)
	}
	podJia := as[0].Hostname
	if p, _ := h.srv.Store.ClusterPodOf(podJia); p.PrincipalID != jia || p.ClaimedAt == nil {
		t.Fatalf("pod row = %+v; want 甲's", p)
	}
	if home, ok, _ := h.srv.Store.EntryHomeOf(jia); !ok || home.Machine != podJia || home.Login != as[0].Login {
		t.Fatalf("甲's 家 = %+v %v; want %s/%s", home, ok, podJia, as[0].Login)
	}
	if c := audits(t, h, "spare.claim"); len(c) != 1 || c[0].Target != as[0].Login {
		t.Fatalf("spare.claim audit = %+v", c)
	}
	// The bind ticket (label) and one refill, in either order.
	got := map[string]control.ClusterTicket{}
	for i := 0; i < 2; i++ {
		select {
		case tk := <-ops.got:
			got[tk.Op] = tk
		case <-time.After(5 * time.Second):
			t.Fatalf("after the claim: got %v; want a bind and a refill", got)
		}
	}
	if b := got[control.ClusterBindUserPod]; b.Pod != podJia || b.Principal != "gh.7001" {
		t.Fatalf("bind = %+v; want %s labelled gh.7001", b, podJia)
	}
	refill := got[control.ClusterCreateUserPod]
	if refill.Pod == "" || refill.Pod == a1.Pod || refill.Pod == a2.Pod {
		t.Fatalf("refill = %+v; want a new pod", refill)
	}
	bootPod(t, h, refill, control.CredsepCentral)
	waitAccount(t, h, refill.Pod, store.AccountActive)

	// The operator removes 甲: the pod is destroyed, never washed.
	if code := operatorPost(t, h, FleetAccountRequest{Action: "remove", PrincipalID: jia, Hostname: podJia}); code != 200 {
		t.Fatalf("remove: HTTP %d", code)
	}
	h.srv.dispatchAccounts()
	if d := ops.expect(control.ClusterDestroyUserPod); d.Pod != podJia {
		t.Fatalf("destroy = %+v; want %s", d, podJia)
	}
	waitPodState(t, h, podJia, store.PodGone)
	waitAccount(t, h, podJia, store.AccountRemoved)
	if _, ok, _ := h.srv.Store.EntryHomeOf(jia); ok {
		t.Fatal("甲's 家 still names the destroyed pod")
	}
	waitFor(t, 3*time.Second, "spare.destroy audited", func() bool {
		d := audits(t, h, "spare.destroy")
		return len(d) == 1 && d[0].Outcome == "ok" && strings.Contains(d[0].Detail, podJia)
	})
	// The pool was refilled at the claim: still two ready, none of them 甲's.
	ops.quiet(300 * time.Millisecond)
	if pic, _ := h.srv.clusterPicture(testCluster); len(pic.ready) != 2 || pic.used != 0 {
		t.Fatalf("after the destroy: ready %d used %d; want 2 / 0", len(pic.ready), pic.used)
	}

	// 乙 is handed a ready pod — never 甲's.
	h.srv.placePrincipal(yi, "Yi", yi)
	bs, _ := h.srv.Store.FleetAccounts(yi)
	if len(bs) != 1 || bs[0].State != store.AccountActive || bs[0].Hostname == podJia {
		t.Fatalf("乙's accounts = %+v; want an active pod other than %s", bs, podJia)
	}
	if c := audits(t, h, "spare.claim"); len(c) != 2 {
		t.Fatalf("spare.claim audits = %d; want 2", len(c))
	}
}

// A spare whose login came back neither separated nor central is never handed
// out: it fails, its pod is destroyed, and the cluster gets no more until the
// operator forgets it.
func TestSparePodUnseparatedIsDestroyed(t *testing.T) {
	h, ops := podRig(t)
	setHubSetting(t, h.srv, SpareMaxPrefix+testCluster, "1")
	h.srv.replenishSpares(time.Now(), true)
	tk := ops.expect(control.ClusterCreateUserPod)
	waitPodState(t, h, tk.Pod, store.PodLive)
	bootPod(t, h, tk, "unseparated")
	waitAccount(t, h, tk.Pod, store.AccountFailed)
	h.srv.replenishSpares(time.Now(), true)
	if d := ops.expect(control.ClusterDestroyUserPod); d.Pod != tk.Pod {
		t.Fatalf("destroy = %+v; want %s", d, tk.Pod)
	}
	waitPodState(t, h, tk.Pod, store.PodGone)
	h.srv.replenishSpares(time.Now(), true)
	ops.quiet(300 * time.Millisecond)
	setHubSetting(t, h.srv, AutoAssignKey, testCluster)
	h.srv.placePrincipal("gh:7003", "Bing", "gh:7003")
	// No ready spare: a pod of their own, under their own name.
	own := ops.expect(control.ClusterCreateUserPod)
	if a := podAccount(t, h, own.Pod); a == nil || a.PrincipalID != "gh:7003" || a.State != store.AccountPending {
		t.Fatalf("own pod's account = %+v; want 丙's, pending", a)
	}
}

// A spare pod that never gets ready in time is failed and destroyed.
func TestSparePodNotReadyInTimeIsDestroyed(t *testing.T) {
	h, ops := podRig(t)
	setHubSetting(t, h.srv, SpareMaxPrefix+testCluster, "1")
	h.srv.replenishSpares(time.Now(), true)
	tk := ops.expect(control.ClusterCreateUserPod)
	waitPodState(t, h, tk.Pod, store.PodLive)
	h.srv.replenishSpares(time.Now().Add(clusterPodJoinWait+time.Minute), true)
	if d := ops.expect(control.ClusterDestroyUserPod); d.Pod != tk.Pod {
		t.Fatalf("destroy = %+v; want %s", d, tk.Pod)
	}
	waitAccount(t, h, tk.Pod, store.AccountFailed)
}

// Off — spares off, no fleet.clusters, or no account key — nothing is made,
// claimed or sent, and placement on the cluster's name is what it was.
func TestSparePodsOffAddsNothing(t *testing.T) {
	for _, c := range []struct {
		name string
		set  func(h *harness)
	}{
		{"spares off", func(h *harness) { setHubSetting(t, h.srv, SparesKey, "off") }},
		{"no clusters", func(h *harness) { setHubSetting(t, h.srv, ClustersKey, "") }},
		{"no account key", func(h *harness) { h.srv.SetAccountKey(nil) }},
	} {
		t.Run(c.name, func(t *testing.T) {
			h, ops := podRig(t)
			c.set(h)
			h.srv.replenishSpares(time.Now(), true)
			h.srv.claimSpareOn("gh:7009", "", "gh:7009", testCluster, time.Now())
			ops.quiet(300 * time.Millisecond)
			if pods, _ := h.srv.Store.ClusterPods(""); len(pods) != 0 {
				t.Fatalf("pods recorded: %+v", pods)
			}
		})
	}
}

// fleet.clusters and fleet.spare_max.<cluster> are checked settings.
func TestSparePodSettings(t *testing.T) {
	h := newFleetHarness(t)
	for v, ok := range map[string]bool{"ack-sz": true, "ack-sz, ack-bj": true, "u-abcd": false, "Ack_SZ": false, "": true} {
		_, why := checkClusters(h.srv, v)
		if (why == "") != ok && v != "" {
			t.Errorf("checkClusters(%q) = %q; want ok=%v", v, why, ok)
		}
	}
	putSetting(t, h, SpareMaxPrefix+testCluster, "3", 200)
	putSetting(t, h, SpareMaxPrefix+testCluster, "99", 400)
	set, _ := h.srv.Store.FleetSettings()
	if got := h.srv.clusterSpareMax(testCluster, set); got != 3 {
		t.Fatalf("clusterSpareMax = %d; want 3", got)
	}
	if got := h.srv.clusterSpareMax("other", set); got != defaultSpareMax {
		t.Fatalf("another cluster = %d; want fleet.spare_max's default", got)
	}
	for in, want := range map[string]string{"gh:12345": "gh.12345", "drill1": "drill1", ":::": ""} {
		if got := podLabel(in); got != want {
			t.Errorf("podLabel(%q) = %q; want %q", in, got, want)
		}
	}
}
