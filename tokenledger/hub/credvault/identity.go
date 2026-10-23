package credvault

import (
	"crypto/sha256"
	"errors"
	"fmt"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

// credentialID hashes high-entropy OAuth material with a purpose and owner/provider
// scope. It is neither an upstream account UUID nor a usable bearer credential.
// Labels, expiry edits and vault encryption-key rotation do not change it.
func credentialID(owner, provider string, s Secret) string {
	token := s.RefreshToken
	if s.SetupToken != "" {
		token = s.SetupToken
	}
	if provider == GitHub || token == "" {
		return ""
	}
	sum := sha256.Sum256([]byte("fleet-credential-meter-v1\x00" + owner + "\x00" + provider + "\x00" + token))
	return fmt.Sprintf("cred:%x", sum)
}

// CredentialID is the stable metering subject. Older secrets are derived in
// place; their first refresh seals this identity before rotating the token.
func (v *Vault) CredentialID(c store.Credential) string {
	sl, err := v.sealer()
	if err != nil {
		return ""
	}
	var s Secret
	if sl.Open(c.SecretSealed, &s, c.PrincipalID, c.Provider, c.Account, "secret") != nil {
		return ""
	}
	if s.MeterID != "" {
		return s.MeterID
	}
	return credentialID(c.PrincipalID, c.Provider, s)
}

// saveAlias preserves optional account metadata while copying only the shared
// OAuth state. The version guard prevents a concurrent replacement inheriting it.
func (v *Vault) saveAlias(c store.Credential, next Secret, acc Access, at time.Time) error {
	sl, err := v.sealer()
	if err != nil {
		return err
	}
	var old Secret
	if err := sl.Open(c.SecretSealed, &old, c.PrincipalID, c.Provider, c.Account, "secret"); err != nil {
		return err
	}
	next.AccountUUID = old.AccountUUID
	secret, err := sl.Seal(next, c.PrincipalID, c.Provider, c.Account, "secret")
	if err != nil {
		return err
	}
	access, err := sl.Seal(acc, c.PrincipalID, c.Provider, c.Account, "access")
	if err != nil {
		return err
	}
	return v.Store.SaveRefresh(c.PrincipalID, c.Provider, c.Account, c.Version, secret, access, acc.ExpiresAt, at)
}

func (v *Vault) shareRefresh(source store.Credential, next Secret, acc Access, at time.Time) error {
	rows, err := v.Store.Credentials(source.PrincipalID)
	if err != nil {
		return err
	}
	for _, c := range rows {
		if c.Provider != source.Provider || c.Account == source.Account || v.CredentialID(c) != next.MeterID {
			continue
		}
		lock := v.lock(c.PrincipalID, c.Provider, c.Account)
		lock.Lock()
		fresh, err := v.Store.Credential(c.PrincipalID, c.Provider, c.Account)
		if err == nil && v.CredentialID(*fresh) == next.MeterID {
			err = v.saveAlias(*fresh, next, acc, at)
		}
		lock.Unlock()
		if err != nil && !errors.Is(err, store.ErrCredConflict) && !errors.Is(err, store.ErrNoCredential) {
			return err
		}
	}
	return nil
}

// An alias imported while another name was refreshing can have missed the
// copy. Converge it from the newest same-identity state before trying to refresh.
func (v *Vault) syncAlias(owner, provider, account, identity string) error {
	current, err := v.Store.Credential(owner, provider, account)
	if err != nil {
		return err
	}
	if v.CredentialID(*current) != identity {
		return store.ErrCredConflict
	}
	rows, err := v.Store.Credentials(owner)
	if err != nil {
		return err
	}
	best := *current
	for _, c := range rows {
		if c.Provider == provider && c.RefreshedAt != nil && v.CredentialID(c) == identity &&
			(best.RefreshedAt == nil || c.RefreshedAt.After(*best.RefreshedAt)) {
			best = c
		}
	}
	if best.Account == current.Account {
		return nil
	}
	sl, err := v.sealer()
	if err != nil {
		return err
	}
	var next Secret
	var acc Access
	if err := sl.Open(best.SecretSealed, &next, owner, provider, best.Account, "secret"); err != nil {
		return err
	}
	if err := sl.Open(best.AccessSealed, &acc, owner, provider, best.Account, "access"); err != nil {
		return err
	}
	return v.saveAlias(*current, next, acc, *best.RefreshedAt)
}

// ClaudeLeaseKey pairs metadata to an actually held access token without leasing
// or refreshing. Same digest as the node's existing pool key, never a bearer.
func (v *Vault) ClaudeLeaseKey(c store.Credential) string {
	if c.Provider != Claude {
		return ""
	}
	sl, err := v.sealer()
	if err != nil {
		return ""
	}
	var a Access
	if sl.Open(c.AccessSealed, &a, c.PrincipalID, c.Provider, c.Account, "access") != nil || a.AccessToken == "" {
		var secret Secret
		if sl.Open(c.SecretSealed, &secret, c.PrincipalID, c.Provider, c.Account, "secret") != nil {
			return ""
		}
		a.AccessToken = secret.SetupToken
	}
	if a.AccessToken == "" {
		return ""
	}
	sum := sha256.Sum256([]byte("claude\x00" + a.AccessToken))
	return fmt.Sprintf("%x", sum)[:32]
}
