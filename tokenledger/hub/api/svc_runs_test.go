package api

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

// Service runs (claude-fleet#4004): dispatch one, read it, cancel it, be told
// how it ended — against a fake runner.

type fakeSvcRunner struct {
	mu        sync.Mutex
	started   []string
	cancelled []string
	failStart bool
}

func (f *fakeSvcRunner) Start(_ context.Context, r store.SvcRun) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.started = append(f.started, r.Ref())
	if f.failStart {
		return io.ErrUnexpectedEOF
	}
	return nil
}

func (f *fakeSvcRunner) Cancel(_ context.Context, r store.SvcRun) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.cancelled = append(f.cancelled, r.Ref())
	return nil
}

const svcTestDigest = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

// svcRunsHarness is a fleet hub with svc:livepage (every scope), a fake
// runner, and its token.
func svcRunsHarness(t *testing.T) (*harness, *fakeSvcRunner, string) {
	t.Helper()
	h := newFleetHarness(t)
	fr := &fakeSvcRunner{}
	h.srv.SvcRunner = fr
	return h, fr, svcSetup(t, h, "livepage", "runs:write runs:read templates:write")
}

func svcDo(t *testing.T, h *harness, method, path, tok string, body any) (int, map[string]any) {
	t.Helper()
	var rd io.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		rd = bytes.NewReader(b)
	}
	r, _ := http.NewRequest(method, h.http.URL+path, rd)
	r.Header.Set("Authorization", "Bearer "+tok)
	res, err := http.DefaultClient.Do(r)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	out := map[string]any{}
	raw, _ := io.ReadAll(res.Body)
	_ = json.Unmarshal(raw, &out)
	return res.StatusCode, out
}

func svcReq(tenant, key string) SvcRunRequest {
	return SvcRunRequest{Template: "daily", TemplateDigest: svcTestDigest, Tenant: tenant, Subject: "space:user:1",
		Inputs: json.RawMessage(`{"request":"行业动态","tz":"Asia/Shanghai"}`), IdempotencyKey: key}
}

func svcSubmit(t *testing.T, h *harness, tok string, req SvcRunRequest) map[string]any {
	t.Helper()
	st, out := svcDo(t, h, http.MethodPost, SvcRunsPath, tok, req)
	if st != http.StatusAccepted {
		t.Fatalf("submit %s: %d %v", req.IdempotencyKey, st, out)
	}
	return out
}

func svcRunID(t *testing.T, ref string) int64 {
	t.Helper()
	id := store.ParseSvcRunRef(ref)
	if id == 0 {
		t.Fatalf("%q is not R<n>", ref)
	}
	return id
}

func svcState(t *testing.T, h *harness, tok, ref string) map[string]any {
	t.Helper()
	st, out := svcDo(t, h, http.MethodGet, SvcRunsPath+"/"+ref, tok, nil)
	if st != http.StatusOK {
		t.Fatalf("get %s: %d %v", ref, st, out)
	}
	return out
}

var svcGoodResult = &SvcRunResult{Report: "# 行业日报\n\n- 一条", Meta: json.RawMessage(`{"title":"行业日报","summary":"今天三条","sources":[]}`)}

// The same idempotency key twice is the same run; with other words it is 409.
func TestSvcRunIdempotent(t *testing.T) {
	h, _, tok := svcRunsHarness(t)
	a := svcSubmit(t, h, tok, svcReq("space:ws:1", "k1"))
	b := svcSubmit(t, h, tok, svcReq("space:ws:1", "k1"))
	if a["run_id"] != b["run_id"] || !strings.HasPrefix(a["run_id"].(string), "R") {
		t.Fatalf("two runs for one key: %v %v", a["run_id"], b["run_id"])
	}
	if b["replayed"] != true || a["replayed"] == true {
		t.Errorf("replayed: first %v, second %v", a["replayed"], b["replayed"])
	}
	other := svcReq("space:ws:2", "k1")
	if st, out := svcDo(t, h, http.MethodPost, SvcRunsPath, tok, other); st != http.StatusConflict {
		t.Errorf("same key, other tenant: %d %v", st, out)
	}
	runs, _ := h.srv.Store.SvcRuns(store.SvcRunFilter{})
	if len(runs) != 1 {
		t.Errorf("%d rows, want 1", len(runs))
	}
	if !svcAudited(t, h, "svc.run.submit", "ok") || !svcAudited(t, h, "svc.run.start", "ok") {
		t.Error("submit / start left no audit row")
	}
}

