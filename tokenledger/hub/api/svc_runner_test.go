package api

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/credvault"
	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

// A service run's throwaway environment (claude-fleet#4005): each attempt is a
// create-svc-run ticket to the cluster, and the Job it makes holds one key
// that opens its own run's spec once and its result once — against the fake
// fleet-ops of the spare-pod tests.

const svcTestAgent = "---\nname: report\ndescription: 行业日报\ntools: WebSearch, WebFetch, Read, Write\n---\n按要求整理。\n"

// svcEnvRig is a hub with the account key, the cluster's ops link, session
// passes on, the cluster runner, svc:livepage and its registered template.
func svcEnvRig(t *testing.T) (*harness, *fakeOps, string) {
	t.Helper()
	h := newFleetHarness(t)
	pub, key, _ := ed25519.GenerateKey(nil)
	h.srv.SetAccountKey(key)
	ops := startFakeOps(t, h, pub)
	h.srv.SessionCredKey = bytes.Repeat([]byte{9}, 32)
	h.srv.SvcRunner = NewClusterSvcRunner(h.srv, testCluster)
	tok := svcSetup(t, h, "livepage", "runs:write runs:read templates:write")
	if err := h.srv.Store.PutSvcTemplate(store.SvcTemplate{Principal: "svc:livepage", Digest: svcTestDigest,
		Name: "daily", AgentMD: svcTestAgent}, time.Now()); err != nil {
		t.Fatal(err)
	}
	return h, ops, tok
}

// svcStarted submits a run for tenant and returns its ref and its Job's ticket.
func svcStarted(t *testing.T, h *harness, ops *fakeOps, tok, tenant, key string) (string, control.ClusterTicket) {
	t.Helper()
	ref := svcSubmit(t, h, tok, svcReq(tenant, key))["run_id"].(string)
	tk := ops.expect(control.ClusterCreateSvcRun)
	if tk.Run != ref || tk.Attempt != 1 || tk.Svc != "livepage" || tk.Deadline != 900 || !svcKeyRE.MatchString(tk.Token) {
		t.Fatalf("ticket %+v; want %s attempt 1 of livepage, its deadline and a key", tk, ref)
	}
	return ref, tk
}

// One run, end to end: the ticket, the spec once (template, inputs, a pass
// bound to the run), the result once — then the key and the pass open nothing.
func TestSvcRunJobSpecAndResultOnce(t *testing.T) {
	h, ops, tok := svcEnvRig(t)
	ref, tk := svcStarted(t, h, ops, tok, "space:ws:1", "e1")
	spec := NodeSvcRunsPath + "/" + ref + "/spec?attempt=1"
	st, out := svcDo(t, h, http.MethodGet, spec, tk.Token, nil)
	if st != http.StatusOK || out["agent_md"] != svcTestAgent || out["template_digest"] != svcTestDigest {
		t.Fatalf("spec: %d %v", st, out)
	}
	if in, _ := out["inputs"].(map[string]any); in["request"] != "行业动态" {
		t.Errorf("spec inputs %v", out["inputs"])
	}
	pass, _ := out["pass"].(string)
	v, _ := h.srv.verifySessionCred(pass, "", credvault.Claude, true, time.Now())
	if !v.Valid || v.Principal != "svc:livepage" || !strings.Contains(v.WorkerID, ref) {
		t.Fatalf("the run's pass: %+v", v)
	}
	if v.Exp > time.Now().Add(900*time.Second+svcPassGrace+time.Minute).Unix() {
		t.Errorf("the pass outlives the run's deadline: exp %d", v.Exp)
	}
	if v, _ := h.srv.verifySessionCred(pass, "", credvault.Codex, true, time.Now()); v.Valid {
		t.Error("the run's pass opens Codex too")
	}
	if st, _ := svcDo(t, h, http.MethodGet, spec, tk.Token, nil); st != http.StatusConflict {
		t.Errorf("a second spec read: %d", st)
	}
	res := map[string]any{"attempt": 1, "exit": SvcExitOK, "report": svcGoodResult.Report,
		"meta": svcGoodResult.Meta, "usage": map[string]any{"model": "m", "input_tokens": 10, "output_tokens": 5, "wall_s": 42}}
	st, out = svcDo(t, h, http.MethodPost, NodeSvcRunsPath+"/"+ref+"/result", tk.Token, res)
	if st != http.StatusOK || out["state"] != store.SvcRunSucceeded {
		t.Fatalf("result: %d %v", st, out)
	}
	got := svcState(t, h, tok, ref)
	if got["state"] != store.SvcRunSucceeded || got["result"] == nil || got["usage"] == nil {
		t.Errorf("the run after its result: %v", got)
	}
	if v, _ := h.srv.verifySessionCred(pass, "", credvault.Claude, true, time.Now()); v.Valid {
		t.Error("the pass still holds after the run ended")
	}
	for _, p := range []string{spec, NodeSvcRunsPath + "/" + ref + "/result"} {
		m := http.MethodGet
		if strings.HasSuffix(p, "result") {
			m = http.MethodPost
		}
		if st, _ := svcDo(t, h, m, p, tk.Token, res); st != http.StatusGone {
			t.Errorf("%s %s after the end: %d, want 410", m, p, st)
		}
	}
	if !svcAudited(t, h, "svc.run.job", "ok") || !svcAudited(t, h, "svc.run.spec", "ok") {
		t.Error("no svc.run.job / svc.run.spec audit row")
	}
	ops.quiet(200 * time.Millisecond)
}

