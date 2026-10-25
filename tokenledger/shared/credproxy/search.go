package credproxy

// Codex 0.162 standalone search is a separate subscription request. Only fresh
// query searches with self-contained text are movable. Browser references,
// open/click/find and unknown extensions fail closed; they are not Responses
// continuation IDs. The original bytes still go through the authenticated proxy.
func codexSearchIndependent(root map[string]any) bool {
	only := func(m map[string]any, keys ...string) bool {
		for k := range m {
			if !contains(keys, k) {
				return false
			}
		}
		return true
	}
	str := func(v any) bool { s, ok := v.(string); return ok && s != "" }
	if !only(root, "id", "model", "input", "commands", "settings", "max_output_tokens") || !str(root["id"]) || !str(root["model"]) {
		return false
	}
	if n, ok := root["max_output_tokens"].(float64); !ok || n <= 0 || n > 100000 || n != float64(int(n)) {
		return false
	}
	commands, ok := root["commands"].(map[string]any)
	if !ok || !only(commands, "search_query", "response_length") {
		return false
	}
	if v, present := commands["response_length"]; present && v != "short" && v != "medium" && v != "long" {
		return false
	}
	queries, ok := commands["search_query"].([]any)
	if !ok || len(queries) == 0 || len(queries) > 4 {
		return false
	}
	for _, value := range queries {
		q, ok := value.(map[string]any)
		if !ok || !only(q, "q", "recency", "domains") || !str(q["q"]) {
			return false
		}
		if v, present := q["recency"]; present && v != nil {
			if n, ok := v.(float64); !ok || n < 0 || n > 1000000000 || n != float64(int(n)) {
				return false
			}
		}
		if v, present := q["domains"]; present && v != nil {
			domains, ok := v.([]any)
			if !ok {
				return false
			}
			for _, d := range domains {
				if !str(d) {
					return false
				}
			}
		}
	}
	settings, ok := root["settings"].(map[string]any)
	if !ok || !only(settings, "allowed_callers", "external_web_access") {
		return false
	}
	if _, ok := settings["external_web_access"].(bool); !ok {
		return false
	}
	callers, ok := settings["allowed_callers"].([]any)
	if !ok || len(callers) != 1 || callers[0] != "direct" {
		return false
	}
	input, ok := root["input"].([]any)
	if !ok || len(input) == 0 {
		return false
	}
	for _, value := range input {
		m, ok := value.(map[string]any)
		if !ok || !only(m, "type", "role", "content", "internal_chat_message_metadata_passthrough") || m["type"] != "message" {
			return false
		}
		if m["role"] != "user" && m["role"] != "assistant" {
			return false
		}
		parts, ok := m["content"].([]any)
		if !ok || len(parts) == 0 {
			return false
		}
		for _, value := range parts {
			part, ok := value.(map[string]any)
			if !ok || !only(part, "type", "text") || (part["type"] != "input_text" && part["type"] != "output_text") {
				return false
			}
			if _, ok := part["text"].(string); !ok {
				return false
			}
		}
		if v, present := m["internal_chat_message_metadata_passthrough"]; present {
			meta, ok := v.(map[string]any)
			if !ok || !only(meta, "turn_id", "create_time", "content_item_kinds") {
				return false
			}
			if !str(meta["turn_id"]) {
				return false
			}
			if _, ok := meta["create_time"].(float64); !ok {
				return false
			}
			kinds, ok := meta["content_item_kinds"].([]any)
			if !ok {
				return false
			}
			for _, k := range kinds {
				if k != "user.text" && k != "assistant.text" {
					return false
				}
			}
		}
	}
	return true
}
