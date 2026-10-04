package credvault

// Envelope encryption under Aliyun KMS (claude-fleet#1417).
//
// Under #1415 the vault key sat in its own k8s Secret: a thief who took the
// database AND that Secret opened every credential. Here the vault key — the
// data key — is stored in the database, but only wrapped by a KMS master key
// that never leaves KMS. Unwrapping it is a KMS Decrypt call made with the
// hub's cloud identity (RRSA / instance role), so database + Secrets together
// open nothing, and every unwrap is a line in KMS's own log (ActionTrail).
//
// Rotating the master key needs nothing from the data: KMS's own rotation
// keeps old versions able to decrypt, and a wrapped blob names its version;
// pointing the hub at a different master key re-wraps the one data key on the
// next start, leaving every sealed row as it is.
//
// No fallback, ever: while KMS cannot be reached the vault stays LOCKED — it
// leases nothing and stores nothing — and the hub raises a critical finding.
// A plain key configured beside KMS is used exactly once, to re-seal the rows
// it sealed under the new data key, and is ignored from then on.

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// envelopeContext is the KMS EncryptionContext every wrap and unwrap carries:
// a blob lifted out of this table cannot be decrypted for any other purpose.
var envelopeContext = map[string]string{"purpose": "ccquota-fleet-credential-vault"}

// Envelope opens the vault's data key from KMS.
type Envelope struct {
	KMS   KMS
	KeyID string // the master key to wrap under (an id, or alias/<name>)
	Store *store.Store
	// Legacy is the pre-KMS key (CCQUOTA_FLEET_CRED_KEY), if still set. It
	// is read only by the first KMS start, to re-seal what it sealed.
	Legacy []byte
	Now    func() time.Time
}

func (e *Envelope) now() time.Time {
	if e.Now != nil {
		return e.Now()
	}
	return time.Now()
}

// Open returns a Sealer over the data key, unwrapping it from KMS — or, on
// the first KMS start, generating and installing one. detail says what
// happened, with the KMS request id, for the log and the audit.
func (e *Envelope) Open(ctx context.Context) (*Sealer, string, error) {
	k, err := e.Store.VaultKey()
	if errors.Is(err, store.ErrNoVaultKey) {
		return e.install(ctx)
	}
	if err != nil {
		return nil, "", err
	}
	res, err := e.KMS.Decrypt(ctx, k.Wrapped, envelopeContext)
	if err != nil {
		return nil, "", fmt.Errorf("kms Decrypt: %w", err)
	}
	s, err := sealerFromB64(res.Plaintext)
	if err != nil {
		return nil, "", err
	}
	if err := e.check(s); err != nil {
		return nil, "", err
	}
	detail := fmt.Sprintf("kms Decrypt ok · key %s version %s · request %s", res.KeyID, res.KeyVersionID, res.RequestID)
	if e.KeyID != "" && e.KeyID != k.KMSKeyID {
		// A different master key is configured: re-wrap the same data key
		// under it. A failure here costs nothing — the old wrapping still
		// opens — so it is logged and retried next start, not fatal.
		w, err := e.KMS.Encrypt(ctx, e.KeyID, res.Plaintext, envelopeContext)
		if err == nil {
			err = e.Store.RewrapVaultKey(e.KeyID, w.CiphertextBlob, e.now())
		}
		if err != nil {
			log.Printf("credvault: re-wrap under %s failed, still wrapped under %s: %v", e.KeyID, k.KMSKeyID, err)
		} else {
			detail += fmt.Sprintf(" · re-wrapped %s → %s (request %s)", k.KMSKeyID, e.KeyID, w.RequestID)
		}
	}
	if e.Legacy != nil {
		log.Printf("credvault: WARNING CCQUOTA_FLEET_CRED_KEY(_FILE) is still set and is IGNORED under KMS — " +
			"delete that Secret: the credentials were re-sealed and it opens nothing any more")
	}
	return s, detail, nil
}

