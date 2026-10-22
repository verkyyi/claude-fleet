package api

import (
	"bufio"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/coder/websocket/wsjson"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

// sseEvent is one event a test read off the stream.
type sseEvent struct {
	name string
	data string
	at   time.Time
}

// openStream opens /v1/fleet/stream as who ("" = the operator's door) and
// hands its events to a channel until the test ends.
func openStream(t *testing.T, h *harness, who, query string) <-chan sseEvent {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, h.http.URL+FleetStreamPath+query, nil)
	req.Header.Set("Authorization", "Bearer "+viewerToken)
	if who != "" {
		req.Header.Set("X-Test-Principal", who)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	if resp.StatusCode != 200 || !strings.HasPrefix(resp.Header.Get("Content-Type"), "text/event-stream") {
		t.Fatalf("stream: HTTP %d %q", resp.StatusCode, resp.Header.Get("Content-Type"))
	}
	if resp.Header.Get("X-Accel-Buffering") != "no" {
		t.Errorf("stream without X-Accel-Buffering: no — a proxy would hold every event")
	}
	out := make(chan sseEvent, 64)
	go func() {
		defer resp.Body.Close()
		defer close(out)
		sc := bufio.NewScanner(resp.Body)
		sc.Buffer(make([]byte, 1<<20), 1<<22)
		var ev sseEvent
		for sc.Scan() {
			line := sc.Text()
			switch {
			case line == "":
				if ev.name != "" {
					ev.at = time.Now()
					out <- ev
				}
				ev = sseEvent{}
			case strings.HasPrefix(line, "event: "):
				ev.name = strings.TrimPrefix(line, "event: ")
			case strings.HasPrefix(line, "data: "):
				ev.data = strings.TrimPrefix(line, "data: ")
			}
		}
	}()
	return out
}

// nextEvent is the next event named name (others skipped), or a failure.
func nextEvent(t *testing.T, ch <-chan sseEvent, name string, within time.Duration) sseEvent {
	t.Helper()
	deadline := time.After(within)
	for {
		select {
		case ev, ok := <-ch:
			if !ok {
				t.Fatalf("stream ended waiting for %q", name)
			}
			if ev.name == name {
				return ev
			}
		case <-deadline:
			t.Fatalf("no %q event within %v", name, within)
		}
	}
}

// streamTiming shortens the stream's clocks for one test; registered before
// the harness so it is restored after the server is gone.
func streamTiming(t *testing.T, recheck, ping time.Duration) {
	oldR, oldP := fleetStreamRecheck, fleetStreamPing
	fleetStreamRecheck, fleetStreamPing = recheck, ping
	t.Cleanup(func() { fleetStreamRecheck, fleetStreamPing = oldR, oldP })
}

// Each person's stream carries their own machines and sessions only — cut on
// the hub, never the whole roster for the page to filter (EPIC #2792 rule 1).
func TestFleetStreamScoped(t *testing.T) {
	streamTiming(t, fleetStreamRecheck, fleetStreamPing)
	h := newFleetHarness(t)
	h.srv.fleetScopeHook = func(r *http.Request) (func(string, string) bool, error) {
		switch r.Header.Get("X-Test-Principal") {
		case "":
			return nil, nil
		case "alice":
			return func(host, user string) bool { return host == "mac-d" && user == "alice" }, nil
		}
		return func(string, string) bool { return false }, nil
	}
	a := connectFakeNode(t, h, "mac-d", false)
	b := connectFakeNode(t, h, "mac-c", false)
	fa := fakeFleet(t, machineA, "alice-fleet", "", "", 1)
	fb := fakeFleet(t, machineB, "bob-fleet", "", "", 2)
	a.beat("mac-d", "alice", machineA, fa)
	b.beat("mac-c", "bob", machineB, fb)
	waitFor(t, 3*time.Second, "registered", func() bool {
		return len(getFleet(t, h, "/v1/fleet/fleet_list", 200)["fleets"].([]any)) == 2
	})

	alice := openStream(t, h, "alice", "")
	for _, topic := range []string{"nodes", "sessions"} {
		ev := nextEvent(t, alice, topic, 3*time.Second)
		if strings.Contains(ev.data, `"mac-c"`) || strings.Contains(ev.data, "bob") {
			t.Errorf("alice's %s event carries bob's machine: %s", topic, ev.data)
		}
		if !strings.Contains(ev.data, `"mac-d"`) {
			t.Errorf("alice's %s event lacks her own machine: %s", topic, ev.data)
		}
		var f struct {
			ObservedAt *time.Time `json:"observed_at"`
			SentAt     time.Time  `json:"sent_at"`
		}
		if err := json.Unmarshal([]byte(ev.data), &f); err != nil || f.ObservedAt == nil || f.SentAt.IsZero() {
			t.Errorf("%s frame = %s (%v); want observed_at and sent_at", topic, ev.data, err)
		}
	}
	stranger := openStream(t, h, "stranger", "?topics=nodes,sessions")
	for _, topic := range []string{"nodes", "sessions"} {
		ev := nextEvent(t, stranger, topic, 3*time.Second)
		if strings.Contains(ev.data, `"mac-c"`) || strings.Contains(ev.data, `"mac-d"`) {
			t.Errorf("a person with no login sees a machine in %s: %s", topic, ev.data)
		}
	}
	op := openStream(t, h, "", "?topics=nodes")
	if ev := nextEvent(t, op, "nodes", 3*time.Second); !strings.Contains(ev.data, `"mac-c"`) || !strings.Contains(ev.data, `"mac-d"`) {
		t.Errorf("the operator's nodes event = %s; want both machines", ev.data)
	}
}

// Nothing new, nothing sent — however often the recheck reads; a heartbeat
// that moves the load is one nodes event within a second of the hub hearing
// it, and a burst of beats is coalesced to one event a second.
func TestFleetStreamOnlyOnChange(t *testing.T) {
	streamTiming(t, 50*time.Millisecond, time.Hour)
	h := newFleetHarness(t)
	a := connectFakeNode(t, h, "mac-d", false)
	at := time.Now().Add(-time.Minute)
	hb := control.Heartbeat{Hostname: "mac-d", OSUser: "alice", MachineID: machineA, Load1: 1.5, NCPU: 8, ObservedAt: at}
	beat(t, a.conn, control.Proto, hb)
	waitFor(t, 3*time.Second, "node heard", func() bool { return len(roster(t, h).Nodes) == 1 && roster(t, h).Nodes[0].LastHeartbeat != nil })

	ch := openStream(t, h, "", "?topics=nodes,usage")
	nextEvent(t, ch, "nodes", 3*time.Second)
	nextEvent(t, ch, "usage", 3*time.Second)
	// Twenty rechecks, no beat: silence.
	select {
	case ev := <-ch:
		t.Fatalf("an event with nothing new: %s %s", ev.name, ev.data)
	case <-time.After(time.Second):
	}

	hb.Load1 = 6.25
	beat(t, a.conn, control.Proto, hb)
	ev := nextEvent(t, ch, "nodes", 3*time.Second)
	if !strings.Contains(ev.data, "6.25") {
		t.Errorf("nodes event after the beat = %s; want the new load", ev.data)
	}
	if d := ev.at.Sub(h.srv.nodesChanged.lastFired()); d > time.Second {
		t.Errorf("nodes event %v after the beat was recorded; want ≤ 1 s", d)
	}

	// Two beats back to back: the second waits out the first's second.
	hb.Load1 = 7
	beat(t, a.conn, control.Proto, hb)
	first := nextEvent(t, ch, "nodes", 3*time.Second)
	hb.Load1 = 8
	beat(t, a.conn, control.Proto, hb)
	second := nextEvent(t, ch, "nodes", 3*time.Second)
	if gap := second.at.Sub(first.at); gap < 900*time.Millisecond {
		t.Errorf("two nodes events %v apart; want them coalesced to one a second", gap)
	}
	if !strings.Contains(second.data, `"load1":8`) {
		t.Errorf("the coalesced event = %s; want the last beat's load", second.data)
	}
}

// A beat recorded while the stream reads the roster tears that read: the rows
// read before the beat, the load history after it (claude-fleet#3396). The
// torn frame is never sent — it would take the topic's second and hold the
// true one a second behind — the next event is the beat's, within a second.
func TestFleetStreamTornRead(t *testing.T) {
	streamTiming(t, 50*time.Millisecond, time.Hour)
	h := newFleetHarness(t)
	var armed atomic.Bool
	var a *fakeNode
	hb := control.Heartbeat{Hostname: "mac-d", OSUser: "alice", MachineID: machineA, Load1: 1.5, NCPU: 8, ObservedAt: time.Now()}
	h.srv.nodesRowsHook = func() {
		if !armed.CompareAndSwap(true, false) {
			return
		}
		// The beat lands between the row read and the rest of the read.
		before := h.srv.nodesChanged.lastFired()
		next := hb
		next.Load1 = 6.25
		m, _ := control.New(control.TypeHeartbeat, next)
		m.Proto = control.Proto
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		if err := wsjson.Write(ctx, a.conn, m); err != nil {
			t.Errorf("beat mid-read: %v", err)
			return
		}
		for deadline := time.Now().Add(3 * time.Second); !h.srv.nodesChanged.lastFired().After(before); {
			if time.Now().After(deadline) {
				t.Error("the mid-read beat was never recorded")
				return
			}
			time.Sleep(time.Millisecond)
		}
	}
	a = connectFakeNode(t, h, "mac-d", false)
	beat(t, a.conn, control.Proto, hb)
	waitFor(t, 3*time.Second, "node heard", func() bool { return len(roster(t, h).Nodes) == 1 && roster(t, h).Nodes[0].LastHeartbeat != nil })
	waitFor(t, 3*time.Second, "load history", func() bool { return len(h.srv.loadHist.series("mac-d", time.Now())) == 1 })

	ch := openStream(t, h, "", "?topics=nodes")
	nextEvent(t, ch, "nodes", 3*time.Second)
	armed.Store(true) // the next recheck's read is torn
	ev := nextEvent(t, ch, "nodes", 3*time.Second)
	if armed.Load() {
		t.Fatal("the read was never torn")
	}
	if !strings.Contains(ev.data, `"load1":6.25`) || strings.Contains(ev.data, `"load1":1.5`) {
		t.Errorf("nodes event after a torn read = %s; want the beat's load only", ev.data)
	}
	if d := ev.at.Sub(h.srv.nodesChanged.lastFired()); d > time.Second {
		t.Errorf("nodes event %v after the beat was recorded; want ≤ 1 s", d)
	}
}

// A hub that is always recording a beat still talks, and does not spin: a
// read is redone a bounded number of times, then sent as read.
func TestFleetStreamTornReadBounded(t *testing.T) {
	streamTiming(t, 50*time.Millisecond, time.Hour)
	h := newFleetHarness(t)
	var reads atomic.Int64
	h.srv.nodesRowsHook = func() { reads.Add(1) }
	a := connectFakeNode(t, h, "mac-d", false)
	hb := control.Heartbeat{Hostname: "mac-d", OSUser: "alice", MachineID: machineA, Load1: 1.5, NCPU: 8, ObservedAt: time.Now()}
	beat(t, a.conn, control.Proto, hb)
	waitFor(t, 3*time.Second, "node heard", func() bool { return len(roster(t, h).Nodes) == 1 && roster(t, h).Nodes[0].LastHeartbeat != nil })

	// Finish the first beat before subscribing, as TestFleetStreamTornRead
	// does. A late load-history update otherwise queues another old-load
	// event while this test sleeps, before the second beat is even sent.
	waitFor(t, 3*time.Second, "load history", func() bool { return len(h.srv.loadHist.series("mac-d", time.Now())) == 1 })

	// A recording that never ends: every read from here on overlaps one.
	h.srv.nodesChanged.begin()
	t.Cleanup(h.srv.nodesChanged.end)
	ch := openStream(t, h, "", "?topics=nodes")
	if ev := nextEvent(t, ch, "nodes", time.Second); !strings.Contains(ev.data, `"load1":1.5`) {
		t.Errorf("first nodes event = %s", ev.data)
	}
	time.Sleep(1100 * time.Millisecond) // out of the first event's second
	hb.Load1 = 6.25
	beat(t, a.conn, control.Proto, hb)
	// Under a deliberately never-settled recording, the bounded fallback
	// may emit a frame read across the second beat. Keep the original
	// deadline, but wait for the new observation rather than mistaking
	// that permitted intermediate frame for the beat's final result.
	deadline := time.Now().Add(3 * time.Second)
	ev := nextEvent(t, ch, "nodes", time.Until(deadline))
	for !strings.Contains(ev.data, `"load1":6.25`) {
		ev = nextEvent(t, ch, "nodes", time.Until(deadline))
	}
	// A permitted intermediate frame can consume the coalescing slot.
	// The final observation then pays that slot plus the bounded rereads
	// and recheck ticks. This is a fixed bound, not a deadline reset per frame.
	maxDelay := fleetStreamCoalesce + time.Duration(fleetStreamRereads)*fleetStreamReread + 2*fleetStreamRecheck
	if d := ev.at.Sub(h.srv.nodesChanged.lastFired()); d > maxDelay {
		t.Errorf("nodes event %v after the beat was recorded; want ≤ %v", d, maxDelay)
	}
	// One second of rechecks (20 at 50 ms), each read at most 1+rereads times.
	n0 := reads.Load()
	time.Sleep(time.Second)
	if n, max := reads.Load()-n0, int64(30*(1+fleetStreamRereads)); n > max {
		t.Errorf("%d roster reads in a second under endless recording; want ≤ %d (no spin)", n, max)
	}
}

func TestChangeBroadcastSettled(t *testing.T) {
	var b changeBroadcast
	ch := b.wait()
	if !b.settled(ch) {
		t.Error("idle broadcast not settled")
	}
	b.begin()
	if b.settled(ch) {
		t.Error("settled with a recording in flight")
	}
	b.end()
	if !b.settled(ch) {
		t.Error("not settled after end")
	}
	b.fire()
	if b.settled(ch) {
		t.Error("settled though it fired since the read began")
	}
	b.end() // an unpaired end never goes below zero
	if !b.settled(b.wait()) {
		t.Error("an unpaired end left it unsettled")
	}
}

// The ping keeps an idle stream talking (the page's 30 s watchdog hears it).
func TestFleetStreamPing(t *testing.T) {
	streamTiming(t, time.Hour, 100*time.Millisecond)
	h := newFleetHarness(t)
	ch := openStream(t, h, "", "?topics=usage")
	nextEvent(t, ch, "usage", 3*time.Second)
	if ev := nextEvent(t, ch, "ping", 2*time.Second); !strings.Contains(ev.data, "sent_at") {
		t.Errorf("ping = %s", ev.data)
	}
}

func TestFleetStreamTopicsArg(t *testing.T) {
	if got, err := streamTopicsArg(""); err != nil || strings.Join(got, ",") != "nodes,sessions,usage" {
		t.Errorf("empty = %v %v; want the default three", got, err)
	}
	if got, err := streamTopicsArg("tasks,sessions"); err != nil || strings.Join(got, ",") != "sessions,tasks" {
		t.Errorf("tasks,sessions = %v %v", got, err)
	}
	if got, err := streamTopicsArg("usage, nodes"); err != nil || strings.Join(got, ",") != "nodes,usage" {
		t.Errorf("usage,nodes = %v %v", got, err)
	}
	if _, err := streamTopicsArg("nodes,secrets"); err == nil {
		t.Error("an unknown topic was accepted")
	}
	h := newFleetHarness(t)
	getFleet(t, h, FleetStreamPath+"?topics=secrets", 400)
}

// The validator ignores the clock: the same roster read twice is one value.
func TestStreamValidatorIgnoresClock(t *testing.T) {
	a := map[string]any{"at": "1", "nodes": []any{map[string]any{"age_sec": 1.5, "load1": 2}}}
	b := map[string]any{"at": "2", "nodes": []any{map[string]any{"age_sec": 9.0, "load1": 2}}}
	c := map[string]any{"at": "2", "nodes": []any{map[string]any{"age_sec": 9.0, "load1": 3}}}
	if streamValidator(a) != streamValidator(b) {
		t.Error("a clock field moved the validator")
	}
	if streamValidator(b) == streamValidator(c) {
		t.Error("a load change did not move the validator")
	}
}

// The tasks topic (T769) is asked by name only, and carries the viewer's own
// records: alice's stream never names bob's task; a stream that names no
// topic carries no tasks event, as before.
func TestFleetStreamTasksOwn(t *testing.T) {
	streamTiming(t, 50*time.Millisecond, fleetStreamPing)
	h := newFleetHarness(t)
	h.srv.fleetScopeHook = func(*http.Request) (func(string, string) bool, error) {
		return func(string, string) bool { return false }, nil
	}
	now := time.Now()
	for _, who := range []string{"alice", "bob"} {
		if _, err := h.srv.Store.CreateFleetTask(store.FleetTask{Owner: who, Title: who + "'s task", Via: "⌘P"}, "test:"+who, now); err != nil {
			t.Fatal(err)
		}
	}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h.srv.handleFleetStream(w, r.WithContext(withPrincipal(r.Context(), r.Header.Get("X-Test-Principal"))))
	}))
	t.Cleanup(srv.Close)
	open := func(who, query string) <-chan sseEvent {
		return openStream(t, &harness{http: srv}, who, query)
	}
	ev := nextEvent(t, open("alice", "?topics=sessions,tasks"), "tasks", 3*time.Second)
	if !strings.Contains(ev.data, "alice's task") || strings.Contains(ev.data, "bob's task") {
		t.Errorf("alice's tasks event = %s; want her own record only", ev.data)
	}
	ch := open("alice", "")
	deadline := time.After(400 * time.Millisecond)
	for done := false; !done; {
		select {
		case ev := <-ch:
			if ev.name == "tasks" {
				t.Fatalf("a stream naming no topic sent tasks: %s", ev.data)
			}
		case <-deadline:
			done = true
		}
	}
}
