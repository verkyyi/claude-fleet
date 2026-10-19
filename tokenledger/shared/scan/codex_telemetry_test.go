package scan

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestCodexStructuredContextMetadata(t *testing.T) {
	s := &codexState{}
	for _, line := range []string{
		`{"type":"session_meta","timestamp":"2026-09-01T11:00:10Z","payload":{"id":"structured","timestamp":"2026-09-01T11:00:00Z","model_provider":"openai","cli_version":"0.153.4","context_window":{"window_id":"context-generation"}}}`,
		`{"type":"event_msg","timestamp":"2026-09-01T12:01:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":60,"output_tokens":20,"reasoning_output_tokens":5},"last_token_usage":{"input_tokens":100,"output_tokens":20},"model_context_window":1000}}}`,
	} {
		if _, _, err := s.parseLine([]byte(line)); err != nil {
			t.Fatal(err)
		}
	}
	v := s.Telemetry
	if v.SessionID != "codex:structured" || v.Provider != "openai" || v.ClientVersion != "0.153.4" || v.State != "recent_activity" || v.StartedAt.Format(time.RFC3339) != "2026-09-01T11:00:00Z" || v.ContextUsedPct == nil || *v.ContextUsedPct != 12 {
		t.Fatalf("structured context discarded session identity or capacity: %+v", v)
	}
}

// Opt in for read-only deployment validation; never include transcript text.
func TestInstalledCodexTelemetry(t *testing.T) {
	home := os.Getenv("CCQUOTA_TEST_CODEX_HOME")
	if home == "" {
		t.Skip("set CCQUOTA_TEST_CODEX_HOME for installed log validation")
	}
	s := NewCodexScanner(home, filepath.Join(t.TempDir(), "cursor.json"))
	if _, err := s.Scan(); err != nil {
		t.Fatal(err)
	}
	recent := 0
	for _, v := range s.CodexSessions() {
		if v.SeenAt.After(time.Now().Add(-24 * time.Hour)) {
			if v.SessionID == "" || v.StartedAt.IsZero() || v.ClientVersion == "" {
				t.Fatal("recent transcript lost session metadata")
			}
			recent++
		}
	}
	if recent == 0 {
		t.Fatal("no recent transcript available for verification")
	}
	t.Logf("validated metadata for %d recent sessions", recent)
}

func TestCodexQuotaOnlyUpdateAndCompletion(t *testing.T) {
	s := &codexState{}
	for _, line := range []string{
		`{"type":"session_meta","timestamp":"2026-09-01T11:00:00Z","payload":{"id":"s1","model_provider":"openai","cli_version":"0.149.0"}}`,
		codexContext, codexRecord("r1"),
		`{"type":"event_msg","timestamp":"2026-09-01T12:01:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":60,"output_tokens":20,"reasoning_output_tokens":5}},"rate_limits":{"primary":{"used_percent":80,"window_duration_mins":10080}}}}`,
	} {
		if _, _, err := s.parseLine([]byte(line)); err != nil {
			t.Fatal(err)
		}
	}
	if s.Telemetry.Quota == nil || s.Telemetry.Quota.Windows[0].UsedPercent != 80 {
		t.Fatal("quota-only echo discarded")
	}
	if _, _, err := s.parseLine([]byte(`{"type":"event_msg","timestamp":"2026-09-01T12:02:00Z","payload":{"type":"task_complete"}}`)); err != nil {
		t.Fatal(err)
	}
	if s.Telemetry.State != "completed" {
		t.Fatal("completion missed")
	}
}

func TestCodexParserUpgradeEnrichesOnlyCommittedPrefix(t *testing.T) {
	home := t.TempDir()
	file := filepath.Join(home, "sessions", "s.jsonl")
	cursor := filepath.Join(t.TempDir(), "cursor.json")
	writeFile(t, file, codexMeta, codexContext, codexRecord("old"))
	s := NewCodexScanner(home, cursor)
	original := scanCodex(t, s, 1)
	if err := s.Commit(); err != nil {
		t.Fatal(err)
	}
	st := s.cursor.Files[file]
	st.Codex.Version = 0
	s.cursor.Files[file] = st
	appendLines(t, file, codexRecord("new"))
	e := scanCodex(t, s, 2)
	if e[0].MessageUUID != original[0].MessageUUID || !e[0].EnrichOnly || e[1].EnrichOnly {
		t.Fatal("parser upgrade replay changed IDs or consumed new usage as metadata")
	}
}
