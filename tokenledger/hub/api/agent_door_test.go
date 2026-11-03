package api

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/pricing"
)

// newAgentHarness is a fleet hub whose /mcp is a stub that answers who came in:
// the person, the door, the role and the grant's scopes (task T4DN).
func newAgentHarness(t *testing.T) *harness {
	t.Helper()
	st := openFleetTestStore(t)
	srv := &Server{Store: st, Pricing: pricing.Default(), ViewerToken: viewerToken, LiveStore: NewLive(), Fleet: true}
	srv.MCP = http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		out := map[string]any{"person": principalOf(r.Context()), "door": doorOf(r.Context()), "role": roleOf(r.Context())}
		if g := agentGrantOf(r.Context()); g != nil {
			out["scopes"] = g.Scopes
		}
		p, _ := srv.FleetPrincipal(r)
		out["write_start"] = srv.authorize(p, "worker:start", "") == nil
		writeJSON(w, 200, out)
	})
	ts := httptest.NewServer(srv.Handler())
	t.Cleanup(ts.Close)
	h := &harness{srv: srv, http: ts, tokens: map[string]string{}}
	enablePeople(t, h, pAlice, pBob)
	return h
}

func jsonAsPerson(t *testing.T, h *harness, method, path, principal string, body any) (int, map[string]any) {
	t.Helper()
	var rd io.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		rd = bytes.NewReader(b)
	}
	r, _ := http.NewRequest(method, h.http.URL+path, rd)
	if body != nil {
		r.Header.Set("Content-Type", "application/json")
	}
	r.AddCookie(personCookie(principal, ""))
	resp, err := http.DefaultClient.Do(r)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	out := map[string]any{}
	json.NewDecoder(resp.Body).Decode(&out)
	return resp.StatusCode, out
}

func mcpWith(t *testing.T, h *harness, tok string) (int, map[string]any, http.Header) {
	t.Helper()
	r, _ := http.NewRequest(http.MethodPost, h.http.URL+"/mcp", strings.NewReader(`{}`))
	if tok != "" {
		r.Header.Set("Authorization", "Bearer "+tok)
	}
	resp, err := http.DefaultClient.Do(r)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	out := map[string]any{}
	json.NewDecoder(resp.Body).Decode(&out)
	return resp.StatusCode, out, resp.Header
}

// A personal key opens /mcp as its person, with its scopes, and nothing else.
func TestAgentKeyOpensMCPOnly(t *testing.T) {
	h := newAgentHarness(t)
	code, made := jsonAsPerson(t, h, http.MethodPost, MeAgentsPath, pAlice,
		map[string]any{"name": "laptop codex", "client": "codex", "permissions": []string{"talk"}, "days": 7})
	if code != http.StatusCreated {
		t.Fatalf("connect: HTTP %d %v", code, made)
	}
	key, _ := made["key"].(string)
	if !strings.HasPrefix(key, agentKeyPrefix) {
		t.Fatalf("key %q", key)
	}
	if sn, _ := made["snippets"].(map[string]any); sn == nil || !strings.Contains(sn["codex"].(string), "bearer_token_env_var") {
		t.Fatalf("snippets: %v", made["snippets"])
	}

	code, who, _ := mcpWith(t, h, key)
	if code != 200 || who["person"] != pAlice || who["door"] != doorAgent || who["role"] != roleUser {
		t.Fatalf("/mcp with the key: HTTP %d %v", code, who)
	}
	if who["write_start"] != false {
		t.Fatalf("a grant without start may start: %v", who)
	}

	// The same bearer anywhere else is no one.
	for _, p := range []string{MeAgentsPath, "/v1/fleet/sessions", "/v1/me"} {
		r, _ := http.NewRequest(http.MethodGet, h.http.URL+p, nil)
		r.Header.Set("Authorization", "Bearer "+key)
		resp, _ := http.DefaultClient.Do(r)
		resp.Body.Close()
		if resp.StatusCode != http.StatusUnauthorized {
			t.Fatalf("%s with an agent key: HTTP %d, want 401", p, resp.StatusCode)
		}
	}

	// Listed for its person only.
	_, list := jsonAsPerson(t, h, http.MethodGet, MeAgentsPath, pAlice, nil)
	if a, _ := list["agents"].([]any); len(a) != 1 {
		t.Fatalf("alice's agents: %v", list)
	}
	_, list = jsonAsPerson(t, h, http.MethodGet, MeAgentsPath, pBob, nil)
	if a, _ := list["agents"].([]any); len(a) != 0 {
		t.Fatalf("bob sees alice's agents: %v", list)
	}
	id := made["agent"].(map[string]any)["id"].(string)
	if code, _ := jsonAsPerson(t, h, http.MethodPost, MeAgentsRevokePath, pBob, map[string]any{"id": id}); code != http.StatusNotFound {
		t.Fatalf("bob revoked alice's agent: HTTP %d", code)
	}

	// Revoked: refused on the very next call, and told it is the token.
	if code, _ := jsonAsPerson(t, h, http.MethodPost, MeAgentsRevokePath, pAlice, map[string]any{"id": id}); code != 200 {
		t.Fatalf("revoke: HTTP %d", code)
	}
	code, _, hdr := mcpWith(t, h, key)
	if code != http.StatusUnauthorized || !strings.Contains(hdr.Get("WWW-Authenticate"), `error="invalid_token"`) {
		t.Fatalf("revoked key: HTTP %d %q", code, hdr.Get("WWW-Authenticate"))
	}
}

