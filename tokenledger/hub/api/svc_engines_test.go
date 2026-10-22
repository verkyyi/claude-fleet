package api

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

func TestSvcEngineThreeFailuresFallbackOnce(t *testing.T) {
	for _, code := range []string{SvcErrInfra, SvcErrOutputInvalid, SvcErrRunTimeout} {
		t.Run(code, func(t *testing.T) {
			h, _, tok := svcRunsHarness(t)
			ref := svcSubmit(t, h, tok, svcExplicitDualReq("probe", code))["run_id"].(string)
			id := svcRunID(t, ref)
			if err := h.srv.Store.SetSvcRunEngine(id, 1, "codex"); err != nil {
				t.Fatal(err)
			}
			first, _ := h.srv.Store.SvcRun(id)
			run, err := h.srv.SvcRunFinish(id, store.SvcRunFailed, code, nil, json.RawMessage(`{"engine":"forged","wall_s":10,"input_tokens":5}`))
			if err != nil || run.State != store.SvcRunQueued {
				t.Fatalf("first: %+v %v", run, err)
			}
			v := svcRunView(run, false)
			if v.Progress.Stage != "fallback" || !strings.Contains(string(v.Attempts), `"engine":"codex"`) {
				t.Fatalf("view: %+v", v)
			}
			h.srv.SvcRunsTick(context.Background(), time.Now())
			if err := h.srv.Store.SetSvcRunEngine(id, 2, "claude"); err != nil {
				t.Fatal(err)
			}
			run, err = h.srv.SvcRunFinish(id, store.SvcRunFailed, code, nil, json.RawMessage(`{"wall_s":20,"input_tokens":7}`))
			if err != nil || run.State != store.SvcRunFailed || run.Attempt != 2 || !run.DeadlineAt.Equal(*first.DeadlineAt) {
				t.Fatalf("second: %+v %v", run, err)
			}
			var attempts []svcAttempt
			_ = json.Unmarshal([]byte(run.AttemptsJSON), &attempts)
			if len(attempts) != 2 || attempts[0].Engine != "codex" || attempts[1].Engine != "claude" || attempts[1].WallS != 20 {
				t.Fatalf("attempts %s", run.AttemptsJSON)
			}
			var usage map[string]any
			_ = json.Unmarshal([]byte(run.UsageJSON), &usage)
			if usage["engine"] != "claude" || usage["wall_s"] != float64(30) || usage["input_tokens"] != float64(12) {
				t.Fatalf("usage %v", usage)
			}
			again, _ := h.srv.SvcRunFinish(id, store.SvcRunFailed, code, nil, nil)
			if again.AttemptsJSON != run.AttemptsJSON {
				t.Fatal("late result changed attempt history")
			}
		})
	}
}

func TestSvcEngineModerationAndTemplateNeverFallback(t *testing.T) {
	for _, code := range []string{"moderation_blocked", SvcErrTemplateInvalid, SvcErrTenantLimit, SvcErrQuotaExceeded} {
		h, _, tok := svcRunsHarness(t)
		ref := svcSubmit(t, h, tok, svcExplicitDualReq("probe", code))["run_id"].(string)
		id := svcRunID(t, ref)
		_ = h.srv.Store.SetSvcRunEngine(id, 1, "codex")
		run, err := h.srv.SvcRunFinish(id, store.SvcRunFailed, code, nil, nil)
		if err != nil || run.State != store.SvcRunFailed || run.Attempt != 1 {
			t.Fatalf("%s: %+v %v", code, run, err)
		}
	}
}

func TestSvcEngineHubRejectsInvalidSuccessThenFallsBack(t *testing.T) {
	h, _, tok := svcRunsHarness(t)
	ref := svcSubmit(t, h, tok, svcExplicitDualReq("probe", "invalid-success"))["run_id"].(string)
	id := svcRunID(t, ref)
	_ = h.srv.Store.SetSvcRunEngine(id, 1, "codex")
	run, err := h.srv.SvcRunFinish(id, store.SvcRunSucceeded, "", nil, nil)
	if err != nil || run.State != store.SvcRunQueued || !strings.Contains(run.AttemptsJSON, SvcErrOutputInvalid) {
		t.Fatalf("%+v %v", run, err)
	}
}

