package codex

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func fakeJWT(v any) string {
	b, _ := json.Marshal(v)
	return "e30." + base64.RawURLEncoding.EncodeToString(b) + ".signature"
}

func TestAuthSnapshotSeparatesMembersAndNeverCopiesRefreshToken(t *testing.T) {
	home := t.TempDir()
	makeAuth := func(member string) {
		tok := fakeJWT(map[string]any{"exp": time.Now().Add(time.Hour).Unix(), "https://api.openai.com/auth": map[string]any{"chatgpt_account_id": "workspace", "chatgpt_user_id": member, "chatgpt_plan_type": "prolite"}})
		b, _ := json.Marshal(map[string]any{"auth_mode": "chatgpt", "tokens": map[string]string{"access_token": tok, "id_token": fakeJWT(map[string]string{"email": "member@example.test"}), "refresh_token": "never-copy-this", "account_id": "workspace"}})
		if err := os.WriteFile(filepath.Join(home, "auth.json"), b, 0600); err != nil {
			t.Fatal(err)
		}
	}
	makeAuth("one")
	a, err := ReadAuth(home)
	if err != nil {
		t.Fatal(err)
	}
	if a.Identity.AccountUUID == "" || a.Mode != "subscription" || a.Identity.SubscriptionType != "prolite" {
		t.Fatal("identity not resolved")
	}
	if strings.Contains(string(a.snapshot), "never-copy-this") || !strings.Contains(string(a.snapshot), `"refresh_token":""`) {
		t.Fatal("unsafe refresh snapshot")
	}
	makeAuth("two")
	b, err := ReadAuth(home)
	if err != nil {
		t.Fatal(err)
	}
	if a.Identity.AccountUUID == b.Identity.AccountUUID {
		t.Fatal("workspace members merged")
	}
	makeAuth("one")
	again, _ := ReadAuth(home)
	if a.Identity.AccountUUID != again.Identity.AccountUUID {
		t.Fatal("unstable account key")
	}
}

func TestQuotaContracts(t *testing.T) {
	at := time.Now().UTC()
	for _, raw := range []string{
		`{"rateLimits":{"primary":{"usedPercent":99}},"rateLimitsByLimitId":{"codex_bengalfox":{"planType":"prolite","primary":{"usedPercent":24,"windowDurationMins":10080,"resetsAt":1900000000},"secondary":null,"credits":{"hasCredits":false,"unlimited":false,"balance":"0"}}}}`,
		`{"limit_id":"codex_bengalfox","plan_type":"prolite","primary":{"used_percent":24,"window_duration_mins":10080,"resets_at":1900000000},"secondary":null,"credits":{"has_credits":false,"unlimited":false,"balance":"0"}}`,
	} {
		q, err := ParseLimits([]byte(raw), at)
		if err != nil {
			t.Fatal(err)
		}
		if len(q.Windows) != 1 || q.Windows[0].LimitID != "codex_bengalfox" || q.Windows[0].Minutes != 10080 || q.Windows[0].UsedPercent != 24 || q.Plan != "prolite" || q.ObservedAt != at {
			t.Fatalf("bad quota normalization: %+v", q)
		}
	}
	for _, raw := range []string{`null`, `{}`, `{"primary":{"used_percent":null}}`, `{"primary":{"used_percent":101}}`} {
		if _, err := ParseLimits([]byte(raw), at); err == nil {
			t.Fatalf("unknown reading became available: %s", raw)
		}
	}
	q, err := ParseLimits([]byte(`{"spend_control_reached":true}`), at)
	if err != nil || !q.Blocked {
		t.Fatal("spend control lost")
	}
}

// Explicit opt-in integration probe. Logs contain only counts/version, never
// credential strings or identifying claims. It makes no model request.
func TestLiveAccountRead(t *testing.T) {
	home := os.Getenv("CCQUOTA_TEST_CODEX_HOME")
	if home == "" {
		t.Skip("set CCQUOTA_TEST_CODEX_HOME for read-only account integration")
	}
	path := filepath.Join(home, "auth.json")
	before, err := os.ReadFile(path)
	if err != nil {
		t.Fatal("file credentials unavailable")
	}
	a, err := ReadAuth(home)
	if err != nil {
		t.Fatal(err)
	}
	if a.Mode != "subscription" {
		t.Logf("billing=%s; no subscription API", a.Mode)
		return
	}
	r, err := Query(context.Background(), Binary(filepath.Dir(home), os.Getenv("CCQUOTA_TEST_CODEX_BINARY")), a)
	if err != nil {
		t.Fatal(err)
	}
	after, err := os.ReadFile(path)
	if err != nil || sha256.Sum256(before) != sha256.Sum256(after) {
		t.Fatal("original auth changed during account query")
	}
	if r.Quota == nil {
		t.Fatalf("quota unavailable: %s", r.LimitsError)
	}
	if r.Usage != nil {
		t.Logf("client=%s plan=%s windows=%d daily_buckets=%d auth_unchanged=true", r.Version, r.Quota.Plan, len(r.Quota.Windows), len(r.Usage.Daily))
	} else {
		t.Logf("client=%s windows=%d usage=%s auth_unchanged=true", r.Version, len(r.Quota.Windows), r.UsageError)
	}
}
