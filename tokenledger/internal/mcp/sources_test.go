package mcp

import (
	"testing"
	"time"

	"github.com/verkyyi/ccquota/internal/model"
)

func TestUsageToolsFilterBySource(t *testing.T) {
	ts, st := newMCP(t)
	seed(t, st, "claude-account", "ep", "/claude", "c1")
	if err := st.UpsertAccount(model.Identity{AccountUUID: "codex:local", Source: "codex"}, "", ""); err != nil {
		t.Fatal(err)
	}
	if _, _, err := st.InsertEvents([]model.UsageEvent{{AccountUUID: "codex:local", EndpointID: "ep", Source: "codex",
		MessageUUID: "codex:r1", TS: time.Now().UTC().Add(-time.Minute), OutputTokens: 120}}); err != nil {
		t.Fatal(err)
	}
	for _, tool := range []string{"usage_by_source", "usage_by_account", "usage_by_endpoint", "usage_by_project", "usage_by_user", "usage_by_session"} {
		response := call(t, ts, tool, map[string]any{"account": "all", "source": "codex"})
		out := response["result"].(map[string]any)["structuredContent"].(map[string]any)
		buckets, ok := out["buckets"].([]any)
		if !ok || len(buckets) != 1 || buckets[0].(map[string]any)["tokens"] != float64(120) {
			t.Fatalf("%s ignored source: %+v", tool, out)
		}
	}
}
