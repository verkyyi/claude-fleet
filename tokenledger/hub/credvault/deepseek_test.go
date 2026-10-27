package credvault

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"
)

// A DeepSeek API key (task J7BN) is stored like a setup token: the key IS the
// lease, never refreshed, nothing written on lease.
func TestDeepSeekAPIKeyIssuedAsIsAndNeverRefreshed(t *testing.T) {
	ref := &countingRefresher{ttl: 8 * time.Hour}
	v := newVault(t, ref)
	key := "fake-ds-key"
	if !ValidProvider(DeepSeek) {
		t.Fatal("deepseek is not a provider")
	}
	if err := v.Put("pool", DeepSeek, "ds1", Secret{APIKey: key}); err != nil {
		t.Fatal(err)
	}
	row, err := v.Store.Credential("pool", DeepSeek, "ds1")
	if err != nil || row.Kind != KindAPIKey || row.SecretExpiresAt != nil {
		t.Fatalf("row = %+v, %v", row, err)
	}
	for i := 0; i < 3; i++ {
		acc, err := v.Lease(context.Background(), "pool", DeepSeek, "ds1")
		if err != nil {
			t.Fatal(err)
		}
		if acc.AccessToken != key || acc.ExpiresAt != nil || acc.Token != "" || len(acc.Scopes) != 0 {
			t.Fatalf("lease %d = %+v", i, acc)
		}
	}
	if acc, err := v.LeaseProbe(context.Background(), "pool", DeepSeek, "ds1"); err != nil || acc.AccessToken != key {
		t.Fatalf("probe = %+v, %v", acc, err)
	}
	if n := ref.n.Load(); n != 0 {
		t.Fatalf("an api key was refreshed %d time(s)", n)
	}
	row, _ = v.Store.Credential("pool", DeepSeek, "ds1")
	if len(row.AccessSealed) != 0 || row.Version != 1 {
		t.Fatalf("an api key lease wrote the row: %+v", row)
	}
	// A stable identity, scoped to the owner; never the key itself.
	id := v.CredentialID(*row)
	if !strings.HasPrefix(id, "cred:") || strings.Contains(id, key) {
		t.Fatalf("identity = %q", id)
	}
	if err := v.Put("p1", DeepSeek, "mine", Secret{APIKey: key}); err != nil {
		t.Fatal(err)
	}
	mine, _ := v.Store.Credential("p1", DeepSeek, "mine")
	if v.CredentialID(*mine) == id || v.CredentialID(*mine) == "" {
		t.Fatalf("a person's own key shares the pool's identity: %q", v.CredentialID(*mine))
	}
	if err := v.Put("pool", DeepSeek, "ds1-alias", Secret{APIKey: key}); err != nil {
		t.Fatal(err)
	}
	alias, _ := v.Store.Credential("pool", DeepSeek, "ds1-alias")
	if v.CredentialID(*alias) != id {
		t.Fatal("the same key under another label is another identity")
	}
	// The vault itself refuses to refresh one.
	if _, _, _, err := v.refresh(context.Background(), DeepSeek, Secret{APIKey: key}); !errors.Is(err, ErrRefreshFailed) {
		t.Fatalf("refresh of an api key: %v", err)
	}
	if n := ref.n.Load(); n != 0 {
		t.Fatalf("the refresher ran %d time(s)", n)
	}

	// Refused upstream: marked reauth_required, then leased no more (a probe still may).
	if dropped, err := v.RejectUpstream("pool", DeepSeek, "ds1", AccessFingerprint(key), "invalid_api_key", "test"); err != nil || !dropped {
		t.Fatalf("reject = %v, %v", dropped, err)
	}
	if _, err := v.Lease(context.Background(), "pool", DeepSeek, "ds1"); !errors.Is(err, ErrReauthRequired) {
		t.Fatalf("lease after rejection: %v", err)
	}
	if _, err := v.LeaseProbe(context.Background(), "pool", DeepSeek, "ds1"); err != nil {
		t.Fatalf("probe after rejection: %v", err)
	}
}

func TestDeepSeekValidate(t *testing.T) {
	exp := time.Now().Add(time.Hour)
	if err := (Secret{APIKey: "sk-abc", AccountUUID: "ds-acct"}).Validate(DeepSeek); err != nil {
		t.Fatalf("a plain key refused: %v", err)
	}
	if (Secret{APIKey: "sk-abc"}).Kind(DeepSeek) != KindAPIKey {
		t.Fatal("kind")
	}
	for name, s := range map[string]Secret{
		"none":          {},
		"space":         {APIKey: "sk abc"},
		"newline":       {APIKey: "sk-abc\n"},
		"tab":           {APIKey: "\tsk-abc"},
		"non-ascii":     {APIKey: "sk-ä"},
		"too long":      {APIKey: strings.Repeat("k", 513)},
		"refresh_token": {APIKey: "sk-abc", RefreshToken: "rt"},
		"setup_token":   {APIKey: "sk-abc", SetupToken: "sk-ant-oat01-x"},
		"expires_at":    {APIKey: "sk-abc", ExpiresAt: &exp},
		"id_token":      {APIKey: "sk-abc", IDToken: "x"},
		"account_id":    {APIKey: "sk-abc", AccountID: "x"},
		"scopes":        {APIKey: "sk-abc", Scopes: []string{"user:inference"}},
		"token":         {APIKey: "sk-abc", Token: "ghp"},
		"user":          {APIKey: "sk-abc", User: "u"},
		"aws":           {APIKey: "sk-abc", AWSAccessKeyID: "AKIA", AWSSecretAccessKey: "s"},
	} {
		if err := s.Validate(DeepSeek); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
	if err := (Secret{APIKey: strings.Repeat("k", 512)}).Validate(DeepSeek); err != nil {
		t.Fatalf("512 chars refused: %v", err)
	}
	// api_key belongs to deepseek alone.
	for _, p := range []string{Claude, Codex, GitHub} {
		s := Secret{APIKey: "sk-abc", RefreshToken: "rt", AccountID: "a", Token: "t", SetupToken: "sk-ant-oat01-x"}
		if err := s.Validate(p); err == nil || !strings.Contains(err.Error(), "deepseek") {
			t.Errorf("%s with api_key: %v", p, err)
		}
	}
	v := newVault(t, nil)
	if err := v.Put("pool", DeepSeek, "bad", Secret{}); err == nil {
		t.Fatal("an empty deepseek put was stored")
	}
}
