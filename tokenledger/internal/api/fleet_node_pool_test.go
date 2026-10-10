package api

import (
	"bytes"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/credvault"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

func getPool(t *testing.T, h *harness, tok string) (int, NodePoolResponse, string) {
	t.Helper()
	req, _ := http.NewRequest(http.MethodGet, h.http.URL+NodePoolPath, nil)
	if tok != "" {
		req.Header.Set("Authorization", "Bearer "+tok)
	}
	res, err := h.http.Client().Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	var body bytes.Buffer
	_, _ = body.ReadFrom(res.Body)
	var out NodePoolResponse
	_ = json.Unmarshal(body.Bytes(), &out)
	return res.StatusCode, out, body.String()
}

// The manifest follows the operator's put / delete, names the node's own pool
// key, and never carries the token (claude-fleet#2850).
func TestNodePoolManifest(t *testing.T) {
	h, tok, _ := newVaultHarness(t)
	if code, _, _ := getPool(t, h, ""); code != http.StatusUnauthorized {
		t.Fatalf("no token: %d", code)
	}
	// Any enrollment token, one with no person behind it too (as a machine's is).
	machine := enrollAs(t, h, "bob-m4", "m4", "bob") // no fleet account is bob
	if code, got, body := getPool(t, h, machine); code != http.StatusOK || len(got.Pool) != 0 {
		t.Fatalf("empty pool: %d %s", code, body)
	}

	exp := time.Now().Add(365 * 24 * time.Hour).UTC().Truncate(time.Second)
	put := func(account, secret string) {
		t.Helper()
		if code, out := h.post(t, "/v1/fleet/credentials", FleetCredentialRequest{Action: "put", PrincipalID: store.PoolPrincipal,
			Provider: credvault.Claude, Account: account, Secret: credvault.Secret{SetupToken: secret, ExpiresAt: &exp}}); code != http.StatusOK {
			t.Fatalf("put %s: %d %v", account, code, out)
		}
	}
	put("icloud", "sk-ant-oat01-POOLSECRET")
	put("gmail", "sk-ant-oat01-OTHER")
	putCred(t, h, credvault.Claude, "main", credvault.Secret{RefreshToken: "sk-ant-ort01-SECRET"})

	code, got, body := getPool(t, h, tok)
	if code != http.StatusOK || strings.Contains(body, "POOLSECRET") || strings.Contains(body, "OTHER") {
		t.Fatalf("manifest: %d %s", code, body)
	}
	if len(got.Pool) != 2 || got.Pool[0].Account != "gmail" || got.Pool[1].Account != "icloud" {
		t.Fatalf("pool rows (pool only, sorted): %+v", got.Pool)
	}
	ic := got.Pool[1]
	// The node's pool_key: sha256("claude\0" + token)[:32].
	if ic.Fingerprint != PoolFingerprint("claude", "sk-ant-oat01-POOLSECRET") ||
		len(ic.Fingerprint) != 32 || ic.ExpiresAt == nil || !ic.ExpiresAt.Equal(exp) {
		t.Fatalf("icloud = %+v", ic)
	}

	// Revoked at the hub: gone from the manifest.
	if code, out := h.post(t, "/v1/fleet/credentials", FleetCredentialRequest{Action: "delete", PrincipalID: store.PoolPrincipal,
		Provider: credvault.Claude, Account: "gmail"}); code != http.StatusOK {
		t.Fatalf("delete: %d %v", code, out)
	}
	if _, got, _ := getPool(t, h, machine); len(got.Pool) != 1 || got.Pool[0].Account != "icloud" {
		t.Fatalf("after delete: %+v", got.Pool)
	}

	// No vault: refused, never an empty list a node would converge on.
	h.srv.Vault = nil
	if code, _, _ := getPool(t, h, tok); code != http.StatusServiceUnavailable {
		t.Fatalf("vault off: %d", code)
	}
}
