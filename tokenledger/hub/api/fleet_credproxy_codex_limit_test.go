package api

import (
	"net/http"
	"testing"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/credvault"
	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

// A Codex subscription whose usage limit is spent is skipped on the central
// road too (claude-fleet#4606, the cluster half of BREAK-IT cred-sep-codex-full):
// the session bound to it is moved by its usage-limit 429 and the same request
// runs on the pool account with room; a new session never opens on the spent
// one; every one spent ⇒ the 429 reaches the session after one resend.

const codexLimit429 = `{"error":{"type":"usage_limit_reached","message":"You've hit your usage limit.","resets_at":4102444800}}`

func codexBound(t *testing.T, r *cpRig, wid string) string {
	t.Helper()
	b, err := r.h.srv.Store.SessionBindFor(wid, credvault.Codex)
	if err != nil {
		t.Fatal(err)
	}
	return b.Account
}

func TestSessionPickSkipsCodexAtLimit(t *testing.T) {
	r := newCPRig(t)
	if err := r.h.srv.Vault.Put(store.PoolPrincipal, credvault.Codex, "poolcx2",
		credvault.Secret{RefreshToken: "rt-cx2", AccountID: "aid-pool2"}); err != nil {
		t.Fatal(err)
	}
	x1 := r.leased(t, store.PoolPrincipal, credvault.Codex, "poolcx")
	x2 := r.leased(t, store.PoolPrincipal, credvault.Codex, "poolcx2")
	r.mu.Lock()
	r.full = map[string]string{x1: codexLimit429}
	r.mu.Unlock()

	credA, widA := r.issue(t, fidA)
	if st, body := r.call(t, credvault.Codex, credA); st != 200 {
		t.Fatalf("poolcx spent → %d %s; want the resend on poolcx2", st, body)
	}
	if acct := codexBound(t, r, widA); acct != "poolcx2" {
		t.Fatalf("A bound to %s after poolcx's usage limit; want poolcx2", acct)
	}

	credB, widB := r.issue(t, fidB)
	n := r.upCount()
	if st, body := r.call(t, credvault.Codex, credB); st != 200 || r.upCount() != n+1 || r.lastAuth() != x2 {
		t.Fatalf("B: %d %s, %d upstream asks, last %q; want ONE ask, on poolcx2", st, body, r.upCount()-n, r.lastAuth())
	}
	if acct := codexBound(t, r, widB); acct != "poolcx2" {
		t.Fatalf("B bound to %s; want poolcx2 (poolcx is spent)", acct)
	}

	r.mu.Lock()
	r.full[x2] = codexLimit429
	r.mu.Unlock()
	n = r.upCount()
	if st, _ := r.call(t, credvault.Codex, credB); st != http.StatusTooManyRequests || r.upCount()-n > 2 {
		t.Fatalf("all spent → %d after %d asks; want the 429, at most one resend", st, r.upCount()-n)
	}
}
