// internal/mcp/history_equiv_test.go
package mcp

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/verkyyi/ccquota/internal/api"
	"github.com/verkyyi/ccquota/internal/pricing"
	"github.com/verkyyi/ccquota/internal/store"
)

// TestUsageHistoryMatchesV1HistoryViaSharedFold is the provability check for
// the 2026-09-02 pre-deploy review's fourth finding: commit 1ff1bfc gave MCP
// usage_history its own hand-written fold (mcp.foldHourly) instead of
// internal/api's foldHours, on the theory that the latter was unexported and
// the wrong shape. Neither held up: internal/mcp already imports internal/api
// (no cycle to export around), and the only shape difference is store.Bucket
// carrying an always-empty Label field api.Series does not.
//
// This pins MCP's usage_history to the SAME fold /v1/history uses in two
// ways at once: it compares usage_history's wire output against api.FoldHours
// applied directly to the identical underlying rollup rows (so the test
// cannot compile, let alone pass, unless usage_history is actually going
// through the exported api.FoldHours), and separately against /v1/history's
// own wire output for the identical filter, which is the literal
// "do these two surfaces agree" check a second, hand-rolled fold could
// silently fail even while looking equivalent today.
func TestUsageHistoryMatchesV1HistoryViaSharedFold(t *testing.T) {
	ts, st := newMCP(t)
	seed(t, st, "acct-a", "ep-1", "/a", "a1", "a2")
	seed(t, st, "acct-a", "ep-2", "/b", "b1")

	httpSrv := httptest.NewServer((&api.Server{Store: st, Pricing: pricing.Default()}).Handler())
	t.Cleanup(httpSrv.Close)

	since := time.Now().UTC().Add(-2 * time.Hour).Format(time.RFC3339)
	until := time.Now().UTC().Add(time.Hour).Format(time.RFC3339)

	// Reference: the exact fold /v1/history calls, applied directly to the
	// rollup rows under the identical filter.
	sinceT, err := time.Parse(time.RFC3339, since)
	if err != nil {
		t.Fatal(err)
	}
	untilT, err := time.Parse(time.RFC3339, until)
	if err != nil {
		t.Fatal(err)
	}
	f := store.Filter{Account: "acct-a", Start: sinceT, End: untilT}.AlignHours()
	rows, err := st.HourlyByModel(f)
	if err != nil {
		t.Fatal(err)
	}
	want, err := api.FoldHours(rows, "hour", false, nil)
	if err != nil {
		t.Fatal(err)
	}
	if len(want) == 0 {
		t.Fatal("setup: no rollup rows in range -- widen the seeded window")
	}

	// MCP's usage_history, over the wire.
	out := call(t, ts, "usage_history", map[string]any{
		"account": "acct-a", "granularity": "hour", "since": since, "until": until,
	})
	res := out["result"].(map[string]any)
	if res["isError"] == true {
		t.Fatalf("usage_history errored: %v", res)
	}
	sc := res["structuredContent"].(map[string]any)
	mcpSeries, _ := sc["series"].([]any)

	// /v1/history, over the wire, same filter.
	httpResp, err := http.Get(httpSrv.URL + "/v1/history?account=acct-a&granularity=hour&since=" + since + "&until=" + until)
	if err != nil {
		t.Fatal(err)
	}
	defer httpResp.Body.Close()
	var httpOut struct {
		Series []map[string]any `json:"series"`
	}
	if err := json.NewDecoder(httpResp.Body).Decode(&httpOut); err != nil {
		t.Fatal(err)
	}

	if len(mcpSeries) != len(want) {
		t.Fatalf("series length: want %d (api.FoldHours), usage_history has %d", len(want), len(mcpSeries))
	}
	if len(httpOut.Series) != len(want) {
		t.Fatalf("series length: want %d (api.FoldHours), /v1/history has %d", len(want), len(httpOut.Series))
	}

	for i, w := range want {
		m, ok := mcpSeries[i].(map[string]any)
		if !ok {
			t.Fatalf("usage_history series[%d] is not an object: %v", i, mcpSeries[i])
		}
		h := httpOut.Series[i]

		if m["key"] != w.Key {
			t.Fatalf("series[%d] key: want %q (api.FoldHours), usage_history has %v", i, w.Key, m["key"])
		}
		if h["key"] != w.Key {
			t.Fatalf("series[%d] key: want %q (api.FoldHours), /v1/history has %v", i, w.Key, h["key"])
		}
		if got := int64(m["tokens"].(float64)); got != w.Tokens {
			t.Fatalf("series[%d] tokens: want %d (api.FoldHours), usage_history has %d", i, w.Tokens, got)
		}
		if got := int64(h["tokens"].(float64)); got != w.Tokens {
			t.Fatalf("series[%d] tokens: want %d (api.FoldHours), /v1/history has %d", i, w.Tokens, got)
		}
		if got := int64(m["events"].(float64)); got != w.Events {
			t.Fatalf("series[%d] events: want %d (api.FoldHours), usage_history has %d", i, w.Events, got)
		}
		if got := int64(h["events"].(float64)); got != w.Events {
			t.Fatalf("series[%d] events: want %d (api.FoldHours), /v1/history has %d", i, w.Events, got)
		}
	}
}
