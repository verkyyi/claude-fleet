package api

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
)

// claude-fleet#3144: the machine link's beat carries its test runner; the hub
// lists every machine's at /v1/fleet/ci-runners; a login's own beat cannot
// speak for it, and a machine with none is not listed.
func TestCIRunnersFromTheMachineLink(t *testing.T) {
	h, n := machineRig(t)
	n.beat("alpha", control.Heartbeat{Hostname: "m4", OSUser: "alpha", NCPU: 10, ObservedAt: time.Now(),
		CIRunner: &control.CIRunnerStatus{State: "idle"}})
	waitFor(t, 3*time.Second, "alpha online", func() bool {
		for _, v := range roster(t, h).Nodes {
			if v.OSUser == "alpha" && v.Status == "online" {
				return true
			}
		}
		return false
	})
	time.Sleep(100 * time.Millisecond)
	if got, _ := h.srv.ciRunners(time.Now()); len(got.Runners) != 0 {
		t.Fatalf("a login's beat spoke for the runner: %+v", got)
	}
	n.beat("", control.Heartbeat{Hostname: "m4", OSUser: "root", NCPU: 10, ObservedAt: time.Now(),
		CIRunner: &control.CIRunnerStatus{State: "paused", Why: "load: 0.92/core > 0.75", Runs: 3, Failed: 1}})
	waitFor(t, 3*time.Second, "m4's runner listed", func() bool {
		got, _ := h.srv.ciRunners(time.Now())
		return len(got.Runners) == 1
	})
	got, _ := h.srv.ciRunners(time.Now())
	r := got.Runners[0]
	if r.Machine != "m4" || !r.Online || r.Runner.State != "paused" || r.Runner.Why == "" || r.Runner.Runs != 3 ||
		got.Online != 1 || got.Idle != 0 {
		t.Fatalf("m4's runner = %+v (%+v)", r, got)
	}
	n.beat("", control.Heartbeat{Hostname: "m4", OSUser: "root", NCPU: 10, ObservedAt: time.Now(),
		CIRunner: &control.CIRunnerStatus{State: "idle"}})
	waitFor(t, 3*time.Second, "m4 idle", func() bool {
		got, _ := h.srv.ciRunners(time.Now())
		return got.Idle == 1
	})
	// unheard past ciRunnerStale: listed, not online
	if got, _ := h.srv.ciRunners(time.Now().Add(ciRunnerStale + time.Minute)); got.Online != 0 || got.Idle != 0 ||
		len(got.Runners) != 1 || got.Runners[0].Online {
		t.Fatalf("a stale machine still online: %+v", got)
	}
	// the route answers the same JSON
	rec := httptest.NewRecorder()
	h.srv.handleCIRunners(rec, httptest.NewRequest(http.MethodGet, CIRunnersPath, nil))
	var body CIRunners
	if rec.Code != 200 || json.Unmarshal(rec.Body.Bytes(), &body) != nil || len(body.Runners) != 1 {
		t.Fatalf("GET %s = %d %s", CIRunnersPath, rec.Code, rec.Body)
	}
	// no ci.env any more: the beat carries none, the list is empty
	n.beat("", control.Heartbeat{Hostname: "m4", OSUser: "root", NCPU: 10, ObservedAt: time.Now()})
	waitFor(t, 3*time.Second, "m4's runner gone", func() bool {
		got, _ := h.srv.ciRunners(time.Now())
		return len(got.Runners) == 0
	})
}
