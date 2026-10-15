package api

import (
	"net/http"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// A trial is only ever a spare (claude-fleet#4259): mac-c and m7 have room
// and no ready spare, mac-d is over placement's CPU line with one — the trial lands
// on mac-d, where least-busy's room-first pick would hold it in line for good.
// With no ready spare anywhere the wait says no_spare and trial_no_spare is
// raised; the next claim that lands clears it.
func TestTrialPicksAMachineWithASpare(t *testing.T) {
	h := newFleetHarness(t)
	enablePeople(t, h)
	nodes := spareFleet(t, h)
	setHubSetting(t, h.srv, TrialKey, "on")
	sparesOn(t, h, "1")
	// mac-c's create is never answered: it holds no ready spare.
	openSpares(t, nodes["mac-d"], 1, control.CredsepSeparated)
	readySpares(t, h, "mac-d", 1)
	hot := 0.95
	beat(t, nodes["mac-d"].c, control.Proto, control.Heartbeat{Hostname: "mac-d", OSUser: "ivan", Sessions: 1,
		NCPU: 10, Load1: 1, CPUBusy: &hot, MemTotalBytes: 64 << 30, MemFreeBytes: 32 << 30})
	waitFor(t, 3*time.Second, "mac-d over the CPU line: least-busy picks a machine with room and no spare", func() bool {
		got := h.srv.leastBusyMachine(time.Now())
		return got != "" && got != "mac-d"
	})
	if host, _ := h.srv.trialMachine(time.Now()); host != "mac-d" {
		t.Fatalf("trialMachine = %q; want mac-d (the only ready spare)", host)
	}

	const a, b = "gh:7301", "gh:7302"
	now := time.Now()
	for i, p := range []string{a, b} {
		if err := h.srv.Store.StartTrial(p, now.Add(time.Duration(i)*time.Second)); err != nil {
			t.Fatal(err)
		}
	}
	code, _, out := tryDo(t, h, http.MethodPost, TryClaimPath, a, nil)
	if code != http.StatusOK || (out["state"] != "ready" && out["state"] != "opening") {
		t.Fatalf("a's claim = %d %v; want a seat on mac-d", code, out)
	}
	if tr, _ := h.srv.Store.Trial(a); tr == nil || tr.State != store.TrialPlaced || tr.Host != "mac-d" {
		t.Fatalf("a's trial = %+v; want placed on mac-d", tr)
	}

	// No ready spare anywhere now: b waits, told no_spare, and the operator
	// is told once.
	if host, noSpare := h.srv.trialMachine(time.Now()); host != "" || !noSpare {
		t.Fatalf("trialMachine with no spare = %q %v; want \"\" true", host, noSpare)
	}
	code, _, out = tryDo(t, h, http.MethodPost, TryClaimPath, b, nil)
	if code != http.StatusOK || out["state"] != "waiting" || out["reason"] != trialWaitNoSpare {
		t.Fatalf("b's claim with no spare = %d %v; want waiting, reason no_spare", code, out)
	}
	if !auditHas(mustAudit(t, h), "trial.queued", "waiting", "reason=no_spare") {
		t.Errorf("no trial.queued reason=no_spare audit row")
	}
	if subs, _ := h.srv.Store.OpenFleetAlertSubjects(store.AlertTrialNoSpare, ""); len(subs) != 1 || subs[0] != trialNoSpareSubject {
		t.Fatalf("trial_no_spare alerts = %v; want one", subs)
	}
	if got := trialPageReason(trialWaitNoSpare); got != trialWaitNoSpare {
		t.Errorf("page reason of no_spare = %q", got)
	}
}
