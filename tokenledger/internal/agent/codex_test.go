package agent

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/verkyyi/ccquota/internal/model"
)

func codexHome(t *testing.T, n int) string {
	t.Helper()
	home := t.TempDir()
	dir := filepath.Join(home, ".codex", "sessions")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	var b strings.Builder
	fmt.Fprintf(&b, "{\"type\":\"session_meta\",\"payload\":{\"id\":\"s1\",\"cwd\":%q}}\n", "/work/"+padding)
	b.WriteString("{\"type\":\"turn_context\",\"payload\":{\"model\":\"gpt-5.3-codex\"}}\n")
	for i := 0; i < n; i++ {
		fmt.Fprintf(&b, "{\"type\":\"token_usage_record\",\"timestamp\":\"2026-09-01T12:00:00Z\",\"payload\":{\"response_id\":\"resp_%d\",\"usage\":{\"input_tokens\":100,\"cached_input_tokens\":50,\"output_tokens\":20,\"reasoning_output_tokens\":5,\"total_tokens\":120}}}\n", i)
	}
	if err := os.WriteFile(filepath.Join(dir, "rollout.jsonl"), []byte(b.String()), 0o600); err != nil {
		t.Fatal(err)
	}
	return home
}

func TestAgentCodexWithoutClaudeLogin(t *testing.T) {
	home := codexHome(t, 2)
	if err := os.WriteFile(filepath.Join(home, ".claude.json"), []byte(`{}`), 0o600); err != nil {
		t.Fatal(err)
	}
	var batches []model.Batch
	var mu sync.Mutex
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var batch model.Batch
		if err := json.NewDecoder(r.Body).Decode(&batch); err != nil {
			t.Error(err)
		}
		mu.Lock()
		batches = append(batches, batch)
		mu.Unlock()
		json.NewEncoder(w).Encode(model.IngestResponse{Accepted: len(batch.Events), EndpointID: "ep"})
	}))
	defer srv.Close()
	a, err := New(Config{HubURL: srv.URL, Token: "test", Home: home, CodexHome: filepath.Join(home, ".codex"), StateDir: t.TempDir()})
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 2; i++ {
		if err := a.cycle(context.Background()); err != nil {
			t.Fatal(err)
		}
	}
	mu.Lock()
	defer mu.Unlock()
	if len(batches) != 1 {
		t.Fatalf("got %d batches", len(batches))
	}
	b := batches[0]
	if b.Identity.Source != "codex" || b.Identity.AccountUUID != "codex:local" ||
		b.Identity.Email != "" || b.AccountOrigin != model.OriginSession || b.Limits != nil || len(b.Events) != 2 {
		t.Fatalf("Codex inherited a Claude identity/limits or lost events: %+v", b)
	}
}

func TestCodexSpoolOverflowRetriesOnSameAgent(t *testing.T) {
	c := newCollector(t)
	c.setDown(true)
	home := codexHome(t, 900)
	a, err := New(Config{HubURL: c.srv.URL, Token: "test", Home: home, Sources: "codex",
		CodexHome: filepath.Join(home, ".codex"), StateDir: t.TempDir(), SpoolMaxBytes: 64 << 10})
	if err != nil {
		t.Fatal(err)
	}
	if err := a.cycle(context.Background()); err == nil {
		t.Fatal("expected unavailable hub")
	}
	c.setDown(false)
	if err := a.cycle(context.Background()); err != nil {
		t.Fatal(err)
	}
	if c.count() != 900 {
		t.Fatalf("only %d of 900 requests survived retry", c.count())
	}
}
