package credvault

import (
	"context"
	"sync"
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

func TestCredentialAliasRefreshShared(t *testing.T) {
	for _, replicas := range []bool{false, true} {
		t.Run(map[bool]string{false: "single", true: "replicas"}[replicas], func(t *testing.T) {
			ref := &countingRefresher{ttl: 8 * time.Hour, delay: 10 * time.Millisecond}
			v := newVault(t, ref)
			other := v
			if replicas {
				other = &Vault{Store: v.Store, Sealer: v.Sealer, Refresher: ref}
				var locks sync.Map
				cross := func(_ context.Context, name string) (func(), error) {
					value, _ := locks.LoadOrStore(name, &sync.Mutex{})
					lock := value.(*sync.Mutex)
					lock.Lock()
					return lock.Unlock, nil
				}
				v.CrossLock, other.CrossLock = cross, cross
			}
			for _, name := range []string{"first", "second"} {
				if err := v.Put("pool", Claude, name, Secret{RefreshToken: "fixture-shared-refresh"}); err != nil {
					t.Fatal(err)
				}
			}
			var wg sync.WaitGroup
			for name, vault := range map[string]*Vault{"first": v, "second": other} {
				wg.Add(1)
				go func(name string, vault *Vault) {
					defer wg.Done()
					if _, err := vault.Lease(context.Background(), "pool", Claude, name); err != nil {
						t.Error(err)
					}
				}(name, vault)
			}
			wg.Wait()
			if ref.n.Load() != 1 {
				t.Fatalf("one token refreshed %d times through aliases", ref.n.Load())
			}
			if err := v.Store.DeleteCredential("pool", Claude, "first"); err != nil {
				t.Fatal(err)
			}
			if _, err := other.Lease(context.Background(), "pool", Claude, "second"); err != nil {
				t.Fatal(err)
			}
			if ref.n.Load() != 1 {
				t.Fatal("deleting one alias lost the shared refresh state")
			}
		})
	}
}
