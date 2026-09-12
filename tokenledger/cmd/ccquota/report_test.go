package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestReportSourceSelectionWithoutClaudeLogin(t *testing.T) {
	home := t.TempDir()
	codex := t.TempDir()
	t.Setenv("CODEX_HOME", codex)
	t.Setenv("CCQUOTA_SOURCES", "")
	files := map[string]string{
		filepath.Join(home, ".claude", "projects", "s.jsonl"): fmt.Sprintf(`{"type":"assistant","uuid":"c1","timestamp":%q,"message":{"model":"claude-sonnet-5","usage":{"output_tokens":10}}}`+"\n", time.Now().UTC().Format(time.RFC3339)),
		filepath.Join(codex, "sessions", "s.jsonl"): `{"type":"session_meta","payload":{"id":"s1"}}` + "\n" +
			fmt.Sprintf(`{"type":"token_usage_record","timestamp":%q,"payload":{"response_id":"resp_1","usage":{"input_tokens":100,"cached_input_tokens":60,"output_tokens":20,"total_tokens":120}}}`+"\n", time.Now().UTC().Format(time.RFC3339)),
	}
	for name, contents := range files {
		if err := os.MkdirAll(filepath.Dir(name), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(name, []byte(contents), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	for _, tc := range []struct {
		source  string
		tokens  int64
		buckets int
	}{
		{"all", 130, 2}, {"claude", 10, 1}, {"codex", 120, 1},
	} {
		t.Run(tc.source, func(t *testing.T) {
			out, err := os.CreateTemp(t.TempDir(), "report.json")
			if err != nil {
				t.Fatal(err)
			}
			defer out.Close()
			previous := os.Stdout
			os.Stdout = out
			defer func() { os.Stdout = previous }()
			if err := runReport([]string{"--home", home, "--sources", tc.source, "--json", "--no-limits"}); err != nil {
				t.Fatal(err)
			}
			if _, err := out.Seek(0, 0); err != nil {
				t.Fatal(err)
			}
			var got report
			if err := json.NewDecoder(out).Decode(&got); err != nil {
				t.Fatal(err)
			}
			if got.Tokens != tc.tokens || len(got.BySource) != tc.buckets || len(got.ScanWarnings) > 0 || got.Limits != nil {
				t.Fatalf("wrong source report: %+v", got)
			}
		})
	}
	if err := runReport([]string{"--home", home, "--sources", "typo", "--no-limits"}); err == nil {
		t.Fatal("invalid source accepted")
	}
}
