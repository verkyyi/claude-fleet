package api

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/credvault"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// Exercise the handlers under the same admin gate as their route. The global
// role-route matrix also verifies all four real mounts refuse member cookies.
func adminSubsCall(t *testing.T, h *harness, actor, path string, body any) (int, map[string]any) {
	t.Helper()
	raw, _ := json.Marshal(body)
	req := httptest.NewRequest("POST", path, bytes.NewReader(raw))
	ctx := context.WithValue(req.Context(), principalKey{}, actor)
	ctx = context.WithValue(ctx, roleKey{}, roleAdmin)
	req = req.WithContext(ctx)
	rec := httptest.NewRecorder()
	var handler http.HandlerFunc
	switch path {
	case AdminSubsLoginPath:
		handler = h.srv.handleAdminSubsLogin
	case AdminSubsFinishPath:
		handler = h.srv.handleAdminSubsFinish
	case AdminSubsTokenPath:
		handler = h.srv.handleAdminSubsToken
	case AdminSubsRefreshPath:
		handler = h.srv.handleAdminSubsRefresh
	}
	h.srv.adminOnly(handler).ServeHTTP(rec, req)
	out := map[string]any{}
	_ = json.Unmarshal(rec.Body.Bytes(), &out)
	return rec.Code, out
}

func TestAdminSubsOAuthIsolationReplayAndExpiry(t *testing.T) {
	h, _, _ := newVaultHarness(t)
	ex := &fakeExchange{}
	h.srv.OAuthExchange = ex.fn
	start := func() map[string]any {
		code, out := adminSubsCall(t, h, "admin-a", AdminSubsLoginPath, map[string]any{"provider": "claude", "account": "web"})
		if code != 200 {
			t.Fatalf("start: %d %v", code, out)
		}
		return out
	}
	flow := start()
	au, _ := url.Parse(flow["authorize_url"].(string))
	if au.Host != "claude.ai" || au.Query().Get("code_challenge_method") != "S256" {
		t.Fatal("not provider PKCE")
	}
	finish := map[string]any{"flow": flow["flow"], "paste": "code#" + au.Query().Get("state")}
	if code, _ := adminSubsCall(t, h, "admin-b", AdminSubsFinishPath, finish); code != 410 {
		t.Fatalf("cross admin: %d", code)
	}
	if code, _ := adminSubsCall(t, h, "admin-a", AdminSubsFinishPath, map[string]any{"flow": flow["flow"], "paste": "code#wrong"}); code != 422 {
		t.Fatalf("wrong state: %d", code)
	}
	// The personal purpose cannot enter the shared pool even for the same actor.
	note := meSubLogin{Provider: "claude", Account: "own", Verifier: "v", State: "s", Expires: time.Now().Add(time.Minute)}
	blob, _ := h.srv.Vault.SealNote(note, "admin-a", meSubLoginNote)
	if code, _ := adminSubsCall(t, h, "admin-a", AdminSubsFinishPath, map[string]any{"flow": base64.RawURLEncoding.EncodeToString(blob), "paste": "c#s"}); code != 410 {
		t.Fatalf("personal purpose: %d", code)
	}
	note.Expires = time.Now().Add(-time.Second)
	blob, _ = h.srv.Vault.SealNote(note, "admin-a", adminSubPurpose)
	if code, _ := adminSubsCall(t, h, "admin-a", AdminSubsFinishPath, map[string]any{"flow": base64.RawURLEncoding.EncodeToString(blob), "paste": "c#s"}); code != 410 {
		t.Fatalf("expired: %d", code)
	}
	// A cancelled start never writes a credential.
	if rows, _ := h.srv.Store.Credentials("pool"); len(rows) != 0 {
		t.Fatal("start wrote credential")
	}
	code, out := adminSubsCall(t, h, "admin-a", AdminSubsFinishPath, finish)
	if code != 200 || out["owner"] != "pool" || out["quota"] != "pending" {
		t.Fatalf("finish: %d %v", code, out)
	}
	if rows, _ := h.srv.Store.Credentials("admin-a"); len(rows) != 0 {
		t.Fatal("admin flow wrote personal credential")
	}
	if code, _ := adminSubsCall(t, h, "admin-a", AdminSubsFinishPath, finish); code != 410 {
		t.Fatalf("replay: %d", code)
	}
	if len(ex.forms) != 1 {
		t.Fatalf("exchange calls: %d", len(ex.forms))
	}
}

