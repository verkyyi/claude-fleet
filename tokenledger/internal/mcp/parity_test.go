// internal/mcp/parity_test.go
//
// Issue #60: three doors lead to this hub -- the web dashboard, the HTTP API
// and MCP -- and they had drifted apart in both directions. Five of the twelve
// grouping axes were reachable over MCP only as filters, so "what did each team
// spend this week" was unanswerable there; and /v1/limits/history, /v1/fx and
// /v1/user had no MCP equivalent at all, which left an agent reading a plan
// priced in CNY with no way to reach an exchange rate.
//
// These are the guards that keep them level. They are deliberately written
// against the HTTP surface's own output rather than against expected values:
// a test with its own copy of the answer drifts the same way the doors did.
package mcp

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"testing"
	"time"

	"github.com/verkyyi/ccquota/internal/api"
	"github.com/verkyyi/ccquota/internal/model"
	"github.com/verkyyi/ccquota/internal/pricing"
	"github.com/verkyyi/ccquota/internal/store"
)

// httpBeside starts an HTTP server on the same store, so a tool's answer can be
// compared against the endpoint it is supposed to mirror.
func httpBeside(t *testing.T, st *store.Store) *httptest.Server {
	t.Helper()
	ts := httptest.NewServer((&api.Server{Store: st, Pricing: pricing.Default()}).Handler())
	t.Cleanup(ts.Close)
	return ts
}

func getJSON(t *testing.T, ts *httptest.Server, path string, into any) {
	t.Helper()
	resp, err := http.Get(ts.URL + path)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("GET %s: %d", path, resp.StatusCode)
	}
	if err := json.NewDecoder(resp.Body).Decode(into); err != nil {
		t.Fatalf("decode %s: %v", path, err)
	}
}

// toolPayload unwraps a tool result, failing loudly on a tool-level error --
// which arrives as isError inside a 200, not as an RPC error, and would
// otherwise surface here only as a missing key.
func toolPayload(t *testing.T, out map[string]any, tool string) map[string]any {
	t.Helper()
	res, ok := out["result"].(map[string]any)
	if !ok {
		t.Fatalf("%s: no result: %v", tool, out)
	}
	if res["isError"] == true {
		t.Fatalf("%s errored: %v", tool, res["content"])
	}
	sc, ok := res["structuredContent"].(map[string]any)
	if !ok {
		t.Fatalf("%s: no structuredContent: %v", tool, res)
	}
	return sc
}

// TestEveryGroupingAxisHasAUsageTool is the structural half of issue #60.
//
// store.Dimensions is the one list of axes this build can group by, and
// /v1/usage?by=<d> accepts every one of them. The naming rule here --
// usage_by_<dimension> -- is what makes the two sets comparable at all, so a
// thirteenth axis added to the store fails this test until MCP grows a tool for
// it, rather than being discovered by an agent that cannot ask the question.
func TestEveryGroupingAxisHasAUsageTool(t *testing.T) {
	registered := map[string]bool{}
	for _, spec := range toolSpecs() {
		registered[spec.Name] = true
	}
	for _, d := range store.Dimensions {
		if name := "usage_by_" + string(d); !registered[name] {
			t.Errorf("/v1/usage?by=%s has no MCP tool (want %s): the axis is filter-only over MCP", d, name)
		}
	}
}

