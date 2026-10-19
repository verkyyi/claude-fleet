package credvault

import (
	"bytes"
	"context"
	"errors"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

func TestBrowserCacheRejectsReplacedSecret(t *testing.T) {
	for _, rotate := range []bool{false, true} {
		t.Run(map[bool]string{false: "replacement", true: "same_identity_refresh"}[rotate], func(t *testing.T) {
			v := newVault(t, nil)
			other := &Vault{Store: v.Store, Sealer: v.Sealer, Refresher: &countingRefresher{ttl: time.Hour}}
			validated := Secret{RefreshToken: "validated-refresh"}
			if err := v.Put("pool", Claude, "shared", validated); err != nil {
				t.Fatal(err)
			}
			original, _ := v.Store.Credential("pool", Claude, "shared")
			// Deterministic interleaving: a non-browser writer changes the row
			// between this import's Put and its subsequent cache write/read.
			if rotate {
				if _, err := other.Lease(context.Background(), "pool", Claude, "shared"); err != nil {
					t.Fatal(err)
				}
			} else if err := other.Put("pool", Claude, "shared", Secret{RefreshToken: "replacement-refresh"}); err != nil {
				t.Fatal(err)
			}
			before, _ := v.Store.Credential("pool", Claude, "shared")
			if rotate && v.CredentialID(*before) != v.CredentialID(*original) {
				t.Fatal("fixture changed the stable metering identity")
			}
			exp := time.Now().Add(8 * time.Hour)
			_, err := v.cacheBrowserAccess("pool", Claude, "shared", validated, Access{AccessToken: "validated-access", ExpiresAt: &exp})
			if !errors.Is(err, store.ErrCredConflict) {
				t.Fatalf("cache for superseded validation: %v; want conflict", err)
			}
			after, _ := v.Store.Credential("pool", Claude, "shared")
			if before.Version != after.Version || !bytes.Equal(before.SecretSealed, after.SecretSealed) || !bytes.Equal(before.AccessSealed, after.AccessSealed) {
				t.Fatal("superseded import changed the current credential or access")
			}
		})
	}
}

func TestBrowserCachePreservesSavedIdentity(t *testing.T) {
	v := newVault(t, nil)
	exp := time.Now().Add(8 * time.Hour)
	sec := Secret{RefreshToken: "validated-refresh", MeterID: "untrusted", Scopes: []string{}}
	row, duplicate, err := v.ImportBrowser(context.Background(), "pool", Claude, "shared", "original-input", false,
		func() (Secret, Access, error) {
			return sec, Access{AccessToken: "validated-access", ExpiresAt: &exp}, nil
		})
	if err != nil || duplicate {
		t.Fatalf("import: duplicate=%v err=%v", duplicate, err)
	}
	var saved Secret
	if err := v.Sealer.Open(row.SecretSealed, &saved, "pool", Claude, "shared", "secret"); err != nil {
		t.Fatal(err)
	}
	if saved.MeterID == "" || saved.MeterID == sec.MeterID || saved.RefreshToken != sec.RefreshToken || saved.BrowserImportFingerprint == "" {
		t.Fatal("saved secret lost its generated identity or import metadata")
	}
	access, err := v.Lease(context.Background(), "pool", Claude, "shared")
	if err != nil || access.AccessToken != "validated-access" {
		t.Fatalf("matching access was not cached: %v", err)
	}
}
