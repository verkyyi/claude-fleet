package api

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"testing"
	"time"

	"github.com/coder/websocket/wsjson"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// Service runs on the Mac mini's service logins (claude-fleet#4086): the hub
// hands each attempt to ONE service login that fleet.svc.logins names and whose
// agent listed CapSvcRun, never more at once than its slots, oldest first; the
// run reads its spec and hands in its result with its own key, as a Job does.

// fakeSvcLogin answers svc_run / svc_run_cancel like a service login's agent.
type fakeSvcLogin struct {
	starts  chan control.SvcRunStart
	cancels chan control.SvcRunCancel
}

func startFakeSvcLogin(t *testing.T, h *harness, label, host, login string) *fakeSvcLogin {
	t.Helper()
	n := connectCaps(t, h, label, host, login, false, control.CapSvcRun)
	f := &fakeSvcLogin{starts: make(chan control.SvcRunStart, 16), cancels: make(chan control.SvcRunCancel, 16)}
	go func() {
		for m := range n.in {
			switch m.Type {
			case control.TypeSvcRun:
				var v control.SvcRunStart
				_ = json.Unmarshal(m.Payload, &v)
				f.starts <- v
			case control.TypeSvcRunCancel:
				var v control.SvcRunCancel
				_ = json.Unmarshal(m.Payload, &v)
				f.cancels <- v
			default:
				continue
			}
			out, _ := control.New(control.TypeResult, control.SvcRunAck{OK: true})
			out.OpID = m.OpID
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			_ = wsjson.Write(ctx, n.c, out)
			cancel()
		}
	}()
	waitFor(t, 3*time.Second, "the service login linked", func() bool {
		return len(h.srv.nodes.svcLanes(func(string, string) bool { return true })) > 0
	})
	return f
}

func (f *fakeSvcLogin) expectStart(t *testing.T) control.SvcRunStart {
	t.Helper()
	select {
	case v := <-f.starts:
		return v
	case <-time.After(5 * time.Second):
		t.Fatal("no svc_run")
	}
	return control.SvcRunStart{}
}

func (f *fakeSvcLogin) quiet(t *testing.T, d time.Duration) {
	t.Helper()
	select {
	case v := <-f.starts:
		t.Fatalf("unexpected svc_run %+v", v)
	case <-time.After(d):
	}
}

func svcNodeRig(t *testing.T, logins string) (*harness, string) {
	t.Helper()
	h := newFleetHarness(t)
	h.srv.SessionCredKey = bytes.Repeat([]byte{9}, 32)
	h.srv.SvcRunner = NewNodeSvcRunner(h.srv)
	tok := svcSetup(t, h, "livepage", "runs:write runs:read templates:write")
	if err := h.srv.Store.PutSvcTemplate(store.SvcTemplate{Principal: "svc:livepage", Digest: svcTestDigest,
		Name: "daily", AgentMD: svcTestAgent}, time.Now()); err != nil {
		t.Fatal(err)
	}
	if logins != "" {
		if err := h.srv.Store.SetFleetSetting(SvcLoginsKey, logins, time.Now()); err != nil {
			t.Fatal(err)
		}
	}
	return h, tok
}