func TestAdminSubsExchangeFailureConsumesFlow(t *testing.T) {
	for _, network := range []bool{false, true} {
		h, _, _ := newVaultHarness(t)
		ex := &fakeExchange{fail: true}
		h.srv.OAuthExchange = ex.fn
		if network {
			h.srv.OAuthExchange = func(context.Context, string, map[string]string, string) (int, []byte, error) {
				return 0, nil, errors.New("sensitive upstream error")
			}
		}
		_, flow := adminSubsCall(t, h, "admin", AdminSubsLoginPath, map[string]any{"provider": "claude", "account": "web"})
		args := map[string]any{"flow": flow["flow"], "paste": "bad-code"}
		code, out := adminSubsCall(t, h, "admin", AdminSubsFinishPath, args)
		want := 422
		if network {
			want = 502
		}
		if code != want {
			t.Fatalf("failure: %d %v", code, out)
		}
		if strings.Contains(out["error"].(string), "sensitive") {
			t.Fatal("upstream error exposed")
		}
		if code, _ := adminSubsCall(t, h, "admin", AdminSubsFinishPath, args); code != 410 {
			t.Fatal("failed exchange replayed")
		}
		if rows, _ := h.srv.Store.Credentials("pool"); len(rows) != 0 {
			t.Fatal("failed exchange stored")
		}
	}
}

func TestAdminSubsTokenValidationDuplicateUpdateAndRefresh(t *testing.T) {
	h, _, _ := newVaultHarness(t)
	h.srv.SessionCredKey = bytes.Repeat([]byte{8}, 32)
	var status atomic.Int32
	status.Store(200)
	relay := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.Contains(r.Header.Get("Authorization"), "invalid") {
			w.WriteHeader(401)
			return
		}
		if status.Load() == 200 {
			w.Header().Set("anthropic-ratelimit-unified-5h-utilization", "0.25")
			w.Header().Set("anthropic-ratelimit-unified-7d-utilization", "0.5")
		}
		w.WriteHeader(int(status.Load()))
	}))
	defer relay.Close()
	h.srv.HubQuota = &HubQuota{RelayURL: relay.URL}
	args := func(name, token string, again bool) map[string]any {
		return map[string]any{"provider": "claude", "account": name, "token": token, "again": again}
	}
	if code, _ := adminSubsCall(t, h, "admin", AdminSubsTokenPath, args("one", "sk-ant-oat01-invalid", false)); code != 422 {
		t.Fatalf("invalid: %d", code)
	}
	status.Store(503)
	if code, _ := adminSubsCall(t, h, "admin", AdminSubsTokenPath, args("one", "sk-ant-oat01-valid", false)); code != 502 {
		t.Fatalf("network: %d", code)
	}
	if rows, _ := h.srv.Store.Credentials("pool"); len(rows) != 0 {
		t.Fatal("unverified token stored")
	}
	status.Store(200)
	code, out := adminSubsCall(t, h, "admin", AdminSubsTokenPath, args("one", "sk-ant-oat01-valid", false))
	if code != 200 {
		t.Fatalf("valid: %d %v", code, out)
	}
	c, _ := h.srv.Store.Credential("pool", "claude", "one")
	if c.SecretExpiresAt != nil {
		t.Fatal("invented expiry")
	}
	for _, name := range []string{"one", "alias"} {
		code, out := adminSubsCall(t, h, "admin", AdminSubsTokenPath, args(name, "sk-ant-oat01-valid", false))
		if code != 200 || out["account"] != "one" || out["duplicate"] != true {
			t.Fatalf("duplicate: %d %v", code, out)
		}
	}
	if code, _ := adminSubsCall(t, h, "admin", AdminSubsTokenPath, args("one", "sk-ant-oat01-new", false)); code != 409 {
		t.Fatalf("implicit replacement: %d", code)
	}
	if code, _ := adminSubsCall(t, h, "admin", AdminSubsTokenPath, args("one", "sk-ant-oat01-new", true)); code != 200 {
		t.Fatalf("explicit replacement: %d", code)
	}
	acc, err := h.srv.Vault.Lease(context.Background(), "pool", "claude", "one")
	if err != nil || acc.AccessToken != "sk-ant-oat01-new" {
		t.Fatal("replacement not saved")
	}
	// UUID compatibility lets this assertion run both before and after #4205.
	if err := h.srv.Vault.BindAccountUUID("pool", "claude", "one", aliceSubUUID); err != nil {
		t.Fatal(err)
	}
	code, out = adminSubsCall(t, h, "admin", AdminSubsRefreshPath, map[string]any{"provider": "claude", "account": "one"})
	if code != 200 || out["quota"] != "ready" {
		t.Fatalf("refresh: %d %v", code, out)
	}
	status.Store(503)
	code, out = adminSubsCall(t, h, "admin", AdminSubsRefreshPath, map[string]any{"provider": "claude", "account": "one"})
	if code != 200 || out["quota"] != "pending" {
		t.Fatalf("pending: %d %v", code, out)
	}
	audit, _ := h.srv.Store.CredAuditLog("pool", 100)
	b, _ := json.Marshal(audit)
	if strings.Contains(string(b), "sk-ant-oat01") {
		t.Fatal("secret in audit")
	}
}

