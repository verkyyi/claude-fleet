// Package credvault is the hub's credential vault (claude-fleet#1415).
//
// Every person's long-lived Claude / Codex credentials — the refresh tokens —
// live in the hub's database, sealed with a key that is NOT in the database
// (a separate k8s Secret). The hub alone refreshes them, one writer per
// account, and hands a node only the short-lived half: an access token and its
// expiry. Why the hub and not each machine: a refresh token rotates on use, so
// two machines refreshing the same account log each other out — and a machine
// that holds one is a machine whose theft is a long-lived compromise.
//
// What a node can do with the short-lived half was measured before any of
// this was written (issue #1415, first comment): a running Claude Code session
// re-reads a credentials FILE (not the env var) on its next request, and a
// running Codex re-reads auth.json on its first 401 — neither needs a refresh
// token to pick up a replacement.
package credvault

import (
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// Providers.
const (
	Claude = "claude"
	Codex  = "codex"
	GitHub = "github"
)

// ValidProvider reports whether p is a provider the vault knows.
func ValidProvider(p string) bool { return p == Claude || p == Codex || p == GitHub }

// Secret is the long-lived half, as the operator stores it. Which fields
// matter depends on the provider:
//
//	claude: refresh_token (+ scopes, subscription_type, carried to the node)
//	codex:  refresh_token, account_id (+ id_token, kept current by refreshes)
//	github: token, user — phase one hands the person's existing token down as
//	        is (it has no refresh); R1 replaces it with a short-lived one.
type Secret struct {
	RefreshToken     string   `json:"refresh_token,omitempty"`
	IDToken          string   `json:"id_token,omitempty"`
	AccountID        string   `json:"account_id,omitempty"`
	Scopes           []string `json:"scopes,omitempty"`
	SubscriptionType string   `json:"subscription_type,omitempty"`
	Token            string   `json:"token,omitempty"`
	User             string   `json:"user,omitempty"`
}

// Validate checks that s carries what provider needs.
func (s Secret) Validate(provider string) error {
	switch provider {
	case Claude:
		if s.RefreshToken == "" {
			return errors.New("claude needs refresh_token")
		}
	case Codex:
		if s.RefreshToken == "" || s.AccountID == "" {
			return errors.New("codex needs refresh_token and account_id")
		}
	case GitHub:
		if s.Token == "" {
			return errors.New("github needs token")
		}
	default:
		return fmt.Errorf("unknown provider %q", provider)
	}
	return nil
}

// Access is the short-lived half: everything a node writes to disk, and
// nothing it could use to mint more. ExpiresAt nil means the credential has
// no expiry of its own (GitHub phase one).
type Access struct {
	AccessToken      string     `json:"access_token,omitempty"`
	IDToken          string     `json:"id_token,omitempty"`
	AccountID        string     `json:"account_id,omitempty"`
	Scopes           []string   `json:"scopes,omitempty"`
	SubscriptionType string     `json:"subscription_type,omitempty"`
	Token            string     `json:"token,omitempty"`
	User             string     `json:"user,omitempty"`
	ExpiresAt        *time.Time `json:"expires_at,omitempty"`
}

// --- sealing -----------------------------------------------------------------

// sealVersion is the first byte of every sealed blob, so a future key or
// cipher change can tell old blobs from new ones.
const sealVersion = 1

// Sealer encrypts the vault's blobs with AES-256-GCM. The additional data
// binds a blob to its row and half, so a blob copied onto another person's
// row — or the access half pasted over the secret half — fails to open.
type Sealer struct{ aead cipher.AEAD }

// NewSealer builds a Sealer from a 32-byte key.
func NewSealer(key []byte) (*Sealer, error) {
	if len(key) != 32 {
		return nil, fmt.Errorf("credential key must be 32 bytes, got %d", len(key))
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	aead, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}
	return &Sealer{aead: aead}, nil
}

// LoadKey reads the vault key: CCQUOTA_FLEET_CRED_KEY_FILE (a path — the k8s
// Secret mount) wins over CCQUOTA_FLEET_CRED_KEY (the value). Either holds 32
// bytes, base64 encoded. ok is false when neither is set: the vault is off,
// and the rest of the fleet module runs without it.
func LoadKey(getenv func(string) string) (key []byte, ok bool, err error) {
	raw := strings.TrimSpace(getenv("CCQUOTA_FLEET_CRED_KEY"))
	if path := getenv("CCQUOTA_FLEET_CRED_KEY_FILE"); path != "" {
		b, err := os.ReadFile(path)
		if err != nil {
			return nil, true, fmt.Errorf("read credential key: %w", err)
		}
		raw = strings.TrimSpace(string(b))
	}
	if raw == "" {
		return nil, false, nil
	}
	for _, enc := range []*base64.Encoding{base64.StdEncoding, base64.RawStdEncoding, base64.URLEncoding, base64.RawURLEncoding} {
		if k, err := enc.DecodeString(raw); err == nil && len(k) == 32 {
			return k, true, nil
		}
	}
	return nil, true, errors.New("credential key must be 32 bytes, base64 encoded (openssl rand -base64 32)")
}

func aad(principal, provider, account, half string) []byte {
	return []byte(principal + "\x00" + provider + "\x00" + account + "\x00" + half)
}

// Seal encrypts v (JSON) for one row's half.
func (s *Sealer) Seal(v any, principal, provider, account, half string) ([]byte, error) {
	plain, err := json.Marshal(v)
	if err != nil {
		return nil, err
	}
	nonce := make([]byte, s.aead.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		return nil, err
	}
	out := append([]byte{sealVersion}, nonce...)
	return s.aead.Seal(out, nonce, plain, aad(principal, provider, account, half)), nil
}

// Open decrypts a blob sealed for one row's half into v.
func (s *Sealer) Open(blob []byte, v any, principal, provider, account, half string) error {
	ns := s.aead.NonceSize()
	if len(blob) < 1+ns || blob[0] != sealVersion {
		return errors.New("sealed blob is malformed or from an unknown version")
	}
	plain, err := s.aead.Open(nil, blob[1:1+ns], blob[1+ns:], aad(principal, provider, account, half))
	if err != nil {
		return errors.New("sealed blob does not open with this key")
	}
	return json.Unmarshal(plain, v)
}

// --- the vault -----------------------------------------------------------------

// Refresher turns a long-lived secret into a fresh short-lived Access — and,
// since refresh tokens rotate, the secret to keep from now on.
type Refresher interface {
	Refresh(ctx context.Context, provider string, s Secret) (Access, Secret, error)
}

// Vault is the hub's credential store.
type Vault struct {
	Store     *store.Store
	Sealer    *Sealer
	Refresher Refresher
	// MinTTL is how long an issued access token must still have to run: a
	// cached one with less is refreshed first. Nodes renew well before
	// expiry, so with an 8h Claude token each account refreshes about every
	// (8h - MinTTL), however many machines lease it.
	MinTTL time.Duration
	Now    func() time.Time

	mu    sync.Mutex
	locks map[string]*sync.Mutex

	// keyMu guards Sealer and locked once the hub unlocks the vault at run
	// time, from KMS (claude-fleet#1417). Under KMS the vault starts LOCKED
	// and stays locked until a Decrypt succeeds — there is no other key to
	// fall back to, by design.
	keyMu  sync.RWMutex
	locked *LockState
}

// LockState says why the vault holds no key, and since when.
type LockState struct {
	Reason string
	Since  time.Time
}

// ErrLocked is returned by every vault operation while the vault has no key.
var ErrLocked = errors.New("credential vault is locked: its key could not be unwrapped from KMS")

// SetLocked marks the vault keyless; reason is what the last unlock attempt
// hit. A vault already locked keeps its Since.
func (v *Vault) SetLocked(reason string, at time.Time) {
	v.keyMu.Lock()
	defer v.keyMu.Unlock()
	v.Sealer = nil
	if v.locked != nil {
		v.locked.Reason = reason
		return
	}
	v.locked = &LockState{Reason: reason, Since: at}
}

// Unlock hands the vault its key.
func (v *Vault) Unlock(s *Sealer) {
	v.keyMu.Lock()
	defer v.keyMu.Unlock()
	v.Sealer, v.locked = s, nil
}

// Locked reports the lock, or nil when the vault can seal and open.
func (v *Vault) Locked() *LockState {
	v.keyMu.RLock()
	defer v.keyMu.RUnlock()
	if v.locked == nil && v.Sealer != nil {
		return nil
	}
	if v.locked == nil {
		return &LockState{Reason: "no key"}
	}
	l := *v.locked
	return &l
}

func (v *Vault) sealer() (*Sealer, error) {
	v.keyMu.RLock()
	defer v.keyMu.RUnlock()
	if v.Sealer == nil {
		return nil, ErrLocked
	}
	return v.Sealer, nil
}

// DefaultMinTTL is Vault.MinTTL when unset.
const DefaultMinTTL = 3 * time.Hour

func (v *Vault) now() time.Time {
	if v.Now != nil {
		return v.Now()
	}
	return time.Now()
}

func (v *Vault) minTTL() time.Duration {
	if v.MinTTL > 0 {
		return v.MinTTL
	}
	return DefaultMinTTL
}

// lock returns the one mutex for a row. The hub is a single instance (SQLite,
// Recreate), so an in-process lock IS the single writer; the version check in
// SaveRefresh is the belt to its braces.
func (v *Vault) lock(principal, provider, account string) *sync.Mutex {
	v.mu.Lock()
	defer v.mu.Unlock()
	if v.locks == nil {
		v.locks = map[string]*sync.Mutex{}
	}
	k := principal + "\x00" + provider + "\x00" + account
	m := v.locks[k]
	if m == nil {
		m = &sync.Mutex{}
		v.locks[k] = m
	}
	return m
}

// Put seals and stores a credential's long-lived half.
func (v *Vault) Put(principal, provider, account string, s Secret) error {
	if err := s.Validate(provider); err != nil {
		return err
	}
	sl, err := v.sealer()
	if err != nil {
		return err
	}
	l := v.lock(principal, provider, account)
	l.Lock()
	defer l.Unlock()
	blob, err := sl.Seal(s, principal, provider, account, "secret")
	if err != nil {
		return err
	}
	return v.Store.PutCredential(principal, provider, account, blob, v.now())
}

// ErrRefreshFailed wraps a refresh that failed with no usable token left.
var ErrRefreshFailed = errors.New("credential refresh failed")

// Lease returns a short-lived Access for one credential with at least MinTTL
// left, refreshing first if the cached one has less. Concurrent leases of one
// account wait on its lock, so the account is refreshed ONCE and the waiters
// get the result; the refresh is saved before anyone receives it.
func (v *Vault) Lease(ctx context.Context, principal, provider, account string) (Access, error) {
	sl, err := v.sealer()
	if err != nil {
		return Access{}, err
	}
	if provider == GitHub {
		// No refresh: the stored token IS the lease.
		c, err := v.Store.Credential(principal, provider, account)
		if err != nil {
			return Access{}, err
		}
		var s Secret
		if err := sl.Open(c.SecretSealed, &s, principal, provider, account, "secret"); err != nil {
			return Access{}, err
		}
		return Access{Token: s.Token, User: s.User}, nil
	}

	l := v.lock(principal, provider, account)
	l.Lock()
	defer l.Unlock()

	for attempt := 0; attempt < 2; attempt++ {
		c, err := v.Store.Credential(principal, provider, account)
		if err != nil {
			return Access{}, err
		}
		var cached Access
		haveCached := len(c.AccessSealed) > 0 &&
			sl.Open(c.AccessSealed, &cached, principal, provider, account, "access") == nil
		if haveCached && cached.ExpiresAt != nil && cached.ExpiresAt.Sub(v.now()) >= v.minTTL() {
			return cached, nil
		}

		var s Secret
		if err := sl.Open(c.SecretSealed, &s, principal, provider, account, "secret"); err != nil {
			return Access{}, err
		}
		acc, next, rerr := v.Refresher.Refresh(ctx, provider, s)
		at := v.now()
		if rerr != nil {
			_ = v.Store.NoteRefreshError(principal, provider, account, truncate(rerr.Error(), 300), at)
			_ = v.Store.AddCredAudit(store.CredAudit{At: at, Action: store.CredRefresh, PrincipalID: principal,
				Provider: provider, Account: account, Detail: "failed: " + truncate(rerr.Error(), 300)})
			// A still-valid cached token beats nothing: the node gets a
			// shorter lease and asks again sooner.
			if haveCached && cached.ExpiresAt != nil && cached.ExpiresAt.After(at) {
				return cached, nil
			}
			return Access{}, fmt.Errorf("%w: %v", ErrRefreshFailed, rerr)
		}
		secretBlob, err := sl.Seal(next, principal, provider, account, "secret")
		if err != nil {
			return Access{}, err
		}
		accessBlob, err := sl.Seal(acc, principal, provider, account, "access")
		if err != nil {
			return Access{}, err
		}
		err = v.Store.SaveRefresh(principal, provider, account, c.Version, secretBlob, accessBlob, acc.ExpiresAt, at)
		if errors.Is(err, store.ErrCredConflict) {
			// The operator replaced the secret mid-refresh. What we just
			// minted came from the old one; read again and redo it.
			continue
		}
		if err != nil {
			// The refresh token has already rotated at the provider; losing
			// the new one here would strand the account. Say so loudly.
			return Access{}, fmt.Errorf("save refreshed credential (the rotated refresh token is lost; re-store this credential): %w", err)
		}
		_ = v.Store.AddCredAudit(store.CredAudit{At: at, Action: store.CredRefresh, PrincipalID: principal,
			Provider: provider, Account: account, ExpiresAt: acc.ExpiresAt, Detail: "ok"})
		return acc, nil
	}
	return Access{}, store.ErrCredConflict
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "…"
}
