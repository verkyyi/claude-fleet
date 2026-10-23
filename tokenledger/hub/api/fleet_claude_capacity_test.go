package api

import (
	"context"
	"encoding/json"
	"fmt"
	"github.com/verkyyi/claude-fleet/tokenledger/hub/credvault"
	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/credproxy"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/model"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

func claudeQuota(t *testing.T, r *cpRig, label string, at time.Time, weekly float64, raw bool) {
	t.Helper()
	c, err := r.h.srv.Store.Credential("gh:1005", credvault.Claude, label)
	if err != nil {
		t.Fatal(err)
	}
	five, week := at.Add(time.Hour), at.Add(24*time.Hour)
	payload := ""
	if raw {
		payload = fmt.Sprintf(`{"five_hour":{"utilization":0,"resets_at":%q},"seven_day":{"utilization":%v,"resets_at":%q}}`, five.Format(time.RFC3339Nano), weekly, week.Format(time.RFC3339Nano))
	}
	err = r.h.srv.Store.InsertLimits(&model.LimitsSnapshot{AccountUUID: r.h.srv.Vault.CredentialID(*c), EndpointID: HubQuotaEndpoint, ObservedAt: at, RawJSON: payload, FiveHour: model.Window{Utilization: 0, ResetsAt: &five}, SevenDay: model.Window{Utilization: weekly, ResetsAt: &week}})
	if err != nil {
		t.Fatal(err)
	}
}
func claudeRig(t *testing.T) (*cpRig, time.Time) {
	r := newCPRig(t)
	now := time.Now()
	profiles := []store.PlanCapacityProfile{}
	for i, a := range []string{"acct1", "acct2"} {
		p := capacityProfile("max", float64(5+i*15), now)
		p.Pool = "claude"
		p.Tier = a
		p.Windows = p.Windows[:1]
		profiles = append(profiles, p)
		if err := r.h.srv.Vault.SetPlan("gh:1005", credvault.Claude, a, "max", a, credvault.PlanEvidence{Source: "fixture provider identity", Confidence: "verified", ObservedAt: now}); err != nil {
			t.Fatal(err)
		}
		claudeQuota(t, r, a, now, 0, true)
	}
	_, err := r.h.srv.Store.SetPlanCapacities(store.PlanCapacityCatalog{Mode: "off", Providers: map[string]store.ProviderCapacityCatalog{"claude": {Mode: "active", Profiles: profiles}}}, 0, "fixture", now)
	if err != nil {
		t.Fatal(err)
	}
	return r, now
}
func TestClaudeHubHardLimitsBeforeMetadata(t *testing.T) {
	r, now := claudeRig(t)
	s := r.h.srv
	for _, a := range []string{"acct1", "acct2"} {
		if err := s.Vault.SetPlan("gh:1005", credvault.Claude, a, "max", a); err != nil {
			t.Fatal(err)
		}
		// Old header snapshots still carry hard negatives, even without raw JSON.
		claudeQuota(t, r, a, now.Add(time.Millisecond), 100, false)
	}
	_, _, err := s.claudeRouteBind("fixture", "gh:1005", "", credproxy.ClaudeRoute{Model: "claude-sonnet-4-6", Independent: true}, now.Add(time.Second))
	if err != errClaudeCapacity {
		t.Fatalf("full quota fell back: %v", err)
	}
	choices, _ := s.sessionBindChoices("gh:1005", "", credvault.Claude)
	cat, _ := s.Store.PlanCapacities()
	for _, q := range s.claudeInputs(choices, store.SessionBind{}, cat.Catalog.Provider("claude"), "claude-sonnet-4-6", now.Add(time.Second)) {
		if q.State != "limited" {
			t.Fatalf("%+v", q)
		}
	}
}
func TestClaudeHubNativeToolContinuityAndRefusal(t *testing.T) {
	r, now := claudeRig(t)
	s := r.h.srv
	pass, wid := r.issue(t, fidA)
	seen := []string{}
	bodies := []string{}
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		raw, _ := io.ReadAll(req.Body)
		seen = append(seen, req.Header.Get("Authorization"))
		bodies = append(bodies, string(raw))
		w.Header().Set("Content-Type", "text/event-stream")
		fmt.Fprint(w, "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tool_source\",\"name\":\"Bash\",\"input\":{}}}\n\n")
	}))
	defer up.Close()
	makeProxy := func() *httptest.Server {
		p, err := credproxy.New(credproxy.Config{Resolver: &credproxy.HubResolver{URL: r.h.http.URL, Token: cpToken}, Direct: true, AnthropicURL: up.URL, Audit: func(string) {}})
		if err != nil {
			t.Fatal(err)
		}
		server := httptest.NewServer(p.Handler())
		t.Cleanup(server.Close)
		return server
	}
	call := func(proxy *httptest.Server, body string, want int) {
		t.Helper()
		req, _ := http.NewRequest("POST", proxy.URL+"/v1/proxy/anthropic/v1/messages", strings.NewReader(body))
		req.Header.Set("Authorization", "Bearer "+pass)
		res, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		raw, _ := io.ReadAll(res.Body)
		res.Body.Close()
		if res.StatusCode != want {
			t.Fatalf("got %d want %d: %s", res.StatusCode, want, raw)
		}
	}
	first := `{"model":"claude-sonnet-4-6","messages":[{"role":"user","content":"hello"}]}`
	call(makeProxy(), first, 200)
	bind, _ := s.Store.SessionBindFor(wid, "claude")
	if bind.Account != "acct2" {
		t.Fatal(bind)
	}
	// A newer explicit pin cannot redirect a tool-result continuation.
	_, err := s.Store.SetSessionBind(store.SessionBind{WorkerID: wid, Provider: "claude", Owner: "gh:1005", Account: "acct1", SetBy: "operator"}, now)
	if err != nil {
		t.Fatal(err)
	}
	next := `{"model":"claude-sonnet-4-6","messages":[{"role":"user","content":[{"type":"tool_result","tool_use_id":"tool_source","content":"TOOL_OK"}]}]}`
	call(makeProxy(), next, 200)
	if seen[0] != seen[1] || bodies[1] != next {
		t.Fatal("source or body changed", seen, bodies)
	}
	call(makeProxy(), strings.ReplaceAll(next, "tool_source", "missing"), 409)
	call(makeProxy(), `{"model":"claude-sonnet-4-6","opaque_state":"unknown","messages":[{"role":"user","content":"hi"}]}`, 409)
	for _, a := range []string{"acct1", "acct2"} {
		claudeQuota(t, r, a, time.Now(), 100, true)
	}
	call(makeProxy(), first, 429)
	call(makeProxy(), next, 429)
	if len(seen) != 2 {
		t.Fatal("refusal contacted provider", seen)
	}
	cat, _ := s.Store.PlanCapacities()
	encoded, _ := json.Marshal(cat.Catalog)
	if cat.Catalog.Mode != "off" {
		t.Fatal(string(encoded))
	}
}

