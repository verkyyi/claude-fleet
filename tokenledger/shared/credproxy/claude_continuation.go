package credproxy

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
)

const ClaudeContinuationUnavailable = "claude_continuation_unavailable"
const ClaudeCapacityUnavailable = "claude_capacity_unavailable"

type ClaudeRoute struct {
	Model       string   `json:"model"`
	Independent bool     `json:"independent"`
	References  []string `json:"references,omitempty"`
	Unknown     bool     `json:"unknown,omitempty"`
}
type ClaudeRouter interface {
	ResolveClaude(context.Context, string, ClaudeRoute) (Resolution, error)
	RecordClaudeAffinity(context.Context, string, Resolution, []string) error
}

func (h *HubResolver) ResolveClaude(ctx context.Context, pass string, route ClaudeRoute) (Resolution, error) {
	return h.resolveRequest(ctx, ResolveRequest{Cred: pass, Provider: Claude, Claude: &route})
}
func (h *HubResolver) RecordClaudeAffinity(ctx context.Context, pass string, res Resolution, refs []string) error {
	answer, err := h.resolveRequest(ctx, ResolveRequest{Cred: pass, Provider: Claude, ClaudeRecord: &CodexAffinityRecord{Owner: res.Owner, Account: res.Account, CredentialID: res.CredentialID, References: refs}})
	if err == nil && (!answer.Valid || !answer.ClaudeAffinityV1) {
		return errors.New("claude continuation record refused")
	}
	return err
}
func ClaudeReference(kind, value string) string {
	sum := sha256.Sum256([]byte("fleet-claude-affinity-v1\x00" + kind + "\x00" + value))
	return hex.EncodeToString(sum[:])
}
func claudeRoute(r *http.Request, body []byte) ClaudeRoute {
	out := ClaudeRoute{}
	refs := map[string]bool{}
	var root map[string]any
	if r.Method != "POST" || !strings.HasSuffix(r.URL.Path, "/v1/messages") || (r.URL.RawQuery != "" && r.URL.RawQuery != "beta=true") || r.Header.Get("Content-Encoding") != "" || !uniqueCodexJSON(body) || json.Unmarshal(body, &root) != nil || root == nil {
		out.Unknown = true
		return out
	}
	out.Model, _ = root["model"].(string)
	allowed := strings.Fields("model messages system max_tokens tools tool_choice stream temperature top_p top_k stop_sequences metadata thinking output_config context_management")
	for k := range root {
		if !contains(allowed, k) {
			out.Unknown = true
		}
	}
	// Native keep-all thinking is a local edit policy. Other context edits need
	// their own provenance handling before they can establish independence.
	if cm := root["context_management"]; cm != nil {
		encoded, _ := json.Marshal(cm)
		if string(encoded) != `{"edits":[{"keep":"all","type":"clear_thinking_20251015"}]}` {
			out.Unknown = true
		}
	}
	add := func(kind string, v any) {
		s, ok := v.(string)
		if !ok || s == "" {
			out.Unknown = true
		} else {
			refs[ClaudeReference(kind, s)] = true
		}
	}
	var content func(any)
	content = func(v any) {
		if _, ok := v.(string); ok {
			return
		}
		arr, ok := v.([]any)
		if !ok {
			out.Unknown = true
			return
		}
		for _, v := range arr {
			p, ok := v.(map[string]any)
			if !ok {
				out.Unknown = true
				continue
			}
			keys := ""
			switch p["type"] {
			case "text":
				keys = "type text cache_control citations"
				if c := p["citations"]; c != nil {
					if a, ok := c.([]any); !ok || len(a) > 0 {
						out.Unknown = true
					}
				}
			case "thinking":
				keys = "type thinking signature"
				add("signature", p["signature"])
			case "redacted_thinking":
				keys = "type data"
				add("redacted", p["data"])
			case "tool_use":
				keys = "type id name input cache_control"
				add("tool", p["id"])
			case "tool_result":
				keys = "type tool_use_id content is_error cache_control"
				add("tool", p["tool_use_id"])
				if p["content"] != nil {
					content(p["content"])
				}
			case "image":
				keys = "type source cache_control"
				src, ok := p["source"].(map[string]any)
				if !ok || src["type"] != "base64" {
					out.Unknown = true
				}
			default:
				out.Unknown = true
			}
			for k := range p {
				if !contains(strings.Fields(keys), k) {
					out.Unknown = true
				}
			}
		}
	}
	msgs, ok := root["messages"].([]any)
	if !ok || len(msgs) == 0 {
		out.Unknown = true
	}
	for _, v := range msgs {
		m, ok := v.(map[string]any)
		if !ok {
			out.Unknown = true
			continue
		}
		if m["role"] != "user" && m["role"] != "assistant" {
			out.Unknown = true
		}
		for k := range m {
			if k != "role" && k != "content" {
				out.Unknown = true
			}
		}
		content(m["content"])
	}
	if root["system"] != nil {
		content(root["system"])
	}
	if v, ok := root["tools"]; ok {
		ts, ok := v.([]any)
		if !ok {
			out.Unknown = true
		}
		for _, v := range ts {
			t, ok := v.(map[string]any)
			if !ok {
				out.Unknown = true
				continue
			}
			for k := range t {
				if !contains(strings.Fields("type name description input_schema cache_control defer_loading eager_input_streaming input_examples strict"), k) {
					out.Unknown = true
				}
			}
			if typ := t["type"]; typ != nil && typ != "custom" {
				out.Unknown = true
			}
		}
	}
	for ref := range refs {
		out.References = append(out.References, ref)
	}
	if len(refs) > MaxCodexReferences {
		out.Unknown = true
		out.References = nil
	}
	out.Independent = !out.Unknown && len(refs) == 0
	return out
}

