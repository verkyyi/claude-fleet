package credproxy

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strings"
)

const MaxCodexReferences = 4096

const CodexContinuationUnavailable = "codex_continuation_unavailable"

// References are purpose-separated SHA256 digests, never provider IDs or
// encrypted reasoning. Unknown shapes cannot establish an independent request.
type CodexRoute struct {
	Independent bool     `json:"independent,omitempty"`
	References  []string `json:"references,omitempty"`
	Unknown     bool     `json:"unknown,omitempty"`
}

type CodexAffinityRecord struct {
	AccountKey   string   `json:"account_key"`
	Owner        string   `json:"owner"`
	Account      string   `json:"account"`
	CredentialID string   `json:"credential_id"`
	References   []string `json:"references"`
}

type CodexRouter interface {
	ResolveCodex(context.Context, string, CodexRoute) (Resolution, error)
	RecordCodexAffinity(context.Context, string, Resolution, []string) error
}

func (h *HubResolver) ResolveCodex(ctx context.Context, pass string, route CodexRoute) (Resolution, error) {
	answer, err := h.resolveRequest(ctx, ResolveRequest{Cred: pass, Provider: Codex, Codex: &route})
	if err == nil && answer.Valid && !answer.CodexAffinityV1 {
		return Resolution{Error: CodexContinuationUnavailable, Reason: "affinity_protocol_unavailable"}, nil
	}
	return answer, err
}

func (h *HubResolver) RecordCodexAffinity(ctx context.Context, pass string, res Resolution, refs []string) error {
	answer, err := h.resolveRequest(ctx, ResolveRequest{Cred: pass, Provider: Codex, CodexRecord: &CodexAffinityRecord{
		Owner: res.Owner, Account: res.Account, CredentialID: res.CredentialID, AccountKey: CodexReference("account", res.AccountID), References: refs,
	}})
	if err == nil && (!answer.Valid || !answer.CodexAffinityV1) {
		return errors.New("continuation record refused: " + answer.Error + " " + answer.Reason)
	}
	return err
}

func CodexReference(kind, value string) string {
	sum := sha256.Sum256([]byte("fleet-codex-affinity-v1\x00" + kind + "\x00" + value))
	return hex.EncodeToString(sum[:])
}

func ValidCodexReferences(refs []string) bool {
	if len(refs) == 0 || len(refs) > MaxCodexReferences {
		return false
	}
	for _, ref := range refs {
		raw, err := hex.DecodeString(ref)
		if err != nil || len(raw) != 32 {
			return false
		}
	}
	return true
}

