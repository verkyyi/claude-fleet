package credvault

import (
	"crypto/sha256"
	"fmt"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
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
