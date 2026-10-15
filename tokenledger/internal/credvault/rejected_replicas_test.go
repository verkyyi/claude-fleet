package credvault

import (
	"context"
	"sync"
	"testing"
	"time"
)

func TestCodexRejectedAccessRecoversAcrossReplicasAndRestart(t *testing.T) {
	refresher := &countingRefresher{ttl: 8 * time.Hour, delay: 10 * time.Millisecond}
	first := newVault(t, refresher)
	second := &Vault{Store: first.Store, Sealer: first.Sealer, Refresher: refresher}
	var locks sync.Map
	crossLock := func(_ context.Context, name string) (func(), error) {
		value, _ := locks.LoadOrStore(name, &sync.Mutex{})
		lock := value.(*sync.Mutex)
		lock.Lock()
		return lock.Unlock, nil
	}
	first.CrossLock, second.CrossLock = crossLock, crossLock
	if err := first.Put("pool", Codex, "default", Secret{RefreshToken: "fixture-initial", AccountID: "fixture-account"}); err != nil {
		t.Fatal(err)
	}
	initial, err := first.Lease(context.Background(), "pool", Codex, "default")
	if err != nil {
		t.Fatal(err)
	}
	fingerprint := AccessFingerprint(initial.AccessToken)
	var workers sync.WaitGroup
	for index := 0; index < 8; index++ {
		for _, replica := range []*Vault{first, second} {
			workers.Add(1)
			go func(replica *Vault) {
				defer workers.Done()
				if _, err := replica.RejectUpstream("pool", Codex, "default", fingerprint, "token_expired", "fixture-proxy"); err != nil {
					t.Error(err)
					return
				}
				access, err := replica.Lease(context.Background(), "pool", Codex, "default")
				if err != nil {
					t.Error(err)
					return
				}
				if access.AccessToken == initial.AccessToken {
					t.Error("rejected access was reissued")
				}
			}(replica)
		}
	}
	workers.Wait()
	if refresher.n.Load() != 2 {
		t.Fatalf("refreshes = %d, want initial plus one recovery", refresher.n.Load())
	}
	restarted := &Vault{Store: first.Store, Sealer: first.Sealer, Refresher: refresher, CrossLock: crossLock}
	if dropped, err := restarted.RejectUpstream("pool", Codex, "default", fingerprint, "token_expired", "late-report"); err != nil || dropped {
		t.Fatalf("late rejection dropped replacement: %v, %v", dropped, err)
	}
	access, err := restarted.Lease(context.Background(), "pool", Codex, "default")
	if err != nil || access.AccessToken != "AT-2" || refresher.n.Load() != 2 {
		t.Fatalf("restart did not reuse persisted replacement: %v, refreshes=%d", err, refresher.n.Load())
	}
	row, err := restarted.Store.Credential("pool", Codex, "default")
	if err != nil {
		t.Fatal(err)
	}
	var secret Secret
	if err := restarted.Sealer.Open(row.SecretSealed, &secret, "pool", Codex, "default", "secret"); err != nil {
		t.Fatal(err)
	}
	if secret.RefreshToken != "RT-2" {
		t.Fatal("rotated refresh state was not persisted")
	}
}