// codexRoute recognizes a deliberately narrow, self-contained input surface.
// New stateful fields default to unknown until their provenance is supported.
func codexRoute(r *http.Request, body []byte) CodexRoute {
	route := CodexRoute{}
	refs := map[string]bool{}
	add := func(kind string, v any) {
		if v == nil {
			return
		}
		s, ok := v.(string)
		if !ok {
			route.Unknown = true
			return
		}
		if s != "" {
			refs[CodexReference(kind, s)] = true
		}
	}
	for _, name := range []string{"X-Codex-Turn-State", "X-Codex-Routing-Hint"} {
		for _, value := range r.Header.Values(name) {
			add("header:"+strings.ToLower(name), value)
		}
	}
	if (r.URL.RawQuery != "" && !(r.Method == http.MethodGet && len(r.URL.Query()) == 1 && r.URL.Query().Get("client_version") != "")) || r.Header.Get("Content-Encoding") != "" {
		route.Unknown = true
	}
	if r.Method == http.MethodGet {
		for ref := range refs {
			route.References = append(route.References, ref)
		}
		route.Independent = !route.Unknown && len(refs) == 0
		return route
	}
	var root map[string]any
	if !uniqueCodexJSON(body) || json.Unmarshal(body, &root) != nil || root == nil {
		route.Unknown = true
		return route
	}
	if strings.HasSuffix(r.URL.Path, "/alpha/search") {
		route.Unknown = route.Unknown || !codexSearchIndependent(root)
		for ref := range refs {
			route.References = append(route.References, ref)
		}
		route.Independent = !route.Unknown && len(refs) == 0
		return route
	}
	allowed := strings.Fields("model instructions input tools tool_choice parallel_tool_calls stream store include reasoning text temperature top_p max_output_tokens max_tool_calls truncation metadata prompt_cache_key prompt_cache_retention safety_identifier service_tier background context_management previous_response_id conversation stream_options client_metadata")
	for key := range root {
		if !contains(allowed, key) {
			route.Unknown = true
		}
	}
	if metadata, ok := root["client_metadata"].(map[string]any); ok {
		for _, name := range []string{"x-codex-turn-state", "x-codex-routing-hint"} {
			add("header:"+name, metadata[name])
		}
	}
	if root["tools"] != nil && !codexToolsIndependent(root["tools"]) {
		route.Unknown = true
	}

	add("id", root["previous_response_id"])
	switch v := root["conversation"].(type) {
	case nil:
	case string:
		add("id", v)
	case map[string]any:
		add("id", v["id"])
		if len(v) != 1 {
			route.Unknown = true
		}
	default:
		route.Unknown = true
	}
	var inputItem func(any)
	inputItem = func(value any) {
		m, ok := value.(map[string]any)
		if !ok {
			route.Unknown = true
			return
		}
		typ, typeOK := m["type"].(string)
		if _, present := m["type"]; present && !typeOK {
			route.Unknown = true
		}
		switch typ {
		case "", "message", "function_call", "function_call_output", "custom_tool_call", "custom_tool_call_output", "additional_tools", "local_shell_call", "web_search_call", "tool_search_call", "tool_search_output", "reasoning", "compaction", "item_reference":
		default:
			route.Unknown = true
		}
		// Native full client inputs carry locally minted IDs before inference.
		// Tool results identify the source by call_id; assistant/provider IDs
		// and all opaque state remain source affinity.
		for _, k := range []string{"id", "call_id"} {
			if k != "id" || !codexClientInputID(m) {
				add("id", m[k])
			}
		}
		add("encrypted", m["encrypted_content"])
		if m["tools"] != nil && !codexToolsIndependent(m["tools"]) {
			route.Unknown = true
		}
		if (typ == "function_call_output" || typ == "custom_tool_call_output") && m["call_id"] == nil && m["id"] == nil {
			route.Unknown = true
		}
		if output, ok := m["output"].([]any); ok {
			inputItem(map[string]any{"type": "message", "content": output})
		}
		if typ == "item_reference" && m["id"] == nil {
			route.Unknown = true
		}
		if (typ == "reasoning" || typ == "compaction") && m["id"] == nil && m["encrypted_content"] == nil {
			route.Unknown = true
		}
		for key := range m {
			if !contains(strings.Fields("type role content id call_id name namespace arguments input output status summary encrypted_content phase tools action execution"), key) {
				route.Unknown = true
			}
		}
		if content, ok := m["content"].([]any); ok {
			for _, part := range content {
				p, ok := part.(map[string]any)
				if !ok {
					route.Unknown = true
					continue
				}
				switch p["type"] {
				case "input_text", "output_text":
					for k := range p {
						if !contains([]string{"type", "text", "annotations", "logprobs"}, k) {
							route.Unknown = true
						}
					}
				case "input_image":
					u, ok := p["image_url"].(string)
					if !ok || !strings.HasPrefix(u, "data:") {
						route.Unknown = true
					}
					for k := range p {
						if !contains([]string{"type", "image_url", "detail"}, k) {
							route.Unknown = true
						}
					}
				default:
					route.Unknown = true
				}
			}
		} else if m["content"] != nil {
			if _, ok := m["content"].(string); !ok {
				route.Unknown = true
			}
		}
	}
	switch input := root["input"].(type) {
	case nil, string:
	case []any:
		for _, item := range input {
			inputItem(item)
		}
	default:
		route.Unknown = true
	}
	for ref := range refs {
		route.References = append(route.References, ref)
	}
	if len(refs) > MaxCodexReferences {
		route.Unknown = true
		route.References = nil
	}
	route.Independent = !route.Unknown && len(refs) == 0
	return route
}