func TestSvcRunOnServiceLogin(t *testing.T) {
	h, tok := svcNodeRig(t, "mini:fleetsvc1")
	// a person's login that also says svc_run but is not named: never sent one
	other := startFakeSvcLogin(t, h, "alice", "mini", "alice")
	svc := startFakeSvcLogin(t, h, "svc1", "mini.local", "fleetsvc1")
	a := svcSubmit(t, h, tok, svcReq("space:ws:a", "a1"))["run_id"].(string)
	b := svcSubmit(t, h, tok, svcReq("space:ws:b", "b1"))["run_id"].(string)
	h.srv.SvcRunsTick(context.Background(), time.Now())
	got := svc.expectStart(t)
	if got.Run != a || got.Attempt != 1 || got.Deadline != 900 || !svcKeyRE.MatchString(got.Token) {
		t.Fatalf("svc_run %+v; want %s attempt 1, its deadline and a key", got, a)
	}
	// one slot: the second run waits in the queue
	h.srv.SvcRunsTick(context.Background(), time.Now())
	svc.quiet(t, 300*time.Millisecond)
	if st := svcState(t, h, tok, b)["state"]; st != store.SvcRunQueued {
		t.Fatalf("the second run is %v while the one slot is held; want queued", st)
	}
	other.quiet(t, 10*time.Millisecond)
	// the run's own road, with the key it was handed
	if st, out := svcDo(t, h, http.MethodGet, NodeSvcRunsPath+"/"+a+"/spec?attempt=1", got.Token, nil); st != http.StatusOK || out["pass"] == "" {
		t.Fatalf("spec: %d %v", st, out)
	}
	res := map[string]any{"attempt": 1, "exit": SvcExitOK, "report": svcGoodResult.Report, "meta": svcGoodResult.Meta}
	if st, out := svcDo(t, h, http.MethodPost, NodeSvcRunsPath+"/"+a+"/result", got.Token, res); st != http.StatusOK || out["state"] != store.SvcRunSucceeded {
		t.Fatalf("result: %d %v", st, out)
	}
	// the slot is free: the second run goes
	h.srv.SvcRunsTick(context.Background(), time.Now())
	if g := svc.expectStart(t); g.Run != b {
		t.Fatalf("next svc_run %+v; want %s", g, b)
	}
	other.quiet(t, 10*time.Millisecond)
	if !svcAudited(t, h, "svc.run.job", "ok") {
		t.Error("no svc.run.job audit row")
	}
	// a cancel reaches the login running it
	if st, _ := svcDo(t, h, http.MethodPost, SvcRunsPath+"/"+b+"/cancel", tok, nil); st/100 != 2 {
		t.Fatalf("cancel: %d", st)
	}
	select {
	case c := <-svc.cancels:
		if c.Run != b || c.Attempt != 1 {
			t.Fatalf("svc_run_cancel %+v; want %s 1", c, b)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("no svc_run_cancel")
	}
}

// No service login named (or none linked): nothing is sent, runs stay queued.
func TestSvcRunNoServiceLoginWaits(t *testing.T) {
	h, tok := svcNodeRig(t, "")
	svc := startFakeSvcLogin(t, h, "svc1", "mini", "fleetsvc1")
	ref := svcSubmit(t, h, tok, svcReq("space:ws:a", "a1"))["run_id"].(string)
	h.srv.SvcRunsTick(context.Background(), time.Now())
	svc.quiet(t, 300*time.Millisecond)
	if st := svcState(t, h, tok, ref)["state"]; st != store.SvcRunQueued {
		t.Fatalf("state %v with no service login named; want queued", st)
	}
	if n := (&NodeSvcRunner{s: h.srv}).FreeSlots(map[string]string{}); n != 0 {
		t.Fatalf("free slots %d with none named", n)
	}
	if n := (&NodeSvcRunner{s: h.srv}).FreeSlots(map[string]string{SvcLoginsKey: "mini:fleetsvc1", SvcPerLoginKey: "3"}); n != 3 {
		t.Fatalf("free slots %d; want 3 (one login × per_login 3)", n)
	}
}

// The two settings are the operator's, and refuse a value they cannot read.
func TestSvcLoginsSettings(t *testing.T) {
	h, _ := svcNodeRig(t, "")
	put := func(k, v string) int {
		t.Helper()
		code, _ := h.post(t, "/v1/fleet/settings", map[string]string{"key": k, "value": v})
		return code
	}
	for v, want := range map[string]int{"mac-a:fleetsvc1,mac-b:fleetsvc2": 200, "": 200, "mac-a": 400, "mac-a:Bad Name": 400} {
		if got := put(SvcLoginsKey, v); got != want {
			t.Errorf("%s=%q: %d, want %d", SvcLoginsKey, v, got, want)
		}
	}
	for v, want := range map[string]int{"2": 200, "": 200, "0": 400, "9": 400, "x": 400} {
		if got := put(SvcPerLoginKey, v); got != want {
			t.Errorf("%s=%q: %d, want %d", SvcPerLoginKey, v, got, want)
		}
	}
}
