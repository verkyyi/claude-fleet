package mcp

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/ccquota/internal/api"
	"github.com/verkyyi/ccquota/internal/model"
	"github.com/verkyyi/ccquota/internal/pricing"
	"github.com/verkyyi/ccquota/internal/store"
)

func newMCP(t *testing.T) (*httptest.Server, *store.Store) {
	t.Helper()
	st, err := store.Open(filepath.Join(t.TempDir(), "t.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })

	srv := &api.Server{Store: st, Pricing: pricing.Default()}
	ts := httptest.NewServer(Handler(srv))
	t.Cleanup(ts.Close)
	return ts, st
}

func seed(t *testing.T, st *store.Store, account, endpoint, cwd string, uuids ...string) {
	t.Helper()
	id := model.Identity{AccountUUID: account, Email: account + "@example.com", Hostname: endpoint}
	if err := st.UpsertAccount(id, "max", "default_claude_max_20x"); err != nil {
		t.Fatal(err)
	}
	if err := st.Enroll(endpoint, endpoint, "hash-"+endpoint); err != nil {
		t.Fatal(err)
	}
	if _, err := st.TouchEndpoint(endpoint, id, "test"); err != nil {
		t.Fatal(err)
	}
	evs := make([]model.UsageEvent, len(uuids))
	for i, u := range uuids {
		c := 1.0
		evs[i] = model.UsageEvent{
			AccountUUID: account, EndpointID: endpoint, MessageUUID: u,
			SessionID: "s-" + endpoint, TS: time.Now().UTC().Add(-time.Minute),
			Model: "claude-sonnet-5", OutputTokens: 1000, CWD: cwd, CostUSD: &c,
		}
	}
	if _, _, err := st.InsertEvents(evs); err != nil {
		t.Fatal(err)
	}
}

func rpc(t *testing.T, ts *httptest.Server, method string, params any) map[string]any {
	t.Helper()
	body := map[string]any{"jsonrpc": "2.0", "id": 1, "method": method}
	if params != nil {
		body["params"] = params
	}
	b, _ := json.Marshal(body)

	resp, err := ts.Client().Post(ts.URL, "application/json", bytes.NewReader(b))
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()

	var out map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		t.Fatalf("decode %s response: %v", method, err)
	}
	return out
}

func call(t *testing.T, ts *httptest.Server, tool string, args map[string]any) map[string]any {
	t.Helper()
	if args == nil {
		args = map[string]any{}
	}
	return rpc(t, ts, "tools/call", map[string]any{"name": tool, "arguments": args})
}

func TestInitialize(t *testing.T) {
	ts, _ := newMCP(t)
	out := rpc(t, ts, "initialize", map[string]any{"protocolVersion": protocolVersion})

	res, ok := out["result"].(map[string]any)
	if !ok {
		t.Fatalf("no result: %v", out)
	}
	if res["protocolVersion"] != protocolVersion {
		t.Errorf("protocolVersion = %v", res["protocolVersion"])
	}
	if _, ok := res["capabilities"].(map[string]any)["tools"]; !ok {
		t.Error("server must advertise the tools capability")
	}
}

func TestToolsList_AllSevenWithCaveats(t *testing.T) {
	ts, _ := newMCP(t)
	out := rpc(t, ts, "tools/list", nil)

	tools, ok := out["result"].(map[string]any)["tools"].([]any)
	if !ok {
		t.Fatalf("no tools: %v", out)
	}
	if len(tools) != 7 {
		t.Fatalf("tools = %d, want 7", len(tools))
	}

	want := map[string]bool{
		"list_accounts": false, "get_limits": false, "list_endpoints": false,
		"usage_by_endpoint": false, "usage_by_project": false,
		"usage_by_session": false, "usage_history": false,
	}
	for _, raw := range tools {
		tool := raw.(map[string]any)
		name := tool["name"].(string)
		if _, known := want[name]; !known {
			t.Errorf("unexpected tool %q", name)
			continue
		}
		want[name] = true
		if tool["description"].(string) == "" {
			t.Errorf("%s has no description", name)
		}
		if _, ok := tool["inputSchema"].(map[string]any)["properties"]; !ok {
			t.Errorf("%s has no input schema properties", name)
		}
	}
	for name, seen := range want {
		if !seen {
			t.Errorf("missing tool %q", name)
		}
	}
}

// An agent that relays these figures must be told they are estimates, or it
// will present them with the confidence of a measurement.
func TestToolsList_UsageToolsCarryTheEstimateCaveat(t *testing.T) {
	ts, _ := newMCP(t)
	out := rpc(t, ts, "tools/list", nil)
	tools := out["result"].(map[string]any)["tools"].([]any)

	for _, raw := range tools {
		tool := raw.(map[string]any)
		name := tool["name"].(string)
		if !strings.HasPrefix(name, "usage_") && name != "get_limits" {
			continue
		}
		desc := tool["description"].(string)
		if !strings.Contains(desc, "ESTIMATE") {
			t.Errorf("%s does not warn that shares are estimates", name)
		}
		if !strings.Contains(desc, "notional") {
			t.Errorf("%s does not warn that costs are notional", name)
		}
	}
}

func TestCall_ListAccounts(t *testing.T) {
	ts, st := newMCP(t)
	seed(t, st, "acct-a", "ep-1", "/srv/alpha", "u1")

	out := call(t, ts, "list_accounts", nil)
	res := out["result"].(map[string]any)
	if res["isError"] == true {
		t.Fatalf("unexpected error: %v", res)
	}
	sc := res["structuredContent"].(map[string]any)
	accts := sc["accounts"].([]any)
	if len(accts) != 1 {
		t.Fatalf("accounts = %d, want 1", len(accts))
	}
}

func TestCall_EmptyHubExplainsItself(t *testing.T) {
	ts, _ := newMCP(t)
	out := call(t, ts, "list_accounts", nil)
	sc := out["result"].(map[string]any)["structuredContent"].(map[string]any)
	if note, _ := sc["note"].(string); note == "" {
		t.Error("an empty hub should say why it is empty, not just return []")
	}
}

// The ambiguity must surface as a tool error the model can act on, not a
// silently-wrong account.
func TestCall_AmbiguousAccountIsAToolErrorNamingTheOptions(t *testing.T) {
	ts, st := newMCP(t)
	seed(t, st, "acct-a", "ep-1", "/a", "a1")
	seed(t, st, "acct-b", "ep-2", "/b", "b1")

	out := call(t, ts, "usage_by_endpoint", nil)
	res := out["result"].(map[string]any)
	if res["isError"] != true {
		t.Fatalf("expected a tool error, got %v", res)
	}
	text := res["content"].([]any)[0].(map[string]any)["text"].(string)
	if !strings.Contains(text, "acct-a") || !strings.Contains(text, "acct-b") {
		t.Errorf("the error should name the available accounts, got %q", text)
	}
}

func TestCall_UsageByProjectIsAccountScoped(t *testing.T) {
	ts, st := newMCP(t)
	seed(t, st, "acct-a", "ep-1", "/srv/alpha", "a1")
	seed(t, st, "acct-b", "ep-2", "/srv/confidential", "b1")

	out := call(t, ts, "usage_by_project", map[string]any{"account": "acct-a"})
	raw, _ := json.Marshal(out)
	if strings.Contains(string(raw), "confidential") {
		t.Fatalf("acct-a's answer leaked acct-b's directory: %s", raw)
	}
}

func TestCall_GetLimitsUnavailableIsExplicit(t *testing.T) {
	ts, st := newMCP(t)
	seed(t, st, "acct-a", "ep-1", "/a", "a1")

	out := call(t, ts, "get_limits", map[string]any{"account": "acct-a"})
	sc := out["result"].(map[string]any)["structuredContent"].(map[string]any)
	if sc["available"] == true {
		t.Fatal("available = true with no snapshot")
	}
	if sc["reason"] == nil || sc["reason"] == "" {
		t.Error("an unavailable reading must carry a reason")
	}
	if _, present := sc["five_hour"]; present {
		t.Error("an unavailable reading must not include a five_hour gauge at all")
	}
}

func TestCall_UnknownToolIsAToolError(t *testing.T) {
	ts, _ := newMCP(t)
	out := call(t, ts, "delete_everything", nil)
	res := out["result"].(map[string]any)
	if res["isError"] != true {
		t.Fatalf("expected a tool error for an unknown tool, got %v", res)
	}
}

func TestUnknownMethodIsAProtocolError(t *testing.T) {
	ts, _ := newMCP(t)
	out := rpc(t, ts, "resources/list", nil)
	e, ok := out["error"].(map[string]any)
	if !ok {
		t.Fatalf("expected a JSON-RPC error, got %v", out)
	}
	if int(e["code"].(float64)) != codeMethodNotFound {
		t.Errorf("code = %v, want %d", e["code"], codeMethodNotFound)
	}
}

// A notification carries no id and must get no response body.
func TestNotificationGetsNoBody(t *testing.T) {
	ts, _ := newMCP(t)
	b, _ := json.Marshal(map[string]any{"jsonrpc": "2.0", "method": "notifications/initialized"})
	resp, err := ts.Client().Post(ts.URL, "application/json", bytes.NewReader(b))
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusAccepted {
		t.Errorf("HTTP %d, want 202 for a notification", resp.StatusCode)
	}
}

func TestGetIsRejectedClearly(t *testing.T) {
	ts, _ := newMCP(t)
	resp, err := ts.Client().Get(ts.URL)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusMethodNotAllowed {
		t.Errorf("HTTP %d, want 405", resp.StatusCode)
	}
}

func TestMalformedJSONIsAnInvalidRequest(t *testing.T) {
	ts, _ := newMCP(t)
	resp, err := ts.Client().Post(ts.URL, "application/json", strings.NewReader("{not json"))
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()

	var out map[string]any
	json.NewDecoder(resp.Body).Decode(&out)
	if _, ok := out["error"]; !ok {
		t.Fatalf("expected a JSON-RPC error, got %v", out)
	}
}

// Every tool is a read. Nothing here may mutate the store.
func TestAllToolsAreReadOnly(t *testing.T) {
	ts, st := newMCP(t)
	seed(t, st, "acct-a", "ep-1", "/a", "a1", "a2", "a3")

	countRows := func() (int, int) {
		var ev, ep int
		st.DB().QueryRow(`SELECT COUNT(*) FROM usage_events`).Scan(&ev)
		st.DB().QueryRow(`SELECT COUNT(*) FROM endpoints`).Scan(&ep)
		return ev, ep
	}
	beforeEv, beforeEp := countRows()

	for _, tool := range []string{
		"list_accounts", "get_limits", "list_endpoints",
		"usage_by_endpoint", "usage_by_project", "usage_by_session", "usage_history",
	} {
		call(t, ts, tool, map[string]any{"account": "acct-a"})
	}

	afterEv, afterEp := countRows()
	if beforeEv != afterEv || beforeEp != afterEp {
		t.Fatalf("a tool mutated the store: events %d->%d, endpoints %d->%d",
			beforeEv, afterEv, beforeEp, afterEp)
	}
}
