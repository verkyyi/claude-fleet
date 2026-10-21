package api

import (
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

// claude-fleet QSSW (EPIC WACK C7): a long trial line and session starts that
// keep failing are each raised once, pushed to the notifier once, and the
// same kind raised again inside fleet.alert.quiet_mins is not pushed again.

type notified struct {
	mu   sync.Mutex
	msgs []string
}

func (n *notified) take(msg string) {
	n.mu.Lock()
	defer n.mu.Unlock()
	n.msgs = append(n.msgs, msg)
}

func (n *notified) with(kind string) int {
	n.mu.Lock()
	defer n.mu.Unlock()
	c := 0
	for _, m := range n.msgs {
		if strings.Contains(strings.SplitN(m, "\n", 2)[0], " "+kind+" ") {
			c++
		}
	}
	return c
}

// failStart records one worker_start that ended failed at at; capacity says
// the machine declined it (at capacity) rather than failing to open it.
func failStart(t *testing.T, h *harness, n int, at time.Time, capacity bool) {
	t.Helper()
	result := `{"error":{"code":"INTERNAL","message":"tmux: no server","stderr1":"spawn died: tmux: no server"}}`
	if capacity {
		result = `{"error":{"code":"AT_CAPACITY","message":"full","exit":2}}`
	}
	id := "op-qssw-" + strconv.Itoa(n)
	if err := h.srv.Store.InsertFleetOperation(store.FleetOperation{ID: id, FleetID: "fleet-a", Action: "worker_start",
		Request: "{}", Idem: id, Status: "accepted", Created: at, Updated: at}); err != nil {
		t.Fatal(err)
	}
	if err := h.srv.Store.UpdateFleetOperation(id, "failed", result, at); err != nil {
		t.Fatal(err)
	}
}

func TestQueueLongAndStartFailedPushOnce(t *testing.T) {
	h := newFleetHarness(t)
	var got notified
	h.srv.Notify = got.take
	since := time.Now().Add(-time.Hour)
	now := time.Now()

	// queue_long: a person on the page, waiting 11 minutes.
	if err := h.srv.Store.StartTrial("gh:qssw-1", now.Add(-11*time.Minute)); err != nil {
		t.Fatal(err)
	}
	if err := h.srv.Store.TouchTrial("gh:qssw-1", now); err != nil {
		t.Fatal(err)
	}
	// start_failed: two failures and a capacity refusal are not three.
	failStart(t, h, 1, now.Add(-10*time.Minute), false)
	failStart(t, h, 2, now.Add(-5*time.Minute), false)
	failStart(t, h, 3, now.Add(-4*time.Minute), true)
	h.srv.QueueLongTick(now)
	h.srv.StartFailedTick(now)
	h.srv.AlertNotifyTick(since, now)
	if n := len(openAlerts(t, h, store.AlertQueueLong)); n != 1 {
		t.Fatalf("queue_long open = %d, want 1", n)
	}
	if n := len(openAlerts(t, h, store.AlertStartFailed)); n != 0 {
		t.Fatalf("start_failed open after 2 failures + 1 capacity refusal = %d, want 0", n)
	}
	// The third real failure in 15 minutes raises it.
	failStart(t, h, 4, now.Add(-time.Minute), false)
	h.srv.StartFailedTick(now)
	h.srv.AlertNotifyTick(since, now)
	if n := len(openAlerts(t, h, store.AlertStartFailed)); n != 1 {
		t.Fatalf("start_failed open = %d, want 1", n)
	}
	if got.with(store.AlertQueueLong) != 1 || got.with(store.AlertStartFailed) != 1 {
		t.Fatalf("pushed %v; want queue_long and start_failed once each", got.msgs)
	}
	for _, m := range got.msgs {
		if strings.Contains(m, store.AlertStartFailed) && !strings.Contains(m, "3 starts failed in 15 min") {
			t.Errorf("start_failed message %q does not say how many", m)
		}
	}

	// Well again: both clear.
	later := now.Add(20 * time.Minute)
	if err := h.srv.Store.PlaceTrial("gh:qssw-1", "mac-a", later); err != nil {
		t.Fatal(err)
	}
	h.srv.QueueLongTick(later)
	h.srv.StartFailedTick(later)
	if len(openAlerts(t, h, store.AlertQueueLong))+len(openAlerts(t, h, store.AlertStartFailed)) != 0 {
		t.Fatal("queue_long / start_failed still open once well")
	}

	// Raised again 25 minutes after the first push — inside the 30-minute
	// quiet window: recorded, not pushed again.
	again := now.Add(25 * time.Minute)
	if err := h.srv.Store.StartTrial("gh:qssw-2", again.Add(-12*time.Minute)); err != nil {
		t.Fatal(err)
	}
	if err := h.srv.Store.TouchTrial("gh:qssw-2", again); err != nil {
		t.Fatal(err)
	}
	for i := 5; i < 8; i++ {
		failStart(t, h, i, again.Add(-time.Duration(i)*time.Minute), false)
	}
	h.srv.QueueLongTick(again)
	h.srv.StartFailedTick(again)
	h.srv.AlertNotifyTick(since, again)
	if len(openAlerts(t, h, store.AlertQueueLong)) != 1 || len(openAlerts(t, h, store.AlertStartFailed)) != 1 {
		t.Fatal("the second raise was not recorded")
	}
	if got.with(store.AlertQueueLong) != 1 || got.with(store.AlertStartFailed) != 1 {
		t.Fatalf("pushed again inside the quiet window: %v", got.msgs)
	}
	rows, _ := h.srv.Store.FleetAlerts(0)
	quiet := 0
	for _, a := range rows {
		if a.Notify == store.AlertNotifyQuiet {
			quiet++
		}
	}
	if quiet != 2 {
		t.Errorf("rows marked quiet = %d, want 2", quiet)
	}
}

// Every other kind is pushed too (node_lost here); a self-telling kind
// (svc_degraded) is left to its raiser, and a row raised before the sweep
// started is never pushed.
func TestAlertNotifyEveryKindOnce(t *testing.T) {
	h := newFleetHarness(t)
	var got notified
	h.srv.Notify = got.take
	now := time.Now()
	since := now.Add(-time.Minute)
	for _, r := range []struct {
		kind, subject string
		at            time.Time
	}{
		{store.AlertNodeLost, "ep-1", now},
		{store.AlertSvcDegraded, "svc:x", now},
		{store.AlertSpareEmpty, "mac-old", now.Add(-time.Hour)},
	} {
		if _, err := h.srv.Store.RaiseFleetAlert(r.kind, r.subject, `{"hostname":"mac-a","os_user":"alice"}`, r.at); err != nil {
			t.Fatal(err)
		}
	}
	h.srv.AlertNotifyTick(since, now)
	h.srv.AlertNotifyTick(since, now.Add(time.Minute))
	if len(got.msgs) != 1 || got.with(store.AlertNodeLost) != 1 || !strings.Contains(got.msgs[0], "alice@") {
		t.Fatalf("pushed %v; want node_lost once", got.msgs)
	}

	// quiet_mins 0: every raise goes out.
	setHubSetting(t, h.srv, AlertQuietMinsKey, "0")
	_, _ = h.srv.Store.ClearFleetAlert(store.AlertNodeLost, "ep-1", now)
	if _, err := h.srv.Store.RaiseFleetAlert(store.AlertNodeLost, "ep-1", "{}", now.Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
	h.srv.AlertNotifyTick(since, now.Add(2*time.Minute))
	if got.with(store.AlertNodeLost) != 2 {
		t.Fatalf("with quiet_mins 0 pushed %v; want node_lost twice", got.msgs)
	}
}
