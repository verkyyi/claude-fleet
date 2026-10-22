package api

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

const svcEvalRunsPath = "/v1/svc/eval-runs"
const svcQualificationsPath = "/v1/svc/template-qualifications"

type svcEvalContextKey struct{}

type SvcEvalCase struct {
	ID       string          `json:"id"`
	Boundary bool            `json:"boundary"`
	Inputs   json.RawMessage `json:"inputs"`
}

type SvcEvalPolicy struct {
	Evaluator      string        `json:"evaluator"`
	Grader         string        `json:"grader"`
	GraderVersion  string        `json:"grader_version"`
	CaseSetVersion string        `json:"case_set_version"`
	Cases          []SvcEvalCase `json:"cases"`
}

func svcSHA(v string) string               { h := sha256.Sum256([]byte(v)); return hex.EncodeToString(h[:]) }
func svcPolicyHash(p SvcEvalPolicy) string { b, _ := json.Marshal(p); return svcSHA(string(b)) }
func svcCasesHash(p SvcEvalPolicy) string {
	b, _ := json.Marshal(struct {
		Version string        `json:"version"`
		Cases   []SvcEvalCase `json:"cases"`
	}{p.CaseSetVersion, p.Cases})
	return svcSHA(string(b))
}

func (s *Server) svcEvalPolicy(target string) (SvcEvalPolicy, error) {
	var p SvcEvalPolicy
	raw, err := s.Store.SvcEvalPolicy(target)
	if err != nil {
		return p, err
	}
	err = json.Unmarshal([]byte(raw), &p)
	return p, err
}

// Only the existing admin-only service management endpoint may install this
// trust policy. Service scopes alone never authorize a target principal.
func (s *Server) svcSetEvalPolicy(target string, p SvcEvalPolicy) error {
	if target == p.Evaluator || target == p.Grader || p.Evaluator == p.Grader {
		return fmt.Errorf("production, evaluator and grader must be separate principals")
	}
	for id, scope := range map[string]string{target: store.SvcRunsWrite, p.Evaluator: store.SvcRunsEval, p.Grader: store.SvcTemplatesQualify} {
		principal, err := s.Store.SvcPrincipal(id)
		if err != nil || !principal.Enabled || !principal.Has(scope) {
			return fmt.Errorf("policy principal lacks required authority")
		}
	}
	if !svcWord(p.GraderVersion, 100) || !svcWord(p.CaseSetVersion, 100) || len(p.Cases) != 8 {
		return fmt.Errorf("policy needs grader version and eight versioned cases")
	}
	seen := map[string]bool{}
	boundary := false
	for i, c := range p.Cases {
		if !svcWord(c.ID, 40) || strings.Contains(c.ID, "/") || seen[c.ID] {
			return fmt.Errorf("case IDs must be unique words without slash")
		}
		var inputs map[string]any
		if json.Unmarshal(c.Inputs, &inputs) != nil || inputs == nil {
			return fmt.Errorf("case inputs must be an object")
		}
		// Canonicalize the exact inputs the hub will dispatch; callers cannot replace them.
		p.Cases[i].Inputs, _ = json.Marshal(inputs)
		seen[c.ID] = true
		boundary = boundary || c.Boundary
	}
	if !boundary {
		return fmt.Errorf("policy must identify boundary cases")
	}
	raw, _ := json.Marshal(p)
	return s.Store.PutSvcEvalPolicy(target, string(raw))
}

func svcEvalTenant(target string, p SvcEvalPolicy, c string) string {
	return "eval/" + base64.RawURLEncoding.EncodeToString([]byte(target)) + "/" + svcPolicyHash(p) + "/" + c
}

func (s *Server) svcAuthorizedEval(run store.SvcRun, engine, digest string) bool {
	parts := strings.Split(run.Tenant, "/")
	if len(parts) != 4 || parts[0] != "eval" || run.EnginePref != engine || run.Digest != digest || run.CallbackURL != "" {
		return false
	}
	b, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return false
	}
	p, err := s.svcEvalPolicy(string(b))
	if err != nil || p.Evaluator != run.Principal || parts[2] != svcPolicyHash(p) {
		return false
	}
	principal, err := s.Store.SvcPrincipal(p.Evaluator)
	if err != nil || !principal.Enabled || !principal.Has(store.SvcRunsEval) {
		return false
	}
	for _, c := range p.Cases {
		if c.ID == parts[3] && string(c.Inputs) == run.InputsJSON {
			return true
		}
	}
	return false
}

