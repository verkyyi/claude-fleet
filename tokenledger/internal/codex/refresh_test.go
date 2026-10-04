package codex

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

func writeTestLogin(t *testing.T, home, member string, expires time.Time) {
	t.Helper()
	token := fakeJWT(map[string]any{"exp": expires.Unix(), "https://api.openai.com/auth": map[string]any{"chatgpt_account_id": "workspace", "chatgpt_user_id": member}})
	b, _ := json.Marshal(map[string]any{"auth_mode": "chatgpt", "tokens": map[string]string{"access_token": token, "id_token": fakeJWT(map[string]string{"email": member + "@example.test"}), "refresh_token": "fixture-refresh-secret", "account_id": "workspace"}})
	if err := os.WriteFile(filepath.Join(home, "auth.json"), b, 0600); err != nil {
		t.Fatal(err)
	}
}

// A real child process exercises the JSON-RPC transport, original-home
// persistence, locking and error redaction without contacting a service.
func TestCodexRPCFixture(t *testing.T) {
	if os.Getenv("CCQUOTA_RPC_FIXTURE") != "1" {
		return
	}
	home := os.Getenv("CODEX_HOME")
	dec, enc := json.NewDecoder(os.Stdin), json.NewEncoder(os.Stdout)
	for {
		var req struct {
			ID     int            `json:"id"`
			Method string         `json:"method"`
			Params map[string]any `json:"params"`
		}
		if dec.Decode(&req) != nil {
			os.Exit(0)
		}
		if req.ID == 0 {
			continue
		}
		var result any
		switch req.Method {
		case "initialize":
			result = map[string]string{"userAgent": "codex/fixture"}
		case "account/read":
			if req.Params["refreshToken"] == true {
				f, _ := os.OpenFile(filepath.Join(home, "fixture-calls"), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0600)
				f.WriteString("refresh\n")
				f.Close()
				time.Sleep(50 * time.Millisecond)
				mode, _ := os.ReadFile(filepath.Join(home, "fixture-mode"))
				if len(mode) > 0 {
					if string(mode) == "legacy-revoked" {
						os.Stderr.WriteString("refresh_token_reused fixture-refresh-secret\n")
						enc.Encode(map[string]any{"id": req.ID, "result": map[string]any{"account": nil, "requiresOpenaiAuth": true}})
						continue
					}
					message := "temporary connection failure fixture-refresh-secret"
					if string(mode) == "revoked" {
						message = "refresh_token_revoked fixture-refresh-secret"
					}
					enc.Encode(map[string]any{"id": req.ID, "error": map[string]any{"code": -32000, "message": message}})
					continue
				}
				b, _ := os.ReadFile(filepath.Join(home, "auth.json"))
				var doc map[string]any
				json.Unmarshal(b, &doc)
				tokens := doc["tokens"].(map[string]any)
				claims := decodeClaims(tokens["access_token"].(string))
				claims["exp"] = time.Now().Add(10 * 24 * time.Hour).Unix()
				tokens["access_token"] = fakeJWT(claims)
				tokens["refresh_token"] = "fixture-rotated-secret"
				doc["last_refresh"] = time.Now().UTC().Format(time.RFC3339Nano)
				b, _ = json.Marshal(doc)
				os.WriteFile(filepath.Join(home, "auth.json"), b, 0600)
			}
			result = map[string]any{"account": map[string]string{"type": "chatgpt"}}
		case "account/rateLimits/read":
			result = map[string]any{"rateLimits": map[string]any{"primary": map[string]any{"usedPercent": 10, "windowDurationMins": 300}}}
		case "account/usage/read":
			result = map[string]any{"summary": map[string]any{"lifetimeTokens": 123}, "dailyUsageBuckets": []any{}}
		default:
			os.Exit(20)
		}
		enc.Encode(map[string]any{"id": req.ID, "result": result})
	}
}

func useRPCFixture(t *testing.T) {
	t.Helper()
	t.Setenv("CCQUOTA_RPC_FIXTURE", "1")
	old := codexCommand
	codexCommand = func(ctx context.Context, _ string, _ ...string) *exec.Cmd {
		return exec.CommandContext(ctx, os.Args[0], "-test.run=^TestCodexRPCFixture$")
	}
	t.Cleanup(func() { codexCommand = old })
}

