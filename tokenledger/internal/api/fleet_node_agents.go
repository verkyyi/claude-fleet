package api

import (
	"errors"
	"net/http"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// NodeAgentsPath is where a node asks which coding agents the person behind
// one of its logins may start (claude-fleet#3826): the new-session pickers
// (⌘P's ⚡ row, ⌘N, the writing area, ⌘K) show every agent and grey the ones
// the subscription allowlists (fleet_cred_policy.go) leave nothing for —
// 「管理员暂未开放」 — instead of offering an agent whose session cannot start,
// or hiding the choice so the person thinks their client is broken.
//
// The answer is advisory and reads the SAME resolver a session's credential
// does (sessionBindChoices: own + pool, after the allowlists). An agent is
// `blocked` only when subscriptions of it exist and the allowlists take every
// one away; none at all is not blocked — that login may run on its own sign-in.
// No vault, no principal, or no restriction ⇒ every agent usable, so a hub
// without allowlists changes nothing on any picker.
const NodeAgentsPath = "/v1/node/agents"

// NodeAgent is one agent's verdict.
type NodeAgent struct {
	Agent   string `json:"agent"`
	Blocked bool   `json:"blocked,omitempty"`
	// Reason is `policy` when Blocked: the allowlists leave none.
	Reason string `json:"reason,omitempty"`
}

// NodeAgentsResponse is the answer: one row per agent, claude first.
type NodeAgentsResponse struct {
	Agents []NodeAgent `json:"agents"`
}

func (s *Server) handleNodeAgents(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		httpError(w, http.StatusMethodNotAllowed, "GET only")
		return
	}
	ep, ok := s.nodeEndpoint(w, r)
	if !ok {
		return
	}
	out := NodeAgentsResponse{}
	for _, a := range sessionCredProviders {
		out.Agents = append(out.Agents, NodeAgent{Agent: a})
	}
	if s.Vault == nil {
		writeJSON(w, http.StatusOK, out)
		return
	}
	host, osUser := s.nodeIdentity(ep)
	principal, err := s.principalOnNode(ep.ID, host, osUser)
	if errors.Is(err, store.ErrNoPrincipal) {
		writeJSON(w, http.StatusOK, out)
		return
	}
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	pol, err := s.credPolicyFor(ep.ID, principal)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if !pol.Restricted() {
		writeJSON(w, http.StatusOK, out)
		return
	}
	for i, a := range out.Agents {
		has := false
		for _, who := range []string{principal, store.PoolPrincipal} {
			rows, err := s.Store.Credentials(who)
			if err != nil {
				httpError(w, http.StatusInternalServerError, err.Error())
				return
			}
			for _, c := range rows {
				if c.Provider == a.Agent {
					has = true
				}
			}
		}
		if !has {
			continue
		}
		left, err := s.sessionBindChoices(principal, ep.ID, a.Agent)
		if err != nil {
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
		if len(left) == 0 {
			out.Agents[i].Blocked, out.Agents[i].Reason = true, "policy"
		}
	}
	writeJSON(w, http.StatusOK, out)
}