// svc-run-sees-keys' hub half: one tenant's Job key opens nothing of another
// tenant's run, a made-up key nothing at all, and no key is kept in the clear.
func TestSvcRunKeyOpensOnlyItsRun(t *testing.T) {
	h, ops, tok := svcEnvRig(t)
	a, ka := svcStarted(t, h, ops, tok, "space:ws:a", "k-a")
	b, kb := svcStarted(t, h, ops, tok, "space:ws:b", "k-b")
	if ka.Token == kb.Token {
		t.Fatal("two runs share a key")
	}
	for _, c := range []struct{ ref, key string }{
		{b, ka.Token}, {a, kb.Token}, {a, "fsj_" + strings.Repeat("a", 52)}, {a, ""}, {a, "fcs_x"},
	} {
		if st, _ := svcDo(t, h, http.MethodGet, NodeSvcRunsPath+"/"+c.ref+"/spec", c.key, nil); st != http.StatusUnauthorized {
			t.Errorf("spec of %s with another key: %d, want 401", c.ref, st)
		}
		if st, _ := svcDo(t, h, http.MethodPost, NodeSvcRunsPath+"/"+c.ref+"/result", c.key,
			map[string]any{"attempt": 1, "exit": 0}); st != http.StatusUnauthorized {
			t.Errorf("result of %s with another key: %d, want 401", c.ref, st)
		}
	}
	for _, id := range []int64{svcRunID(t, a), svcRunID(t, b)} {
		j, err := h.srv.Store.SvcRunJobOf(id, 1)
		if err != nil || j.KeySHA == ka.Token || j.KeySHA == kb.Token || j.KeySHA != svcKeySHA(map[int64]string{
			svcRunID(t, a): ka.Token, svcRunID(t, b): kb.Token}[id]) {
			t.Errorf("run %d keeps %+v (%v); want only its key's sha256", id, j, err)
		}
	}
	// a node token is not a run's key either
	if st, _ := svcDo(t, h, http.MethodGet, NodeSvcRunsPath+"/"+a+"/spec", tok, nil); st != http.StatusUnauthorized {
		t.Errorf("the principal's own token on the Job's road: %d", st)
	}
	ops.quiet(200 * time.Millisecond)
}

