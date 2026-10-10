package api

import (
	"bufio"
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
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
			return func(host, user string) bool { return host == "m5" && user == "alice" }, nil
		}
		return func(string, string) bool { return false }, nil
	}
	a := connectFakeNode(t, h, "m5", false)
	b := connectFakeNode(t, h, "m4", false)
	fa := fakeFleet(t, machineA, "alice-fleet", "", "", 1)
	fb := fakeFleet(t, machineB, "bob-fleet", "", "", 2)
	a.beat("m5", "alice", machineA, fa)
	b.beat("m4", "bob", machineB, fb)
	waitFor(t, 3*time.Second, "registered", func() bool {
		return len(getFleet(t, h, "/v1/fleet/fleet_list", 200)["fleets"].([]any)) == 2
	})

	alice := openStream(t, h, "alice", "")
	for _, topic := range []string{"nodes", "sessions"} {
		ev := nextEvent(t, alice, topic, 3*time.Second)
		if strings.Contains(ev.data, `"m4"`) || strings.Contains(ev.data, "bob") {
			t.Errorf("alice's %s event carries bob's machine: %s", topic, ev.data)
		}
		if !strings.Contains(ev.data, `"m5"`) {
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
		if strings.Contains(ev.data, `"m4"`) || strings.Contains(ev.data, `"m5"`) {
			t.Errorf("a person with no login sees a machine in %s: %s", topic, ev.data)
		}
	}
	op := openStream(t, h, "", "?topics=nodes")
	if ev := nextEvent(t, op, "nodes", 3*time.Second); !strings.Contains(ev.data, `"m4"`) || !strings.Contains(ev.data, `"m5"`) {
		t.Errorf("the operator's nodes event = %s; want both machines", ev.data)
	}
}

// Nothing new, nothing sent — however often the recheck reads; a heartbeat
// that moves the load is one nodes event within a second of the hub hearing
// it, and a burst of beats is coalesced to one event a second.
func TestFleetStreamOnlyOnChange(t *testing.T) {
	streamTiming(t, 50*time.Millisecond, time.Hour)
	h := newFleetHarness(t)
	a := connectFakeNode(t, h, "m5", false)
	at := time.Now().Add(-time.Minute)
	hb := control.Heartbeat{Hostname: "m5", OSUser: "alice", MachineID: machineA, Load1: 1.5, NCPU: 8, ObservedAt: at}
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
		t.Errorf("empty = %v %v; want all", got, err)
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
