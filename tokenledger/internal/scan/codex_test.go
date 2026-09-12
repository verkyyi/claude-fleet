package scan

import (
	"fmt"
	"os"
	"path/filepath"
	"testing"

	"github.com/verkyyi/ccquota/internal/model"
)

const codexMeta = `{"type":"session_meta","payload":{"id":"s1","cwd":"/work/project","source":"cli","git":{"branch":"main"}}}`
const codexContext = `{"type":"turn_context","payload":{"model":"gpt-5.3-codex","effort":"high","turn_id":"turn1"}}`

func codexCount(in, cache, out, reasoning int64) string {
	return fmt.Sprintf(`{"type":"event_msg","timestamp":"2026-09-01T12:00:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":%d,"cached_input_tokens":%d,"output_tokens":%d,"reasoning_output_tokens":%d,"total_tokens":%d}}}}`, in, cache, out, reasoning, in+out)
}

func codexRecord(response string) string {
	return fmt.Sprintf(`{"type":"token_usage_record","timestamp":"2026-09-01T12:00:00Z","payload":{"response_id":%q,"thread_id":"s1","turn_id":"turn1","usage":{"input_tokens":100,"cached_input_tokens":60,"cache_write_input_tokens":10,"output_tokens":20,"reasoning_output_tokens":5,"total_tokens":120},"thread_token_usage":{"input_tokens":100,"cached_input_tokens":60,"output_tokens":20,"reasoning_output_tokens":5,"total_tokens":120}}}`, response)
}

func scanCodex(t *testing.T, s *Scanner, want int) []model.UsageEvent {
	t.Helper()
	events, err := s.Scan()
	if err != nil || len(s.Errs) > 0 || len(events) != want {
		t.Fatalf("scan: events=%d want=%d err=%v warnings=%v", len(events), want, err, s.Errs)
	}
	return events
}

func TestCodexCumulativeUsageAndRestart(t *testing.T) {
	home := t.TempDir()
	cursor := filepath.Join(t.TempDir(), "cursor.json")
	file := filepath.Join(home, "sessions", "2026", "09", "01", "rollout.jsonl")
	writeFile(t, file, codexMeta, codexContext, codexCount(100, 50, 20, 5),
		codexCount(100, 50, 20, 5), // quota refresh, not another request
		`{"type":"event_msg","payload":{"type":"token_count","info":null}}`,
		codexCount(300, 160, 60, 15))
	s := NewCodexScanner(home, cursor)
	events := scanCodex(t, s, 2)
	if events[0].TotalTokens() != 120 || events[1].TotalTokens() != 240 ||
		events[1].InputTokens != 90 || events[1].CacheRead != 110 || events[1].Thinking != 10 {
		t.Fatalf("wrong delta or duplicate cache/reasoning: %+v", events)
	}
	// Failed handoff on a running daemon must replay, even without restart.
	replayed := scanCodex(t, s, 2)
	if replayed[1].MessageUUID != events[1].MessageUUID {
		t.Fatal("unstable request id")
	}
	if err := s.Commit(); err != nil {
		t.Fatal(err)
	}
	appendLines(t, file, codexCount(400, 200, 80, 20))
	s = NewCodexScanner(home, cursor)
	e := scanCodex(t, s, 1)[0]
	if e.TotalTokens() != 120 || e.Model != "gpt-5.3-codex" || e.Effort != "high" ||
		e.CWD != "/work/project" || e.GitBranch != "main" || e.Source != "codex" || e.SessionID != "codex:s1" {
		t.Fatalf("lost persisted context/baseline: %+v", e)
	}
	if err := s.Commit(); err != nil {
		t.Fatal(err)
	}
	scanCodex(t, s, 0)
}