// Claude signatures can arrive in multiple deltas. Record their assembled
// value before the block stop reaches the client; never parse tool input/text.
func claudeOutputRecorder(record func([]string) error) func(map[string]any) error {
	signatures := map[float64]string{}
	return func(v map[string]any) error {
		refs := []string{}
		block := func(p map[string]any) {
			key, field := "", ""
			switch p["type"] {
			case "tool_use":
				key, field = "tool", "id"
			case "thinking":
				key, field = "signature", "signature"
			case "redacted_thinking":
				key, field = "redacted", "data"
			}
			if s, ok := p[field].(string); key != "" && ok && s != "" {
				refs = append(refs, ClaudeReference(key, s))
			}
		}
		if arr, ok := v["content"].([]any); ok {
			for _, p := range arr {
				if p, ok := p.(map[string]any); ok {
					block(p)
				}
			}
		}
		idx, _ := v["index"].(float64)
		if p, ok := v["content_block"].(map[string]any); ok {
			block(p)
			if p["type"] == "thinking" {
				signatures[idx], _ = p["signature"].(string)
			}
		}
		if d, ok := v["delta"].(map[string]any); ok && d["type"] == "signature_delta" {
			s, ok := d["signature"].(string)
			if !ok || len(signatures[idx])+len(s) > maxWhole {
				return errors.New("invalid signature delta")
			}
			signatures[idx] += s
		}
		if v["type"] == "content_block_stop" {
			if s := signatures[idx]; s != "" {
				refs = append(refs, ClaudeReference("signature", s))
			}
			delete(signatures, idx)
		}
		if len(refs) > 0 {
			return record(refs)
		}
		return nil
	}
}

// Legacy OFF keeps its existing bounded restart fallback. Once this proxy has
// observed shadow/active, no pass-only cache can authorize a capacity request.
func (p *Proxy) resolveClaude(ctx context.Context, router ClaudeRouter, pass string, route ClaudeRoute) (Resolution, bool, error) {
	sum := sha256.Sum256([]byte(Claude + "\x00" + pass))
	key := hex.EncodeToString(sum[:])
	p.mu.Lock()
	e := p.cache[key]
	if e == nil {
		e = &entry{}
		p.cache[key] = e
	}
	p.mu.Unlock()
	e.mu.Lock()
	defer e.mu.Unlock()
	now := p.cfg.Now()
	answer, err := router.ResolveClaude(ctx, pass, route)
	if err == nil {
		e.ok = !answer.ClaudeAffinityV1
		if e.ok {
			e.res = answer
			e.at = now
			p.sweep(now)
		} else {
			p.mu.Lock()
			delete(p.cache, key)
			p.mu.Unlock()
		}
		return answer, false, nil
	}
	if errors.Is(err, ErrHubUnavailable) && e.ok && e.res.Valid && !now.Before(e.at) && now.Sub(e.at) < p.cfg.CacheTTL+p.cfg.StaleFor && (e.res.Exp == 0 || e.res.Exp > now.Unix()) && (e.res.ExpiresAt == nil || e.res.ExpiresAt.After(now)) {
		return e.res, true, nil
	}
	if !e.ok {
		p.mu.Lock()
		delete(p.cache, key)
		p.mu.Unlock()
	}
	return answer, false, err
}