// TestUsageToolsGroupOnTheSameAxisAsHTTP is the behavioural half: the tool
// exists AND groups on the axis its name claims, agreeing bucket for bucket
// with GET /v1/usage?by=<d> over the identical scope.
func TestUsageToolsGroupOnTheSameAxisAsHTTP(t *testing.T) {
	ts, st := newMCP(t)
	httpSrv := httpBeside(t, st)

	// Two machines on two teams, two logins, two branches, two efforts, two
	// entrypoints -- so every axis has more than one bucket and a tool that
	// silently grouped by something else would not match by accident.
	seedAxes(t, st)

	since := time.Now().UTC().Add(-3 * time.Hour).Format(time.RFC3339)
	until := time.Now().UTC().Add(time.Hour).Format(time.RFC3339)

	for _, d := range store.Dimensions {
		d := d
		t.Run(string(d), func(t *testing.T) {
			var want struct {
				By      string         `json:"by"`
				Buckets []store.Bucket `json:"buckets"`
			}
			getJSON(t, httpSrv, fmt.Sprintf("/v1/usage?by=%s&account=all&since=%s&until=%s",
				d, url.QueryEscape(since), url.QueryEscape(until)), &want)
			if want.By != string(d) {
				t.Fatalf("/v1/usage echoed by=%q for %q", want.By, d)
			}
			if len(want.Buckets) == 0 {
				t.Fatalf("setup: /v1/usage?by=%s returned no buckets", d)
			}

			sc := toolPayload(t, call(t, ts, "usage_by_"+string(d), map[string]any{
				"account": "all", "since": since, "until": until,
			}), "usage_by_"+string(d))

			if sc["by"] != string(d) {
				t.Fatalf("usage_by_%s reports by=%v", d, sc["by"])
			}
			got, _ := sc["buckets"].([]any)
			if len(got) != len(want.Buckets) {
				t.Fatalf("usage_by_%s: %d buckets, /v1/usage?by=%s has %d",
					d, len(got), d, len(want.Buckets))
			}
			for i, w := range want.Buckets {
				b, ok := got[i].(map[string]any)
				if !ok {
					t.Fatalf("bucket %d is not an object: %v", i, got[i])
				}
				if b["key"] != w.Key {
					t.Fatalf("usage_by_%s bucket %d key = %v, /v1/usage has %q", d, i, b["key"], w.Key)
				}
				if int64(b["tokens"].(float64)) != w.Tokens {
					t.Fatalf("usage_by_%s bucket %q tokens = %v, /v1/usage has %d",
						d, w.Key, b["tokens"], w.Tokens)
				}
			}
		})
	}
}

// TestUsageSummaryCarriesEffortAndEntrypoint pins the one asymmetry that was
// not about a missing tool: effort and entrypoint are the only two axes with no
// chip to filter on, so GET /v1/summary's splits were the only way to reach
// them -- and usage_summary did not have them.
func TestUsageSummaryCarriesEffortAndEntrypoint(t *testing.T) {
	ts, st := newMCP(t)
	httpSrv := httpBeside(t, st)
	seedAxes(t, st)

	since := time.Now().UTC().Add(-3 * time.Hour).Format(time.RFC3339)
	until := time.Now().UTC().Add(time.Hour).Format(time.RFC3339)

	var want struct {
		Effort     []store.Bucket `json:"effort"`
		Entrypoint []store.Bucket `json:"entrypoint"`
	}
	getJSON(t, httpSrv, fmt.Sprintf("/v1/summary?account=all&since=%s&until=%s",
		url.QueryEscape(since), url.QueryEscape(until)), &want)
	if len(want.Effort) == 0 || len(want.Entrypoint) == 0 {
		t.Fatal("setup: /v1/summary returned no effort/entrypoint split")
	}

	sc := toolPayload(t, call(t, ts, "usage_summary", map[string]any{
		"account": "all", "since": since, "until": until,
	}), "usage_summary")

	for _, tc := range []struct {
		key  string
		want []store.Bucket
	}{{"effort", want.Effort}, {"entrypoint", want.Entrypoint}} {
		got, ok := sc[tc.key].([]any)
		if !ok {
			t.Fatalf("usage_summary has no %q split; /v1/summary returns %d rows", tc.key, len(tc.want))
		}
		if len(got) != len(tc.want) {
			t.Fatalf("usage_summary %s: %d rows, /v1/summary has %d", tc.key, len(got), len(tc.want))
		}
		for i, w := range tc.want {
			b := got[i].(map[string]any)
			if b["key"] != w.Key || int64(b["tokens"].(float64)) != w.Tokens {
				t.Fatalf("usage_summary %s row %d = %v, /v1/summary has {%q %d}",
					tc.key, i, b, w.Key, w.Tokens)
			}
		}
	}
}

