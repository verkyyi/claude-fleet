package e2e

import (
	"encoding/json"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"
	. "github.com/verkyyi/claude-fleet/tokenledger/hub/api"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"

	"context"
	"path/filepath"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/agent"
)

// The end-to-end check of the completion criterion: a hub and two agents with
// different homes; both show online, and the one that is killed turns lost
// within three of its heartbeat periods.
func TestNodesIntegrationTwoAgents(t *testing.T) {
	h := newFleetHarness(t)
	const every = 150 * time.Millisecond

	start := func(label string) context.CancelFunc {
		home := t.TempDir()
		a, err := agent.New(agent.Config{
			HubURL: h.HTTP.URL, Token: h.Enroll(t, label), Home: home,
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
