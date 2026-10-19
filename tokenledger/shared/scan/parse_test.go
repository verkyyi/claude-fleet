package scan

import (
	"testing"
	"time"
)

// A real assistant entry, trimmed of message content. Note `iterations`: it
// repeats the same spend as a breakdown. If a parser sums it, every number
// downstream doubles.
const assistantLine = `{"type":"assistant","uuid":"46acc20b-abe9-4de0-8f1e-fb9bda9e70bf","parentUuid":"a1","requestId":"req_011Ceb7ZHofMtNNq4TkUPPy4","sessionId":"61ad2788-93bd-4cc4-abf9-858660acc0f7","timestamp":"2026-08-31T14:03:11.221Z","cwd":"/Users/x/projects/demo","gitBranch":"main","version":"2.1.252","entrypoint":"cli","effort":"high","isSidechain":false,"userType":"external","message":{"id":"msg_01","role":"assistant","model":"claude-sonnet-5","stop_reason":"end_turn","usage":{"input_tokens":2,"cache_creation_input_tokens":47351,"cache_read_input_tokens":18549,"output_tokens":426,"output_tokens_details":{"thinking_tokens":219},"server_tool_use":{"web_search_requests":3,"web_fetch_requests":1},"service_tier":"standard","cache_creation":{"ephemeral_1h_input_tokens":47351,"ephemeral_5m_input_tokens":0},"iterations":[{"input_tokens":2,"output_tokens":426,"cache_read_input_tokens":18549,"cache_creation_input_tokens":47351,"type":"message"}]}}}`

const userLine = `{"type":"user","uuid":"u1","sessionId":"s1","timestamp":"2026-08-31T14:03:00Z","message":{"role":"user","content":"hi"}}`

// An assistant entry with no usage block at all — a streaming artifact.
const assistantNoUsage = `{"type":"assistant","uuid":"a2","sessionId":"s1","timestamp":"2026-08-31T14:03:00Z","message":{"role":"assistant","model":"claude-opus-5"}}`

// Split cache creation across both TTLs, and no `cache_creation` object at all
// (older transcripts) — the flat total must then land somewhere, not vanish.
const legacyCacheLine = `{"type":"assistant","uuid":"a3","sessionId":"s1","timestamp":"2026-08-31T15:00:00Z","message":{"role":"assistant","model":"claude-opus-5","usage":{"input_tokens":10,"output_tokens":20,"cache_creation_input_tokens":500,"cache_read_input_tokens":100}}}`

func TestParseLine_AssistantWithUsage(t *testing.T) {
	ev, ok, err := ParseLine([]byte(assistantLine))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !ok {
		t.Fatal("expected a usage event")
	}

	if ev.MessageUUID != "46acc20b-abe9-4de0-8f1e-fb9bda9e70bf" {
		t.Errorf("MessageUUID = %q", ev.MessageUUID)
	}
	if ev.RequestID != "req_011Ceb7ZHofMtNNq4TkUPPy4" {
		t.Errorf("RequestID = %q", ev.RequestID)
	}
	if ev.SessionID != "61ad2788-93bd-4cc4-abf9-858660acc0f7" {
		t.Errorf("SessionID = %q", ev.SessionID)
	}
	if ev.Model != "claude-sonnet-5" {
		t.Errorf("Model = %q", ev.Model)
	}

	want := time.Date(2026, 8, 31, 14, 3, 11, 221000000, time.UTC)
	if !ev.TS.Equal(want) {
		t.Errorf("TS = %v, want %v", ev.TS, want)
	}

	// The whole point: totals are the top-level counters, NOT top-level plus
	// iterations.
	if ev.InputTokens != 2 {
		t.Errorf("InputTokens = %d, want 2 (iterations must not be summed)", ev.InputTokens)
	}
	if ev.OutputTokens != 426 {
		t.Errorf("OutputTokens = %d, want 426 (iterations must not be summed)", ev.OutputTokens)
	}
	if ev.CacheRead != 18549 {
		t.Errorf("CacheRead = %d, want 18549 (iterations must not be summed)", ev.CacheRead)
	}
	if ev.CacheCreate1h != 47351 {
		t.Errorf("CacheCreate1h = %d, want 47351", ev.CacheCreate1h)
	}
	if ev.CacheCreate5m != 0 {
		t.Errorf("CacheCreate5m = %d, want 0", ev.CacheCreate5m)
	}
	if ev.Thinking != 219 {
		t.Errorf("Thinking = %d, want 219", ev.Thinking)
	}
	if ev.WebSearchRequests != 3 || ev.WebFetchRequests != 1 {
		t.Errorf("server tool use = %d/%d, want 3/1", ev.WebSearchRequests, ev.WebFetchRequests)
	}

	if ev.CWD != "/Users/x/projects/demo" || ev.GitBranch != "main" {
		t.Errorf("cwd/branch = %q/%q", ev.CWD, ev.GitBranch)
	}
	if ev.Entrypoint != "cli" || ev.Effort != "high" {
		t.Errorf("entrypoint/effort = %q/%q", ev.Entrypoint, ev.Effort)
	}
	if ev.IsSidechain {
		t.Error("IsSidechain = true, want false")
	}
}

