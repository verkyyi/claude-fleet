package api

import (
	"bytes"
	"encoding/json"
	"fmt"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// dispatchChoice is the accepted provider input, not an agent definition or
// proof of the executable. C3 supplies the actual-provider receipt. Legacy
// requests without coding_agent/dispatch retain their existing protocol.
type dispatchChoice struct {
	Version        int    `json:"version"`
	RequestID      string `json:"request_id"`
	RequestedAgent string `json:"requested_agent"`
	ResolvedAgent  string `json:"resolved_agent"`
	AgentSource    string `json:"agent_source"`
	Task           string `json:"task,omitempty"`
	Generation     int64  `json:"generation,omitempty"`
	AttemptID      string `json:"attempt_id,omitempty"`
}

func codingAgentOK(a string) bool { return a == "claude" || a == "codex" }

func resolveDispatch(coding, legacy string, raw any, key string) (*dispatchChoice, error) {
	bad := func() (*dispatchChoice, error) {
		return nil, fault("INVALID_ARGUMENT", "invalid or contradictory coding agent / accepted dispatch")
	}
	if legacy != "" && !codingAgentOK(legacy) || coding != "" && !codingAgentOK(coding) || coding != "" && legacy != "" && coding != legacy {
		return bad()
	}
	if raw == nil && coding == "" {
		return nil, nil
	}
	d := &dispatchChoice{Version: 1, RequestID: key, RequestedAgent: coding, ResolvedAgent: coding, AgentSource: "explicit"}
	if raw != nil {
		d = &dispatchChoice{}
		b, err := json.Marshal(raw)
		decoder := json.NewDecoder(bytes.NewReader(b))
		decoder.DisallowUnknownFields()
		if err != nil || decoder.Decode(d) != nil {
			return bad()
		}
	}
	if d.Version != 1 || !idemRE.MatchString(d.RequestID) || (key != "" && key != d.RequestID) || !codingAgentOK(d.ResolvedAgent) ||
		(d.RequestedAgent != "default" && !codingAgentOK(d.RequestedAgent)) {
		return bad()
	}
	switch d.AgentSource {
	case "explicit", "template", "label", "fleet", "default":
	default:
		return bad()
	}
	if d.RequestedAgent != "default" && (d.RequestedAgent != d.ResolvedAgent || d.AgentSource != "explicit") ||
		d.RequestedAgent == "default" && d.AgentSource == "explicit" ||
		coding != "" && coding != d.ResolvedAgent || legacy != "" && legacy != d.ResolvedAgent {
		return bad()
	}
	if d.Task != "" && (!taskRefRE.MatchString(d.Task) || d.Generation < 1 || d.AttemptID != fmt.Sprintf("task:%s:g%d", d.Task, d.Generation)) {
		return bad()
	}
	if d.Task == "" && (d.Generation != 0 || d.AttemptID != "") {
		return bad()
	}
	return d, nil
}

// acceptDispatch attaches the C1 identity before journalling/sending. An
// existing legacy T record is never adopted. Replays compare the full original
// input, while a task supplied by the authority must still name its generation.
func (s *Server) acceptDispatch(p fleetPrincipal, w *writeRequest) error {
	if _, draft := w.params["draft"]; draft {
		return nil
	} // unsent draft is not accepted work
	raw, ok := w.params["dispatch"]
	if !ok {
		return nil
	}
	d, err := resolveDispatch("", asString(w.params["agent"]), raw, "")
	if err != nil {
		return err
	}
	var t store.FleetTask
	owner := p.TaskOwner
	if owner == "" {
		owner = p.Actor
	}
	if d.Task != "" {
		if supplied := asString(w.params["task"]); supplied != "" && supplied != d.Task {
			return fault("INVALID_ARGUMENT", "task differs from accepted dispatch")
		}
		t, err = s.Store.FleetTask(store.ParseTaskRef(d.Task))
		if err != nil || t.Owner != owner || t.Repo != w.repo || t.AuthorityVersion != 1 || t.Generation != d.Generation ||
			t.RequestedAgent != d.RequestedAgent || t.ResolvedAgent != d.ResolvedAgent || t.AttemptID != d.AttemptID {
			return fault("INVALID_STATE", "accepted dispatch task owner, generation or provider does not match")
		}

		var payload map[string]any
		if json.Unmarshal([]byte(t.RequestPayload), &payload) != nil {
			return fault("INVALID_STATE", "accepted task has no dispatch input")
		}
		original, _ := payload["dispatch"].(map[string]any)
		if params, ok := payload["params"].(map[string]any); ok {
			original, _ = params["dispatch"].(map[string]any)
			// Destination fleet and operation IDs may change at placement; the
			// work and provider inputs cannot change after acceptance.
			copyParams := func(src map[string]any) string {
				dst := map[string]any{}
				for k, v := range src {
					if k != "task" && k != "dispatch" {
						dst[k] = v
					}
				}
				b, _ := json.Marshal(dst)
				return string(b)
			}
			if copyParams(params) != copyParams(w.params) {
				return fault("IDEMPOTENCY_CONFLICT", "work input differs from accepted dispatch")
			}
		}
		if original == nil || original["request_id"] != d.RequestID || original["agent_source"] != d.AgentSource {
			return fault("IDEMPOTENCY_CONFLICT", "provider provenance differs from accepted dispatch")
		}
	} else {
		if asString(w.params["task"]) != "" {
			return fault("INVALID_ARGUMENT", "legacy task cannot be adopted by a dispatch")
		}
		title := asString(w.params["title"])
		if title == "" {
			title = asString(w.params["name"])
		}
		if title == "" {
			title = clipText(asString(w.params["body"]), 240)
		}
		if title == "" {
			title = fmt.Sprintf("%s dispatch", d.ResolvedAgent)
		}
		t, err = s.Store.CreateFleetTask(store.FleetTask{Owner: owner, Title: title, Repo: w.repo,
			AuthorityVersion: 1, Agent: d.ResolvedAgent, RequestedAgent: d.RequestedAgent,
			ResolvedAgent: d.ResolvedAgent, ParentSession: asString(w.params["origin_wid"]), RequestPayload: dispatchPayload(w)},
			"dispatch:"+owner+":"+d.RequestID, time.Now())
		if err != nil {
			return fault("IDEMPOTENCY_CONFLICT", "dispatch conflicts with its accepted request")
		}
		d.Task, d.Generation, d.AttemptID = t.Ref, t.Generation, t.AttemptID
	}
	w.params["dispatch"], w.params["task"] = d, d.Task
	// Include the accepted identity in the dispatch journal as well as C1's
	// separate attempt journal. Repeating acceptance yields this same identity.
	b, _ := json.Marshal(map[string]any{"action": w.action, "fleet_id": w.fleetID, "node": w.node, "params": w.params})
	w.canonical = string(b)
	return nil
}

// Avoid a typed nil interface decoding as a non-empty envelope.
func dispatchRaw(d *dispatchChoice) any {
	if d == nil {
		return nil
	}
	return d
}

func dispatchPayload(w *writeRequest) string {
	b, _ := json.Marshal(map[string]any{"action": w.action, "node": w.node, "params": w.params})
	return string(b)
}
