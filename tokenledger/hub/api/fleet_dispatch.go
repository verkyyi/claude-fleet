package api

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
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

// The same reversible default the clients read. Explicit choices and accepted
// envelopes belong to their caller; changing a default never rewrites them.
func (s *Server) resolveStartDispatch(coding, legacy string, raw any, key string) (*dispatchChoice, error) {
	if coding == "" && legacy == "" && raw == nil {
		settings, err := s.Store.FleetSettings()
		if err != nil {
			return nil, err
		}
		if agent := settings[ClientDefaultsPrefix+"FLEET_AGENT"]; codingAgentOK(agent) {
			if key == "" {
				key = "place-" + newOperationID()
			}
			raw = dispatchChoice{Version: 1, RequestID: key, RequestedAgent: "default", ResolvedAgent: agent, AgentSource: "fleet"}
		}
	}
	return resolveDispatch(coding, legacy, raw, key)
}

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
	if d.Version != 1 || !idemRE.MatchString(d.RequestID) || (key != "" && key != d.RequestID && !retryKeyOf(key, d.RequestID)) || !codingAgentOK(d.ResolvedAgent) ||
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

// ticketRefMatches says ref is the GitHub issue (repo, number): `gh:<repo>#<N>`,
// the one backend a task's ticket_ref names since the hub's own tickets left
// (claude-fleet#4898, T477).
func ticketRefMatches(ref, repo, number string) bool {
	return ref == store.TicketGitHub+":"+repo+"#"+number
}

// acceptDispatch attaches the C1 identity before journalling/sending. An
// existing legacy T record is never adopted. Replays compare the full original
// input, while a task supplied by the authority must still name its generation.
func (s *Server) acceptDispatch(p fleetPrincipal, w *writeRequest) error {
	if err := s.ownerDispatchGate(p.taskOwner(), w.params["dispatch"] != nil); err != nil {
		return err
	}
	if ref := asString(w.params["ticket_ref"]); ref != "" && !ticketRefMatches(ref, w.repo, fmt.Sprint(w.params["issue"])) {
		return fault("INVALID_ARGUMENT", "ticket_ref must explicitly match the accepted repo and issue")
	}
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
	owner := p.taskOwner()
	if d.Task != "" {
		if supplied := asString(w.params["task"]); supplied != "" && supplied != d.Task {
			return fault("INVALID_ARGUMENT", "task differs from accepted dispatch")
		}
		t, err = s.Store.FleetTask(store.ParseTaskRef(d.Task))
		// A repo is one repo whatever its case (claude-fleet T672): the record
		// keeps it lower-cased, a start names it as the fleet registered it.
		if err != nil || t.Owner != owner || store.NormRepo(t.Repo) != store.NormRepo(w.repo) || t.AuthorityVersion != 1 || t.Generation != d.Generation ||
			t.CancelRequest != "" || t.State == store.TaskCancelled || t.Outcome == store.TaskCancelled ||
			t.RequestedAgent != d.RequestedAgent || t.ResolvedAgent != d.ResolvedAgent || t.AttemptID != d.AttemptID {
			return fault("INVALID_STATE", "accepted dispatch task owner, generation or provider does not match")
		}

		var payload map[string]any
		if json.Unmarshal([]byte(t.RequestPayload), &payload) != nil {
			return fault("INVALID_STATE", "accepted task has no dispatch input")
		}
		original, _ := payload["dispatch"].(map[string]any)
		if _, placed := payload["params"]; !placed {
			// A coordinator accepted the words before filing. Only its explicit
			// ticket attachment authorizes an issue start; it cannot substitute
			// another issue or parent when converting those words to placement.
			if w.params["issue"] != nil && !ticketRefMatches(t.TicketRef, w.repo, fmt.Sprint(w.params["issue"])) {
				return fault("INVALID_STATE", "issue start requires the accepted task's linked ticket")
			}
			if t.ParentSession != asString(w.params["origin_wid"]) {
				return fault("INVALID_STATE", "parent differs from accepted task")
			}
		}
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
				if r, ok := dst["repo"].(string); ok {
					dst["repo"] = store.NormRepo(r)
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
		if err = s.checkTaskParentSession(owner, asString(w.params["origin_wid"])); err != nil {
			return fault("INVALID_ARGUMENT", "accepted parent must be a stable session identity in this account")
		}
		// A task is a T<n> (claude-fleet#4896): it carries a ticket only when
		// the caller names one; none is made up from where a repo's tickets live.
		ref := asString(w.params["ticket_ref"])
		t, err = s.Store.CreateFleetTask(store.FleetTask{Owner: owner, Title: title, Repo: w.repo, TicketRef: ref,
			AuthorityVersion: 1, Agent: d.ResolvedAgent, RequestedAgent: d.RequestedAgent,
			ResolvedAgent: d.ResolvedAgent, ParentSession: asString(w.params["origin_wid"]), RequestPayload: dispatchPayload(w)},
			"dispatch:"+owner+":"+d.RequestID, time.Now())
		switch {
		case errors.Is(err, store.ErrTaskFence):
			// Another owner's ticket or parent task is a refusal of WHO asks,
			// not a reused key (claude-fleet#4697).
			return fault("FORBIDDEN", "ticket_ref or parent task belongs to another owner or backend")
		case errors.Is(err, store.ErrTaskInvalid):
			return fault("INVALID_ARGUMENT", "the accepted task is invalid (ticket_ref names no ticket)")
		case err != nil:
			return fault("IDEMPOTENCY_CONFLICT", "dispatch conflicts with its accepted request")
		}
		if t.CancelRequest != "" || t.State == store.TaskCancelled || t.Outcome == store.TaskCancelled {
			return fault("INVALID_STATE", "accepted dispatch was cancelled")
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

// replayDispatch restores only the task identity added by acceptDispatch on
// the first request. All original request/provider fields must still match.
func replayDispatch(o store.FleetOperation, w writeRequest) (map[string]any, error) {
	var original struct {
		Params struct {
			Dispatch *dispatchChoice `json:"dispatch"`
		} `json:"params"`
	}
	if json.Unmarshal([]byte(o.Request), &original) != nil || original.Params.Dispatch == nil || original.Params.Dispatch.Task == "" || w.params["dispatch"] == nil {
		return replayed(o, w)
	}
	d, err := resolveDispatch("", asString(w.params["agent"]), w.params["dispatch"], "")
	if err != nil {
		return nil, err
	}
	if d.Task == "" {
		old := original.Params.Dispatch
		d.Task, d.Generation, d.AttemptID = old.Task, old.Generation, old.AttemptID
	}
	w.params["dispatch"] = d
	if asString(w.params["task"]) == "" {
		w.params["task"] = d.Task
	}
	b, _ := json.Marshal(map[string]any{"action": w.action, "fleet_id": w.fleetID, "node": w.node, "params": w.params})
	w.canonical = string(b)
	return replayed(o, w)
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

// retryKeyOf says whether key is a placement's later try of the dispatch
// requestID (claude-fleet T672): retryIdem's `<id>:try<N>` — the same accepted
// work sent to the next machine after one declined, its own operation.
func retryKeyOf(key, requestID string) bool {
	base := requestID[:min(len(requestID), 120)] + ":try"
	if !strings.HasPrefix(key, base) || len(key) == len(base) {
		return false
	}
	for _, c := range key[len(base):] {
		if c < '0' || c > '9' {
			return false
		}
	}
	return true
}