// Guards the invariant directly, in the terms a future reader will search for.
func TestParseLine_DoesNotSumIterations(t *testing.T) {
	ev, _, err := ParseLine([]byte(assistantLine))
	if err != nil {
		t.Fatal(err)
	}
	// Top-level says 47351 cache-creation. iterations[] repeats 47351. A
	// summing parser reports 94702.
	if got := ev.CacheCreate1h + ev.CacheCreate5m; got != 47351 {
		t.Fatalf("cache creation = %d, want 47351; iterations[] was summed on top", got)
	}
}

func TestParseLine_SkipsNonBillable(t *testing.T) {
	for name, line := range map[string]string{
		"user entry":         userLine,
		"assistant no usage": assistantNoUsage,
		"blank":              "",
		"whitespace":         "   ",
	} {
		t.Run(name, func(t *testing.T) {
			_, ok, err := ParseLine([]byte(line))
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if ok {
				t.Error("expected no usage event")
			}
		})
	}
}

// Transcripts predating the cache_creation split still carry a flat
// cache_creation_input_tokens. Dropping it would silently undercount.
func TestParseLine_LegacyFlatCacheCreation(t *testing.T) {
	ev, ok, err := ParseLine([]byte(legacyCacheLine))
	if err != nil || !ok {
		t.Fatalf("ok=%v err=%v", ok, err)
	}
	if got := ev.CacheCreate5m + ev.CacheCreate1h; got != 500 {
		t.Errorf("cache creation total = %d, want 500", got)
	}
	// With no TTL breakdown available, attribute to 5m — the cheaper rate, so
	// an unknown never inflates the notional cost.
	if ev.CacheCreate5m != 500 {
		t.Errorf("CacheCreate5m = %d, want 500 (unknown TTL bills at the cheaper rate)", ev.CacheCreate5m)
	}
}

func TestParseLine_UnknownFieldsIgnored(t *testing.T) {
	line := `{"type":"assistant","uuid":"a9","sessionId":"s","timestamp":"2026-08-31T00:00:00Z","brandNewField":{"x":1},"message":{"role":"assistant","model":"m","usage":{"output_tokens":5,"someFutureCounter":99}}}`
	ev, ok, err := ParseLine([]byte(line))
	if err != nil {
		t.Fatalf("a new field must not break the parser: %v", err)
	}
	if !ok || ev.OutputTokens != 5 {
		t.Errorf("ok=%v output=%d", ok, ev.OutputTokens)
	}
}

func TestParseLine_MalformedJSON(t *testing.T) {
	if _, _, err := ParseLine([]byte(`{"type":"assistant"`)); err == nil {
		t.Error("expected an error on truncated JSON")
	}
}

// A sidechain entry is a subagent turn; it spends real tokens and must be
// counted, but flagged so the dashboard can break it out.
func TestParseLine_Sidechain(t *testing.T) {
	line := `{"type":"assistant","uuid":"sc1","sessionId":"s","timestamp":"2026-08-31T00:00:00Z","isSidechain":true,"message":{"role":"assistant","model":"claude-haiku-4-5-20251001","usage":{"input_tokens":1,"output_tokens":2}}}`
	ev, ok, err := ParseLine([]byte(line))
	if err != nil || !ok {
		t.Fatalf("ok=%v err=%v", ok, err)
	}
	if !ev.IsSidechain {
		t.Error("IsSidechain = false, want true")
	}
}

// An entry whose counters are all zero is not billable and would otherwise
// pollute per-session listings with empty rows.
func TestParseLine_ZeroUsageSkipped(t *testing.T) {
	line := `{"type":"assistant","uuid":"z1","sessionId":"s","timestamp":"2026-08-31T00:00:00Z","message":{"role":"assistant","model":"m","usage":{"input_tokens":0,"output_tokens":0}}}`
	_, ok, err := ParseLine([]byte(line))
	if err != nil {
		t.Fatal(err)
	}
	if ok {
		t.Error("an all-zero usage block should not produce an event")
	}
}