func TestCodexRecordsDoNotCountNotificationEchoesOrCopies(t *testing.T) {
	home := t.TempDir()
	for _, dir := range []string{"sessions", "archived_sessions"} {
		writeFile(t, filepath.Join(home, dir, "rollout.jsonl"), codexMeta, codexContext,
			codexRecord("resp_1"), codexCount(100, 60, 20, 5), codexRecord("resp_1"))
	}
	s := NewCodexScanner(home, filepath.Join(t.TempDir(), "cursor.json"))
	e := scanCodex(t, s, 1)[0]
	if e.TotalTokens() != 120 || e.InputTokens != 40 || e.CacheRead != 60 ||
		e.OutputTokens != 20 || e.Thinking != 5 || e.RequestID != "resp_1" {
		t.Fatalf("wrong normalized record: %+v", e)
	}
	if err := s.Commit(); err != nil {
		t.Fatal(err)
	}
	appendLines(t, filepath.Join(home, "sessions", "rollout.jsonl"), codexCount(300, 160, 60, 15))
	scanCodex(t, NewCodexScanner(home, s.cursor.path), 0)
}

func TestCodexPartialLineRewriteAndMalformedUsage(t *testing.T) {
	home := t.TempDir()
	file := filepath.Join(home, "sessions", "rollout.jsonl")
	writeFile(t, file, codexMeta, codexContext)
	s := NewCodexScanner(home, filepath.Join(t.TempDir(), "cursor.json"))
	partial := codexRecord("resp_partial")
	f, err := os.OpenFile(file, os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := f.WriteString(partial[:len(partial)/2]); err != nil {
		t.Fatal(err)
	}
	f.Close()
	scanCodex(t, s, 0)
	if err := s.Commit(); err != nil {
		t.Fatal(err)
	}
	appendLines(t, file, partial[len(partial)/2:])
	scanCodex(t, s, 1)
	if err := s.Commit(); err != nil {
		t.Fatal(err)
	}
	// Rewriting the file must discard its old parser state as well as offset.
	writeFile(t, file, codexMeta, codexContext, codexCount(10, 2, 3, 1))
	if e := scanCodex(t, s, 1)[0]; e.TotalTokens() != 13 {
		t.Fatalf("%+v", e)
	}
	if err := s.Commit(); err != nil {
		t.Fatal(err)
	}
	appendLines(t, file, `{broken}`, codexCount(-1, 0, 3, 1), codexCount(20, 4, 6, 2))
	events, err := s.Scan()
	if err != nil || len(s.Errs) != 2 || len(events) != 1 || events[0].TotalTokens() != 13 {
		t.Fatalf("malformed line stopped valid usage: %+v err=%v warnings=%v", events, err, s.Errs)
	}
}

func TestCodexCounterResetUsesLastRequest(t *testing.T) {
	s := &codexState{SessionID: "session", Previous: &codexUsage{Input: 1000, Output: 500, Total: 1500}}
	line := `{"type":"event_msg","timestamp":"2026-09-01T12:00:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"output_tokens":20,"total_tokens":120},"last_token_usage":{"input_tokens":30,"cached_input_tokens":10,"output_tokens":5,"reasoning_output_tokens":2,"total_tokens":35}}}}`
	e, ok, err := s.parseLine([]byte(line))
	if err != nil || !ok || e.TotalTokens() != 35 {
		t.Fatalf("event=%+v ok=%v err=%v", e, ok, err)
	}
	if _, ok, err := s.parseLine([]byte(line)); err != nil || ok {
		t.Fatalf("reset echoed twice: ok=%v err=%v", ok, err)
	}
}

func TestSourceSelectionAndCodexHome(t *testing.T) {
	t.Setenv("CODEX_HOME", "/env/codex")
	if CodexHome("/user", "") != "/env/codex" || CodexHome("/user", "/override") != "/override" {
		t.Fatal("Codex home precedence")
	}
	t.Setenv("CODEX_HOME", "")
	if CodexHome("/user", "") != filepath.Join("/user", ".codex") {
		t.Fatal("Codex home fallback")
	}
	for _, value := range []string{"", "all", "claude,codex", "claude, codex,claude"} {
		sources, err := ParseSources(value)
		if err != nil || len(sources) != 2 {
			t.Fatalf("%q: %v %v", value, sources, err)
		}
	}
	for _, value := range []string{"unknown", "claude,", "codex,all"} {
		if _, err := ParseSources(value); err == nil {
			t.Fatalf("accepted %q", value)
		}
	}
	scanCodex(t, NewCodexScanner(t.TempDir(), filepath.Join(t.TempDir(), "cursor.json")), 0)
}
