package api

import (
	"context"
	"fmt"
	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"net/http"
	"net/http/httptest"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

// Readiness changes before any link moves; peers still reach waiting links.
func TestDrainKeepsWaitingLinksReachable(t *testing.T) {
	a, b := newReplicaPair(t)
	c := dialNode(t, a, a.enroll(t, "waiting"))
	helloRaw(t, c)
	waitFor(t, time.Second, "peer link", func() bool { return len(b.srv.peerConns()) == 1 })
	a.srv.Drain()
	w := httptest.NewRecorder()
	a.srv.handleReadyz(w, httptest.NewRequest("GET", "/readyz", nil))
	if w.Code != http.StatusServiceUnavailable {
		t.Errorf("draining replica is ready: %d", w.Code)
	}
	if len(b.srv.peerConns()) != 1 {
		t.Error("waiting node disappeared before its drain slot")
	}
}

// helloRaw says a plain node hello on c and reads the welcome.
func helloRaw(t *testing.T, c *websocket.Conn) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	m, _ := control.New(control.TypeHello, control.Hello{HeartbeatMS: 5000, AgentVersion: "test"})
	if err := wsjson.Write(ctx, c, m); err != nil {
		t.Fatal(err)
	}
	var reply control.Message
	if err := wsjson.Read(ctx, c, &reply); err != nil || reply.Type != control.TypeWelcome {
		t.Fatalf("hello: %v %+v", err, reply)
	}
}

// A replica that goes away hands its node links over (task PNWW): with two
// replicas, a draining one closes its links with 1012 and waits until each
// session's own end has run (the link leaves its roster, the drop is booked
// hub_shutdown), refuses a new connect with 503, and the agent's next dial on
// the replica still up is served there.
func TestDrainLinksHandsTheLinkOver(t *testing.T) {
	ha, hb := newReplicaPair(t)
	ha.srv.LinkDrainSpread = 50 * time.Millisecond
	tok := ha.enroll(t, "drainhome")
	ca := dialNode(t, ha, tok)
	helloRaw(t, ca)
	dialNode(t, ha, tok) // a second link, still before its hello: drained too
	waitFor(t, 3*time.Second, "the link is held by hub-a", func() bool { return holder(t, ha, "ep_drainhome") == "hub-a" })

	closed := make(chan websocket.StatusCode, 1)
	go func() {
		var m control.Message
		for {
			if err := wsjson.Read(context.Background(), ca, &m); err != nil {
				closed <- websocket.CloseStatus(err)
				return
			}
		}
	}()

	ha.srv.Drain()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	start := time.Now()
	if n := ha.srv.DrainLinks(ctx); n != 2 {
		t.Fatalf("drained %d links; want 2", n)
	}
	if ctx.Err() != nil {
		t.Fatalf("the drain ran out its grace (%s): a session did not end", time.Since(start))
	}
	select {
	case code := <-closed:
		if code != websocket.StatusServiceRestart {
			t.Fatalf("the agent read close %d; want 1012 (service restart)", code)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("the agent's link was never closed")
	}
	if c := ha.srv.nodes.get("ep_drainhome"); c != nil {
		t.Fatal("the drained link is still in hub-a's roster: its end did not run")
	}
	if _, live := ha.srv.links.snapshot(); live != 0 {
		t.Fatalf("%d link(s) / session(s) still counted after the drain", live)
	}
	evs, _ := ha.srv.Store.LinkEvents(time.Now().Add(-time.Hour))
	booked := false
	for _, e := range evs {
		if e.Event == linkEventDown && e.Cause == linkEndShutdown && e.Replica == "hub-a" {
			booked = true
		}
	}
	if !booked {
		t.Fatalf("the hand-over was not booked hub_shutdown on hub-a: %+v", evs)
	}

	// A connect that still reaches the draining replica is refused, not served.
	dctx, dcancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer dcancel()
	url := "ws" + strings.TrimPrefix(ha.http.URL, "http") + control.Path
	_, resp, err := websocket.Dial(dctx, url, &websocket.DialOptions{
		HTTPHeader: http.Header{"Authorization": []string{"Bearer " + tok}}})
	if err == nil || resp == nil || resp.StatusCode != http.StatusServiceUnavailable || resp.Header.Get("Retry-After") == "" {
		t.Fatalf("a connect to the draining replica: err=%v resp=%v; want 503 + Retry-After", err, resp)
	}

	// The agent's next dial, on the replica still up, is served there.
	cb := dialNode(t, hb, tok)
	helloRaw(t, cb)
	waitFor(t, 3*time.Second, "the link is held by hub-b", func() bool { return holder(t, hb, "ep_drainhome") == "hub-b" })
}

// A single hub (no replica: the sqlite shape) refuses nothing while draining.
func TestDrainLinksSingleHubRefusesNothing(t *testing.T) {
	h := newFleetHarness(t)
	h.srv.Drain()
	tok := h.enroll(t, "solo")
	c := dialNode(t, h, tok)
	helloRaw(t, c)
}

func TestDrainSpreadsClosesAcrossWindow(t *testing.T) {
	a, _ := newReplicaPair(t)
	a.srv.LinkDrainSpread = 400 * time.Millisecond
	const count = 6
	closed := make(chan time.Time, count)
	for i := 0; i < count; i++ {
		c := dialNode(t, a, a.enroll(t, fmt.Sprintf("spread%d", i)))
		helloRaw(t, c)
		go func() {
			for {
				_, _, err := c.Read(context.Background())
				if err != nil {
					if websocket.CloseStatus(err) != websocket.StatusServiceRestart {
						t.Errorf("close: %v", err)
					}
					closed <- time.Now()
					return
				}
			}
		}()
	}
	a.srv.Drain()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if n := a.srv.DrainLinks(ctx); n != count || ctx.Err() != nil {
		t.Fatalf("drain: %d, %v", n, ctx.Err())
	}
	times := make([]time.Time, count)
	for i := range times {
		times[i] = <-closed
	}
	sort.Slice(times, func(i, j int) bool { return times[i].Before(times[j]) })
	if span := times[count-1].Sub(times[0]); span < 300*time.Millisecond {
		t.Fatalf("closes bunched into %s", span)
	}
	for i := 1; i < count; i++ {
		if times[i].Sub(times[i-1]) < 30*time.Millisecond {
			t.Fatal("adjacent closes bunched")
		}
	}
}

func TestDrainHandoffIsNotCountedAsNetwork(t *testing.T) {
	a, b := newReplicaPair(t)
	tok := a.enroll(t, "handoff-stats")
	c := dialNode(t, a, tok)
	helloRaw(t, c)
	waitFor(t, time.Second, "connected", func() bool { return holder(t, a, "ep_handoff-stats") == "hub-a" })
	ep := &store.Endpoint{ID: "ep_handoff-stats", Hostname: "handoff-stats", OSUser: "test"}
	now := time.Now()
	if err := a.srv.Store.RecordLinkEvent(store.LinkEvent{At: now, Host: ep.Hostname, Login: ep.OSUser, Event: linkEventDown, Cause: linkEndShutdown, Replica: "hub-a"}); err != nil {
		t.Fatal(err)
	}
	p := b.srv.linkBefore(ep)
	p.known = true
	p.lastBeat = &now
	if cause, _ := b.srv.linkCause(p, now.Add(time.Second)); cause != linkCauseHub {
		t.Fatalf("handoff with old replica still alive: %s", cause)
	}
}
