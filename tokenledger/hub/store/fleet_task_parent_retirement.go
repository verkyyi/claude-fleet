package store

import (
	"encoding/json"
	"strings"
)

// decodeTaskRequest retains numbers exactly and all unknown/user fields. The
// retirement comparison never edits the stored accepted_request bytes.
func decodeTaskRequest(raw string) (map[string]any, bool) {
	if !json.Valid([]byte(raw)) {
		return nil, false
	}
	var value map[string]any
	d := json.NewDecoder(strings.NewReader(raw))
	d.UseNumber()
	if d.Decode(&value) != nil || value == nil {
		return nil, false
	}
	return value, true
}

// stripDispatchParent touches only worker_start's known transport slot. A
// user's nested body, attachments or arbitrary payload has no retirement rules.
func stripDispatchParent(value map[string]any) {
	if value["action"] != "worker_start" {
		return
	}
	if params, ok := value["params"].(map[string]any); ok {
		delete(params, "origin_wid")
	}
}

// NormalizeTaskDispatchRequest is the comparison/new-write view of a dispatch
// envelope. Historical request bytes remain untouched in storage.
func NormalizeTaskDispatchRequest(raw string) string {
	value, ok := decodeTaskRequest(raw)
	if !ok {
		return raw
	}
	stripDispatchParent(value)
	b, err := json.Marshal(value)
	if err != nil {
		return raw
	}
	return string(b)
}

func normalizedAcceptedTaskRequest(raw string) string {
	value, ok := decodeTaskRequest(raw)
	if !ok {
		return raw
	}
	delete(value, "ParentTask")
	delete(value, "ParentSession")
	if payload, ok := value["Payload"].(map[string]any); ok {
		stripDispatchParent(payload)
	}
	b, err := json.Marshal(value)
	if err != nil {
		return raw
	}
	return string(b)
}