func TestAdminSubsConcurrentDuplicate(t *testing.T) {
	h, _, _ := newVaultHarness(t)
	var calls atomic.Int32
	validate := func() (credvault.Secret, credvault.Access, error) {
		calls.Add(1)
		return credvault.Secret{SetupToken: "sk-ant-oat01-race"}, credvault.Access{}, nil
	}
	var wg sync.WaitGroup
	for _, name := range []string{"a", "b", "c"} {
		wg.Add(1)
		go func(name string) {
			defer wg.Done()
			_, _, err := h.srv.Vault.ImportBrowser(context.Background(), store.PoolPrincipal, "claude", name, "sk-ant-oat01-race", false, validate)
			if err != nil {
				t.Error(err)
			}
		}(name)
	}
	wg.Wait()
	rows, _ := h.srv.Store.Credentials("pool")
	if len(rows) != 1 || calls.Load() != 1 {
		t.Fatalf("rows=%d validations=%d", len(rows), calls.Load())
	}
}

func TestAdminSubsMemberCannotWrite(t *testing.T) {
	h, _, member := rolesHarness(t)
	for _, path := range []string{AdminSubsLoginPath, AdminSubsFinishPath, AdminSubsTokenPath, AdminSubsRefreshPath} {
		code, _ := requestsDo(t, h, member, "POST", path, map[string]any{"provider": "claude", "account": "forbidden", "token": "test-only", "owner": "pool"})
		if code != http.StatusForbidden {
			t.Fatalf("member POST %s = %d", path, code)
		}
	}
}

type adminSubRefresher struct {
	calls   int
	idToken string
}

func (f *adminSubRefresher) Refresh(_ context.Context, _ string, sec credvault.Secret) (credvault.Access, credvault.Secret, error) {
	f.calls++
	exp := time.Now().Add(time.Hour)
	sec.RefreshToken, sec.IDToken = "rotated-test-refresh", f.idToken
	return credvault.Access{AccessToken: "test-access", ExpiresAt: &exp}, sec, nil
}

func TestAdminSubsCodexBrowserAndExistingToken(t *testing.T) {
	h, _, _ := newVaultHarness(t)
	ex := &fakeExchange{}
	h.srv.OAuthExchange = ex.fn
	code, start := adminSubsCall(t, h, "admin", AdminSubsLoginPath, map[string]any{"provider": "codex", "account": "browser"})
	if code != 200 || start["paste"] != "url" {
		t.Fatalf("codex start: %d %v", code, start)
	}
	auth, _ := url.Parse(start["authorize_url"].(string))
	if auth.Host != "auth.openai.com" {
		t.Fatal("not official Codex login")
	}
	paste := "http://localhost:1455/auth/callback?code=test&state=" + auth.Query().Get("state")
	code, out := adminSubsCall(t, h, "admin", AdminSubsFinishPath, map[string]any{"flow": start["flow"], "paste": paste})
	if code != 200 || out["owner"] != "pool" {
		t.Fatalf("codex finish: %d %v", code, out)
	}
	c, _ := h.srv.Store.Credential("pool", "codex", "browser")
	plan, source := h.srv.Vault.PlanMetadata(*c)
	if plan != "plus" || source != "provider" {
		t.Fatalf("plan provenance: %s %s", plan, source)
	}
	_, raw, _ := ex.fn(context.Background(), "codex", nil, "")
	var ans tokenAnswer
	_ = json.Unmarshal(raw, &ans)
	ref := &adminSubRefresher{idToken: ans.IDToken}
	h.srv.Vault.Refresher = ref
	for _, name := range []string{"existing", "alias"} {
		code, out := adminSubsCall(t, h, "admin", AdminSubsTokenPath, map[string]any{"provider": "codex", "account": name, "token": "original-test-refresh"})
		if code != 200 || out["account"] != "existing" {
			t.Fatalf("codex token: %d %v", code, out)
		}
		b, _ := json.Marshal(out)
		if strings.Contains(string(b), "test-refresh") || strings.Contains(string(b), "test-access") {
			t.Fatal("secret in answer")
		}
	}
	if ref.calls != 1 {
		t.Fatalf("rotated token submitted twice: %d refreshes", ref.calls)
	}
}