// install generates the data key and stores it wrapped, re-sealing whatever
// the legacy key sealed in the same transaction.
func (e *Envelope) install(ctx context.Context) (*Sealer, string, error) {
	if e.KeyID == "" {
		return nil, "", errors.New("no wrapped vault key yet and no master key id to make one under")
	}
	var legacy *Sealer
	if e.Legacy != nil {
		var err error
		if legacy, err = NewSealer(e.Legacy); err != nil {
			return nil, "", err
		}
	}
	res, err := e.KMS.GenerateDataKey(ctx, e.KeyID, envelopeContext)
	if err != nil {
		return nil, "", fmt.Errorf("kms GenerateDataKey: %w", err)
	}
	s, err := sealerFromB64(res.Plaintext)
	if err != nil {
		return nil, "", err
	}
	var reseal func(store.Credential) ([]byte, []byte, error)
	if legacy != nil {
		reseal = func(c store.Credential) ([]byte, []byte, error) {
			return resealRow(legacy, s, c)
		}
	}
	n, err := e.Store.InstallVaultKey(store.VaultKey{KMSKeyID: e.KeyID, Wrapped: res.CiphertextBlob, CreatedAt: e.now()}, reseal)
	if err != nil {
		return nil, "", fmt.Errorf("install vault key: %w", err)
	}
	detail := fmt.Sprintf("kms GenerateDataKey ok · key %s version %s · request %s · new data key", res.KeyID, res.KeyVersionID, res.RequestID)
	if n > 0 {
		detail += fmt.Sprintf(" · re-sealed %d credential(s) from CCQUOTA_FLEET_CRED_KEY", n)
		log.Printf("credvault: re-sealed %d credential(s) under the KMS data key — now DELETE the CCQUOTA_FLEET_CRED_KEY Secret", n)
	}
	return s, detail, nil
}

// check opens one stored secret, so a data key that does not match the rows
// (a database restored beside another hub's key row) locks the vault loudly
// instead of failing every lease one by one.
func (e *Envelope) check(s *Sealer) error {
	creds, err := e.Store.Credentials("")
	if err != nil || len(creds) == 0 {
		return err
	}
	c := creds[0]
	var raw json.RawMessage
	if err := s.Open(c.SecretSealed, &raw, c.PrincipalID, c.Provider, c.Account, "secret"); err != nil {
		return errors.New("the KMS data key does not open the stored credentials")
	}
	return nil
}

func resealRow(from, to *Sealer, c store.Credential) (secret, access []byte, err error) {
	var raw json.RawMessage
	if err := from.Open(c.SecretSealed, &raw, c.PrincipalID, c.Provider, c.Account, "secret"); err != nil {
		return nil, nil, err
	}
	if secret, err = to.Seal(raw, c.PrincipalID, c.Provider, c.Account, "secret"); err != nil {
		return nil, nil, err
	}
	if len(c.AccessSealed) == 0 {
		return secret, nil, nil
	}
	// A cached access half that no longer opens is dropped, not fatal: the
	// next lease refreshes it.
	if from.Open(c.AccessSealed, &raw, c.PrincipalID, c.Provider, c.Account, "access") != nil {
		return secret, nil, nil
	}
	access, err = to.Seal(raw, c.PrincipalID, c.Provider, c.Account, "access")
	return secret, access, err
}

func sealerFromB64(plain string) (*Sealer, error) {
	key, err := base64.StdEncoding.DecodeString(plain)
	if err != nil || len(key) != 32 {
		return nil, errors.New("kms returned a data key that is not 32 bytes of base64")
	}
	return NewSealer(key)
}

// KeepUnlocked runs the vault's unlock until it succeeds: one attempt now,
// then retries backing off from first to max. Until then the vault is locked
// and alert is told — once when it locks, and once more when it opens — so the
// hub's log and audit record transitions, not every retry. It returns when the
// vault opens or ctx ends.
func KeepUnlocked(ctx context.Context, v *Vault, e *Envelope, first, max time.Duration, alert func(locked bool, detail string)) {
	wait := first
	wasLocked := false
	for {
		attempt, cancel := context.WithTimeout(ctx, 30*time.Second)
		s, detail, err := e.Open(attempt)
		cancel()
		if err == nil {
			v.Unlock(s)
			alert(false, detail)
			return
		}
		v.SetLocked(err.Error(), e.now())
		if !wasLocked {
			alert(true, err.Error())
			wasLocked = true
		} else {
			log.Printf("credvault: ALERT vault still locked, retrying in %s: %v", wait, err)
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(wait):
		}
		if wait *= 2; wait > max {
			wait = max
		}
	}
}