// TestGetUserMatchesV1User: usage_by_user returns a row in a ranking; this is
// the person behind one of those rows, and it had no MCP tool at all.
func TestGetUserMatchesV1User(t *testing.T) {
	ts, st := newMCP(t)
	httpSrv := httpBeside(t, st)
	seedAxes(t, st)

	since := time.Now().UTC().Add(-3 * time.Hour).Format(time.RFC3339)
	until := time.Now().UTC().Add(time.Hour).Format(time.RFC3339)

	var want api.UserView
	getJSON(t, httpSrv, fmt.Sprintf("/v1/user?user=alice&since=%s&until=%s",
		url.QueryEscape(since), url.QueryEscape(until)), &want)
	if want.Tokens == 0 {
		t.Fatal("setup: /v1/user?user=alice has no tokens")
	}

	sc := toolPayload(t, call(t, ts, "get_user", map[string]any{
		"user": "alice", "since": since, "until": until,
	}), "get_user")

	user, ok := sc["user"].(map[string]any)
	if !ok {
		t.Fatalf("get_user has no user object: %v", sc)
	}
	if user["os_user"] != "alice" {
		t.Fatalf("get_user returned %v", user["os_user"])
	}
	if int64(user["tokens"].(float64)) != want.Tokens {
		t.Fatalf("get_user tokens = %v, /v1/user has %d", user["tokens"], want.Tokens)
	}
	// The breakdowns are the reason this is not just usage_by_user: they are
	// scoped to the login rather than cut out of a fleet-wide ranking.
	if got, _ := user["top_projects"].([]any); len(got) != len(want.TopProjects) {
		t.Fatalf("get_user top_projects = %d rows, /v1/user has %d", len(got), len(want.TopProjects))
	}
	if got, _ := user["machines_breakdown"].([]any); len(got) != len(want.MachinesBreakdown) {
		t.Fatalf("get_user machines_breakdown = %d rows, /v1/user has %d",
			len(got), len(want.MachinesBreakdown))
	}

	// A missing login is the caller's error, reported as a tool error the model
	// can act on rather than as a zeroed page it would relay as fact.
	res := call(t, ts, "get_user", map[string]any{})["result"].(map[string]any)
	if res["isError"] != true {
		t.Fatalf("get_user with no user must error, got %v", res)
	}
}

// TestGetFXMatchesV1FX. Without this tool an agent reading a CNY-priced plan
// has no way to reach a rate, nor to learn how stale it is.
func TestGetFXMatchesV1FX(t *testing.T) {
	ts, st := newMCP(t)
	httpSrv := httpBeside(t, st)

	// No feed is wired up in these servers, so USD->USD is the identity rate
	// and USD->CNY is unavailable. Both are answers, and an agent must be able
	// to tell them apart -- that is what is being pinned.
	var want map[string]any
	getJSON(t, httpSrv, "/v1/fx?base=USD&target=USD", &want)
	sc := toolPayload(t, call(t, ts, "get_fx", map[string]any{"base": "USD", "target": "USD"}), "get_fx")
	if sc["available"] != true || want["available"] != true {
		t.Fatalf("identity rate must be available: mcp=%v http=%v", sc["available"], want["available"])
	}
	if sc["rate"] != want["rate"] {
		t.Fatalf("get_fx rate = %v, /v1/fx has %v", sc["rate"], want["rate"])
	}
	if sc["note"] == "" || sc["note"] == nil {
		t.Error("get_fx must carry the display-only note")
	}

	var unavailable map[string]any
	getJSON(t, httpSrv, "/v1/fx?base=USD&target=XYZ", &unavailable)
	miss := toolPayload(t, call(t, ts, "get_fx", map[string]any{"base": "USD", "target": "XYZ"}), "get_fx")
	if miss["available"] != false || unavailable["available"] != false {
		t.Fatalf("an unknown pair must report available:false: mcp=%v http=%v",
			miss["available"], unavailable["available"])
	}
	// Unavailable is an answer, not a failure: the caller shows each figure in
	// its own currency. It must not come back as a tool error.
	if _, ok := miss["reason"]; !ok {
		t.Error("an unavailable pair must say why")
	}
}

