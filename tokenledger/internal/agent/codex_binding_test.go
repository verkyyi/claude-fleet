package agent

import (
	"encoding/base64"
	"encoding/json"
	"github.com/verkyyi/ccquota/internal/codex"
	"github.com/verkyyi/ccquota/internal/scan"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestCodexBindingDoesNotClaimOldOrThirdPartySessions(t *testing.T) {
	now := time.Now().UTC()
	p := &codexCollector{statePath: filepath.Join(t.TempDir(), "binding.json")}
	if err := p.bind("account-a", now); err != nil {
		t.Fatal(err)
	}
	old := scan.CodexTelemetry{Provider: "openai", StartedAt: now.Add(-time.Hour)}
	if p.owns(old, now.Add(time.Second)) {
		t.Fatal("historical session claimed")
	}
	new := old
	new.StartedAt = now.Add(time.Second)
	if !p.owns(new, now.Add(time.Minute)) {
		t.Fatal("new session not associated")
	}
	new.Provider = "bedrock"
	if p.owns(new, now.Add(time.Minute)) {
		t.Fatal("third party drew down OpenAI account")
	}
	if err := p.bind("account-a", now.Add(time.Hour)); err != nil {
		t.Fatal(err)
	}
	if p.binding.Since != now {
		t.Fatal("heartbeat changed binding boundary")
	}
	if err := p.bind("account-b", now.Add(time.Hour)); err != nil {
		t.Fatal(err)
	}
	new.Provider = "openai"
	if p.owns(new, now.Add(2*time.Hour)) {
		t.Fatal("old running session moved to new account")
	}
}

func TestFirstSessionAfterManagedLoginPrecedesNextScan(t *testing.T) {
	home := t.TempDir()
	claims, _ := json.Marshal(map[string]any{"exp": time.Now().Add(time.Hour).Unix(), "https://api.openai.com/auth": map[string]string{"chatgpt_account_id": "account", "chatgpt_user_id": "member"}})
	b, _ := json.Marshal(map[string]any{"auth_mode": "chatgpt", "tokens": map[string]string{"access_token": "e30." + base64.RawURLEncoding.EncodeToString(claims) + ".signature", "account_id": "account"}})
	if err := os.WriteFile(filepath.Join(home, "auth.json"), b, 0600); err != nil {
		t.Fatal(err)
	}
	if err := codex.RecordLogin(home); err != nil {
		t.Fatal(err)
	}
	a, err := codex.ReadAuth(home)
	if err != nil {
		t.Fatal(err)
	}
	loginAt := codex.LoginObservedAt(home, a)
	p := &codexCollector{home: home, statePath: filepath.Join(t.TempDir(), "binding.json")}
	if err := p.bindObserved(a.Identity.AccountUUID, a, loginAt.Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
	fresh := scan.CodexTelemetry{Provider: "openai", StartedAt: loginAt.Add(time.Second)}
	if !p.owns(fresh, loginAt.Add(30*time.Second)) {
		t.Fatal("first managed session lost account attribution")
	}
	fresh.StartedAt = loginAt.Add(-time.Hour)
	if p.owns(fresh, loginAt.Add(30*time.Second)) {
		t.Fatal("managed login claimed existing history")
	}
}
