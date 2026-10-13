package api

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
)

// A cluster's readings (claude-fleet#3734).

func sendReadings(t *testing.T, c *websocket.Conn, pods ...control.PodReading) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	m, _ := control.New(control.TypeClusterReadings, control.ClusterReadings{Pods: pods})
	if err := wsjson.Write(ctx, c, m); err != nil {
		t.Fatal(err)
	}
}

func nextReading(t *testing.T, c *websocket.Conn, ts int64, what string) control.MachineReading {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	var m control.Message
	if err := wsjson.Read(ctx, c, &m); err != nil {
		t.Fatalf("%s: no message: %v", what, err)
	}
	var r control.ClusterReading
	_ = json.Unmarshal(m.Payload, &r)
	if m.Type != control.TypeClusterReading || r.Reading.TS != ts {
		t.Fatalf("%s: got %s %s, want cluster_reading ts %d", what, m.Type, m.Payload, ts)
	}
	return r.Reading
}

func reading(ts int64, load string) control.MachineReading {
	return control.MachineReading{V: 1, TS: ts, MemProbe: "1 60 0 0", MemTotalMB: "6144", LoadPerCore: load}
}

// fleet-ops' reading of a pod reaches that pod's login at once, a beat hands
// over only a newer one, a reconnect gets the last one, and nothing reaches a
// pod of another cluster, another pod, a pod the hub never made, or a link
// that did not list the capability.
func TestClusterReadingReachesItsPod(t *testing.T) {
	h := newFleetHarness(t)
	now := time.Now()
	ok := func(string) bool { return true }
	mine, err := h.srv.Store.CreateClusterSpare("ack", ok, now)
	must(t, err)
	theirs, err := h.srv.Store.CreateClusterSpare("other", ok, now)
	must(t, err)
	podA, podB := mine.Hostname, theirs.Hostname
	hb := func(host string) control.Heartbeat { return control.Heartbeat{Hostname: host, OSUser: "op"} }

	tokOps, tokA, tokB, tokOld, tokFake := h.enroll(t, "ops"), h.enroll(t, "a"), h.enroll(t, "b"), h.enroll(t, "old"), h.enroll(t, "fake")
	ops := teamNode(t, h, tokOps, control.CapClusterOps)
	beat(t, ops, control.Proto, hb("ack"))
	a := teamNode(t, h, tokA, control.CapClusterReading)
	beat(t, a, control.Proto, hb(podA)) // nothing yet (a timed-out read would close the link)
	b := teamNode(t, h, tokB, control.CapClusterReading)
	beat(t, b, control.Proto, hb(podB))
	old := teamNode(t, h, tokOld, control.CapRead) // an older agent on the same pod
	beat(t, old, control.Proto, hb(podA))

	sendReadings(t, ops,
		control.PodReading{Pod: podA, Reading: reading(100, "0.25")},
		control.PodReading{Pod: podB, Reading: reading(100, "0.90")},        // another cluster's pod
		control.PodReading{Pod: "u-nevermade1", Reading: reading(100, "1")}, // not the hub's
		control.PodReading{Pod: podA, Reading: control.MachineReading{V: 1, TS: 101, LoadPerCore: "1; rm -rf"}})
	if r := nextReading(t, a, 100, "pushed"); r.LoadPerCore != "0.25" || r.MemTotalMB != "6144" {
		t.Fatalf("reading = %+v", r)
	}
	silent(t, b, "another cluster's ops link names it")
	silent(t, old, "no CapClusterReading")

	// A beat repeats nothing and an older reading never goes out: the next
	// message is the newer one.
	beat(t, a, control.Proto, hb(podA))
	sendReadings(t, ops, control.PodReading{Pod: podA, Reading: reading(90, "0.10")})
	time.Sleep(200 * time.Millisecond)
	sendReadings(t, ops, control.PodReading{Pod: podA, Reading: reading(115, "0.50")})
	nextReading(t, a, 115, "newer reading (the beat and the older one sent nothing)")

	// Reconnected (or on the other replica): its first beat hands over the last one.
	a.CloseNow()
	a2 := teamNode(t, h, tokA, control.CapClusterReading)
	beat(t, a2, control.Proto, hb(podA))
	nextReading(t, a2, 115, "reconnect")

	// A link without CapClusterOps cannot feed a pod.
	fake := teamNode(t, h, tokFake, control.CapRead)
	beat(t, fake, control.Proto, hb("ack"))
	sendReadings(t, fake, control.PodReading{Pod: podA, Reading: reading(200, "9.99")})
	silent(t, a2, "not an ops link")
}

// TestClusterReadingOffAddsNothing: no ops link sends readings ⇒ a link that
// lists the capability is sent nothing, beat after beat.
func TestClusterReadingOffAddsNothing(t *testing.T) {
	h := newFleetHarness(t)
	sp, err := h.srv.Store.CreateClusterSpare("ack", func(string) bool { return true }, time.Now())
	must(t, err)
	a := teamNode(t, h, h.enroll(t, "a"), control.CapClusterReading)
	beat(t, a, control.Proto, control.Heartbeat{Hostname: sp.Hostname, OSUser: "op"})
	beat(t, a, control.Proto, control.Heartbeat{Hostname: sp.Hostname, OSUser: "op"})
	silent(t, a, "no fleet-ops")
}
