package api

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"net/http"
	"net/http/httptest"
	"net/http/httputil"
	"net/url"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/agent"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
)

// An SSH relay with two hub replicas (claude-fleet#2151, EPIC #2119 C8).

// startSSHRelayAgentAt is startSSHRelayAgent for an agent that dials hubURL —
// a replica, or a front that splits its requests between them — and whose
// link holder is holder.
func startSSHRelayAgentAt(t *testing.T, enrollOn, holder *harness, hubURL, label, sshd string) string {
	t.Helper()
	agent.SetSSHRelayTargetForTest(sshd)
	t.Cleanup(func() { agent.SetSSHRelayTargetForTest("") })
	home := t.TempDir()
	a, err := agent.New(agent.Config{
		HubURL: hubURL, Token: enrollOn.enroll(t, label), Home: home,
		StateDir: filepath.Join(home, "state"), SessionsDir: filepath.Join(home, "sessions"),
		Sources: "claude", LiveInterval: 200 * time.Millisecond, ScanInterval: time.Hour, LimitsInterval: time.Hour,
		Fleet: true, FleetSSHRelay: true, Version: "it-" + label,
	})
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { a.Run(ctx); close(done) }()
	t.Cleanup(func() { cancel(); <-done })
	host, _ := os.Hostname()
	waitFor(t, 5*time.Second, "agent connected", func() bool {
		c := holder.srv.nodes.get("ep_" + label)
		return c != nil && c.hostname() == host
	})
	waitFor(t, 5*time.Second, "its link recorded", func() bool { return holderOf(holder, "ep_"+label) })
	return host
}

func holderOf(h *harness, endpoint string) bool {
	c, ok, err := h.srv.Store.NodeConnOf(endpoint)
	return err == nil && ok && c.Replica == h.srv.Replica.Name
}

// relayDigest runs n random bytes through an SSH login over conn's relay and
// checks the digest the machine computed: both directions carried the stream.
func relayDigest(t *testing.T, h *harness, host string, n int) {
	t.Helper()
	conn, code := sshRelayDial(t, h, host, asOperator, nil)
	if conn == nil {
		t.Fatalf("relay through %s refused: %s", h.srv.Replica.Name, code)
	}
	cl := sshOver(t, conn)
	defer cl.Close()
	sess := mustSession(t, cl)
	data := make([]byte, n)
	rand.Read(data)
	sum := sha256.Sum256(data)
	sess.Stdin = bytes.NewReader(data)
	out, err := sess.Output("sha256")
	if err != nil {
		t.Fatalf("exec through the relay: %v", err)
	}
	if got, want := string(out), hex.EncodeToString(sum[:]); got != want {
		t.Fatalf("digest through the relay = %s, want %s", got, want)
	}
}

// The issue's 完成判据: the machine's link ends in B, the client asks A — the
// bytes go both ways, A says the machine is relayable, and the audit row is
// written once (by B, which carried it).
func TestSSHRelayTwoReplicas(t *testing.T) {
	ha, hb := newReplicaPair(t)
	ha.srv.SSHRelayRateBPS, hb.srv.SSHRelayRateBPS = -1, -1

	// No link anywhere: A refuses on its own, nothing proxied.
	if _, code := sshRelayDial(t, ha, "m4", asOperator, nil); code != "NODE_OFFLINE" {
		t.Fatalf("relay to a machine no replica holds: %s, want NODE_OFFLINE", code)
	}
	if n := ha.srv.forwarded.Load(); n != 0 {
		t.Fatalf("A proxied %d request(s) with no holder anywhere", n)
	}

	host := startSSHRelayAgentAt(t, hb, hb, hb.http.URL, "m4", testSSHD(t))
	if ha.srv.sshRelayLocal(host) {
		t.Fatal("A holds no link, yet says it can relay itself")
	}
	if !ha.srv.sshRelayReadiness()(host) {
		t.Fatal("A's connect page: the machine B holds is not relayable")
	}

	relayDigest(t, ha, host, 2<<20)
	if ha.srv.forwarded.Load() == 0 {
		t.Fatal("A carried the relay without proxying it")
	}
	if hb.srv.forwarded.Load() != 0 {
		t.Fatal("B proxied a request it was handed (a bounce)")
	}
	waitFor(t, 5*time.Second, "relay audited as closed", func() bool {
		rows, _ := ha.srv.Store.SSHRelays(10)
		return len(rows) == 1 && rows[0].EndedAt != nil && rows[0].Outcome == "closed" && rows[0].EndpointID == "ep_m4"
	})

	// Asked of B directly, it is B's own relay: no proxy either way.
	before := ha.srv.forwarded.Load()
	relayDigest(t, hb, host, 64<<10)
	if ha.srv.forwarded.Load() != before || hb.srv.forwarded.Load() != 0 {
		t.Fatal("a relay asked of the holder went through a proxy")
	}
}

// The agent's data half dials the public address too, so it can land on the
// replica that did not ask for it: a front sends the control channel to B and
// every data half to A, and the relay still goes through.
func TestSSHRelayDataHalfOnOtherReplica(t *testing.T) {
	ha, hb := newReplicaPair(t)
	ha.srv.SSHRelayRateBPS, hb.srv.SSHRelayRateBPS = -1, -1
	ua, _ := url.Parse(ha.http.URL)
	ub, _ := url.Parse(hb.http.URL)
	pa, pb := httputil.NewSingleHostReverseProxy(ua), httputil.NewSingleHostReverseProxy(ub)
	var dataOnA atomic.Int64
	front := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == control.SSHRelayDataPath {
			dataOnA.Add(1)
			pa.ServeHTTP(w, r)
			return
		}
		pb.ServeHTTP(w, r)
	}))
	t.Cleanup(front.Close)

	host := startSSHRelayAgentAt(t, hb, hb, front.URL, "m4", testSSHD(t))
	for _, h := range []*harness{ha, hb} {
		relayDigest(t, h, host, 256<<10)
	}
	if n := dataOnA.Load(); n != 2 {
		t.Fatalf("data halves through A = %d, want 2", n)
	}
	if ha.srv.forwarded.Load() != 3 {
		// Two data halves, plus the client that asked A.
		t.Fatalf("A proxied %d request(s), want 3", ha.srv.forwarded.Load())
	}
}

// A single hub never proxies: a relay, a refusal and the connect page all run
// as before.
func TestSSHRelayReplicaSingleNeverProxies(t *testing.T) {
	h := newFleetHarness(t)
	h.srv.SSHRelayRateBPS = -1
	if _, code := sshRelayDial(t, h, "m5", asOperator, nil); code != "NODE_OFFLINE" {
		t.Fatalf("relay to an absent machine: %s, want NODE_OFFLINE", code)
	}
	host, _ := startSSHRelayAgent(t, h, "m4", testSSHD(t))
	conn, code := sshRelayDial(t, h, host, asOperator, nil)
	if conn == nil {
		t.Fatalf("relay refused: %s", code)
	}
	cl := sshOver(t, conn)
	mustSession(t, cl).Close()
	cl.Close()
	if !h.srv.sshRelayReadiness()(host) || h.srv.sshRelayReadiness()("m5") {
		t.Fatal("connect page relay flags wrong on a single hub")
	}
	if n := h.srv.forwarded.Load(); n != 0 {
		t.Fatalf("a single hub proxied %d request(s)", n)
	}
}
