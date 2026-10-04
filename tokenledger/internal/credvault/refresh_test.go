package credvault

import (
	"context"
	"errors"
	"testing"
	"time"
)

// ProxyRefresher reads a relayed answer exactly as HTTPRefresher reads a direct
// one, and turns "could not ask" into ErrRefreshUnavailable — never a
// provider's refusal.
func TestProxyRefresherParsesAndClassifies(t *testing.T) {
	now := time.Date(2026, 10, 4, 12, 0, 0, 0, time.UTC)
	s := Secret{RefreshToken: "rt-0", AccountID: "acct"}

	ok := &ProxyRefresher{Now: func() time.Time { return now }, Via: func(_ context.Context, provider string, form map[string]string) (ProxyAnswer, error) {
		if provider != Codex || form["refresh_token"] != "rt-0" || form["client_id"] != CodexClientID || form["grant_type"] != "refresh_token" {
			t.Fatalf("form = %v", form)
		}
		return ProxyAnswer{Status: 200, Via: "op@m5", Body: []byte(`{"access_token":"at-1","refresh_token":"rt-1","id_token":"id-1","expires_in":3600}`)}, nil
	}}
	acc, next, via, err := ok.RefreshVia(context.Background(), Codex, s)
	if err != nil || via != "op@m5" || acc.AccessToken != "at-1" || acc.IDToken != "id-1" || acc.AccountID != "acct" ||
		next.RefreshToken != "rt-1" || next.IDToken != "id-1" || acc.ExpiresAt == nil || !acc.ExpiresAt.Equal(now.Add(time.Hour)) {
		t.Fatalf("ok: %+v %+v %q %v", acc, next, via, err)
	}

	down := &ProxyRefresher{Via: func(context.Context, string, map[string]string) (ProxyAnswer, error) {
		return ProxyAnswer{}, errors.New("no admin node is online")
	}}
	if _, next, _, err := down.RefreshVia(context.Background(), Codex, s); !errors.Is(err, ErrRefreshUnavailable) || next.RefreshToken != "rt-0" {
		t.Fatalf("down: %v %+v", err, next)
	}

	refused := &ProxyRefresher{Via: func(context.Context, string, map[string]string) (ProxyAnswer, error) {
		return ProxyAnswer{Status: 403, Via: "op@m4", Body: []byte(`{"error":{"code":"unsupported_country_region_territory"}}`)}, nil
	}}
	_, next, via, err = refused.RefreshVia(context.Background(), Codex, s)
	if err == nil || errors.Is(err, ErrRefreshUnavailable) || via != "op@m4" || next.RefreshToken != "rt-0" {
		t.Fatalf("refused: %v %q %+v", err, via, next)
	}

	// Through the vault: the audit row names the node.
	v := newVault(t, ok)
	if err := v.Put("pool", Codex, "default", s); err != nil {
		t.Fatal(err)
	}
	v.Now = func() time.Time { return now }
	if _, err := v.Lease(context.Background(), "pool", Codex, "default"); err != nil {
		t.Fatal(err)
	}
	rows, _ := v.Store.CredAuditLog("pool", 10)
	found := false
	for _, r := range rows {
		if r.Action == "refresh" && r.Detail == "ok · refresh_via=op@m5" {
			found = true
		}
	}
	if !found {
		t.Fatalf("audit = %+v", rows)
	}
	if _, _, err := (&ProxyRefresher{}).Refresh(context.Background(), GitHub, Secret{Token: "x"}); err == nil {
		t.Fatal("github has no refresh")
	}
}