// codexClientInputID recognizes full, self-contained client input, never by
// ID prefix or metadata. Extra or opaque fields cannot acquire the exemption.
// Keep this surface aligned with fleet-cred-proxy.py and the shared vectors.
func codexClientInputID(m map[string]any) bool {
	if _, ok := m["id"].(string); !ok {
		return false
	}
	only := func(keys []string, obj map[string]any) bool {
		for key := range obj {
			if !contains(keys, key) {
				return false
			}
		}
		return true
	}
	if m["type"] == "function_call_output" || m["type"] == "custom_tool_call_output" {
		// Native result IDs are client-minted. call_id remains mandatory source
		// affinity; never exempt reference-only, opaque or extended outputs.
		call, ok := m["call_id"].(string)
		if !ok || call == "" || !only([]string{"type", "id", "call_id", "output"}, m) {
			return false
		}
		return codexClientInputID(map[string]any{"id": m["id"], "role": "user", "content": m["output"]})
	}
	if m["type"] == "additional_tools" {
		return m["role"] == "developer" && only([]string{"type", "id", "role", "tools"}, m) && codexToolsIndependent(m["tools"])
	}
	typ, ok := m["type"].(string)
	if _, present := m["type"]; present && !ok {
		return false
	}
	role, _ := m["role"].(string)
	if (typ != "" && typ != "message") || !contains([]string{"user", "developer", "system"}, role) || !only([]string{"type", "id", "role", "content"}, m) {
		return false
	}
	if _, ok := m["content"].(string); ok {
		return true
	}
	content, ok := m["content"].([]any)
	if !ok || len(content) == 0 {
		return false
	}
	for _, value := range content {
		part, ok := value.(map[string]any)
		if !ok {
			return false
		}
		switch part["type"] {
		case "input_text":
			if _, ok := part["text"].(string); !ok || !only([]string{"type", "text"}, part) {
				return false
			}
		case "input_image":
			if url, ok := part["image_url"].(string); !ok || !strings.HasPrefix(url, "data:") || !only([]string{"type", "image_url", "detail"}, part) {
				return false
			}
		default:
			return false
		}
	}
	return true
}

// Called on provider JSON only, never on user input or a tool schema. Missing
// or oversized events leave references unknown, which resolution refuses.
func codexOutputReferences(v map[string]any) ([]string, error) {
	refs := map[string]bool{}
	var visit func(any)
	visit = func(value any) {
		switch x := value.(type) {
		case map[string]any:
			for k, v := range x {
				kind := ""
				if k == "id" || k == "call_id" || k == "conversation" {
					kind = "id"
				}
				if k == "encrypted_content" {
					kind = "encrypted"
				}
				if s, ok := v.(string); kind != "" && ok && s != "" {
					refs[CodexReference(kind, s)] = true
				}
				if _, ok := v.(string); !ok {
					visit(v)
				}
			}
		case []any:
			for _, v := range x {
				visit(v)
			}
		}
	}
	// Skip arbitrary tool arguments, text and metadata. Only response/item
	// envelopes supply references; nested textual JSON is never decoded.
	if response, ok := v["response"].(map[string]any); ok {
		v = response
	}
	for _, k := range []string{"id", "output", "item", "conversation"} {
		if k == "id" || (k == "conversation" && v[k] != nil) {
			if s, ok := v[k].(string); ok {
				refs[CodexReference("id", s)] = true
				continue
			}
		}
		visit(v[k])
	}
	if len(refs) > MaxCodexReferences {
		return nil, errors.New("affinity_references_too_many")
	}
	out := make([]string, 0, len(refs))
	for ref := range refs {
		out = append(out, ref)
	}
	return out, nil
}

// Duplicate JSON keys have no portable interpretation across parsers. Reject
// them instead of classifying one value and forwarding another interpretation.
func uniqueCodexJSON(body []byte) bool {
	d := json.NewDecoder(bytes.NewReader(body))
	var value func(int) bool
	value = func(depth int) bool {
		if depth > 128 {
			return false
		}
		token, err := d.Token()
		if err != nil {
			return false
		}
		delim, ok := token.(json.Delim)
		if !ok {
			return true
		}
		switch delim {
		case '{':
			keys := map[string]bool{}
			for d.More() {
				token, err := d.Token()
				if err != nil {
					return false
				}
				key, ok := token.(string)
				if !ok || keys[key] {
					return false
				}
				keys[key] = true
				if !value(depth + 1) {
					return false
				}
			}
			end, err := d.Token()
			return err == nil && end == json.Delim('}')
		case '[':
			for d.More() {
				if !value(depth + 1) {
					return false
				}
			}
			end, err := d.Token()
			return err == nil && end == json.Delim(']')
		}
		return false
	}
	if !value(0) {
		return false
	}
	_, err := d.Token()
	return err == io.EOF
}

// Function/custom definitions and namespaces contain local tool schemas, not
// provider-side file or vector-store handles. Other tool families need their
// own reference handling before they can establish independence.
func codexToolsIndependent(value any) bool {
	tools, ok := value.([]any)
	if !ok {
		return false
	}
	for _, value := range tools {
		tool, ok := value.(map[string]any)
		if !ok {
			return false
		}
		switch tool["type"] {
		case "function", "custom":
		case "namespace":
			if !codexToolsIndependent(tool["tools"]) {
				return false
			}
		case "web_search", "web_search_preview":
			for key := range tool {
				if !contains([]string{"type", "filters", "user_location", "search_context_size", "external_web_access"}, key) {
					return false
				}
			}
		default:
			return false
		}
	}
	return true
}