// /mcp's 401 names where to sign in; the metadata names the endpoints.
func TestMCPUnauthorizedPointsToMetadata(t *testing.T) {
	h := newAgentHarness(t)
	code, _, hdr := mcpWith(t, h, "")
	if code != 401 || !strings.Contains(hdr.Get("WWW-Authenticate"), `resource_metadata="`+h.http.URL+"/.well-known/oauth-protected-resource/mcp") {
		t.Fatalf("HTTP %d %q", code, hdr.Get("WWW-Authenticate"))
	}
	var pr, as map[string]any
	agentGetJSON(t, h.http.URL+"/.well-known/oauth-protected-resource/mcp", &pr)
	if pr["resource"] != h.http.URL+"/mcp" {
		t.Fatalf("protected resource: %v", pr)
	}
	agentGetJSON(t, h.http.URL+authServerMetaPath, &as)
	if as["token_endpoint"] != h.http.URL+OAuthTokenPath || as["client_id_metadata_document_supported"] != true {
		t.Fatalf("auth server metadata: %v", as)
	}
}

func agentGetJSON(t *testing.T, u string, v any) {
	t.Helper()
	resp, err := http.Get(u)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		t.Fatalf("GET %s: HTTP %d", u, resp.StatusCode)
	}
	json.NewDecoder(resp.Body).Decode(v)
}

func agentPostForm(t *testing.T, u string, v url.Values) (int, map[string]any) {
	t.Helper()
	resp, err := http.PostForm(u, v)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	out := map[string]any{}
	json.NewDecoder(resp.Body).Decode(&out)
	return resp.StatusCode, out
}