// The runner contract's exit codes, and outputs the contract refuses.
func TestSvcRunJobExitCodes(t *testing.T) {
	h, ops, tok := svcEnvRig(t)
	for i, c := range []struct {
		body map[string]any
		code string
	}{
		{map[string]any{"exit": SvcExitOutputInvalid}, SvcErrOutputInvalid},
		{map[string]any{"exit": SvcExitTimeout}, SvcErrRunTimeout},
		{map[string]any{"exit": 0, "report": "# x", "meta": map[string]any{"summary": "no title"}}, SvcErrOutputInvalid},
		{map[string]any{"exit": 0}, SvcErrOutputInvalid},
	} {
		ref, tk := svcStarted(t, h, ops, tok, "space:ws:x"+string(rune('a'+i)), "x"+string(rune('a'+i)))
		c.body["attempt"] = 1
		if st, out := svcDo(t, h, http.MethodPost, NodeSvcRunsPath+"/"+ref+"/result", tk.Token, c.body); st != http.StatusOK ||
			out["state"] != store.SvcRunFailed || out["error_code"] != c.code {
			t.Errorf("%v: %d %v, want failed %s", c.body, st, out, c.code)
		}
	}
	ref, tk := svcStarted(t, h, ops, tok, "space:ws:y", "y1")
	if st, _ := svcDo(t, h, http.MethodPost, NodeSvcRunsPath+"/"+ref+"/result", tk.Token,
		map[string]any{"attempt": 2, "exit": 0}); st != http.StatusConflict {
		t.Errorf("another attempt's result: %d", st)
	}
	// infra_error: the first attempt is retried (claude-fleet#4007) — a new Job,
	// a new key, no more than the deadline left; the old key opens nothing
	st, out := svcDo(t, h, http.MethodPost, NodeSvcRunsPath+"/"+ref+"/result", tk.Token,
		map[string]any{"attempt": 1, "exit": 1, "detail": "claude ended 1"})
	if st != http.StatusOK || out["state"] != store.SvcRunQueued {
		t.Fatalf("attempt 1's infra_error: %d %v, want queued for its retry", st, out)
	}
	h.srv.SvcRunsTick(context.Background(), time.Now())
	tk2 := ops.expect(control.ClusterCreateSvcRun)
	if tk2.Run != ref || tk2.Attempt != 2 || tk2.Token == tk.Token || tk2.Deadline > 900 || tk2.Deadline < 60 {
		t.Fatalf("the retry's ticket %+v", tk2)
	}
	if st, _ := svcDo(t, h, http.MethodGet, NodeSvcRunsPath+"/"+ref+"/spec", tk.Token, nil); st != http.StatusGone {
		t.Errorf("attempt 1's key after its end: %d, want 410", st)
	}
	if st, out := svcDo(t, h, http.MethodPost, NodeSvcRunsPath+"/"+ref+"/result", tk2.Token,
		map[string]any{"attempt": 2, "exit": 1}); st != http.StatusOK || out["state"] != store.SvcRunFailed ||
		out["error_code"] != SvcErrInfra {
		t.Errorf("attempt 2's infra_error: %d %v, want failed infra_error", st, out)
	}
	ops.quiet(200 * time.Millisecond)
}

// A digest never registered: the run ends template_invalid and no Job is asked for.
func TestSvcRunUnregisteredTemplateMakesNoJob(t *testing.T) {
	h, ops, tok := svcEnvRig(t)
	req := svcReq("space:ws:1", "u1")
	req.TemplateDigest = strings.Repeat("e", 64)
	ref := svcSubmit(t, h, tok, req)["run_id"].(string)
	ops.quiet(300 * time.Millisecond)
	if got := svcState(t, h, tok, ref); got["state"] != store.SvcRunFailed || got["error_code"] != SvcErrTemplateInvalid {
		t.Errorf("unregistered digest: %v", got)
	}
}

// A cancel and a run past its deadline: the Job is deleted, the key and the
// pass end.
func TestSvcRunCancelDeletesTheJob(t *testing.T) {
	h, ops, tok := svcEnvRig(t)
	ref, tk := svcStarted(t, h, ops, tok, "space:ws:1", "c1")
	_, out := svcDo(t, h, http.MethodGet, NodeSvcRunsPath+"/"+ref+"/spec", tk.Token, nil)
	pass, _ := out["pass"].(string)
	if st, out := svcDo(t, h, http.MethodPost, SvcRunsPath+"/"+ref+"/cancel", tok, nil); st != http.StatusOK {
		t.Fatalf("cancel: %d %v", st, out)
	}
	if d := ops.expect(control.ClusterDeleteSvcRun); d.Run != ref || d.Attempt != 1 || d.Token != "" {
		t.Errorf("delete ticket %+v", d)
	}
	if st, _ := svcDo(t, h, http.MethodPost, NodeSvcRunsPath+"/"+ref+"/result", tk.Token,
		map[string]any{"attempt": 1, "exit": 0}); st != http.StatusGone {
		t.Errorf("a result after the cancel: %d", st)
	}
	if v, _ := h.srv.verifySessionCred(pass, "", credvault.Claude, true, time.Now()); v.Valid {
		t.Error("the pass holds after a cancel")
	}
	// past its deadline: the sweep fails it and the Job goes
	r2, _ := svcStarted(t, h, ops, tok, "space:ws:2", "c2")
	h.srv.SvcRunsTick(context.Background(), time.Now().Add(20*time.Minute))
	if d := ops.expect(control.ClusterDeleteSvcRun); d.Run != r2 {
		t.Errorf("the timed-out run's delete ticket %+v", d)
	}
	ops.quiet(200 * time.Millisecond)
}