func TestSvcEngineSelectionAndScopedPass(t *testing.T) {
	h, ops, tok := svcEnvRig(t)
	if err := h.srv.Store.PutCredential("svc:livepage", "codex", "test-codex", []byte("test-only"), "oauth", nil, time.Now()); err != nil {
		t.Fatal(err)
	}
	req := svcExplicitDualReq("probe", "codex-first")
	req.EngineTemplates = map[string]string{"codex": svcTestDigest}
	ref := svcSubmit(t, h, tok, req)["run_id"].(string)
	ticket := ops.expect("create-svc-run")
	st, spec := svcDo(t, h, http.MethodGet, NodeSvcRunsPath+"/"+ref+"/spec", ticket.Token, nil)
	if st != 200 || spec["engine"] != "codex" {
		t.Fatalf("spec %d %v", st, spec)
	}
	if v, _ := h.srv.verifySessionCred(spec["pass"].(string), "", "codex", true, time.Now()); !v.Valid {
		t.Fatal("codex pass invalid")
	}
	if v, _ := h.srv.verifySessionCred(spec["pass"].(string), "", "claude", true, time.Now()); v.Valid {
		t.Fatal("codex pass opens claude")
	}
	if spec["attempt_timeout_s"].(float64) > 450 {
		t.Fatal("no time reserved for fallback")
	}
	// A repeated spec read must not end or change the live attempt.
	st, _ = svcDo(t, h, http.MethodGet, NodeSvcRunsPath+"/"+ref+"/spec", ticket.Token, nil)
	run, _ := h.srv.Store.SvcRun(svcRunID(t, ref))
	if st != 409 || run.State != store.SvcRunRunning || run.Engine != "codex" {
		t.Fatalf("replay changed run %+v", run)
	}
}

func TestSvcEngineUnavailableCodexStartsClaude(t *testing.T) {
	h, ops, tok := svcEnvRig(t) // Claude only
	req := svcExplicitDualReq("probe", "codex-empty")
	req.EngineTemplates = map[string]string{"codex": svcTestDigest}
	ref := svcSubmit(t, h, tok, req)["run_id"].(string)
	ticket := ops.expect("create-svc-run")
	st, spec := svcDo(t, h, http.MethodGet, NodeSvcRunsPath+"/"+ref+"/spec", ticket.Token, nil)
	if st != 200 || spec["engine"] != "claude" {
		t.Fatalf("spec %d %v", st, spec)
	}
	run, _ := h.srv.Store.SvcRun(svcRunID(t, ref))
	if svcFallbackAllowed(run, SvcErrInfra) {
		t.Fatal("Claude fallback may not repeat")
	}
}

func TestSvcProbeConsecutiveFinalFailures(t *testing.T) {
	runs := []store.SvcRun{{ID: 1, Principal: "svc:test", Tenant: "probe", State: store.SvcRunFailed},
		{ID: 2, Principal: "svc:test", Tenant: "probe", State: store.SvcRunFailed}}
	health := map[string]*svcHealth{}
	svcProbeHealth(health, runs)
	if health["svc:test"] == nil || !health["svc:test"].degraded() {
		t.Fatal("two failed probes silent")
	}
	runs = append(runs, store.SvcRun{ID: 3, Principal: "svc:test", Tenant: "probe", State: store.SvcRunSucceeded})
	health = map[string]*svcHealth{}
	svcProbeHealth(health, runs)
	if health["svc:test"] != nil {
		t.Fatal("successful probe did not clear streak")
	}
}

func TestSvcCodexPlainTemplateAndSingleEngine(t *testing.T) {
	h, ops, tok := svcEnvRig(t)
	st, registered := svcDo(t, h, http.MethodPost, SvcTemplatesPath, tok,
		map[string]any{"engine": "codex", "name": "daily-brief", "agent_md": "Write a daily report."})
	if st != 200 {
		t.Fatalf("plain template: %d %v", st, registered)
	}
	if err := h.srv.Store.PutCredential("svc:livepage", "codex", "test-codex", []byte("test-only"), "oauth", nil, time.Now()); err != nil {
		t.Fatal(err)
	}
	req := svcReq("probe", "single-codex")
	req.EnginePref, req.TemplateDigest = "codex", registered["digest"].(string)
	ref := svcSubmit(t, h, tok, req)["run_id"].(string)
	ticket := ops.expect("create-svc-run")
	st, spec := svcDo(t, h, http.MethodGet, NodeSvcRunsPath+"/"+ref+"/spec", ticket.Token, nil)
	if st != 200 || spec["engine"] != "codex" || spec["agent_md"] != "Write a daily report." {
		t.Fatalf("single codex: %d %v", st, spec)
	}
	run, _ := h.srv.Store.SvcRun(svcRunID(t, ref))
	if svcFallbackAllowed(run, SvcErrInfra) {
		t.Fatal("single engine must not fallback")
	}
}

