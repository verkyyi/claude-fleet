package api

import (
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

type SvcRunProgress struct {
	Stage   string `json:"stage"`
	Engine  string `json:"engine,omitempty"`
	Attempt int    `json:"attempt"`
}

type svcAttempt struct {
	Engine string  `json:"engine"`
	Code   string  `json:"code"`
	WallS  float64 `json:"wall_s"`
}

func svcAttemptsJSON(r store.SvcRun) json.RawMessage {
	if r.AttemptsJSON == "" {
		return json.RawMessage("[]")
	}
	return json.RawMessage(r.AttemptsJSON)
}

func svcProgress(r store.SvcRun) SvcRunProgress {
	stage := r.State
	if store.SvcRunTerminal(stage) {
		stage = "completed"
	}
	if r.State == store.SvcRunQueued && r.Attempt > 0 {
		stage = "fallback"
	}
	return SvcRunProgress{Stage: stage, Engine: r.Engine, Attempt: r.Attempt}
}

func svcEngineRequest(req *SvcRunRequest) string {
	if req.EnginePref == "" {
		req.EnginePref = "codex,claude"
	}
	if req.EnginePref != "codex,claude" && req.EnginePref != "codex" && req.EnginePref != "claude" {
		return "engine_pref is codex,claude, codex, or claude"
	}
	for engine, digest := range req.EngineTemplates {
		if (engine != "codex" && engine != "claude") || !svcHexDigest(strings.TrimPrefix(digest, "sha256:")) {
			return "engine_templates maps codex/claude to registered template digests"
		}
		req.EngineTemplates[engine] = strings.TrimPrefix(digest, "sha256:")
	}
	return ""
}

func svcEngineDigest(run store.SvcRun, engine string) string {
	var templates map[string]string
	_ = json.Unmarshal([]byte(run.EngineTemplates), &templates)
	if digest := templates[engine]; digest != "" {
		return digest
	}
	if engine == "claude" || run.EnginePref == "codex" {
		return run.Digest
	}
	return ""
}

func svcEngineOrder(run store.SvcRun) []string {
	pref := run.EnginePref
	if pref == "" {
		return []string{"claude"}
	} // already queued before this release
	return strings.Split(pref, ",")
}

func svcNextEngine(run store.SvcRun) string {
	order := svcEngineOrder(run)
	if run.Engine == "" && len(order) > 1 {
		return order[1]
	}
	for i, engine := range order {
		if engine == run.Engine && i+1 < len(order) {
			return order[i+1]
		}
	}
	return ""
}

// Select on the hub, before handing out a model pass. The existing binding
// policy remains the single owner of account allowlists and service yielding.
func (s *Server) svcSelectEngine(run store.SvcRun, worker string, now time.Time) (store.SvcTemplate, string, error) {
	order := svcEngineOrder(run)
	if run.Attempt > 1 {
		next := svcNextEngine(run)
		if next == "" {
			return store.SvcTemplate{}, "", fmt.Errorf("no fallback engine remains")
		}
		order = []string{next}
	}
	var reasons []string
	for _, engine := range order {
		digest := svcEngineDigest(run, engine)
		if digest == "" {
			reasons = append(reasons, engine+": no evaluated template registered")
			continue
		}
		template, err := s.Store.SvcTemplateOf(run.Principal, digest)
		if err != nil {
			return store.SvcTemplate{}, "", fmt.Errorf("template_invalid: %s template is not registered", engine)
		}
		if err := s.Store.SetSvcRunEngine(run.ID, run.Attempt, engine); err != nil {
			return store.SvcTemplate{}, "", err
		}
		if _, err := s.sessionBind(worker, run.Principal, "", engine, now); err != nil {
			reasons = append(reasons, s.svcPoolDetail(run.Principal, engine, now))
			continue
		}
		return template, engine, nil
	}
	return store.SvcTemplate{}, "", fmt.Errorf("infra_error: no service engine available: %s", strings.Join(reasons, "; "))
}

// Diagnostic metadata only: no credentials or model response bodies.
func (s *Server) svcPoolDetail(principal, engine string, now time.Time) string {
	choices, err := s.sessionBindChoices(principal, "", engine)
	if err != nil {
		return engine + " pool: policy unavailable"
	}
	settings, _ := s.Store.FleetSettings()
	parts := []string{fmt.Sprintf("%s pool: %d accounts, yield %.0f%%", engine, len(choices), svcYieldPct(settings, principal))}
	for _, c := range choices {
		parts = append(parts, fmt.Sprintf("%s peak %.1f%%", c.Account, s.credPeak(c, now)))
	}
	return strings.Join(parts, ", ")
}

func svcFallbackAllowed(run store.SvcRun, code string) bool {
	if code != SvcErrInfra && code != SvcErrOutputInvalid && code != SvcErrRunTimeout {
		return false
	}
	if run.EnginePref == "" {
		return code == SvcErrInfra
	} // pre-release runs finish under their original contract
	if run.Engine == "" && code != SvcErrInfra {
		return false
	}
	return run.Attempt == 1 && svcNextEngine(run) != ""
}

func (s *Server) svcRecordAttempt(run store.SvcRun, code string, usage json.RawMessage) (string, error) {
	var attempts []svcAttempt
	_ = json.Unmarshal([]byte(run.AttemptsJSON), &attempts)
	var u map[string]any
	_ = json.Unmarshal(usage, &u)
	if u == nil {
		u = map[string]any{}
	}
	wall, _ := u["wall_s"].(float64)
	if wall < 0 {
		wall = 0
	}
	engine := run.Engine
	if engine == "" {
		engine = svcEngineOrder(run)[0]
	}
	u["engine"] = engine
	if run.Attempt > 1 {
		var previous map[string]any
		_ = json.Unmarshal([]byte(run.UsageJSON), &previous)
		for _, k := range []string{"wall_s", "input_tokens", "output_tokens", "cached_input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"} {
			a, _ := previous[k].(float64)
			b, _ := u[k].(float64)
			if a != 0 || b != 0 {
				u[k] = a + b
			}
		}
	}
	if code == "" {
		code = "ok"
	}
	if len(attempts) < run.Attempt {
		attempts = append(attempts, svcAttempt{engine, code, wall})
	}
	a, _ := json.Marshal(attempts)
	b, _ := json.Marshal(u)
	return string(b), s.Store.RecordSvcAttempt(run.ID, run.Attempt, string(a), string(b))
}