// At most one run per tenant and max_running in all; the rest wait in order.
func TestSvcRunConcurrency(t *testing.T) {
	h, fr, tok := svcRunsHarness(t)
	if err := h.srv.Store.SetFleetSetting(SvcMaxRunningKey("svc:livepage"), "2", time.Now()); err != nil {
		t.Fatal(err)
	}
	a1 := svcSubmit(t, h, tok, svcReq("space:ws:a", "a1"))["run_id"].(string)
	a2 := svcSubmit(t, h, tok, svcReq("space:ws:a", "a2"))["run_id"].(string)
	b1 := svcSubmit(t, h, tok, svcReq("space:ws:b", "b1"))["run_id"].(string)
	c1 := svcSubmit(t, h, tok, svcReq("space:ws:c", "c1"))["run_id"].(string)
	want := map[string]string{a1: "running", a2: "queued", b1: "running", c1: "queued"}
	for ref, w := range want {
		if got := svcState(t, h, tok, ref)["state"]; got != w {
			t.Errorf("%s: %v, want %s", ref, got, w)
		}
	}
	if _, err := h.srv.SvcRunFinish(svcRunID(t, a1), store.SvcRunSucceeded, "", svcGoodResult, nil); err != nil {
		t.Fatal(err)
	}
	h.srv.SvcRunsTick(context.Background(), time.Now())
	// a2 is older than c1 and its tenant is free again.
	if got := svcState(t, h, tok, a2)["state"]; got != "running" {
		t.Errorf("a2 after a1 ended: %v", got)
	}
	if got := svcState(t, h, tok, c1)["state"]; got != "queued" {
		t.Errorf("c1 past the cap: %v", got)
	}
	if len(fr.started) != 3 {
		t.Errorf("runner started %v", fr.started)
	}
}

// Queued past 30 minutes: expired, queue_timeout. Running past its deadline:
// failed, run_timeout, the runner told to stop.
func TestSvcRunTimeouts(t *testing.T) {
	h, fr, tok := svcRunsHarness(t)
	h.srv.Store.SetFleetSetting(SvcMaxRunningKey("svc:livepage"), "1", time.Now())
	r1 := svcSubmit(t, h, tok, svcReq("space:ws:a", "t1"))["run_id"].(string)
	r2 := svcSubmit(t, h, tok, svcReq("space:ws:b", "t2"))["run_id"].(string)
	h.srv.SvcRunsTick(context.Background(), time.Now().Add(10*time.Minute))
	if got := svcState(t, h, tok, r2)["state"]; got != "queued" {
		t.Fatalf("r2 at 10m: %v", got)
	}
	h.srv.SvcRunsTick(context.Background(), time.Now().Add(31*time.Minute))
	got := svcState(t, h, tok, r2)
	if got["state"] != "expired" || got["error_code"] != SvcErrQueueTimeout {
		t.Errorf("r2 at 31m: %v %v", got["state"], got["error_code"])
	}
	got = svcState(t, h, tok, r1)
	if got["state"] != "failed" || got["error_code"] != SvcErrRunTimeout {
		t.Errorf("r1 past 900s + grace: %v %v", got["state"], got["error_code"])
	}
	if len(fr.cancelled) != 1 || fr.cancelled[0] != r1 {
		t.Errorf("runner cancel %v", fr.cancelled)
	}
	// The runner's late word changes nothing.
	run, _ := h.srv.SvcRunFinish(svcRunID(t, r1), store.SvcRunSucceeded, "", svcGoodResult, nil)
	if run.State != store.SvcRunFailed {
		t.Errorf("a late result rewrote a timed-out run: %s", run.State)
	}
}