// TestGetLimitsHistoryMatchesV1 pins the third missing tool, and the rule that
// survives it: the series are per subscription and are never merged.
func TestGetLimitsHistoryMatchesV1(t *testing.T) {
	ts, st := newMCP(t)
	httpSrv := httpBeside(t, st)
	seed(t, st, "acct-a", "ep-1", "/a", "a1")
	seed(t, st, "acct-b", "ep-2", "/b", "b1")
	seedLimitPoints(t, st, "acct-a", "ep-1", 95, 40)
	seedLimitPoints(t, st, "acct-b", "ep-2", 10, 12)

	since := time.Now().UTC().Add(-3 * time.Hour).Format(time.RFC3339)
	until := time.Now().UTC().Add(time.Hour).Format(time.RFC3339)
	q := fmt.Sprintf("account=all&since=%s&until=%s", url.QueryEscape(since), url.QueryEscape(until))

	var want struct {
		Accounts []api.LimitSeries `json:"accounts"`
	}
	getJSON(t, httpSrv, "/v1/limits/history?"+q, &want)
	if len(want.Accounts) != 2 {
		t.Fatalf("setup: want two subscriptions in /v1/limits/history, got %d", len(want.Accounts))
	}

	sc := toolPayload(t, call(t, ts, "get_limits_history", map[string]any{
		"account": "all", "since": since, "until": until,
	}), "get_limits_history")

	got, _ := sc["accounts"].([]any)
	if len(got) != len(want.Accounts) {
		t.Fatalf("get_limits_history: %d series, /v1/limits/history has %d", len(got), len(want.Accounts))
	}
	for i, w := range want.Accounts {
		s := got[i].(map[string]any)
		if s["account_uuid"] != w.AccountUUID {
			t.Fatalf("series %d account = %v, want %q", i, s["account_uuid"], w.AccountUUID)
		}
		if int64(s["critical_seconds"].(float64)) != w.CriticalSeconds {
			t.Fatalf("series %q critical_seconds = %v, /v1/limits/history has %d",
				w.AccountUUID, s["critical_seconds"], w.CriticalSeconds)
		}
	}
	// Spanning subscriptions must say so, for the same reason every other
	// all-accounts answer does.
	if sc["all_accounts"] != true || sc["scope_note"] == "" {
		t.Errorf("an all-accounts answer must carry its scope note: %v", sc["scope_note"])
	}
}

// seedAxes lays down events that differ along every axis, so a tool grouping on
// the wrong column cannot match the HTTP answer by accident.
func seedAxes(t *testing.T, st *store.Store) {
	t.Helper()
	seed(t, st, "acct-a", "ep-1", "/a", "warm-1")
	seed(t, st, "acct-b", "ep-2", "/b", "warm-2")
	if err := st.SetEndpointTeam("ep-1", "platform"); err != nil {
		t.Fatal(err)
	}
	if err := st.SetEndpointTeam("ep-2", "growth"); err != nil {
		t.Fatal(err)
	}

	now := time.Now().UTC().Add(-time.Minute)
	cost := 1.0
	rows := []model.UsageEvent{
		{AccountUUID: "acct-a", EndpointID: "ep-1", MessageUUID: "ax-1", SessionID: "s-1",
			TS: now, Model: "claude-sonnet-5", Provider: "anthropic", CWD: "/a",
			OSUser: "alice", GitBranch: "main", Effort: "high", Entrypoint: "cli",
			OutputTokens: 1000, CostUSD: &cost},
		{AccountUUID: "acct-b", EndpointID: "ep-2", MessageUUID: "ax-2", SessionID: "s-2",
			TS: now, Model: "claude-opus-5", Provider: "bedrock", CWD: "/b",
			OSUser: "bob", GitBranch: "feature", Effort: "low", Entrypoint: "ide",
			OutputTokens: 500, CostUSD: &cost},
	}
	if _, _, err := st.InsertEvents(rows); err != nil {
		t.Fatal(err)
	}
}

// seedLimitPoints writes n utilization readings two minutes apart, so
// criticalTime has gaps it can actually sum.
func seedLimitPoints(t *testing.T, st *store.Store, account, endpoint string, pct float64, n int) {
	t.Helper()
	base := time.Now().UTC().Add(-time.Duration(n) * 2 * time.Minute)
	for i := 0; i < n; i++ {
		if err := st.InsertLimits(&model.LimitsSnapshot{
			AccountUUID: account, EndpointID: endpoint,
			ObservedAt: base.Add(time.Duration(i) * 2 * time.Minute),
			FiveHour:   model.Window{Utilization: pct},
			SevenDay:   model.Window{Utilization: pct / 2},
		}); err != nil {
			t.Fatal(err)
		}
	}
}
