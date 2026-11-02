package api

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/credvault"
)

const chatCodexFallbackNotice = "这台托管机器只能用 Codex，已用 Codex 打开"

// The home's native agents use the same cluster-specific provider policy as
// computeFor and the credential lease. DeepSeek models are placed separately.
func (s *Server) chatHomeAgents(settings map[string]string, machine string) []string {
	pod := s.podProvidersFor(settings, machine)
	agents := []string{}
	for _, agent := range []string{credvault.Claude, credvault.Codex} {
		if pod == nil || pod[agent] {
			agents = append(agents, agent)
		}
	}
	return agents
}

// Run on the replica owning the relay, so the fallback receipt travels back
// with its response. Keep every other body field, including first-line images.
func (s *Server) chatOpenProvider(w http.ResponseWriter, r *http.Request, person, machine string, body map[string]json.RawMessage) (string, bool) {
	if body == nil {
		s.chatRefuse(w, person, "open", http.StatusBadRequest, "bad_body", "open body must be a JSON object")
		return "", false
	}
	agent := ""
	if raw, ok := body["agent"]; ok && json.Unmarshal(raw, &agent) != nil {
		s.chatRefuse(w, person, "open", http.StatusBadRequest, "agent", "agent: claude or codex")
		return "", false
	}
	if agent == "" {
		agent = credvault.Claude
	}
	if agent != credvault.Claude && agent != credvault.Codex {
		s.chatRefuse(w, person, "open", http.StatusBadRequest, "agent", "agent: claude or codex")
		return "", false
	}
	settings, err := s.Store.FleetSettings()
	if err != nil {
		s.chatRefuse(w, person, "open", http.StatusServiceUnavailable, "home_provider", "暂时无法开始会话，请稍后再试。")
		return "", false
	}
	pod := s.podProvidersFor(settings, machine)
	if pod == nil || pod[agent] {
		return "", true
	}
	if !pod[credvault.Codex] {
		s.chatRefuse(w, person, "open", http.StatusConflict, "home_provider", "这台托管机器不支持所选助手，请选择可用的助手或模型。")
		return "", false
	}
	body["agent"] = json.RawMessage(`"codex"`)
	raw, err := json.Marshal(body)
	if err != nil {
		httpError(w, http.StatusBadRequest, "invalid open body")
		return "", false
	}
	if r.Body != nil {
		_ = r.Body.Close()
	}
	r.Body = io.NopCloser(bytes.NewReader(raw))
	r.ContentLength = int64(len(raw))
	return chatCodexFallbackNotice, true
}

func chatOpenNotice(resp *http.Response, notice string) {
	if notice == "" {
		return
	}
	raw, err := io.ReadAll(resp.Body)
	resp.Body.Close()
	var out map[string]any
	if err == nil && json.Unmarshal(raw, &out) == nil && out != nil && out["state"] != "refused" {
		out["notice"], out["agent"] = notice, credvault.Codex
		raw, _ = json.Marshal(out)
	}
	resp.Body = io.NopCloser(bytes.NewReader(raw))
	resp.ContentLength = int64(len(raw))
	resp.Header.Del("Content-Length")
}