func (s *Server) svcQualified(target, engine, digest string) bool {
	p, err := s.svcEvalPolicy(target)
	if err != nil {
		return false
	}
	for id, scope := range map[string]string{p.Evaluator: store.SvcRunsEval, p.Grader: store.SvcTemplatesQualify} {
		who, e := s.Store.SvcPrincipal(id)
		if e != nil || !who.Enabled || !who.Has(scope) {
			return false
		}
	}
	_, err = s.Store.SvcQualification(target, engine, digest, svcPolicyHash(p))
	return err == nil
}

func (s *Server) handleSvcEvalRun(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	caller, _, _ := SvcCallerOf(r.Context())
	if r.Method == http.MethodGet {
		p, err := s.svcEvalPolicy(r.URL.Query().Get("target_principal"))
		if err != nil || !((p.Evaluator == caller.ID && caller.Has(store.SvcRunsEval)) || (p.Grader == caller.ID && caller.Has(store.SvcTemplatesQualify))) {
			httpError(w, http.StatusForbidden, "no evaluation read authority for target")
			return
		}
		run, err := s.Store.SvcRun(store.ParseSvcRunRef(r.URL.Query().Get("run_id")))
		parts := strings.Split(run.Tenant, "/")
		if err != nil || len(parts) != 4 || run.Tenant != svcEvalTenant(r.URL.Query().Get("target_principal"), p, parts[3]) || !s.svcAuthorizedEval(run, run.EnginePref, run.Digest) {
			httpError(w, http.StatusNotFound, "no matching evaluation run")
			return
		}
		writeJSON(w, http.StatusOK, svcRunView(run, SvcRunTerminalView(run)))
		return
	}
	if r.Method != http.MethodPost {
		httpError(w, 405, "GET or POST")
		return
	}
	if !caller.Has(store.SvcRunsEval) {
		httpError(w, http.StatusForbidden, "runs:eval required")
		return
	}
	var in struct {
		Target  string `json:"target_principal"`
		Engine  string `json:"engine"`
		Digest  string `json:"template_digest"`
		CaseSet string `json:"case_set_digest"`
		Case    string `json:"case_id"`
		Key     string `json:"idempotency_key"`
	}
	if json.NewDecoder(http.MaxBytesReader(w, r.Body, 16<<10)).Decode(&in) != nil {
		httpError(w, 400, "malformed eval request")
		return
	}
	p, err := s.svcEvalPolicy(in.Target)
	if err != nil || p.Evaluator != caller.ID {
		httpError(w, 403, "no evaluation authority for target")
		return
	}
	if (in.Engine != "codex" && in.Engine != "claude") || in.CaseSet != svcCasesHash(p) {
		httpError(w, 400, "engine or case set does not match policy")
		return
	}
	target, err := s.Store.SvcPrincipal(in.Target)
	if err != nil || !target.Enabled {
		httpError(w, 403, "target unavailable")
		return
	}
	t, err := s.Store.SvcTemplateOf(in.Target, in.Digest)
	if err != nil {
		httpError(w, 400, "target template not registered")
		return
	}
	var inputs json.RawMessage
	for _, c := range p.Cases {
		if c.ID == in.Case {
			inputs = c.Inputs
		}
	}
	if inputs == nil {
		httpError(w, 400, "unknown case")
		return
	}
	// Copy only the authorized target digest into the evaluator's namespace.
	t.Principal = caller.ID
	if err = s.Store.PutSvcTemplate(t, time.Now()); err != nil {
		httpError(w, 500, "cannot stage eval template")
		return
	}
	req := SvcRunRequest{EnginePref: in.Engine, Template: t.Name, TemplateDigest: in.Digest, Tenant: svcEvalTenant(in.Target, p, in.Case), Subject: in.Case, Inputs: inputs, IdempotencyKey: in.Key, DeadlineS: 900}
	body, _ := json.Marshal(req)
	clone := r.Clone(context.WithValue(r.Context(), svcEvalContextKey{}, true))
	clone.Body = io.NopCloser(bytes.NewReader(body))
	s.handleSvcRunSubmit(w, clone)
}

type svcCaseEvidence struct {
	CaseID    string `json:"case_id"`
	RunID     string `json:"run_id"`
	OutputSHA string `json:"result_sha256"`
	Passed    bool   `json:"passed"`
}
type svcQualificationEvidence struct {
	Target        string            `json:"target_principal"`
	Engine        string            `json:"engine"`
	Digest        string            `json:"template_digest"`
	CaseSet       string            `json:"case_set_digest"`
	GraderVersion string            `json:"grader_version"`
	Cases         []svcCaseEvidence `json:"cases"`
}

