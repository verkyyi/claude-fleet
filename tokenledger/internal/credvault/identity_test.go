package credvault

import (
	"context"
	"testing"
	"time"
)

func TestCredentialIdentityScopesAndRefresh(t *testing.T) {
	v := newVault(t, &countingRefresher{ttl: time.Hour})
	put := func(owner, provider, label string) string {
		t.Helper()
		if err := v.Put(owner, provider, label, Secret{RefreshToken: "fixture-same-token", AccountID: "fixture-account", MeterID: "injected"}); err != nil {
			t.Fatal(err)
		}
		c, _ := v.Store.Credential(owner, provider, label)
		return v.CredentialID(*c)
	}
	a := put("pool", Claude, "first")
	alias := put("pool", Claude, "alias")
	owner := put("alice", Claude, "first")
	provider := put("pool", Codex, "first")
	if a == "" || a == "injected" || a != alias || a == owner || a == provider || owner == provider {
		t.Fatal("identity scope/alias contract broken")
	}
	if _, err := v.Lease(context.Background(), "pool", Claude, "first"); err != nil {
		t.Fatal(err)
	}
	c, _ := v.Store.Credential("pool", Claude, "first")
	if got := v.CredentialID(*c); got != a {
		t.Fatal("token refresh changed identity")
	}
	// Re-encryption never changes the identity, which is independent of the key.
	var secret Secret
	if err := v.Sealer.Open(c.SecretSealed, &secret, c.PrincipalID, c.Provider, c.Account, "secret"); err != nil {
		t.Fatal(err)
	}
	if err := v.Put("pool", Claude, "rotated-alias", secret); err != nil {
		t.Fatal(err)
	}
	aliasRow, _ := v.Store.Credential("pool", Claude, "rotated-alias")
	if v.CredentialID(*aliasRow) != a {
		t.Fatal("reimporting rotated token inflated capacity")
	}
	newer, _ := NewSealer(make([]byte, 32))
	blob, err := newer.Seal(secret, c.PrincipalID, c.Provider, c.Account, "secret")
	if err != nil {
		t.Fatal(err)
	}
	c.SecretSealed = blob
	v.Sealer = newer
	if got := v.CredentialID(*c); got != a {
		t.Fatal("vault key rotation changed identity")
	}
}