// Cancel a queued run and a running one; a second cancel is 409.
func TestSvcRunCancel(t *testing.T) {
	h, fr, tok := svcRunsHarness(t)
	run := svcSubmit(t, h, tok, svcReq("space:ws:a", "c1"))["run_id"].(string)
	queued := svcSubmit(t, h, tok, svcReq("space:ws:a", "c2"))["run_id"].(string)
	for _, ref := range []string{queued, run} {
		st, out := svcDo(t, h, http.MethodPost, SvcRunsPath+"/"+ref+"/cancel", tok, nil)
		if st != http.StatusOK || out["state"] != "cancelled" || out["error_code"] != SvcErrCancelled {
			t.Errorf("cancel %s: %d %v", ref, st, out)
		}
	}
	if len(fr.cancelled) != 1 || fr.cancelled[0] != run {
		t.Errorf("runner told to cancel %v, want only the running %s", fr.cancelled, run)
	}
	if st, _ := svcDo(t, h, http.MethodPost, SvcRunsPath+"/"+run+"/cancel", tok, nil); st != http.StatusConflict {
		t.Errorf("second cancel: %d", st)
	}
	r, _ := h.srv.SvcRunFinish(svcRunID(t, run), store.SvcRunSucceeded, "", svcGoodResult, nil)
	if r.State != store.SvcRunCancelled {
		t.Errorf("the runner's word after a cancel: %s", r.State)
	}
	if !svcAudited(t, h, "svc.run.cancel", "ok") {
		t.Error("no svc.run.cancel audit row")
	}
}

// Another principal's run is 404; a read-only token cannot submit or cancel.
func TestSvcRunScopes(t *testing.T) {
	h, _, tok := svcRunsHarness(t)
	ref := svcSubmit(t, h, tok, svcReq("space:ws:a", "s1"))["run_id"].(string)
	other := svcSetup(t, h, "other", "runs:read runs:write")
	if st, _ := svcDo(t, h, http.MethodGet, SvcRunsPath+"/"+ref, other, nil); st != http.StatusNotFound {
		t.Errorf("other principal's GET: %d", st)
	}
	if st, _ := svcDo(t, h, http.MethodPost, SvcRunsPath+"/"+ref+"/cancel", other, nil); st != http.StatusNotFound {
		t.Errorf("other principal's cancel: %d", st)
	}
	if _, out := svcDo(t, h, http.MethodGet, SvcRunsPath, other, nil); len(out["runs"].([]any)) != 0 {
		t.Errorf("other principal lists %v", out["runs"])
	}
	reader := svcSetup(t, h, "reader", "runs:read")
	if st, _ := svcDo(t, h, http.MethodPost, SvcRunsPath, reader, svcReq("space:ws:a", "s2")); st != http.StatusForbidden {
		t.Errorf("read-only submit: %d", st)
	}
	if st, _ := svcDo(t, h, http.MethodGet, SvcRunsPath+"/"+ref, reader, nil); st != http.StatusNotFound {
		t.Errorf("reader sees livepage's run: %d", st)
	}
	if st, _ := svcDo(t, h, http.MethodGet, SvcRunsPath+"/R0", tok, nil); st != http.StatusNotFound {
		t.Errorf("R0: %d", st)
	}
	// list filters by tenant and state
	svcSubmit(t, h, tok, svcReq("space:ws:b", "s3"))
	_, out := svcDo(t, h, http.MethodGet, SvcRunsPath+"?tenant=space:ws:b", tok, nil)
	if runs := out["runs"].([]any); len(runs) != 1 {
		t.Errorf("tenant filter: %v", runs)
	}
	bad := svcReq("space:ws:a", "s4")
	bad.TemplateDigest = "nope"
	if st, out := svcDo(t, h, http.MethodPost, SvcRunsPath, tok, bad); st != http.StatusBadRequest || out["error_code"] != SvcErrTemplateInvalid {
		t.Errorf("bad digest: %d %v", st, out)
	}
}