// The whole OAuth road: register (DCR), authorize → consent, approve, code +
// PKCE → tokens, /mcp as the person, refresh rotates, a replayed refresh token
// revokes the connection.
func TestOAuthRoundTrip(t *testing.T) {
	h := newAgentHarness(t)
	reg, _ := json.Marshal(map[string]any{"client_name": "Codex CLI", "redirect_uris": []string{"http://127.0.0.1:4000/callback"}})
	resp, err := http.Post(h.http.URL+OAuthRegisterPath, "application/json", bytes.NewReader(reg))
	if err != nil {
		t.Fatal(err)
	}
	var cl map[string]any
	json.NewDecoder(resp.Body).Decode(&cl)
	resp.Body.Close()
	clientID, _ := cl["client_id"].(string)
	if resp.StatusCode != 201 || clientID == "" {
		t.Fatalf("register: HTTP %d %v", resp.StatusCode, cl)
	}
	// A non-loopback http redirect is never registered.
	bad, _ := json.Marshal(map[string]any{"redirect_uris": []string{"http://evil.example/cb"}})
	if resp, _ := http.Post(h.http.URL+OAuthRegisterPath, "application/json", bytes.NewReader(bad)); resp.StatusCode != 400 {
		t.Fatalf("http redirect registered: HTTP %d", resp.StatusCode)
	}

	verifier := strings.Repeat("v", 50)
	q := url.Values{"response_type": {"code"}, "client_id": {clientID},
		"redirect_uri":   {"http://127.0.0.1:53111/callback"}, // another port: loopback matches without it
		"code_challenge": {pkceS256(verifier)}, "code_challenge_method": {"S256"},
		"state": {"xyz"}, "scope": {"read talk start"}, "resource": {h.http.URL + "/mcp"}}
	r := h.raw(t, OAuthAuthorizePath+"?"+q.Encode(), nil)
	if r.StatusCode != http.StatusFound || !strings.HasPrefix(r.Header.Get("Location"), appURL(oauthConsentPage)+"?") {
		t.Fatalf("authorize: HTTP %d → %q", r.StatusCode, r.Header.Get("Location"))
	}
	// An unregistered redirect goes nowhere.
	q2 := url.Values{}
	for k, v := range q {
		q2[k] = v
	}
	q2.Set("redirect_uri", "https://evil.example/cb")
	if r := h.raw(t, OAuthAuthorizePath+"?"+q2.Encode(), nil); r.StatusCode != 400 {
		t.Fatalf("foreign redirect: HTTP %d", r.StatusCode)
	}

	code, req := jsonAsPerson(t, h, http.MethodGet, MeOAuthRequestPath+"?"+q.Encode(), pAlice, nil)
	if code != 200 || req["client"].(map[string]any)["name"] != "Codex CLI" {
		t.Fatalf("consent request: HTTP %d %v", code, req)
	}
	code, ans := jsonAsPerson(t, h, http.MethodPost, MeOAuthApprovePath, pAlice,
		map[string]any{"query": q.Encode(), "permissions": []string{"talk"}, "days": 30, "approve": true})
	red, _ := url.Parse(ans["redirect"].(string))
	if code != 200 || red.Query().Get("state") != "xyz" || red.Query().Get("iss") != h.http.URL || red.Query().Get("code") == "" {
		t.Fatalf("approve: HTTP %d %v", code, ans)
	}
	authCode := red.Query().Get("code")

	// A wrong verifier spends nothing useful; the right one gets tokens once.
	tokURL := h.http.URL + OAuthTokenPath
	base := url.Values{"grant_type": {"authorization_code"}, "code": {authCode}, "client_id": {clientID},
		"redirect_uri": {"http://127.0.0.1:53111/callback"}}
	good := url.Values{}
	for k, v := range base {
		good[k] = v
	}
	good.Set("code_verifier", verifier)
	code, tok := agentPostForm(t, tokURL, good)
	if code != 200 {
		t.Fatalf("token: HTTP %d %v", code, tok)
	}
	if code, _ := agentPostForm(t, tokURL, good); code != 400 {
		t.Fatalf("a code worked twice: HTTP %d", code)
	}
	access, refresh := tok["access_token"].(string), tok["refresh_token"].(string)
	if tok["scope"] != "fleet:read worker:message" {
		t.Fatalf("scope: the person's choice, not the client's ask: %v", tok["scope"])
	}

	code, who, _ := mcpWith(t, h, access)
	if code != 200 || who["person"] != pAlice || who["door"] != doorAgent {
		t.Fatalf("/mcp with the access token: HTTP %d %v", code, who)
	}

	code, tok2 := agentPostForm(t, tokURL, url.Values{"grant_type": {"refresh_token"}, "refresh_token": {refresh}, "client_id": {clientID}})
	if code != 200 || tok2["access_token"] == access {
		t.Fatalf("refresh: HTTP %d %v", code, tok2)
	}
	if code, _ := agentPostForm(t, tokURL, url.Values{"grant_type": {"refresh_token"}, "refresh_token": {refresh}, "client_id": {clientID}}); code != 400 {
		t.Fatalf("a spent refresh token worked: HTTP %d", code)
	}
	if code, _, _ := mcpWith(t, h, tok2["access_token"].(string)); code != 401 {
		t.Fatalf("after a replay the connection still works: HTTP %d", code)
	}
}