func TestClaudeHubNativeCLI(t *testing.T) {
	binary := os.Getenv("FLEET_CLAUDE_NATIVE_FIXTURE")
	if binary == "" {
		t.Skip("explicit isolated native Claude only")
	}
	r, _ := claudeRig(t)
	pass, wid := r.issue(t, fidA)
	var mu sync.Mutex
	var seen []string
	var bodies []json.RawMessage
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		raw, _ := io.ReadAll(req.Body)
		mu.Lock()
		seen = append(seen, req.Header.Get("Authorization"))
		bodies = append(bodies, raw)
		n := len(seen)
		mu.Unlock()
		w.Header().Set("Content-Type", "text/event-stream")
		event := func(v any) {
			b, _ := json.Marshal(v)
			fmt.Fprintf(w, "event: %s\ndata: %s\n\n", v.(map[string]any)["type"], b)
		}
		event(map[string]any{"type": "message_start", "message": map[string]any{"id": fmt.Sprint("msg_fixture_", n), "type": "message", "role": "assistant", "model": "claude-sonnet-4-6", "content": []any{}, "stop_reason": nil, "stop_sequence": nil, "usage": map[string]int{"input_tokens": 10, "output_tokens": 0}}})
		block := map[string]any{"type": "text", "text": ""}
		delta := map[string]any{"type": "text_delta", "text": "FIXTURE_NONCE"}
		stop := "end_turn"
		if n == 1 {
			block = map[string]any{"type": "tool_use", "id": "tool_source", "name": "Bash", "input": map[string]any{}}
			delta = map[string]any{"type": "input_json_delta", "partial_json": `{"command":"printf TOOL_OK","description":"Print fixture nonce"}`}
			stop = "tool_use"
		}
		event(map[string]any{"type": "content_block_start", "index": 0, "content_block": block})
		event(map[string]any{"type": "content_block_delta", "index": 0, "delta": delta})
		event(map[string]any{"type": "content_block_stop", "index": 0})
		event(map[string]any{"type": "message_delta", "delta": map[string]any{"stop_reason": stop, "stop_sequence": nil}, "usage": map[string]int{"output_tokens": 5}})
		event(map[string]any{"type": "message_stop"})
	}))
	defer up.Close()
	proxy, err := credproxy.New(credproxy.Config{Resolver: &credproxy.HubResolver{URL: r.h.http.URL, Token: cpToken}, Direct: true, AnthropicURL: up.URL, Audit: func(string) {}})
	if err != nil {
		t.Fatal(err)
	}
	server := httptest.NewServer(proxy.Handler())
	defer server.Close()
	home := t.TempDir()
	work := t.TempDir()
	sid := ""
	for _, prompt := range []string{"Use Bash to print TOOL_OK, then reply FIXTURE_NONCE.", "Repeat the nonce. Do not use tools."} {
		args := []string{"--bare", "-p", "--output-format", "stream-json", "--verbose", "--tools", "Bash", "--allowedTools", "Bash", "--strict-mcp-config", "--model", "claude-sonnet-4-6", "--permission-mode", "bypassPermissions"}
		if sid != "" {
			args = append(args, "--resume", sid)
		}
		args = append(args, prompt)
		ctx, cancel := context.WithTimeout(t.Context(), 40*time.Second)
		cmd := exec.CommandContext(ctx, binary, args...)
		cmd.Dir = work
		cmd.Env = []string{"PATH=" + os.Getenv("PATH"), "HOME=" + home, "CLAUDE_CONFIG_DIR=" + filepath.Join(home, ".claude"), "TMPDIR=" + home, "ANTHROPIC_API_KEY=" + pass, "ANTHROPIC_BASE_URL=" + server.URL + "/v1/proxy/anthropic", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1", "DISABLE_AUTOUPDATER=1", "NO_PROXY=*", "no_proxy=*"}
		output, err := cmd.CombinedOutput()
		cancel()
		if err != nil {
			t.Fatalf("native: %v %s", err, output)
		}
		success := false
		for _, line := range strings.Split(string(output), "\n") {
			var e map[string]any
			if json.Unmarshal([]byte(line), &e) != nil {
				continue
			}
			if e["type"] == "system" && e["subtype"] == "init" {
				sid, _ = e["session_id"].(string)
			}
			if e["type"] == "result" && e["result"] == "FIXTURE_NONCE" {
				success = true
			}
		}
		if !success || sid == "" {
			t.Fatalf("native result: %s", output)
		}
	}
	mu.Lock()
	defer mu.Unlock()
	if len(seen) != 3 || seen[0] != seen[1] || seen[1] != seen[2] || !strings.Contains(string(bodies[1]), "TOOL_OK") {
		t.Fatal("native source/tool roundtrip", seen)
	}
	b, _ := r.h.srv.Store.SessionBindFor(wid, "claude")
	if b.Account != "acct2" {
		t.Fatal(b)
	}
	if path := os.Getenv("FLEET_CLAUDE_HUB_NATIVE_WIRE"); path != "" {
		raw, _ := json.MarshalIndent(bodies, "", "  ")
		if err := os.WriteFile(path, raw, 0600); err != nil {
			t.Fatal(err)
		}
	}
}

