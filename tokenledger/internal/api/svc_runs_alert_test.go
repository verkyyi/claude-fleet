package api

import (
	"context"
	"encoding/json"
	"net/http"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// claude-fleet#4007: an infra_error is retried once and only once, nothing else
// is, and svc_degraded tells the person on duty when runs fail in a batch or
// wait too long.

// infra_error on attempt 1: back in the queue, the same R<n>, attempt 2 inside
// the first start's deadline; attempt 2's infra_error ends it. The caller sees
// the code only, never the runner's words.
func TestSvcRunRetryInfraOnce(t *testing.T) {
	h, fr, tok := svcRunsHarness(t)
	ref := svcSubmit(t, h, tok, svcReq("space:ws:a", "r1"))["run_id"].(string)
	id := svcRunID(t, ref)
	first, _ := h.srv.Store.SvcRun(id)
	if first.DeadlineAt == nil {
		t.Fatal("no deadline_at after the first start")
	}
	run, err := h.srv.SvcRunFinishDetail(id, store.SvcRunFailed, SvcErrInfra, "pod lost: node reclaimed\nstderr tail", nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	if run.State != store.SvcRunQueued || run.Attempt != 1 || run.ErrorCode != "" {
		t.Fatalf("after attempt 1's infra_error: %s attempt %d %q", run.State, run.Attempt, run.ErrorCode)
	}
	h.srv.SvcRunsTick(context.Background(), time.Now())
	again, _ := h.srv.Store.SvcRun(id)
	if again.State != store.SvcRunRunning || again.Attempt != 2 || !again.DeadlineAt.Equal(*first.DeadlineAt) {
		t.Fatalf("retry: %s attempt %d deadline %v (first %v)", again.State, again.Attempt, again.DeadlineAt, first.DeadlineAt)
	}
	if len(fr.started) != 2 || fr.started[0] != ref || fr.started[1] != ref {
		t.Errorf("runner started %v, want %s twice", fr.started, ref)
	}
	end, _ := h.srv.SvcRunFinishDetail(id, store.SvcRunFailed, SvcErrInfra, "credproxy 503", nil, nil)
	if end.State != store.SvcRunFailed || end.ErrorCode != SvcErrInfra || end.Attempt != 2 {
		t.Fatalf("attempt 2's infra_error: %s %s attempt %d", end.State, end.ErrorCode, end.Attempt)
	}
	v := svcState(t, h, tok, ref)
	if b, _ := json.Marshal(v); strings.Contains(string(b), "pod lost") || strings.Contains(string(b), "credproxy") {
		t.Errorf("the runner's words reached the caller: %s", b)
	}
	if !svcAudited(t, h, "svc.run.retry", "queued") {
		t.Error("no svc.run.retry audit row")
	}
}

// Every other code ends the run at once; so does an infra_error with less than
// a minute of its deadline left.
func TestSvcRunNoRetry(t *testing.T) {
	h, _, tok := svcRunsHarness(t)
	for i, code := range []string{SvcErrRunTimeout, SvcErrOutputInvalid, SvcErrTemplateInvalid, "quota_exhausted"} {
		ref := svcSubmit(t, h, tok, svcReq("space:ws:n"+string(rune('a'+i)), "n"+code))["run_id"].(string)
		run, _ := h.srv.SvcRunFinish(svcRunID(t, ref), store.SvcRunFailed, code, nil, nil)
		if run.State != store.SvcRunFailed || run.ErrorCode != code || run.Attempt != 1 {
			t.Errorf("%s: %s %s attempt %d", code, run.State, run.ErrorCode, run.Attempt)
		}
	}
	h.srv.SvcRunner = nil
	late := svcReq("space:ws:late", "late")
	late.DeadlineS = 60
	ref := svcSubmit(t, h, tok, late)["run_id"].(string)
	id := svcRunID(t, ref)
	h.srv.Store.ClaimSvcRuns("svc:livepage", 4, time.Now().Add(-30*time.Second)) // 30 s of 60 left
	if run, _ := h.srv.SvcRunFinish(id, store.SvcRunFailed, SvcErrInfra, nil, nil); run.State != store.SvcRunFailed {
		t.Errorf("infra_error with 30 s left: %s", run.State)
	}
}

// A retry that cannot start before its deadline ends failed infra_error, and
// one that starts and overruns times out on the FIRST start's deadline.
func TestSvcRunRetryDeadline(t *testing.T) {
	h, _, tok := svcRunsHarness(t)
	h.srv.SvcRunner = nil // nothing dispatches the retry
	ref := svcSubmit(t, h, tok, svcReq("space:ws:a", "d1"))["run_id"].(string)
	id := svcRunID(t, ref)
	now := time.Now()
	runs, _ := h.srv.Store.ClaimSvcRuns("svc:livepage", 4, now)
	if len(runs) != 1 {
		t.Fatalf("claimed %d", len(runs))
	}
	if run, _ := h.srv.SvcRunFinish(id, store.SvcRunFailed, SvcErrInfra, nil, nil); run.State != store.SvcRunQueued {
		t.Fatalf("not requeued: %s", run.State)
	}
	h.srv.SvcRunsTick(context.Background(), now.Add(10*time.Minute))
	if run, _ := h.srv.Store.SvcRun(id); run.State != store.SvcRunQueued {
		t.Fatalf("retry at 10m: %s", run.State)
	}
	h.srv.SvcRunsTick(context.Background(), now.Add(16*time.Minute))
	if run, _ := h.srv.Store.SvcRun(id); run.State != store.SvcRunFailed || run.ErrorCode != SvcErrInfra {
		t.Errorf("retry past the deadline: %s %s", run.State, run.ErrorCode)
	}

	ref2 := svcSubmit(t, h, tok, svcReq("space:ws:b", "d2"))["run_id"].(string)
	id2 := svcRunID(t, ref2)
	h.srv.Store.ClaimSvcRuns("svc:livepage", 4, now)
	h.srv.SvcRunFinish(id2, store.SvcRunFailed, SvcErrInfra, nil, nil)
	h.srv.Store.ClaimSvcRuns("svc:livepage", 4, now.Add(10*time.Minute)) // the retry starts 10 minutes in
	h.srv.SvcRunsTick(context.Background(), now.Add(18*time.Minute))     // 900 s + 2 min grace from the FIRST start
	if run, _ := h.srv.Store.SvcRun(id2); run.State != store.SvcRunFailed || run.ErrorCode != SvcErrRunTimeout {
		t.Errorf("retry overran the first deadline: %s %s", run.State, run.ErrorCode)
	}
}

type notifyRec struct {
	mu   sync.Mutex
	msgs []string
}

func (n *notifyRec) add(m string) { n.mu.Lock(); n.msgs = append(n.msgs, m); n.mu.Unlock() }
func (n *notifyRec) n() int       { n.mu.Lock(); defer n.mu.Unlock(); return len(n.msgs) }

func svcAlertHarness(t *testing.T) (*harness, string, *notifyRec) {
	t.Helper()
	old := svcAlertEvery
	svcAlertEvery = 0
	t.Cleanup(func() { svcAlertEvery = old })
	h, _, tok := svcRunsHarness(t)
	rec := &notifyRec{}
	h.srv.Notify = rec.add
	return h, tok, rec
}

func svcOpenAlerts(t *testing.T, h *harness) []string {
	t.Helper()
	open, err := h.srv.Store.OpenFleetAlertSubjects(store.AlertSvcDegraded, "")
	if err != nil {
		t.Fatal(err)
	}
	return open
}

// Three runs failing for good (each after its retry): raised on the second
// pass, one message, no second message within the hour, cleared once well.
func TestSvcDegradedFailures(t *testing.T) {
	h, tok, rec := svcAlertHarness(t)
	ok := svcSubmit(t, h, tok, svcReq("space:ws:ok", "ok"))["run_id"].(string)
	h.srv.SvcRunFinish(svcRunID(t, ok), store.SvcRunSucceeded, "", svcGoodResult, nil)
	for _, k := range []string{"f1", "f2"} {
		ref := svcSubmit(t, h, tok, svcReq("space:ws:"+k, k))["run_id"].(string)
		h.srv.SvcRunFinish(svcRunID(t, ref), store.SvcRunFailed, SvcErrRunTimeout, nil, nil)
	}
	now := time.Now()
	h.srv.SvcAlertTick(now)
	h.srv.SvcAlertTick(now.Add(time.Minute))
	if len(svcOpenAlerts(t, h)) != 0 || rec.n() != 0 {
		t.Fatalf("2 failures of 3 raised: %v %v", svcOpenAlerts(t, h), rec.msgs)
	}
	ref := svcSubmit(t, h, tok, svcReq("space:ws:f3", "f3"))["run_id"].(string)
	h.srv.SvcRunFinish(svcRunID(t, ref), store.SvcRunFailed, SvcErrInfra, nil, nil) // retried, not yet failed
	h.srv.SvcAlertTick(now.Add(2 * time.Minute))
	if len(svcOpenAlerts(t, h)) != 0 {
		t.Fatal("a run being retried counted as failed")
	}
	h.srv.SvcRunsTick(context.Background(), time.Now())
	h.srv.SvcRunFinish(svcRunID(t, ref), store.SvcRunFailed, SvcErrInfra, nil, nil)
	h.srv.SvcAlertTick(now.Add(3 * time.Minute))
	if len(svcOpenAlerts(t, h)) != 0 {
		t.Fatal("raised on the first pass that saw it (no debounce)")
	}
	h.srv.SvcAlertTick(now.Add(4 * time.Minute))
	if got := svcOpenAlerts(t, h); len(got) != 1 || got[0] != "svc:livepage" || rec.n() != 1 {
		t.Fatalf("3/4 failed, second pass: open %v, messages %v", got, rec.msgs)
	}
	if m := rec.msgs[0]; !strings.Contains(m, "svc_degraded") || !strings.Contains(m, "3/4") ||
		!strings.Contains(m, "infra_error×1") || !strings.Contains(m, "run_timeout×2") {
		t.Errorf("message: %s", m)
	}
	// Past the window: well again — cleared; failing again within the hour: no
	// second message.
	h.srv.SvcAlertTick(now.Add(40 * time.Minute))
	if len(svcOpenAlerts(t, h)) != 0 {
		t.Fatal("not cleared once the window holds no failures")
	}
	for _, k := range []string{"g1", "g2", "g3"} {
		r := svcSubmit(t, h, tok, svcReq("space:ws:"+k, k))["run_id"].(string)
		h.srv.SvcRunFinish(svcRunID(t, r), store.SvcRunFailed, SvcErrOutputInvalid, nil, nil)
	}
	h.srv.SvcAlertTick(now.Add(time.Minute))
	h.srv.SvcAlertTick(now.Add(2 * time.Minute))
	if rec.n() != 1 {
		t.Errorf("a second message within the hour: %v", rec.msgs)
	}
}

// Runs waiting past 10 minutes at p95: raised; a cancel counts neither way.
func TestSvcDegradedWaiting(t *testing.T) {
	h, tok, rec := svcAlertHarness(t)
	h.srv.SvcRunner = nil
	for _, k := range []string{"w1", "w2", "w3"} {
		svcSubmit(t, h, tok, svcReq("space:ws:"+k, k))
	}
	c := svcSubmit(t, h, tok, svcReq("space:ws:c", "c"))["run_id"].(string)
	if st, _ := svcDo(t, h, http.MethodPost, SvcRunsPath+"/"+c+"/cancel", tok, nil); st != http.StatusOK {
		t.Fatal("cancel")
	}
	now := time.Now()
	h.srv.SvcAlertTick(now.Add(5 * time.Minute))
	h.srv.SvcAlertTick(now.Add(6 * time.Minute))
	if rec.n() != 0 {
		t.Fatalf("raised at 6 minutes' wait: %v", rec.msgs)
	}
	h.srv.SvcAlertTick(now.Add(11 * time.Minute))
	h.srv.SvcAlertTick(now.Add(12 * time.Minute))
	if rec.n() != 1 || !strings.Contains(rec.msgs[0], "排队等待 p95") {
		t.Fatalf("waiting 12 minutes: %v", rec.msgs)
	}
	if strings.Contains(rec.msgs[0], "失败") {
		t.Errorf("a cancel counted as a failure: %s", rec.msgs[0])
	}
}

// FLEET_NOTIFY_CMD is run as `<cmd> "<message>"`.
func TestSvcNotifyCmd(t *testing.T) {
	dir := t.TempDir()
	out := dir + "/msg"
	cmd := dir + "/notify.sh"
	if err := os.WriteFile(cmd, []byte("#!/bin/sh\nprintf '%s' \"$1\" > "+out+"\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	s := &Server{NotifyCmd: cmd}
	s.notify("fleet 服务运行告警 svc_degraded · svc:x")
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if b, err := os.ReadFile(out); err == nil && len(b) > 0 {
			if string(b) != "fleet 服务运行告警 svc_degraded · svc:x" {
				t.Fatalf("notifier got %q", b)
			}
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatal("the notifier never ran")
}