func TestRenewalIsSingleWriterAndDoesNotCopyOrMixAccounts(t *testing.T) {
	useRPCFixture(t)
	home, other := t.TempDir(), t.TempDir()
	writeTestLogin(t, home, "one", time.Now().Add(-time.Hour))
	writeTestLogin(t, other, "two", time.Now().Add(-time.Hour))
	beforeOther, _ := os.ReadFile(filepath.Join(other, "auth.json"))
	before, _ := ReadAuth(home)
	var wg sync.WaitGroup
	errs := make(chan error, 2)
	for range 2 {
		wg.Add(1)
		go func() { defer wg.Done(); _, err := Maintain(context.Background(), "fixture", home, false); errs <- err }()
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		if err != nil && !errors.Is(err, ErrProfileBusy) {
			t.Fatal(err)
		}
	}
	got, err := ReadAuth(home)
	if err != nil || !got.ExpiresAt.After(time.Now()) || got.LastRefresh == nil || got.Identity.AccountUUID != before.Identity.AccountUUID {
		t.Fatal("renewal lost identity or failed to persist access")
	}
	if _, err := Maintain(context.Background(), "fixture", home, false); err != nil {
		t.Fatal(err)
	}
	calls, _ := os.ReadFile(filepath.Join(home, "fixture-calls"))
	if string(calls) != "refresh\n" {
		t.Fatalf("expected one renewal, got %q", calls)
	}
	otherAfter, _ := os.ReadFile(filepath.Join(other, "auth.json"))
	if string(otherAfter) != string(beforeOther) {
		t.Fatal("another account was modified")
	}
	h := LoginHealth(home, got, true)
	if h.State != "valid" || h.RefreshAttemptAt == nil {
		t.Fatalf("bad health: %+v", h)
	}
	state, _ := os.ReadFile(filepath.Join(home, ".ccquota-auth-state.json"))
	if strings.Contains(string(state), "fixture-refresh-secret") || strings.Contains(string(state), "fixture-rotated-secret") {
		t.Fatal("credential copied to health state")
	}
	r, err := Query(context.Background(), "fixture", got)
	if err != nil || r.Quota == nil || r.Usage == nil {
		t.Fatal("refreshed access could not read quota/usage", err)
	}
}

func TestRenewalDistinguishesReauthenticationAndTransientFailure(t *testing.T) {
	useRPCFixture(t)
	for _, tc := range []struct{ mode, state string }{{"revoked", "reauth_required"}, {"legacy-revoked", "reauth_required"}, {"network", "retry_pending"}} {
		t.Run(tc.mode, func(t *testing.T) {
			home := t.TempDir()
			writeTestLogin(t, home, "one", time.Now().Add(-time.Hour))
			os.WriteFile(filepath.Join(home, "fixture-mode"), []byte(tc.mode), 0600)
			before, _ := os.ReadFile(filepath.Join(home, "auth.json"))
			a, err := Maintain(context.Background(), "fixture", home, false)
			if err == nil || strings.Contains(err.Error(), "fixture-refresh-secret") {
				t.Fatal("unredacted or absent error")
			}
			h := LoginHealth(home, a, true)
			if h.State != tc.state || (tc.mode == "network" && h.RetryAt == nil) {
				t.Fatalf("wrong failure classification: %+v", h)
			}
			Maintain(context.Background(), "fixture", home, false)
			calls, _ := os.ReadFile(filepath.Join(home, "fixture-calls"))
			if string(calls) != "refresh\n" {
				t.Fatal("backoff did not survive another call")
			}
			after, _ := os.ReadFile(filepath.Join(home, "auth.json"))
			if string(before) != string(after) {
				t.Fatal("failure changed credentials")
			}
			writeTestLogin(t, home, "one", time.Now().Add(10*24*time.Hour))
			a, _ = ReadAuth(home)
			if LoginHealth(home, a, true).State != "valid" {
				t.Fatal("fresh login retained obsolete error")
			}
		})
	}
}

func TestManagedSessionsShareProfileButExcludeMaintenance(t *testing.T) {
	home := t.TempDir()
	a, err := AcquireRunProfile(home)
	if err != nil {
		t.Fatal(err)
	}
	b, err := AcquireRunProfile(home)
	if err != nil {
		a()
		t.Fatal(err)
	}
	if release, err := AcquireProfile(home); err == nil {
		release()
		t.Fatal("maintenance raced active sessions")
	}
	a()
	b()
	release, err := AcquireProfile(home)
	if err != nil {
		t.Fatal(err)
	}
	release()
	d := &authDiagnostics{}
	d.Write([]byte("MCP OAuth error: invalid_grant\n"))
	if d.reauthenticationRequired() {
		t.Fatal("another service's OAuth failure invalidated Codex")
	}
	d.Write([]byte("refresh_token_"))
	d.Write([]byte("reused secret"))
	if !d.reauthenticationRequired() {
		t.Fatal("split diagnostic marker lost")
	}
}

func TestProfileEnvironmentCannotOverrideNamedAuthentication(t *testing.T) {
	for _, key := range []string{"CODEX_ACCESS_TOKEN", "CODEX_API_KEY", "OPENAI_API_KEY", "OPENAI_IDENTITY_TOKEN_FILE", "CODEX_INTERNAL_TEST"} {
		t.Setenv(key, "fixture-secret")
	}
	for _, e := range ProfileEnv("/profile") {
		if strings.Contains(e, "fixture-secret") {
			t.Fatal("ambient credentials inherited")
		}
	}
	if !classifyRPC(-32000, "Your refresh token has already been used. Sign in again.").reauth {
		t.Fatal("refresh rejection not recognized")
	}
	if classifyRPC(-32000, "refresh token request timed out").reauth {
		t.Fatal("network failure requires browser login")
	}
	if !NeedsRefresh(Result{}, classifyRPC(-32000, "rate limits failed: status code: 401")) {
		t.Fatal("authorization failure cannot trigger renewal")
	}
}