func TestSvcLegacyQueuedRunStillReplaysAndRetries(t *testing.T) {
	h, _, tok := svcEnvRig(t)
	req := svcReq("probe", "before-release")
	req.DeadlineS = 900
	inputs := string(req.Inputs)
	run, _, err := h.srv.Store.CreateSvcRun(store.SvcRun{Principal: "svc:livepage", Tenant: req.Tenant,
		Subject: req.Subject, Template: req.Template, Digest: req.TemplateDigest, InputsJSON: inputs,
		IdempotencyKey: req.IdempotencyKey, RequestSHA: svcRequestSHA(req, inputs), DeadlineS: 900}, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	st, replay := svcDo(t, h, http.MethodPost, SvcRunsPath, tok, req)
	if st != http.StatusAccepted || replay["run_id"] != run.Ref() || replay["replayed"] != true {
		t.Fatalf("legacy replay %d %v", st, replay)
	}
	_, _ = h.srv.Store.ClaimSvcRuns("svc:livepage", 4, time.Now())
	_, _ = h.srv.SvcRunFinish(run.ID, store.SvcRunFailed, SvcErrInfra, nil, nil)
	_, _ = h.srv.Store.ClaimSvcRuns("svc:livepage", 4, time.Now())
	run, _ = h.srv.Store.SvcRun(run.ID)
	_, engine, err := h.srv.svcSelectEngine(run, "svc/legacy/a2", time.Now())
	if err != nil || engine != "claude" {
		t.Fatalf("legacy retry %s %v", engine, err)
	}
}

func svcExplicitDualReq(tenant, key string) SvcRunRequest {
	req := svcReq(tenant, key)
	req.EnginePref = "codex,claude"
	return req
}

func TestSvcOmittedEnginePreservesLegacyTemplateAndRetry(t *testing.T) {
	h, _, tok := svcRunsHarness(t)
	req := svcReq("probe", "legacy-with-stray-mapping")
	originalSHA := svcRequestSHA(req, string(req.Inputs))
	req.EngineTemplates = map[string]string{"codex": strings.Repeat("a", 64), "claude": strings.Repeat("b", 64)}
	if why := svcEngineRequest(&req); why != "" || req.EnginePref != "" || len(req.EngineTemplates) != 0 || svcRequestSHA(req, string(req.Inputs)) != originalSHA {
		t.Fatalf("legacy normalization changed request: %+v %s", req, why)
	}
	ref := svcSubmit(t, h, tok, req)["run_id"].(string)
	id := svcRunID(t, ref)
	run, _ := h.srv.Store.SvcRun(id)
	if svcEngineDigest(run, "claude") != svcTestDigest || svcEngineDigest(run, "codex") != "" {
		t.Fatal("legacy template changed")
	}
	run, err := h.srv.SvcRunFinish(id, store.SvcRunFailed, SvcErrInfra, nil, nil)
	if err != nil || run.State != store.SvcRunQueued {
		t.Fatalf("legacy did not retry: %+v %v", run, err)
	}
	h.srv.SvcRunsTick(context.Background(), time.Now())
	run, _ = h.srv.Store.SvcRun(id)
	if run.Attempt != 2 || len(svcEngineOrder(run)) != 1 || svcEngineOrder(run)[0] != "claude" {
		t.Fatalf("legacy retry changed engine: %+v", run)
	}
	run, err = h.srv.SvcRunFinish(id, store.SvcRunFailed, SvcErrInfra, nil, nil)
	if err != nil || run.State != store.SvcRunFailed {
		t.Fatalf("legacy exceeded retry limit: %+v %v", run, err)
	}
}
