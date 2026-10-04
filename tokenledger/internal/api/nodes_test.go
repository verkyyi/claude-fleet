package api

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/agent"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/pricing"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"

	"net/http/httptest"
)

// newFleetHarness is newHarness with the fleet module on, as the hub command
// sets it up under CCQUOTA_FLEET=1.
func newFleetHarness(t *testing.T) *harness {
	t.Helper()
	st, err := store.Open(filepath.Join(t.TempDir(), "test.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	if err := st.EnsureNodes(); err != nil {
		t.Fatal(err)
	}
	srv := &Server{Store: st, Pricing: pricing.Default(), ViewerToken: viewerToken,
		LiveStore: NewLive(), Fleet: true}
	ts := httptest.NewServer(srv.Handler())
	t.Cleanup(ts.Close)
	return &harness{srv: srv, http: ts, tokens: map[string]string{}}
}

func dialNode(t *testing.T, h *harness, token string) *websocket.Conn {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	url := "ws" + strings.TrimPrefix(h.http.URL, "http") + control.Path
	c, _, err := websocket.Dial(ctx, url, &websocket.DialOptions{
		HTTPHeader: http.Header{"Authorization": []string{"Bearer " + token}},
	})
	if err != nil {
		t.Fatalf("dial control channel: %v", err)
	}
	t.Cleanup(func() { c.CloseNow() })
	return c
}

func hello(t *testing.T, c *websocket.Conn, proto, heartbeatMS int) control.Welcome {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	m, _ := control.New(control.TypeHello, control.Hello{HeartbeatMS: heartbeatMS, AgentVersion: "test"})
	m.Proto = proto
	if err := wsjson.Write(ctx, c, m); err != nil {
		t.Fatal(err)
	}
	var reply control.Message
	if err := wsjson.Read(ctx, c, &reply); err != nil {
		t.Fatal(err)
	}
	if reply.Type != control.TypeWelcome || reply.OpID != m.OpID {
		t.Fatalf("hello answered with %+v, want a welcome carrying op_id %s", reply, m.OpID)
	}
	var w control.Welcome
	if err := json.Unmarshal(reply.Payload, &w); err != nil {
		t.Fatal(err)
	}
	return w
}

func beat(t *testing.T, c *websocket.Conn, proto int, hb control.Heartbeat) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	m, _ := control.New(control.TypeHeartbeat, hb)
	m.Proto = proto
	if err := wsjson.Write(ctx, c, m); err != nil {
		t.Fatal(err)
	}
}

func roster(t *testing.T, h *harness) NodesSnapshot {
	t.Helper()
	req, _ := http.NewRequest(http.MethodGet, h.http.URL+"/v1/nodes", nil)
	req.Header.Set("Authorization", "Bearer "+viewerToken)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("/v1/nodes: HTTP %d", resp.StatusCode)
	}
	var snap NodesSnapshot
	if err := json.NewDecoder(resp.Body).Decode(&snap); err != nil {
		t.Fatal(err)
	}
	return snap
}

