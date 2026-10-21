package credvault

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/codex"
)

var ErrImportExists = errors.New("subscription name exists; explicitly update its credential")
var ErrImportMissing = errors.New("subscription to update no longer exists")

// ImportBrowser serializes browser imports across replicas. Validation runs
// before a write, and a repeated token returns its existing row, even after its
// refresh token rotated. The fingerprint is sealed, never a public identifier.
func (v *Vault) ImportBrowser(ctx context.Context, owner, provider, account, token string, again bool,
	validate func() (Secret, Access, error)) (*store.Credential, bool, error) {
	sl, err := v.sealer()
	if err != nil {
		return nil, false, err
	}
	lock := v.lock(owner, provider, "@browser-import")
	lock.Lock()
	defer lock.Unlock()
	if v.CrossLock != nil {
		unlock, err := v.CrossLock(ctx, "browser-import/"+owner+"/"+provider)
		if err != nil {
			return nil, false, err
		}
		defer unlock()
	}
	sum := sha256.Sum256([]byte(token))
	fingerprint := hex.EncodeToString(sum[:])
	rows, err := v.Store.Credentials(owner)
	if err != nil {
		return nil, false, err
	}
	var target *store.Credential
	for _, c := range rows {
		if c.Provider != provider {
			continue
		}
		if c.Account == account {
			copy := c
			target = &copy
		}
		var sec Secret
		if err := sl.Open(c.SecretSealed, &sec, owner, provider, c.Account, "secret"); err != nil {
			return nil, false, err
		}
		// Compare the sealed original input as well as pre-browser credentials.
		if token != "" && (sec.BrowserImportFingerprint == fingerprint || sec.SetupToken == token || sec.RefreshToken == token) {
			if again && c.Account != account {
				return nil, false, ErrImportExists
			}
			return &c, true, nil
		}
	}
	if target != nil && !again {
		return nil, false, ErrImportExists
	}
	if target == nil && again {
		return nil, false, ErrImportMissing
	}
	sec, access, err := validate()
	if err != nil {
		return nil, false, err
	}
	if token != "" {
		sec.BrowserImportFingerprint = fingerprint
	}
	if err := v.Put(owner, provider, account, sec); err != nil {
		return nil, false, err
	}
	c, err := v.cacheBrowserAccess(owner, provider, account, sec, access)
	return c, false, err
}

// cacheBrowserAccess runs after Put, separately from the browser import lock:
// other credential writers do not take that lock.
func (v *Vault) cacheBrowserAccess(owner, provider, account string, expected Secret, access Access) (*store.Credential, error) {
	sl, err := v.sealer()
	if err != nil {
		return nil, err
	}
	c, err := v.Store.Credential(owner, provider, account)
	if err != nil {
		return nil, err
	}
	// This version may already belong to another writer. Match the actual
	// validated secret, not its label or stable metering ID (refresh preserves
	// that ID while changing the token). Put alone owns the generated MeterID.
	var saved Secret
	if err := sl.Open(c.SecretSealed, &saved, owner, provider, account, "secret"); err != nil {
		return nil, err
	}
	expected.MeterID = saved.MeterID
	want, err := json.Marshal(expected)
	if err != nil {
		return nil, err
	}
	got, err := json.Marshal(saved)
	if err != nil {
		return nil, err
	}
	if !bytes.Equal(want, got) {
		return nil, store.ErrCredConflict
	}
	// Keep the exchanged access token: do not immediately rotate a fresh refresh
	// token a second time just to perform the first quota read. The CAS below
	// refuses a replacement that lands after the comparison above.
	if access.AccessToken != "" && access.ExpiresAt != nil {
		accessBlob, err := sl.Seal(access, owner, provider, account, "access")
		if err != nil {
			return nil, err
		}
		if err := v.Store.SaveRefresh(owner, provider, account, c.Version, c.SecretSealed, accessBlob, access.ExpiresAt, v.now()); err != nil {
			return nil, err
		}
	}
	return c, nil
}

// PlanMetadata exposes only explicitly stored plan information. Legacy manual
// imports are labelled as such; labels and quota sizes are never plan evidence.
func (v *Vault) PlanMetadata(c store.Credential) (plan, source string) {
	sl, err := v.sealer()
	if err != nil {
		return "", ""
	}
	var sec Secret
	if sl.Open(c.SecretSealed, &sec, c.PrincipalID, c.Provider, c.Account, "secret") != nil {
		return "", ""
	}
	if c.Provider == Codex && sec.IDToken != "" {
		if p := codex.PlanFromIDToken(sec.IDToken); p != "" {
			return p, "provider"
		}
	}
	if sec.SubscriptionType != "" {
		return sec.SubscriptionType, "admin"
	}
	return "", ""
}

// PlanTier is the rate-limit tier an admin recorded beside the plan
// (claude-fleet EEJD: Max 5× or Max 20×), "" when none was. Only meaningful
// with an "admin" plan — a provider-read plan names no tier here.
func (v *Vault) PlanTier(c store.Credential) string {
	sl, err := v.sealer()
	if err != nil {
		return ""
	}
	var sec Secret
	if sl.Open(c.SecretSealed, &sec, c.PrincipalID, c.Provider, c.Account, "secret") != nil {
		return ""
	}
	return sec.RateLimitTier
}
