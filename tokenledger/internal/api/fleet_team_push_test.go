package api

import (
	"context"
	"encoding/json"
	"net/http"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
)

// The team version, pushed (claude-fleet#1899, EPIC #1906 C6).

func teamNode(t *testing.T, h *harness, token string, caps ...string) *websocket.Conn {
	t.Helper()
	c := dialNode(t, h, token)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	m, _ := control.New(control.TypeHello, control.Hello{HeartbeatMS: 60000, AgentVersion: "test", Capabilities: caps})
	if err := wsjson.Write(ctx, c, m); err != nil {
		t.Fatal(err)
	}
	var reply control.Message
	if err := wsjson.Read(ctx, c, &reply); err != nil || reply.Type != control.TypeWelcome {
		t.Fatalf("hello: %v %+v", err, reply)
	}
	return c
}

// nextTeam reads the next message and wants a TypeTeam carrying v.
func nextTeam(t *testing.T, c *websocket.Conn, v int, what string) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	var m control.Message
	if err := wsjson.Read(ctx, c, &m); err != nil {
		t.Fatalf("%s: no message: %v", what, err)
	}
	var tm control.Team
	_ = json.Unmarshal(m.Payload, &tm)
	if m.Type != control.TypeTeam || tm.TeamVersion != v {
		t.Fatalf("%s: got %s %s, want team v%d", what, m.Type, m.Payload, v)
	}
}

// silent wants nothing on c for a moment. It ends the connection (a read
// whose context expires closes it), so it is each connection's last check.
func silent(t *testing.T, c *websocket.Conn, what string) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 400*time.Millisecond)
	defer cancel()
	var m control.Message
	if err := wsjson.Read(ctx, c, &m); err == nil {
		t.Fatalf("%s: got %s %s, want nothing", what, m.Type, m.Payload)
	}
}

func TestTeamPushOnPutBeatAndReconnect(t *testing.T) {
	h := newFleetHarness(t)
	tokA, tokB, tokC := h.enroll(t, "a"), h.enroll(t, "b"), h.enroll(t, "c")
	hb := func(host string) control.Heartbeat { return control.Heartbeat{Hostname: host, OSUser: "op"} }

	// No team layer yet: a node that follows hears nothing (the degenerate case).
	c := teamNode(t, h, tokC, control.CapTeam)
	beat(t, c, control.Proto, hb("m3"))
	silent(t, c, "no team layer")

	a := teamNode(t, h, tokA, control.CapRead, control.CapTeam)
	b := teamNode(t, h, tokB, control.CapRead) // an older agent: no CapTeam
	beat(t, a, control.Proto, hb("m5"))
	beat(t, b, control.Proto, hb("m4"))

	// The PUT reaches the connected node at once — no beat needed.
	if code, _, raw, _ := teamCall(t, h, http.MethodPut, asOperator, teamV1, ""); code != 200 {
		t.Fatalf("PUT v1: HTTP %d %s", code, raw)
	}
	nextTeam(t, a, 1, "after PUT v1")

	// Beats on a link that already heard v1 push nothing; the next message is v2.
	beat(t, a, control.Proto, hb("m5"))
	beat(t, a, control.Proto, hb("m5"))
	time.Sleep(200 * time.Millisecond)
	if code, _, raw, _ := teamCall(t, h, http.MethodPut, asOperator, map[string]any{"restore": 1}, ""); code != 200 {
		t.Fatalf("PUT v2: HTTP %d %s", code, raw)
	}
	nextTeam(t, a, 2, "after PUT v2 (beats in between repeat nothing)")

	// A machine that was offline hears the current version on its first beat back.
	a.CloseNow()
	a2 := teamNode(t, h, tokA, control.CapRead, control.CapTeam)
	beat(t, a2, control.Proto, hb("m5"))
	nextTeam(t, a2, 2, "reconnect")

	// The node without the capability was never sent one.
	silent(t, b, "no CapTeam")
}

func TestTeamBundleVersion(t *testing.T) {
	h := newFleetHarness(t)
	if v, err := h.srv.Store.TeamBundleVersion(); err != nil || v != 0 {
		t.Fatalf("empty: v%d %v, want 0", v, err)
	}
	for i := 1; i <= 2; i++ {
		if code, _, raw, _ := teamCall(t, h, http.MethodPut, asOperator, teamV1, ""); code != 200 {
			t.Fatalf("PUT: HTTP %d %s", code, raw)
		}
	}
	if v, err := h.srv.Store.TeamBundleVersion(); err != nil || v != 2 {
		t.Fatalf("after two PUTs: v%d %v, want 2", v, err)
	}
}
