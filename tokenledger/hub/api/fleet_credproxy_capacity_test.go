package api

import (
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/credvault"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/credproxy"
)

// Exercise the real hub resolver and proxy: missing inventory is distinct
// from authentication and policy, and Codex can still serve the SAME pass.
func TestCredProxyClaudeCapacityContinuation(t *testing.T) {
	r := newCPRig(t)
	pass, _ := r.issue(t, fidA)
	for _, account := range []string{"acct1", "acct2"} {
		if err := r.h.srv.Store.DeleteCredential("gh:1005", credvault.Claude, account); err != nil {
			t.Fatal(err)
		}
	}
	st, body := r.call(t, credvault.Claude, pass)
	if st != 429 || !strings.Contains(body, credproxy.ClaudePoolUnavailable) {
		t.Fatalf("empty Claude inventory = %d %s", st, body)
	}
	if r.upCount() != 0 {
		t.Fatal("empty Claude inventory reached upstream")
	}
	if st, body = r.call(t, credvault.Codex, pass); st != 200 {
		t.Fatalf("same person's Codex pass = %d %s", st, body)
	}
	if st, body = r.call(t, credvault.Claude, "forged"); st != 403 || strings.Contains(body, credproxy.ClaudePoolUnavailable) {
		t.Fatalf("auth mislabeled capacity = %d %s", st, body)
	}
	// A real credential denied by policy is NOT absence or quota exhaustion.
	if err := r.h.srv.Vault.Put("gh:1005", credvault.Claude, "denied", credvault.Secret{RefreshToken: "test-only"}); err != nil {
		t.Fatal(err)
	}
	setHubSetting(t, r.h.srv, credUserKey("gh:1005"), "[]")
	r.pastCache()
	if st, body = r.call(t, credvault.Claude, pass); st != 403 || strings.Contains(body, credproxy.ClaudePoolUnavailable) {
		t.Fatalf("policy mislabeled capacity = %d %s", st, body)
	}
	setHubSetting(t, r.h.srv, credUserKey("gh:1005"), `"*"`)
	if err := r.h.srv.Store.MarkReauthRequired("gh:1005", credvault.Claude, "denied", "test reauth", true, time.Now()); err != nil {
		t.Fatal(err)
	}
	r.pastCache()
	if st, body = r.call(t, credvault.Claude, pass); st != 403 || strings.Contains(body, credproxy.ClaudePoolUnavailable) {
		t.Fatalf("reauth mislabeled capacity = %d %s", st, body)
	}
}