// callback_url must sit under the registered prefix.
func TestSvcRunCallbackPrefix(t *testing.T) {
	h, _, tok := svcRunsHarness(t)
	req := svcReq("space:ws:a", "p1")
	req.CallbackURL = "https://space.example.com/hooks/fleet"
	if st, _ := svcDo(t, h, http.MethodPost, SvcRunsPath, tok, req); st != http.StatusBadRequest {
		t.Errorf("no prefix registered: %d", st)
	}
	if st, out := svcAdmin(t, h, SvcAdminRequest{Op: "callback", Principal: "livepage",
		CallbackPrefix: "http://space.example.com/hooks"}); st != http.StatusBadRequest {
		t.Errorf("plain http prefix: %d %v", st, out)
	}
	st, out := svcAdmin(t, h, SvcAdminRequest{Op: "callback", Principal: "livepage",
		CallbackPrefix: "https://space.example.com/hooks"})
	if st != http.StatusOK || !strings.HasPrefix(out["secret"].(string), "fcb_") || out["callback_prefix"] != "https://space.example.com/hooks/" {
		t.Fatalf("register: %d %v", st, out)
	}
	if _, again := svcAdmin(t, h, SvcAdminRequest{Op: "callback", Principal: "livepage",
		CallbackPrefix: "https://space.example.com/hooks"}); again["secret"] != nil {
		t.Errorf("re-registering without rotate showed a secret again")
	}
	i := 0
	for u, want := range map[string]int{
		"https://space.example.com/hooks/fleet":         http.StatusAccepted,
		"https://space.example.com/hooksX/fleet":        http.StatusBadRequest,
		"https://space.example.com.evil.io/hooks/fleet": http.StatusBadRequest,
		"https://space.example.com/hooks/../admin":      http.StatusBadRequest,
		"https://space.example.com/hooks/%2e%2e/admin":  http.StatusBadRequest,
		"https://evil.io/hooks/fleet":                   http.StatusBadRequest,
		"https://space.example.com/hooks/x#frag":        http.StatusBadRequest,
	} {
		i++
		req := svcReq("space:ws:a", "p-"+strconv.Itoa(i))
		req.CallbackURL = u
		if st, out := svcDo(t, h, http.MethodPost, SvcRunsPath, tok, req); st != want {
			t.Errorf("%s: %d %v, want %d", u, st, out, want)
		}
	}
}

func svcVerify(t *testing.T, secret, sig string, body []byte) {
	t.Helper()
	var ts, v1 string
	for _, part := range strings.Split(sig, ",") {
		k, v, _ := strings.Cut(part, "=")
		switch k {
		case "t":
			ts = v
		case "v1":
			v1 = v
		}
	}
	m := hmac.New(sha256.New, []byte(secret))
	m.Write([]byte(ts + "." + string(body)))
	if ts == "" || !hmac.Equal([]byte(v1), []byte(hex.EncodeToString(m.Sum(nil)))) {
		t.Errorf("signature %q does not verify", sig)
	}
}

// The end to end: submit → the runner starts → it ends → the callback, signed,
// carries the result; GET answers the same; a failing receiver is retried at
// 1m / 5m / 30m and then given up.
func TestSvcRunEndToEnd(t *testing.T) {
	h, fr, tok := svcRunsHarness(t)
	var mu sync.Mutex
	var got [][]byte
	var sigs []string
	fail := 2
	space := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		mu.Lock()
		defer mu.Unlock()
		got, sigs = append(got, b), append(sigs, r.Header.Get("X-Fleet-Signature"))
		if fail > 0 {
			fail--
			w.WriteHeader(http.StatusBadGateway)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	}))
	defer space.Close()
	_, reg := svcAdmin(t, h, SvcAdminRequest{Op: "callback", Principal: "livepage", CallbackPrefix: space.URL + "/cb"})
	secret := reg["secret"].(string)

	req := svcReq("space:ws:a", "e1")
	req.CallbackURL = space.URL + "/cb/run"
	ref := svcSubmit(t, h, tok, req)["run_id"].(string)
	if len(fr.started) != 1 || fr.started[0] != ref {
		t.Fatalf("runner started %v", fr.started)
	}
	if svcState(t, h, tok, ref)["state"] != "running" {
		t.Fatal("not running after submit")
	}
	usage := json.RawMessage(`{"model":"m","input_tokens":10,"output_tokens":20,"wall_s":30}`)
	if _, err := h.srv.SvcRunFinish(svcRunID(t, ref), store.SvcRunSucceeded, "", svcGoodResult, usage); err != nil {
		t.Fatal(err)
	}
	view := svcState(t, h, tok, ref)
	res, _ := view["result"].(map[string]any)
	if view["state"] != "succeeded" || res["report"] != svcGoodResult.Report || view["usage"] == nil {
		t.Fatalf("GET after the end: %v", view)
	}

	ctx, t0 := context.Background(), time.Now()
	h.srv.SvcCallbacksTick(ctx, t0)                                               // try 1: 502
	h.srv.SvcCallbacksTick(ctx, t0.Add(30*time.Second))                           // not due yet
	h.srv.SvcCallbacksTick(ctx, t0.Add(61*time.Second))                           // try 2: 502
	h.srv.SvcCallbacksTick(ctx, t0.Add(61*time.Second+5*time.Minute+time.Second)) // try 3: 204
	h.srv.SvcCallbacksTick(ctx, t0.Add(2*time.Hour))                              // nothing left
	mu.Lock()
	defer mu.Unlock()
	if len(got) != 3 {
		t.Fatalf("%d callbacks, want 3", len(got))
	}
	for i := range got {
		svcVerify(t, secret, sigs[i], got[i])
	}
	var body map[string]any
	_ = json.Unmarshal(got[2], &body)
	if body["run_id"] != ref || body["state"] != "succeeded" || body["result"] == nil || body["usage"] == nil {
		t.Errorf("callback body %v", body)
	}
	run, _ := h.srv.Store.SvcRun(svcRunID(t, ref))
	if run.CallbackState != store.SvcCallbackDelivered || run.CallbackAttempts != 3 {
		t.Errorf("callback %s after %d", run.CallbackState, run.CallbackAttempts)
	}
}