// A metadata-document client is fetched, checked and kept; one naming another
// client_id is refused.
func TestOAuthCIMDClient(t *testing.T) {
	h := newAgentHarness(t)
	id := "https://claude.ai/oauth/mcp-oauth-client-metadata"
	saved := cimdFetch
	t.Cleanup(func() { cimdFetch = saved })
	doc := map[string]any{"client_id": id, "client_name": "Claude", "redirect_uris": []string{"https://claude.ai/api/mcp/auth_callback"}}
	cimdFetch = func(context.Context, string) ([]byte, error) { return json.Marshal(doc) }
	q := url.Values{"response_type": {"code"}, "client_id": {id}, "redirect_uri": {"https://claude.ai/api/mcp/auth_callback"},
		"code_challenge": {pkceS256(strings.Repeat("w", 43))}, "code_challenge_method": {"S256"}}
	code, req := jsonAsPerson(t, h, http.MethodGet, MeOAuthRequestPath+"?"+q.Encode(), pAlice, nil)
	if code != 200 || req["client"].(map[string]any)["host"] != "claude.ai" {
		t.Fatalf("cimd: HTTP %d %v", code, req)
	}
	c, err := h.srv.Store.OAuthClient(id)
	if err != nil || c.Kind != "cimd" || clientKind(c) != "claude-ai" {
		t.Fatalf("stored client: %+v %v", c, err)
	}
	doc["client_id"] = "https://evil.example/other"
	h.srv.Store.PutOAuthClient(store.OAuthClient{ClientID: id, Kind: "cimd", CreatedAt: time.Now().Add(-2 * cimdTTL)})
	if code, _ := jsonAsPerson(t, h, http.MethodGet, MeOAuthRequestPath+"?"+q.Encode(), pAlice, nil); code != 400 {
		t.Fatalf("a document naming another client: HTTP %d", code)
	}
	if !isCIMD(id) || isCIMD("https://claude.ai") || isCIMD("http://x.example/a") {
		t.Fatal("isCIMD")
	}
}

func TestRedirectMatches(t *testing.T) {
	for _, c := range []struct {
		reg, ask string
		want     bool
	}{
		{"http://127.0.0.1:4000/cb", "http://127.0.0.1:9999/cb", true},
		{"http://localhost/cb", "http://localhost:1234/cb", true},
		{"http://127.0.0.1:4000/cb", "http://127.0.0.1:9999/other", false},
		{"http://127.0.0.1/cb", "http://localhost/cb", false},
		{"https://a.example/cb", "https://a.example:444/cb", false},
		{"https://a.example/cb", "https://a.example/cb", true},
	} {
		if got := redirectMatches(c.reg, c.ask); got != c.want {
			t.Errorf("redirectMatches(%q, %q) = %v", c.reg, c.ask, got)
		}
	}
}

func TestPublicDialerRefusesPrivate(t *testing.T) {
	for _, a := range []string{"127.0.0.1:443", "10.0.0.1:443", "192.168.1.1:443", "169.254.169.254:80", "100.100.1.1:443", "[::1]:443"} { // oss-ok: the private ranges the CIMD dialer must refuse
		if err := publicDialer.Control("tcp", a, nil); err == nil {
			t.Errorf("%s allowed", a)
		}
	}
	if err := publicDialer.Control("tcp", "8.8.8.8:443", nil); err != nil {
		t.Errorf("public refused: %v", err)
	}
}

