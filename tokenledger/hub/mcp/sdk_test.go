package mcp

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	sdkmcp "github.com/modelcontextprotocol/go-sdk/mcp"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/api"
	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/hub/store/storetest"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/pricing"
)

// The SDK's own client speaks to Handler end to end (task T4DN): initialize,
// list, call — the road ChatGPT, Claude and Codex take.
func TestSDKClientInitializeListCall(t *testing.T) {
	ts, st := newMCP(t)
	seed(t, st, "acct-a", "ep-1", "/a", "a1")

	client := sdkmcp.NewClient(&sdkmcp.Implementation{Name: "test", Version: "1"}, nil)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	cs, err := client.Connect(ctx, &sdkmcp.StreamableClientTransport{Endpoint: ts.URL, DisableStandaloneSSE: true}, nil)
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	defer cs.Close()

	init := cs.InitializeResult()
	if init.ServerInfo.Name != "tokenman" || init.Capabilities.Tools == nil || !strings.Contains(init.Instructions, "ESTIMATES") {
		t.Fatalf("initialize = %+v", init)
	}
	tools, err := cs.ListTools(ctx, nil)
	if err != nil {
		t.Fatal(err)
	}
	var la *sdkmcp.Tool
	for _, x := range tools.Tools {
		if x.Name == "list_accounts" {
			la = x
		}
	}
	if len(tools.Tools) != len(toolSpecs()) || la == nil {
		t.Fatalf("tools = %d (list_accounts %v), want %d", len(tools.Tools), la != nil, len(toolSpecs()))
	}
	if la.Annotations == nil || !la.Annotations.ReadOnlyHint {
		t.Errorf("list_accounts annotations = %+v; want readOnlyHint", la.Annotations)
	}
	ss, _ := la.Meta["securitySchemes"].([]any)
	if len(ss) != 1 || !strings.Contains(mustJSON(ss), `"fleet:read"`) || !strings.Contains(mustJSON(ss), `"oauth2"`) {
		t.Errorf("list_accounts securitySchemes = %v", la.Meta)
	}

	res, err := cs.CallTool(ctx, &sdkmcp.CallToolParams{Name: "list_accounts", Arguments: map[string]any{}})
	if err != nil {
		t.Fatal(err)
	}
	if res.IsError || res.StructuredContent == nil || !strings.Contains(mustJSON(res.StructuredContent), "acct-a") {
		t.Fatalf("list_accounts = %+v", res)
	}
	if tc, ok := res.Content[0].(*sdkmcp.TextContent); !ok || !strings.Contains(tc.Text, "acct-a") {
		t.Fatalf("content = %v", res.Content)
	}

	// A tool this server does not have is still a tool error, not a protocol one.
	res, err = cs.CallTool(ctx, &sdkmcp.CallToolParams{Name: "delete_everything", Arguments: map[string]any{}})
	if err != nil || !res.IsError {
		t.Fatalf("delete_everything = %+v, %v; want a tool error", res, err)
	}
}

// Stateless: a bare POST answers with no initialize first, no session id
// handed out, and no Accept header needed.
func TestPlainPostWithoutInitialize(t *testing.T) {
	ts, _ := newMCP(t)
	req, _ := http.NewRequest(http.MethodPost, ts.URL, strings.NewReader(`{"jsonrpc":"2.0","id":7,"method":"tools/list"}`))
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 || !strings.HasPrefix(resp.Header.Get("Content-Type"), "application/json") {
		t.Fatalf("HTTP %d %s", resp.StatusCode, resp.Header.Get("Content-Type"))
	}
	if sid := resp.Header.Get("Mcp-Session-Id"); sid != "" {
		t.Errorf("a stateless server handed out session %q", sid)
	}
	var out map[string]any
	json.NewDecoder(resp.Body).Decode(&out)
	if tools, _ := out["result"].(map[string]any)["tools"].([]any); len(tools) != len(toolSpecs()) || out["id"] != float64(7) {
		t.Fatalf("tools/list = %v", out)
	}
}

