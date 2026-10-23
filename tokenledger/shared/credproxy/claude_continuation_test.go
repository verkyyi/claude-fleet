package credproxy

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"reflect"
	"sort"
	"strings"
	"testing"
)

func TestClaudeContinuationNativeWire(t *testing.T) {
	path := "testdata/claude_native_context.json"
	if p := os.Getenv("FLEET_CLAUDE_NATIVE_WIRE"); p != "" {
		path = p
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var bodies []json.RawMessage
	if err := json.Unmarshal(raw, &bodies); err != nil {
		t.Fatal(err)
	}
	if len(bodies) != 3 {
		t.Fatal(len(bodies))
	}
	for i, body := range bodies {
		r := claudeRoute(httptest.NewRequest("POST", "/v1/messages?beta=true", nil), body)
		if r.Unknown || r.Independent != (i == 0) {
			t.Fatalf("request %d: %+v", i, r)
		}
		expected := []string{ClaudeReference("tool", "tool_source")}
		if strings.Contains(string(body), "fixture-signature") {
			expected = append(expected, ClaudeReference("signature", "fixture-signature"))
		}
		sort.Strings(expected)
		sort.Strings(r.References)
		if i > 0 && !reflect.DeepEqual(r.References, expected) {
			t.Fatal(r)
		}
	}
	for _, body := range []string{`{"model":"claude-sonnet-4-6","messages":[{"role":"user","content":[{"type":"tool_result","tool_use_id":""}]}]}`, `{"messages":[],"messages":[{"role":"user","content":"hi"}]}`, `{"messages":[{"role":"user","content":"hi"}],"opaque":"state"}`} {
		if r := claudeRoute(httptest.NewRequest("POST", "/v1/messages", nil), []byte(body)); !r.Unknown {
			t.Fatalf("unknown accepted: %s", body)
		}
	}
}
func TestClaudeContinuationSignatureFrames(t *testing.T) {
	raw := "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"thinking\",\"thinking\":\"\",\"signature\":\"\"}}\n\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"signature_delta\",\"signature\":\"part1\"}}\n\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"signature_delta\",\"signature\":\"part2\"}}\n\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n"
	refs := []string{}
	reader, err := codexResponseReader(strings.NewReader(raw), "text/event-stream", claudeOutputRecorder(func(r []string) error { refs = append(refs, r...); return nil }))
	if err != nil {
		t.Fatal(err)
	}
	got, err := io.ReadAll(reader)
	if err != nil || string(got) != raw {
		t.Fatal(err, string(got))
	}
	sort.Strings(refs)
	if !reflect.DeepEqual(refs, []string{ClaudeReference("signature", "part1part2")}) {
		t.Fatal(refs)
	}
	if ClaudeReference("tool", "same") == CodexReference("id", "same") {
		t.Fatal("provider namespaces crossed")
	}
}

type claudeFailedRecorder struct{ calls int }

func (c *claudeFailedRecorder) Resolve(context.Context, string, string) (Resolution, error) {
	return Resolution{}, nil
}
func (c *claudeFailedRecorder) ResolveClaude(_ context.Context, _ string, r ClaudeRoute) (Resolution, error) {
	if len(r.References) > 0 {
		return Resolution{Error: ClaudeContinuationUnavailable, Reason: "unknown_reference", ClaudeAffinityV1: true}, nil
	}
	return Resolution{Valid: true, ClaudeAffinityV1: true, AccessToken: "fake", Owner: "fixture", Account: "fixture", CredentialID: "fixture"}, nil
}
func (c *claudeFailedRecorder) RecordClaudeAffinity(context.Context, string, Resolution, []string) error {
	c.calls++
	return errors.New("fixture recording unavailable")
}
func TestClaudeStreamRecordingOutageNeverReplays(t *testing.T) {
	raw := "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"content_block\":{\"type\":\"tool_use\",\"id\":\"tool_source\"}}\n\nevent: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"
	sends := 0
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		sends++
		w.Header().Set("Content-Type", "text/event-stream")
		io.WriteString(w, raw)
	}))
	defer up.Close()
	resolver := &claudeFailedRecorder{}
	proxy, err := New(Config{Resolver: resolver, Direct: true, AnthropicURL: up.URL, Audit: func(string) {}})
	if err != nil {
		t.Fatal(err)
	}
	call := func(body string) *httptest.ResponseRecorder {
		req := httptest.NewRequest("POST", "/v1/proxy/anthropic/v1/messages", strings.NewReader(body))
		req.Header.Set("Authorization", "Bearer fcp-h1.fixture")
		w := httptest.NewRecorder()
		proxy.Handler().ServeHTTP(w, req)
		return w
	}
	first := call(`{"model":"claude-sonnet-4-6","messages":[{"role":"user","content":"hi"}]}`)
	if first.Code != 200 || first.Body.String() != raw || resolver.calls != 1 || sends != 1 {
		t.Fatal(first.Code, first.Body.String(), resolver.calls, sends)
	}
	next := call(`{"model":"claude-sonnet-4-6","messages":[{"role":"user","content":[{"type":"tool_result","tool_use_id":"tool_source","content":"OK"}]}]}`)
	if next.Code != 409 || sends != 1 {
		t.Fatal("unknown recording replayed", next.Code, sends)
	}
}