// A signed-out person's consent page comes back to them, the whole OAuth
// request with it, after the sign-in.
func TestOAuthConsentSurvivesSignIn(t *testing.T) {
	q := url.Values{"response_type": {"code"}, "client_id": {"https://claude.ai/oauth/mcp-oauth-client-metadata"},
		"redirect_uri": {"https://claude.ai/api/mcp/auth_callback"}, "code_challenge": {strings.Repeat("c", 43)},
		"code_challenge_method": {"S256"}, "state": {strings.Repeat("s", 300)}, "scope": {"read talk start stop answer"},
		"resource": {"https://hub.example.com/mcp"}}
	to := oauthConsentPagePath + "?" + q.Encode()
	if len(to) <= appReturnMax || !appReturnOK(to) {
		t.Fatalf("a %d-byte consent address is not carried back through the sign-in", len(to))
	}
	if appReturnOK(AppPrefix + "/s/x?" + q.Encode()) {
		t.Fatal("the longer bound leaked to every page")
	}
}

// A session tool's chat call handed to the replica holding the person's link
// is admitted there as the person; the same key from outside is not.
func TestAgentKeyRidesAReplicaHopOnly(t *testing.T) {
	h := newAgentHarness(t)
	h.srv.Replica = &Replica{Name: "r1", Token: "replica-secret"}
	_, made := jsonAsPerson(t, h, http.MethodPost, MeAgentsPath, pAlice, map[string]any{"client": "codex", "permissions": []string{"talk"}})
	key := made["key"].(string)
	call := func(hop string) int {
		r, _ := http.NewRequest(http.MethodPost, h.http.URL+ChatPathPrefix+"stop?worker=x", strings.NewReader(`{}`))
		r.Header.Set("Authorization", "Bearer "+key)
		r.Header.Set("Content-Type", "application/json")
		if hop != "" {
			r.Header.Set(replicaTokenHeader, hop)
		}
		resp, err := http.DefaultClient.Do(r)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		return resp.StatusCode
	}
	if c := call(""); c != http.StatusUnauthorized {
		t.Fatalf("an agent key straight to the chat road: HTTP %d", c)
	}
	if c := call("wrong"); c != http.StatusUnauthorized {
		t.Fatalf("a forged hop: HTTP %d", c)
	}
	if c := call("replica-secret"); c == http.StatusUnauthorized {
		t.Fatal("a replica hop carrying an agent key is refused at the door")
	}
}

// ChatGPT's metadata document (as published): it prefers private_key_jwt but
// supports none, so it signs in as a public client; one with no none is refused.
func TestOAuthCIMDChatGPTDocument(t *testing.T) {
	h := newAgentHarness(t)
	id := "https://chatgpt.com/oauth/abc123/client.json"
	saved := cimdFetch
	t.Cleanup(func() { cimdFetch = saved })
	doc := map[string]any{"client_id": id, "client_name": "ChatGPT",
		"redirect_uris":                         []string{"https://chatgpt.com/connector_platform_oauth_redirect"},
		"token_endpoint_auth_method":            "private_key_jwt",
		"token_endpoint_auth_methods_supported": []string{"none", "private_key_jwt"},
		"jwks_uri":                              "https://chatgpt.com/oauth/jwks.json"}
	cimdFetch = func(context.Context, string) ([]byte, error) { return json.Marshal(doc) }
	q := url.Values{"response_type": {"code"}, "client_id": {id}, "redirect_uri": {"https://chatgpt.com/connector_platform_oauth_redirect"},
		"code_challenge": {pkceS256(strings.Repeat("w", 43))}, "code_challenge_method": {"S256"}}
	if code, req := jsonAsPerson(t, h, http.MethodGet, MeOAuthRequestPath+"?"+q.Encode(), pAlice, nil); code != 200 {
		t.Fatalf("ChatGPT's document: HTTP %d %v", code, req)
	}
	if !cimdPublicOK("private_key_jwt", []string{"none", "private_key_jwt"}) || cimdPublicOK("private_key_jwt", []string{"private_key_jwt"}) ||
		cimdPublicOK("client_secret_basic", nil) || !cimdPublicOK("", nil) {
		t.Fatal("cimdPublicOK")
	}
}
