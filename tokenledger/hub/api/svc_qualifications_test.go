package api

import (
	"encoding/json"
	"fmt"
	"net/http"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

func svcPolicyFixture(t *testing.T, h *harness) (SvcEvalPolicy, string, string) {
	t.Helper()
	eval := svcSetup(t, h, "report-eval", "runs:eval runs:read")
	grader := svcSetup(t, h, "report-grader", "templates:qualify")
	p := SvcEvalPolicy{Evaluator: "svc:report-eval", Grader: "svc:report-grader", GraderVersion: "grader-v1", CaseSetVersion: "daily-v7"}
	for i := 0; i < 8; i++ {
		p.Cases = append(p.Cases, SvcEvalCase{ID: fmt.Sprintf("case-%d", i), Boundary: i == 0, Inputs: json.RawMessage(fmt.Sprintf(`{"case":%d}`, i))})
	}
	status, out := svcAdmin(t, h, SvcAdminRequest{Op: "eval-policy", Principal: "svc:livepage", EvalPolicy: &p})
	if status != 200 {
		t.Fatalf("admin policy: %d %v", status, out)
	}
	p, err := h.srv.svcEvalPolicy("svc:livepage")
	if err != nil {
		t.Fatal(err)
	}
	return p, eval, grader
}

// Engine routing tests may install an already-verified qualification fixture.
// The HTTP evidence checks themselves are covered below without this shortcut.
func svcQualifiedFixture(t *testing.T, h *harness, digest string) {
	p, _, _ := svcPolicyFixture(t, h)
	if err := h.srv.Store.PutSvcQualification("svc:livepage", "codex", digest, svcPolicyHash(p), `{}`); err != nil {
		t.Fatal(err)
	}
}

func TestSvcQualificationRejectsRegisteredOnlyAndForgedEval(t *testing.T) {
	h, _, prod := svcEnvRig(t)
	req := svcReq("probe", "unqualified")
	req.EnginePref = "codex"
	if status, _ := svcDo(t, h, http.MethodPost, SvcRunsPath, prod, req); status != 403 {
		t.Fatalf("registered only Codex accepted: %d", status)
	}
	if status, _ := svcDo(t, h, http.MethodPost, svcQualificationsPath, prod, map[string]any{"passed": true}); status != 403 {
		t.Fatalf("client self-approved: %d", status)
	}
	if status, _ := svcDo(t, h, http.MethodPost, svcEvalRunsPath, prod, map[string]any{}); status != 403 {
		t.Fatalf("ordinary client eval bypass: %d", status)
	}
	p, eval, _ := svcPolicyFixture(t, h)
	req.EnginePref = "claude"
	req.Tenant = svcEvalTenant("svc:livepage", p, "case-0")
	if status, _ := svcDo(t, h, http.MethodPost, SvcRunsPath, prod, req); status != 403 {
		t.Fatalf("forged eval tenant: %d", status)
	}
	if status, _ := svcDo(t, h, http.MethodPost, SvcRunsPath, eval, req); status != 403 {
		t.Fatalf("eval identity production endpoint: %d", status)
	}
	if status, _ := svcDo(t, h, http.MethodPost, svcEvalRunsPath, eval, map[string]any{"target_principal": "svc:other", "engine": "codex"}); status != 403 {
		t.Fatalf("cross-principal eval: %d", status)
	}
}

func TestSvcUnqualifiedDualSkipsWithoutCodexAttempt(t *testing.T) {
	h, ops, prod := svcEnvRig(t)
	req := svcExplicitDualReq("probe", "unqualified-dual")
	req.EngineTemplates = map[string]string{"codex": svcTestDigest}
	ref := svcSubmit(t, h, prod, req)["run_id"].(string)
	ticket := ops.expect("create-svc-run")
	status, spec := svcDo(t, h, http.MethodGet, NodeSvcRunsPath+"/"+ref+"/spec", ticket.Token, nil)
	if status != 200 || spec["engine"] != "claude" {
		t.Fatalf("did not skip unqualified Codex: %d", status)
	}
	run, err := h.srv.SvcRunFinish(svcRunID(t, ref), store.SvcRunSucceeded, "", svcGoodResult, nil)
	if err != nil {
		t.Fatal(err)
	}
	var a []svcAttempt
	_ = json.Unmarshal([]byte(run.AttemptsJSON), &a)
	if len(a) != 1 || a[0].Engine != "claude" || a[0].Code != "ok" {
		t.Fatalf("fabricated attempt: %+v", a)
	}
}

func TestSvcTrustedEvaluationEvidenceAndRevocation(t *testing.T) {
	h, _, prod := svcRunsHarness(t)
	p, eval, grader := svcPolicyFixture(t, h)
	digest := SvcTemplateDigest("Report honestly.")
	if err := h.srv.Store.PutSvcTemplate(store.SvcTemplate{Principal: "svc:livepage", Digest: digest, Name: "report", AgentMD: "Report honestly."}, time.Now()); err != nil {
		t.Fatal(err)
	}
	evidence := svcQualificationEvidence{Target: "svc:livepage", Engine: "codex", Digest: digest, CaseSet: svcCasesHash(p), GraderVersion: p.GraderVersion}
	for i, c := range p.Cases {
		req := map[string]any{"target_principal": "svc:livepage", "engine": "codex", "template_digest": digest, "case_set_digest": svcCasesHash(p), "case_id": c.ID, "idempotency_key": c.ID, "inputs": map[string]any{"forged": true}, "callback_url": "https://example.invalid/ignored"}
		status, out := svcDo(t, h, http.MethodPost, svcEvalRunsPath, eval, req)
		if status != 202 {
			t.Fatalf("eval %d: %d %v", i, status, out)
		}
		id := svcRunID(t, out["run_id"].(string))
		run, _ := h.srv.Store.SvcRun(id)
		if run.InputsJSON != string(c.Inputs) || run.CallbackURL != "" || !h.srv.svcAuthorizedEval(run, "codex", digest) {
			t.Fatal("caller replaced policy inputs or callback")
		}
		if err := h.srv.Store.SetSvcRunEngine(id, 1, "codex"); err != nil {
			t.Fatal(err)
		}
		if err := h.srv.Store.AddSvcRunJob(store.SvcRunJob{RunID: id, Attempt: 1, KeySHA: fmt.Sprintf("test-key-%d", i)}, time.Now()); err != nil {
			t.Fatal(err)
		}
		if ok, err := h.srv.Store.FetchSvcRunJob(id, 1, "test-pass", time.Now()); err != nil || !ok {
			t.Fatal("fetch fixture failed")
		}
		run, err := h.srv.SvcRunFinish(id, store.SvcRunSucceeded, "", svcGoodResult, json.RawMessage(`{"input_tokens":1}`))
		if err != nil {
			t.Fatal(err)
		}
		evidence.Cases = append(evidence.Cases, svcCaseEvidence{CaseID: c.ID, RunID: run.Ref(), OutputSHA: svcSHA(run.ResultJSON), Passed: i != 7})
		view := svcRunView(run, true)
		if view.ResultSHA256 != svcSHA(run.ResultJSON) {
			t.Fatal("result hash unavailable to grader")
		}
		path := svcEvalRunsPath + "?target_principal=svc:livepage&run_id=" + run.Ref()
		if status, output := svcDo(t, h, http.MethodGet, path, grader, nil); status != 200 || output["result_sha256"] != svcSHA(run.ResultJSON) {
			t.Fatalf("authorized grader cannot read result: %d", status)
		}
		if status, _ := svcDo(t, h, http.MethodGet, path, prod, nil); status != 403 {
			t.Fatalf("production identity read eval result: %d", status)
		}
	}
	// Every rejection is before a qualification has been installed.
	for name, mutate := range map[string]func(*svcQualificationEvidence){
		"duplicate-run":        func(e *svcQualificationEvidence) { e.Cases[1].RunID = e.Cases[0].RunID },
		"duplicate-case":       func(e *svcQualificationEvidence) { e.Cases[1].CaseID = e.Cases[0].CaseID },
		"wrong-output":         func(e *svcQualificationEvidence) { e.Cases[1].OutputSHA = "wrong" },
		"boundary-failure":     func(e *svcQualificationEvidence) { e.Cases[0].Passed = false },
		"six-of-eight":         func(e *svcQualificationEvidence) { e.Cases[6].Passed = false },
		"other-digest":         func(e *svcQualificationEvidence) { e.Digest = svcTestDigest },
		"other-grader-version": func(e *svcQualificationEvidence) { e.GraderVersion = "v2" },
		"other-case-set":       func(e *svcQualificationEvidence) { e.CaseSet = "wrong" },
		"wrong-engine":         func(e *svcQualificationEvidence) { e.Engine = "claude" },
	} {
		t.Run(name, func(t *testing.T) {
			bad := evidence
			bad.Cases = append([]svcCaseEvidence(nil), evidence.Cases...)
			mutate(&bad)
			if status, _ := svcDo(t, h, http.MethodPost, svcQualificationsPath, grader, bad); status != 400 {
				t.Fatalf("bad evidence accepted: %d", status)
			}
			if h.srv.svcQualified("svc:livepage", "codex", digest) {
				t.Fatal("rejection granted qualification")
			}
		})
	}
	if status, _ := svcDo(t, h, http.MethodPost, svcQualificationsPath, eval, evidence); status != 403 {
		t.Fatalf("evaluator self-approved: %d", status)
	}
	if status, _ := svcDo(t, h, http.MethodPost, svcQualificationsPath, grader, evidence); status != 200 {
		t.Fatalf("trusted 7/8 rejected: %d", status)
	}
	status, readback := svcDo(t, h, http.MethodGet, svcQualificationsPath+"?engine=codex&template_digest="+digest, prod, nil)
	if status != 200 || readback["qualified"] != true {
		t.Fatalf("readback: %d %v", status, readback)
	}
	if h.srv.svcQualified("svc:other", "codex", digest) || h.srv.svcQualified("svc:livepage", "codex", svcTestDigest) {
		t.Fatal("qualification leaked")
	}
	req := svcReq("probe", "qualified-production")
	req.EnginePref = "codex"
	req.TemplateDigest = digest
	if status, _ := svcDo(t, h, http.MethodPost, SvcRunsPath, prod, req); status != 202 {
		t.Fatalf("qualified request rejected: %d", status)
	}
	// Updating the admin-owned policy invalidates the old qualification and eval exemption.
	p.GraderVersion = "grader-v2"
	if err := h.srv.svcSetEvalPolicy("svc:livepage", p); err != nil {
		t.Fatal(err)
	}
	if h.srv.svcQualified("svc:livepage", "codex", digest) {
		t.Fatal("stale qualification survived policy change")
	}
	req.IdempotencyKey = "after-policy-change"
	if status, _ := svcDo(t, h, http.MethodPost, SvcRunsPath, prod, req); status != 403 {
		t.Fatalf("stale policy bypass: %d", status)
	}
}

func TestSvcControlledEvalIssuesOnlySelectedEnginePass(t *testing.T) {
	h, ops, _ := svcEnvRig(t)
	p, eval, _ := svcPolicyFixture(t, h)
	if status, _ := h.post(t, CredPolicyPath, map[string]any{"scope": "user", "id": p.Evaluator, "all": true}); status != 200 {
		t.Fatal("fixture evaluator allowlist")
	}
	if err := h.srv.Store.PutCredential(p.Evaluator, "codex", "test-eval-account", []byte("test-only"), "oauth", nil, time.Now()); err != nil {
		t.Fatal(err)
	}
	req := map[string]any{"target_principal": "svc:livepage", "engine": "codex", "template_digest": svcTestDigest, "case_set_digest": svcCasesHash(p), "case_id": "case-0", "idempotency_key": "first-eval"}
	status, out := svcDo(t, h, http.MethodPost, svcEvalRunsPath, eval, req)
	if status != 202 {
		t.Fatalf("controlled eval: %d", status)
	}
	ref := out["run_id"].(string)
	ticket := ops.expect("create-svc-run")
	status, spec := svcDo(t, h, http.MethodGet, NodeSvcRunsPath+"/"+ref+"/spec", ticket.Token, nil)
	if status != 200 || spec["engine"] != "codex" || spec["template_digest"] != svcTestDigest {
		t.Fatalf("eval spec mismatch: %d", status)
	}
	if v, _ := h.srv.verifySessionCred(spec["pass"].(string), "", "codex", true, time.Now()); !v.Valid {
		t.Fatal("eval pass missing Codex authority")
	}
	if v, _ := h.srv.verifySessionCred(spec["pass"].(string), "", "claude", true, time.Now()); v.Valid {
		t.Fatal("eval pass opens fallback engine")
	}
	run, err := h.srv.SvcRunFinish(svcRunID(t, ref), store.SvcRunFailed, SvcErrInfra, nil, nil)
	if err != nil || run.State != store.SvcRunFailed || run.Attempt != 1 {
		t.Fatal("single engine eval retried/fell back")
	}
}
