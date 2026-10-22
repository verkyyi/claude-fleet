package api

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

func TestMachineParkCensusAllLogins(t *testing.T) {
	h := newFleetHarness(t)
	nodes := []*fleetNode{connectNode(t, h, "a", "node-a", "alpha", false), connectNode(t, h, "b", "node-a", "beta", false)}
	send := func(i int, p *control.ParkMetrics) {
		beat(t, nodes[i].c, control.Proto, control.Heartbeat{Hostname: "node-a", OSUser: []string{"alpha", "beta"}[i], ParkMetrics: p, ObservedAt: time.Now()})
	}
	for i := range nodes {
		p := control.EmptyParkMetrics()
		*p.SessionsWorking = 1
		p.SessionsParked = i + 1
		*p.ParkedSavedMB = float64((i + 1) * 1024)
		*p.SessionsIdle = 1
		p.IdleReasons = map[string]int{"old-shell": 1}
		*p.IdleRSSMB = 512
		send(i, p)
	}
	waitFor(t, 3*time.Second, "all login park readings", func() bool {
		d, err := h.srv.nodeDetail(time.Now(), "node-a", nil)
		return err == nil && d != nil && d.Machine.ParkMetrics != nil && d.Machine.SessionsParked == 3
	})
	_, d := getDetail(t, h, "/v1/nodes/node-a", "")
	m := d.Machine
	if m.ParkMetrics == nil || m.SessionsWorking == nil || *m.SessionsWorking != 2 || m.SessionsIdle == nil || *m.SessionsIdle != 2 || m.SessionsParked != 3 || m.ParkedSavedMB == nil || *m.ParkedSavedMB != 3072 || *m.IdleRSSMB != 1024 || m.IdleReasons["old-shell"] != 2 {
		t.Fatalf("aggregate: %+v", m.ParkMetrics)
	}
	// A held session from an older wrapper has a count, but no pre-park RSS.
	unknown := control.EmptyParkMetrics()
	unknown.SessionsParked, unknown.ParkedSavedMB = 2, nil
	send(1, unknown)
	waitFor(t, 3*time.Second, "unknown savings are not zero", func() bool {
		d, err := h.srv.nodeDetail(time.Now(), "node-a", nil)
		return err == nil && d != nil && d.Machine.ParkMetrics != nil && d.Machine.ParkedSavedMB == nil
	})
	// An ended turn needs a complete CPU sample before the machine can claim idle.
	unknown.SessionsIdle, unknown.SessionsWorking, unknown.IdleRSSMB = nil, nil, nil
	send(1, unknown)
	waitFor(t, 3*time.Second, "sampling stays unknown across logins", func() bool {
		d, err := h.srv.nodeDetail(time.Now(), "node-a", nil)
		return err == nil && d != nil && d.Machine.ParkMetrics != nil && d.Machine.SessionsIdle == nil && d.Machine.SessionsWorking == nil && d.Machine.IdleRSSMB == nil
	})
	// One old login makes the whole census unknown, rather than a partial sum.
	send(1, nil)
	waitFor(t, 3*time.Second, "old login omits census", func() bool {
		d, err := h.srv.nodeDetail(time.Now(), "node-a", nil)
		return err == nil && d != nil && d.Machine.ParkMetrics == nil
	})
	_, d = getDetail(t, h, "/v1/nodes/node-a", "")
	b, _ := json.Marshal(d.Machine)
	if strings.Contains(string(b), "sessions_parked") {
		t.Fatalf("old node invented metrics: %s", b)
	}
}