// agentHub is a fleet hub behind its real middleware, /mcp served by Handler,
// with a person whose connected agent was granted fleet:read only.
func agentHub(t *testing.T) (ts *httptest.Server, key string) {
	t.Helper()
	st := storetest.OpenFleet(t)
	const person = "gh:4242"
	if err := st.UpsertHubUser(store.HubUser{PrincipalID: person, Login: "alice", Role: store.RoleUser, AddedBy: "test", AddedAt: time.Now()}); err != nil {
		t.Fatal(err)
	}
	key = "tm_" + strings.Repeat("k", 24) // a stand-in key, not a secret
	g := store.AgentGrant{ID: "g1", Person: person, Name: "read only", Client: "chatgpt", Kind: store.AgentGrantPAT,
		Scopes: []string{"fleet:read"}, CreatedAt: time.Now(), ExpiresAt: time.Now().Add(time.Hour)}
	if err := st.AddAgentGrant(g, api.HashToken(key)); err != nil {
		t.Fatal(err)
	}
	srv := &api.Server{Store: st, Pricing: pricing.Default(), Fleet: true, LiveStore: api.NewLive(),
		ViewerToken: "viewer", FleetPublicURL: "https://hub.example",
		GitHub: &api.GitHubAuth{ClientID: "Iv1.test", ClientSecret: "s"}}
	srv.MCP = Handler(srv)
	ts = httptest.NewServer(srv.Handler())
	t.Cleanup(ts.Close)
	return ts, key
}

// rpcAs posts one JSON-RPC request to /mcp with a bearer.
func rpcAs(t *testing.T, ts *httptest.Server, tok, method string, params any) map[string]any {
	t.Helper()
	b, _ := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": 1, "method": method, "params": params})
	req, _ := http.NewRequest(http.MethodPost, ts.URL+"/mcp", bytes.NewReader(b))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+tok)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var out map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		t.Fatalf("%s: HTTP %d: %v", method, resp.StatusCode, err)
	}
	return out
}

// What a user is shown differs from the operator (claude-fleet#1985): the
// operator every tool of the fleet module, a person's agent only theirs.
func TestToolsListUserVersusOperator(t *testing.T) {
	ts, key := agentHub(t)
	names := func(tok string) map[string]bool {
		got := map[string]bool{}
		out := rpcAs(t, ts, tok, "tools/list", map[string]any{})
		r, _ := out["result"].(map[string]any)
		if r == nil {
			t.Fatalf("tools/list as %.6s: %v", tok, out)
		}
		tools, _ := r["tools"].([]any)
		for _, x := range tools {
			got[x.(map[string]any)["name"].(string)] = true
		}
		return got
	}
	op, mine := names("viewer"), names(key)
	if len(op) != len(toolSpecs())+len(fleetToolSpecs())+len(sessionToolSpecs()) {
		t.Fatalf("operator sees %d tools", len(op))
	}
	if len(mine) == 0 || len(mine) >= len(op) || !mine["sessions_list"] || mine["list_accounts"] {
		t.Fatalf("agent sees %d of %d: %v", len(mine), len(op), mine)
	}
	for n := range mine {
		if !api.IsUserTool(n) && !api.IsSessionTool(n) {
			t.Errorf("agent shown %s", n)
		}
	}
}

// A connected agent refused for a scope its grant lacks gets the
// insufficient_scope challenge in _meta["mcp/www_authenticate"] (OpenAI's MCP
// auth): the scope it needs and where the resource metadata is.
func TestInsufficientScopeCarriesChallenge(t *testing.T) {
	ts, key := agentHub(t)
	out := rpcAs(t, ts, key, "tools/call", map[string]any{"name": "session_say",
		"arguments": map[string]any{"id": "x", "text": "hi", "idempotency_key": "k1"}})
	res, _ := out["result"].(map[string]any)
	if res == nil || res["isError"] != true {
		t.Fatalf("%v; want a tool error", out)
	}
	meta, _ := res["_meta"].(map[string]any)
	ch, _ := meta["mcp/www_authenticate"].([]any)
	if len(ch) != 1 {
		t.Fatalf("_meta = %v", res["_meta"])
	}
	v := ch[0].(string)
	for _, want := range []string{`Bearer error="insufficient_scope"`, `scope="worker:message"`,
		`resource_metadata="https://hub.example/.well-known/oauth-protected-resource/mcp"`, `error_description=`} {
		if !strings.Contains(v, want) {
			t.Errorf("challenge %q lacks %s", v, want)
		}
	}

	// A read the grant holds carries no challenge.
	out = rpcAs(t, ts, key, "tools/call", map[string]any{"name": "task_list", "arguments": map[string]any{}})
	if res, _ := out["result"].(map[string]any); res == nil || res["_meta"] != nil {
		t.Fatalf("task_list = %v", out)
	}
}

func mustJSON(v any) string {
	b, _ := json.Marshal(v)
	return string(b)
}