func TestClaudeMetadataAndPreviewReadOnly(t *testing.T) {
	h, tok, ref := newVaultHarness(t)
	expiry := time.Now().Add(24 * time.Hour)
	for _, owner := range []string{pAlice, "pool", "unrelated"} {
		if err := h.srv.Vault.Put(owner, "claude", owner, credvault.Secret{SetupToken: "sk-ant-oat01-fixture-" + owner, ExpiresAt: &expiry}); err != nil {
			t.Fatal(err)
		}
	}
	call := func(token string) (int, string) {
		req := httptest.NewRequest("GET", nodeClaudeCapacityPath, nil)
		req.Header.Set("Authorization", "Bearer "+token)
		w := httptest.NewRecorder()
		h.srv.handleNodeCapacity(w, req)
		return w.Code, w.Body.String()
	}
	if code, _ := call(""); code != 401 {
		t.Fatal(code)
	}
	code, raw := call(tok)
	if code != 200 || strings.Contains(raw, "unrelated") || strings.Contains(raw, "sk-ant-oat01") || !strings.Contains(raw, `"mode":"off"`) {
		t.Fatal(code, raw)
	}
	if ref.n.Load() != 0 {
		t.Fatal("metadata refreshed credential")
	}
	if err := h.srv.Store.Revoke("mac-c", pAlice, "test", time.Now()); err != nil {
		t.Fatal(err)
	}
	if code, _ := call(tok); code != 403 {
		t.Fatal(code)
	}
	r, now := claudeRig(t)
	_, wid := r.issue(t, fidA)
	before, err := r.h.srv.Store.SetSessionBind(store.SessionBind{WorkerID: wid, Provider: "claude", Owner: "gh:1005", Account: "acct1", SetBy: "operator"}, now)
	if err != nil {
		t.Fatal(err)
	}
	request := fmt.Sprintf(`{"provider":"claude","model":"claude-sonnet-4-6","worker_id":%q,"new_session":true}`, wid)
	w := httptest.NewRecorder()
	r.h.srv.handleCodexPreview(w, httptest.NewRequest("POST", codexPreviewPath, strings.NewReader(request)))
	if w.Code != 200 || !strings.Contains(w.Body.String(), `"account":"acct2"`) || !strings.Contains(w.Body.String(), `"mutates_bindings":false`) {
		t.Fatal(w.Code, w.Body.String())
	}
	after, err := r.h.srv.Store.SessionBindFor(wid, "claude")
	if err != nil || before != after {
		t.Fatal("preview mutated binding", before, after, err)
	}
}

func TestClaudeCatalogDoesNotChangeCodexSelection(t *testing.T) {
	r, now, cat := registerCapacityRig(t)
	s := r.h.srv
	choices, _ := s.sessionBindChoices("gh:1005", "", credvault.Codex)
	b := store.SessionBind{WorkerID: "fixture"}
	before, _ := json.Marshal(s.codexSelectionInputs(choices, b, now, cat))
	p := capacityProfile("max", 20, now)
	p.Pool = "claude"
	p.Windows = p.Windows[:1]
	for _, mode := range []string{"off", "shadow", "active"} {
		cat.Providers = map[string]store.ProviderCapacityCatalog{"claude": {Mode: mode, Profiles: []store.PlanCapacityProfile{p}}}
		if err := cat.Validate(); err != nil {
			t.Fatal(err)
		}
		after, _ := json.Marshal(s.codexSelectionInputs(choices, b, now, cat))
		if string(before) != string(after) {
			t.Fatalf("Claude %s changed Codex inputs", mode)
		}
	}
}
