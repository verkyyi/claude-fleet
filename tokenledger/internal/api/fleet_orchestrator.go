package api

import "net/http"

// There is no orchestrating seat any more (claude-fleet#3118, EPIC #3111 C7):
// the hub no longer picks a machine to hold the person's orchestrator, and a
// client's ⌘N opens a new session (#3119). An older node still asks
// /v1/node/orchestrator on its tick, and an older client's ⌘N may still send
// orch_ensure, for one version: both answer 「没有编排」 — never a 500, never a
// window. compat-1v: 下一批删.
//
//	GET|POST /v1/node/orchestrator → {"machine": "", "here": false, "rule": "none", "reason": "没有编排…"}
//
// `rule: none` with no machine is the answer an older bin/fleet-orchestrator.sh
// already read as «the hub names nobody»: it keeps its hands off another
// machine's window and never retires its own.

// noOrchestrator is the one sentence both roads answer with.
const noOrchestrator = "没有编排：入口不再开编排会话；在任一会话里输入 /fleet-orchestrate 接手"

// OrchestratorResponse is the body of /v1/node/orchestrator.
type OrchestratorResponse struct {
	Machine string `json:"machine"`
	Here    bool   `json:"here"`
	Rule    string `json:"rule"`
	Reason  string `json:"reason"`
}

// handleNodeOrchestrator serves /v1/node/orchestrator: 「没有编排」 to a node
// that asks with its own token.
func (s *Server) handleNodeOrchestrator(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.nodeEndpoint(w, r); !ok {
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	if r.Method != http.MethodGet && r.Method != http.MethodPost {
		w.Header().Set("Allow", "GET, POST")
		httpError(w, http.StatusMethodNotAllowed, "GET or POST")
		return
	}
	writeJSON(w, http.StatusOK, OrchestratorResponse{Rule: "none", Reason: noOrchestrator})
}