// waitFor polls cond until it holds or the deadline passes.
func waitFor(t *testing.T, d time.Duration, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(d)
	for time.Now().Before(deadline) {
		if cond() {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("timed out after %s waiting for %s", d, what)
}

// Off is today's hub: no route, no table.
func TestFleetModuleOffAddsNothing(t *testing.T) {
	h := newHarness(t)
	tok := h.enroll(t, "m5")

	req, _ := http.NewRequest(http.MethodGet, h.http.URL+control.Path, nil)
	req.Header.Set("Authorization", "Bearer "+tok)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode == http.StatusSwitchingProtocols || resp.StatusCode == http.StatusOK {
		t.Fatalf("control channel answered %d with the fleet module off", resp.StatusCode)
	}
	if _, err := h.srv.Store.Nodes(); err == nil {
		t.Fatal("nodes table exists although the fleet module is off; the database must be untouched")
	}
}

func TestNodeConnectRequiresEnrollmentToken(t *testing.T) {
	h := newFleetHarness(t)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	url := "ws" + strings.TrimPrefix(h.http.URL, "http") + control.Path
	_, resp, err := websocket.Dial(ctx, url, &websocket.DialOptions{
		HTTPHeader: http.Header{"Authorization": []string{"Bearer nope"}},
	})
	if err == nil {
		t.Fatal("an unknown token opened a control channel")
	}
	if resp == nil || resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("want 401, got %v", resp)
	}
}

func TestNodeHeartbeatListedOnline(t *testing.T) {
	h := newFleetHarness(t)
	c := dialNode(t, h, h.enroll(t, "m5"))
	if w := hello(t, c, control.Proto, 5000); !w.Accepted {
		t.Fatalf("a current node was not accepted: %+v", w)
	}
	beat(t, c, control.Proto, control.Heartbeat{
		Hostname: "m5", OSUser: "verkyyi", Load1: 2.5, NCPU: 10, MemFreeBytes: 8 << 30, MemTotalBytes: 64 << 30,
		Sessions: 3, Fleets: []control.Fleet{{FleetID: "f1", Name: "fleet-a", State: "running", Count: 3}},
	})
	var snap NodesSnapshot
	waitFor(t, 3*time.Second, "the heartbeat to land", func() bool {
		snap = roster(t, h)
		return len(snap.Nodes) == 1 && sessionsIs(snap.Nodes[0].Sessions, 3)
	})
	n := snap.Nodes[0]
	if n.Status != "online" || !n.Connected || !n.Compatible || n.Hostname != "m5" || n.Load1 != 2.5 || n.NCPU != 10 {
		t.Fatalf("node = %+v", n)
	}
	if len(n.Fleets) != 1 || n.Fleets[0].Name != "fleet-a" || n.Fleets[0].Count != 3 {
		t.Fatalf("fleets = %+v", n.Fleets)
	}
	if len(snap.Machines) != 1 || snap.Machines[0].Status != "online" || !sessionsIs(snap.Machines[0].Sessions, 3) {
		t.Fatalf("machines = %+v", snap.Machines)
	}
}

// A node speaking a protocol the hub does not accept is listed — with its
// version — and never written to.
func TestNodeProtoMismatchRefusesWrites(t *testing.T) {
	h := newFleetHarness(t)
	old := dialNode(t, h, h.enroll(t, "old"))
	w := hello(t, old, control.Proto+98, 5000)
	if w.Accepted || w.Reason != control.CodeProtoMismatch {
		t.Fatalf("welcome = %+v, want refused with %s", w, control.CodeProtoMismatch)
	}
	beat(t, old, control.Proto+98, control.Heartbeat{Hostname: "old"})

	cur := dialNode(t, h, h.enroll(t, "cur"))
	hello(t, cur, control.Proto, 5000)

	waitFor(t, 3*time.Second, "both nodes registered", func() bool {
		return h.srv.nodes.get("ep_old") != nil && h.srv.nodes.get("ep_cur") != nil
	})
	snap := roster(t, h)
	var listed bool
	for _, n := range snap.Nodes {
		if n.EndpointID == "ep_old" {
			listed = true
			if n.Compatible || n.Proto != control.Proto+98 {
				t.Fatalf("incompatible node listed as %+v", n)
			}
		}
	}
	if !listed {
		t.Fatal("an incompatible node must still be listed")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	op, _ := control.New("worker_start", map[string]any{"issue": 1})
	if err := h.srv.SendNodeWrite(ctx, "ep_old", op); !errors.Is(err, control.ErrIncompatible) {
		t.Fatalf("write to an incompatible node: err = %v, want ErrIncompatible", err)
	}
	if err := h.srv.SendNodeWrite(ctx, "ep_cur", op); err != nil {
		t.Fatalf("write to a compatible node: %v", err)
	}
	var got control.Message
	if err := wsjson.Read(ctx, cur, &got); err != nil || got.OpID != op.OpID {
		t.Fatalf("compatible node received %+v (%v), want op %s", got, err, op.OpID)
	}
	if err := h.srv.SendNodeWrite(ctx, "ep_nobody", op); !errors.Is(err, ErrNodeOffline) {
		t.Fatalf("write to an unconnected node: err = %v, want ErrNodeOffline", err)
	}
}

func TestNodeFirstMessageMustBeHello(t *testing.T) {
	h := newFleetHarness(t)
	c := dialNode(t, h, h.enroll(t, "m5"))
	beat(t, c, control.Proto, control.Heartbeat{Hostname: "m5"})
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	var reply control.Message
	if err := wsjson.Read(ctx, c, &reply); err != nil {
		t.Fatal(err)
	}
	if reply.Type != control.TypeError || reply.Error == nil || reply.Error.Code != control.CodeBadMessage {
		t.Fatalf("reply = %+v, want a BAD_MESSAGE error", reply)
	}
}

func TestNodeStatusLostAfterThreeMissedBeats(t *testing.T) {
	now := time.Date(2026, 10, 3, 12, 0, 0, 0, time.UTC)
	at := func(ago time.Duration) *time.Time { t := now.Add(-ago); return &t }
	cases := []struct {
		last *time.Time
		hbMS int
		want string
	}{
		{at(0), 5000, "online"},
		{at(14 * time.Second), 5000, "online"},
		{at(16 * time.Second), 5000, "lost"},
		{at(16 * time.Second), 0, "lost"}, // unstated cadence = the 5s default
		{at(2 * time.Second), 500, "lost"},
		{nil, 5000, "lost"},
	}
	for _, c := range cases {
		if got := NodeStatus(c.last, c.hbMS, now); got != c.want {
			t.Errorf("NodeStatus(%v, %d) = %s, want %s", c.last, c.hbMS, got, c.want)
		}
	}
}

// A node that goes silent is marked lost — and kept, never dropped.
func TestNodeGoesLostButStaysListed(t *testing.T) {
	h := newFleetHarness(t)
	c := dialNode(t, h, h.enroll(t, "m4"))
	hello(t, c, control.Proto, 100)
	beat(t, c, control.Proto, control.Heartbeat{Hostname: "m4", Sessions: 2})
	waitFor(t, 3*time.Second, "online", func() bool {
		s := roster(t, h)
		return len(s.Nodes) == 1 && s.Nodes[0].Status == "online" && sessionsIs(s.Nodes[0].Sessions, 2)
	})
	waitFor(t, 3*time.Second, "lost after three silent intervals", func() bool {
		s := roster(t, h)
		return len(s.Nodes) == 1 && s.Nodes[0].Status == "lost"
	})
	s := roster(t, h)
	if s.Machines[0].Status != "lost" || !sessionsIs(s.Machines[0].Sessions, 0) {
		t.Fatalf("machine = %+v; a lost machine reports no live sessions rather than stale ones", s.Machines[0])
	}
}

// The end-to-end check of the completion criterion: a hub and two agents with
// different homes; both show online, and the one that is killed turns lost
// within three of its heartbeat periods.
func TestNodesIntegrationTwoAgents(t *testing.T) {
	h := newFleetHarness(t)
	const every = 150 * time.Millisecond

	start := func(label string) context.CancelFunc {
		home := t.TempDir()
		a, err := agent.New(agent.Config{
			HubURL: h.http.URL, Token: h.enroll(t, label), Home: home,
			StateDir: filepath.Join(home, "state"), SessionsDir: filepath.Join(home, "sessions"),
			Sources: "claude", LiveInterval: every, ScanInterval: time.Hour, LimitsInterval: time.Hour,
			Fleet: true, Version: "it-" + label,
		})
		if err != nil {
			t.Fatal(err)
		}
		ctx, cancel := context.WithCancel(context.Background())
		done := make(chan struct{})
		go func() { a.Run(ctx); close(done) }()
		t.Cleanup(func() { cancel(); <-done })
		return cancel
	}
	start("alpha")
	stopBeta := start("beta")

	online := func(s NodesSnapshot) map[string]string {
		m := map[string]string{}
		for _, n := range s.Nodes {
			m[n.EndpointID] = n.Status
		}
		return m
	}
	waitFor(t, 5*time.Second, "both agents online", func() bool {
		m := online(roster(t, h))
		return m["ep_alpha"] == "online" && m["ep_beta"] == "online"
	})

	stopBeta()
	killed := time.Now()
	waitFor(t, 5*time.Second, "beta lost", func() bool {
		return online(roster(t, h))["ep_beta"] == "lost"
	})
	// Three periods, plus a second of slack for a busy CI runner: the
	// assertion is "a few beats", not "a timeout somewhere".
	if took := time.Since(killed); took > 3*every+time.Second {
		t.Fatalf("beta took %s to read lost; want within ~3 heartbeat periods of %s", took, every)
	}
	if m := online(roster(t, h)); m["ep_alpha"] != "online" {
		t.Fatalf("alpha = %s after beta stopped; want online", m["ep_alpha"])
	}
}