func (s *Server) handleSvcQualifications(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	caller, _, _ := SvcCallerOf(r.Context())
	if r.Method == http.MethodGet {
		if !caller.Has(store.SvcRunsRead) {
			httpError(w, 403, "runs:read required")
			return
		}
		p, err := s.svcEvalPolicy(caller.ID)
		if err != nil {
			writeJSON(w, 200, map[string]any{"qualified": false})
			return
		}
		engine, digest := r.URL.Query().Get("engine"), r.URL.Query().Get("template_digest")
		evidence, err := s.Store.SvcQualification(caller.ID, engine, digest, svcPolicyHash(p))
		out := map[string]any{"qualified": err == nil && s.svcQualified(caller.ID, engine, digest), "policy_hash": svcPolicyHash(p), "case_set_digest": svcCasesHash(p), "grader_version": p.GraderVersion}
		if err == nil {
			out["evidence"] = json.RawMessage(evidence)
		}
		writeJSON(w, 200, out)
		return
	}
	if r.Method != http.MethodPost {
		httpError(w, 405, "GET or POST")
		return
	}
	if !caller.Has(store.SvcTemplatesQualify) {
		httpError(w, 403, "templates:qualify required")
		return
	}
	var in svcQualificationEvidence
	if json.NewDecoder(http.MaxBytesReader(w, r.Body, 64<<10)).Decode(&in) != nil {
		httpError(w, 400, "malformed evidence")
		return
	}
	p, err := s.svcEvalPolicy(in.Target)
	if err != nil || p.Grader != caller.ID {
		httpError(w, 403, "no grading authority for target")
		return
	}
	if (in.Engine != "codex" && in.Engine != "claude") || in.CaseSet != svcCasesHash(p) || in.GraderVersion != p.GraderVersion || len(in.Cases) != 8 {
		httpError(w, 400, "evidence does not match policy")
		return
	}
	if _, err = s.Store.SvcTemplateOf(in.Target, in.Digest); err != nil {
		httpError(w, 400, "template not registered")
		return
	}
	seenCases := map[string]bool{}
	seenRuns := map[string]bool{}
	passed := 0
	for _, ev := range in.Cases {
		var c *SvcEvalCase
		for i := range p.Cases {
			if p.Cases[i].ID == ev.CaseID {
				c = &p.Cases[i]
			}
		}
		if c == nil || seenCases[ev.CaseID] || seenRuns[ev.RunID] {
			httpError(w, 400, "duplicate or unknown evidence case/run")
			return
		}
		seenCases[ev.CaseID] = true
		seenRuns[ev.RunID] = true
		run, e := s.Store.SvcRun(store.ParseSvcRunRef(ev.RunID))
		if e != nil || !s.svcAuthorizedEval(run, in.Engine, in.Digest) || run.Tenant != svcEvalTenant(in.Target, p, ev.CaseID) || !store.SvcRunTerminal(run.State) || run.Attempt != 1 || run.Engine != in.Engine {
			httpError(w, 400, "run is not matching terminal single-engine eval")
			return
		}
		job, e := s.Store.SvcRunJobOf(run.ID, 1)
		if e != nil || job.Fetched == nil {
			httpError(w, 400, "eval never fetched a scoped execution pass")
			return
		}
		var attempts []svcAttempt
		if json.Unmarshal([]byte(run.AttemptsJSON), &attempts) != nil || len(attempts) != 1 || attempts[0].Engine != in.Engine {
			httpError(w, 400, "eval attempt mismatch")
			return
		}
		if ev.OutputSHA != svcSHA(run.ResultJSON) {
			httpError(w, 400, "result hash mismatch")
			return
		}
		if ev.Passed && (run.State != store.SvcRunSucceeded || attempts[0].Code != "ok") {
			httpError(w, 400, "failed run cannot pass")
			return
		}
		if c.Boundary && !ev.Passed {
			httpError(w, 400, "boundary case failed")
			return
		}
		if ev.Passed {
			passed++
		}
	}
	minimum := 8
	if in.Engine == "codex" {
		minimum = 7
	}
	if passed < minimum {
		httpError(w, 400, "evaluation threshold not met")
		return
	}
	raw, _ := json.Marshal(map[string]any{"grader_principal": caller.ID, "recorded_at": time.Now().UTC(), "passed": passed, "total": 8, "evidence": in})
	if err = s.Store.PutSvcQualification(in.Target, in.Engine, in.Digest, svcPolicyHash(p), string(raw)); err != nil {
		httpError(w, 500, "cannot persist qualification")
		return
	}
	s.svcAudit(caller.ID, "svc.template.qualify", in.Target+"/"+in.Engine+"/"+in.Digest, "ok", svcPolicyHash(p), time.Now())
	writeJSON(w, 200, map[string]any{"qualified": true, "policy_hash": svcPolicyHash(p)})
}
