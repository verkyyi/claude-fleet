package scan

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/verkyyi/ccquota/internal/model"
)

// ParseSources selects collectors independently of model names and accounts.
func ParseSources(value string) ([]string, error) {
	if value == "" || value == "all" {
		return []string{model.SourceClaude, model.SourceCodex}, nil
	}
	var out []string
	seen := map[string]bool{}
	for _, source := range strings.Split(value, ",") {
		source = strings.TrimSpace(source)
		switch source {
		case model.SourceClaude, model.SourceCodex:
		default:
			return nil, fmt.Errorf("unknown source %q: choose all, claude, codex, or claude,codex", source)
		}
		if !seen[source] {
			out = append(out, source)
			seen[source] = true
		}
	}
	return out, nil
}

// CodexHome resolves the transcript root without reading Codex credentials.
func CodexHome(home, override string) string {
	if override != "" {
		return override
	}
	if dir := os.Getenv("CODEX_HOME"); dir != "" {
		return dir
	}
	return filepath.Join(home, ".codex")
}

// NewCodexScanner covers active and archived rollouts, sharing one cursor and
// dedup set. Other JSONL files under CODEX_HOME are not usage transcripts.
func NewCodexScanner(home, cursorPath string) *Scanner {
	return &Scanner{
		root: home, cursor: loadCursor(cursorPath), codex: true,
		roots: []string{filepath.Join(home, "sessions"), filepath.Join(home, "archived_sessions")},
	}
}
