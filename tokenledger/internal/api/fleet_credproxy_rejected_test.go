package api

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/credvault"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/credproxy"
)

func TestCredProxyExpiredAccessRefreshes(t *testing.T) {
	rig := newCPRig(t)
	pass, _ := rig.issue(t, fidA)
	old := rig.leased(t, store.PoolPrincipal, credvault.Codex, "poolcx")
	var calls atomic.Int64
	upstream := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		calls.Add(1)
		if request.Header.Get("Authorization") == old {
			writer.WriteHeader(http.StatusUnauthorized)
			_, _ = io.WriteString(writer, `{"error":{"code":"token_expired"}}`)
			return
		}
		_, _ = io.WriteString(writer, "OK")
	}))
	defer upstream.Close()
	proxy, err := credproxy.New(credproxy.Config{Resolver: &credproxy.HubResolver{URL: rig.h.http.URL, Token: cpToken}, Direct: true, CodexURL: upstream.URL, Audit: func(string) {}})
	if err != nil {
		t.Fatal(err)
	}
	request := httptest.NewRequest(http.MethodPost, "/v1/proxy/codex/responses", strings.NewReader("{}"))
	request.Header.Set("Authorization", "Bearer "+pass)
	response := httptest.NewRecorder()
	proxy.Handler().ServeHTTP(response, request)
	if response.Code != 200 || response.Body.String() != "OK" || calls.Load() != 2 {
		t.Fatalf("status=%d body=%q calls=%d", response.Code, response.Body.String(), calls.Load())
	}
	if rig.leased(t, store.PoolPrincipal, credvault.Codex, "poolcx") == old {
		t.Fatal("vault still issues the rejected token")
	}
	audit, err := rig.h.srv.Store.CredAuditLog(store.PoolPrincipal, 20)
	if err != nil {
		t.Fatal(err)
	}
	found := false
	for _, row := range audit {
		if row.Action == store.CredUpstreamRejected && strings.Contains(row.Detail, "token_expired") {
			found = true
		}
	}
	if !found {
		t.Fatal("missing upstream rejection audit")
	}
}

func TestCredProxyRejectAccessBoundAccountOnly(t *testing.T) {
	rig := newCPRig(t)
	pass, _ := rig.issue(t, fidA)
	resolver := &credproxy.HubResolver{URL: rig.h.http.URL, Token: cpToken}
	initial, err := resolver.Resolve(context.Background(), pass, credvault.Codex)
	if err != nil || !initial.Valid {
		t.Fatalf("resolve: %v", err)
	}
	for _, test := range []struct{ name, owner, account, token string }{
		{"different owner", "another", initial.Account, initial.AccessToken},
		{"different account", initial.Owner, "another", initial.AccessToken},
		{"stale fingerprint", initial.Owner, initial.Account, "replaced-token"},
	} {
		t.Run(test.name, func(t *testing.T) {
			previous := initial
			previous.Owner, previous.Account, previous.AccessToken = test.owner, test.account, test.token
			result, err := resolver.RejectAccess(context.Background(), pass, credvault.Codex, previous, "token_expired")
			if err != nil || result.AccessToken != initial.AccessToken {
				t.Fatalf("unmatched report changed the vault: %v", err)
			}
		})
	}
	if _, err := resolver.RejectAccess(context.Background(), pass, credvault.Codex, initial, "arbitrary-error"); err == nil {
		t.Fatal("unrecognized rejection code accepted")
	}
	invalid, err := resolver.RejectAccess(context.Background(), "fcp-h1.forged", credvault.Codex, initial, "token_expired")
	if err != nil || invalid.Valid || rig.leased(t, store.PoolPrincipal, credvault.Codex, "poolcx") != "Bearer "+initial.AccessToken {
		t.Fatal("forged pass changed credential state")
	}
	resolver.Token = "wrong"
	if _, err := resolver.RejectAccess(context.Background(), pass, credvault.Codex, initial, "token_expired"); err == nil {
		t.Fatal("unauthenticated rejection accepted")
	}
}

func TestCredProxyRejectedRefreshNeedsReauth(t *testing.T) {
	rig := newCPRig(t)
	pass, _ := rig.issue(t, fidA)
	resolver := &credproxy.HubResolver{URL: rig.h.http.URL, Token: cpToken}
	initial, err := resolver.Resolve(context.Background(), pass, credvault.Codex)
	if err != nil || !initial.Valid {
		t.Fatalf("resolve: %v", err)
	}
	rig.h.srv.Vault.Refresher.(*stubRefresher).refuse.Store(true)
	result, err := resolver.RejectAccess(context.Background(), pass, credvault.Codex, initial, "token_expired")
	if err != nil || result.Valid || result.AccessToken != "" || result.Error != "no_credential" {
		t.Fatalf("dead refresh grant must not issue another token: %v", err)
	}
	credential, err := rig.h.srv.Store.Credential(store.PoolPrincipal, credvault.Codex, "poolcx")
	if err != nil || !credential.ReauthRequired || len(credential.AccessSealed) != 0 {
		t.Fatalf("dead grant must be marked for owner reauthentication: %v", err)
	}
}