// A receiver that never answers 2xx: four tries in all, then failed — and GET
// still answers the run.
func TestSvcRunCallbackGivesUp(t *testing.T) {
	h, _, tok := svcRunsHarness(t)
	n := 0
	space := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		n++
		w.WriteHeader(http.StatusInternalServerError)
	}))
	defer space.Close()
	svcAdmin(t, h, SvcAdminRequest{Op: "callback", Principal: "livepage", CallbackPrefix: space.URL + "/"})
	req := svcReq("space:ws:a", "g1")
	req.CallbackURL = space.URL + "/x"
	ref := svcSubmit(t, h, tok, req)["run_id"].(string)
	h.srv.SvcRunFinish(svcRunID(t, ref), store.SvcRunFailed, SvcErrRunTimeout, nil, nil) // not retried
	t0 := time.Now()
	for _, at := range []time.Duration{0, 2 * time.Minute, 8 * time.Minute, 40 * time.Minute, 3 * time.Hour} {
		h.srv.SvcCallbacksTick(context.Background(), t0.Add(at))
	}
	run, _ := h.srv.Store.SvcRun(svcRunID(t, ref))
	if n != 4 || run.CallbackState != store.SvcCallbackFailed {
		t.Errorf("%d tries, state %s; want 4 and failed", n, run.CallbackState)
	}
	if v := svcState(t, h, tok, ref); v["state"] != "failed" || v["error_code"] != SvcErrRunTimeout {
		t.Errorf("GET after the callback gave up: %v", v)
	}
}

// A result the contract refuses fails the run output_invalid; a runner that
// cannot start fails it infra_error.
func TestSvcRunOutputInvalid(t *testing.T) {
	h, fr, tok := svcRunsHarness(t)
	ref := svcSubmit(t, h, tok, svcReq("space:ws:a", "o1"))["run_id"].(string)
	long := &SvcRunResult{Report: "x", Meta: json.RawMessage(`{"title":"t","summary":"` + strings.Repeat("长", 61) + `"}`)}
	run, _ := h.srv.SvcRunFinish(svcRunID(t, ref), store.SvcRunSucceeded, "", long, nil)
	if run.State != store.SvcRunFailed || run.ErrorCode != SvcErrOutputInvalid {
		t.Errorf("summary over 60: %s %s", run.State, run.ErrorCode)
	}
	fr.failStart = true
	ref2 := svcSubmit(t, h, tok, svcReq("space:ws:b", "o2"))["run_id"].(string)
	// The first failed start is retried once (claude-fleet#4007) …
	if v := svcState(t, h, tok, ref2); v["state"] != "queued" || v["attempt"] != float64(1) {
		t.Errorf("runner start failed once: %v", v)
	}
	// … and the second ends it.
	h.srv.SvcRunsTick(context.Background(), time.Now())
	if v := svcState(t, h, tok, ref2); v["state"] != "failed" || v["error_code"] != SvcErrInfra || v["attempt"] != float64(2) {
		t.Errorf("runner start failed twice: %v", v)
	}
}

// No runner: nothing is dispatched; the run waits and expires.
func TestSvcRunNoRunner(t *testing.T) {
	h, _, tok := svcRunsHarness(t)
	h.srv.SvcRunner = nil
	ref := svcSubmit(t, h, tok, svcReq("space:ws:a", "n1"))["run_id"].(string)
	h.srv.SvcRunsTick(context.Background(), time.Now())
	if v := svcState(t, h, tok, ref); v["state"] != "queued" {
		t.Errorf("no runner: %v", v["state"])
	}
}
