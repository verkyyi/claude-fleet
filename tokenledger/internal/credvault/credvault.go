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

	"github.com/verkyyi/claude-fleet/tokenledger/internal/codex"
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
//	        — OR setup_token + expires_at (claude-fleet#1463): the long-lived
//	        OAuth token `claude setup-token` mints (~1 year, no refresh token).
//	        It cannot be refreshed and does not rotate, so the hub hands it
//	        down as is and several machines may hold one without logging
//	        each other out. The expiry is the operator's to state; the hub
//	        reminds them 30 days before it (findings) and refuses to lease
//	        one that has passed.
//	codex:  refresh_token, account_id (+ id_token, kept current by refreshes)
//	github: token, user — phase one hands the person's existing token down as
//	        is (it has no refresh); R1 replaces it with a short-lived one.
//
// account_uuid (optional, any provider) is the usage account the credential
// belongs to, as the importing login knows it (oauthAccount.accountUuid): a
// setup token cannot say whose it is (claude-fleet#2127). Not a secret — it
// rides in the sealed half only so a refresh carries it along unchanged.
type Secret struct {
	RefreshToken     string     `json:"refresh_token,omitempty"`
	SetupToken       string     `json:"setup_token,omitempty"`
	ExpiresAt        *time.Time `json:"expires_at,omitempty"`
	IDToken          string     `json:"id_token,omitempty"`
	AccountID        string     `json:"account_id,omitempty"`
	Scopes           []string   `json:"scopes,omitempty"`
	SubscriptionType string     `json:"subscription_type,omitempty"`
	Token            string     `json:"token,omitempty"`
	User             string     `json:"user,omitempty"`
	AccountUUID      string     `json:"account_uuid,omitempty"`
}

// Kinds — what the long-lived half IS, kept beside the row as metadata (the
// sealed blob cannot be asked). "" on a row predating the column means
// refresh_token for claude/codex and token for github.
const (
	KindRefreshToken = "refresh_token" // refreshed by the hub, rotates on use
	KindSetupToken   = "setup_token"   // claude setup-token: issued as is, never refreshed
	KindToken        = "token"         // github phase one: issued as is
)

// Kind reports s's kind for provider (after Validate).
func (s Secret) Kind(provider string) string {
	switch {
	case provider == GitHub:
		return KindToken
	case provider == Claude && s.SetupToken != "":
		return KindSetupToken
	}
	return KindRefreshToken
}

// SecretExpiry is when the long-lived half itself runs out, when it has a
// known end: a setup token's expires_at. Nil for a refresh token (it rotates)
// and for github phase one.
func (s Secret) SecretExpiry(provider string) *time.Time {
	if s.Kind(provider) == KindSetupToken {
		return s.ExpiresAt
	}
	return nil
}

// Validate checks that s carries what provider needs.
func (s Secret) Validate(provider string) error {
	if s.AccountUUID != "" && !validAccountUUID(s.AccountUUID) {
		return errors.New("account_uuid must be 1-128 of [A-Za-z0-9:._-]")
	}
	switch provider {
	case Claude:
		switch {
		case s.RefreshToken != "" && s.SetupToken != "":
			return errors.New("claude takes refresh_token or setup_token, not both")
		case s.SetupToken != "" && s.ExpiresAt == nil:
			return errors.New("claude setup_token needs expires_at (claude setup-token mints a ~1 year token; say when it ends)")
		case s.SetupToken != "" && !strings.HasPrefix(s.SetupToken, "sk-ant-oat01-"):
			return errors.New("claude setup_token must be the sk-ant-oat01-… token `claude setup-token` prints")
		case s.RefreshToken == "" && s.SetupToken == "":
			return errors.New("claude needs refresh_token or setup_token")
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

func validAccountUUID(u string) bool {
	if len(u) > 128 {
		return false
	}
	for _, r := range u {
		if !(r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || strings.ContainsRune(":._-", r)) {
			return false
		}
	}
	return true
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

	// CrossLock, when set, holds an account's refresh across hub replicas
	// (claude-fleet#2123): two hubs on one Postgres each have their own row
	// mutex, and an account refreshed by both at once gets its whole grant
	// revoked upstream. nil — a single hub — is the row mutex alone.
	CrossLock func(ctx context.Context, name string) (unlock func(), err error)
	// Replica names this hub in the refresh audit when set (claude-fleet#2123).
	Replica string

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

// crossLockWait bounds the wait for another replica's refresh of the same
// account: one refresh round-trip, with room.
const crossLockWait = 45 * time.Second

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

// lock returns the one mutex for a row. On a single hub (SQLite, Recreate) an
// in-process lock IS the single writer; with replicas CrossLock is taken under
// it. The version check in SaveRefresh is the belt to its braces.
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

// ErrSetupTokenExpired is returned for a setup token past its stated expiry:
// nothing can be issued from it, the operator must mint a new one.
var ErrSetupTokenExpired = errors.New("setup token has expired; run `claude setup-token` and import it again")

// Put seals and stores a credential's long-lived half. A setup token already
// past its expires_at is refused: storing it could only ever issue a dead
// token.
func (v *Vault) Put(principal, provider, account string, s Secret) error {
	if err := s.Validate(provider); err != nil {
		return err
	}
	if exp := s.SecretExpiry(provider); exp != nil && !exp.After(v.now()) {
		return fmt.Errorf("%w (expires_at %s)", ErrSetupTokenExpired, exp.UTC().Format(time.RFC3339))
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
	return v.Store.PutCredential(principal, provider, account, blob, s.Kind(provider), s.SecretExpiry(provider), v.now())
}

// AccountUUID is the usage account a stored credential belongs to, as the
// usage side names it — a Codex credential's codex:account:<…> from its
// account_id and id_token, else the account_uuid recorded at import (a Claude
// setup token's) — or "" when it cannot say (GitHub, a locked vault, an
// older import). Nothing secret leaves here.
func (v *Vault) AccountUUID(c store.Credential) string {
	if c.Provider == GitHub || len(c.SecretSealed) == 0 {
		return ""
	}
	sl, err := v.sealer()
	if err != nil {
		return ""
	}
	var s Secret
	if sl.Open(c.SecretSealed, &s, c.PrincipalID, c.Provider, c.Account, "secret") != nil {
		return ""
	}
	if c.Provider == Codex && s.IDToken != "" {
		if u := codex.AccountUUIDFromIDToken(s.IDToken, s.AccountID); u != "" {
			return u
		}
	}
	return s.AccountUUID
}

// BindAccountUUID records which usage account an EXISTING credential belongs
// to (claude-fleet#2169): a Claude setup token imported before account_uuid
// was recorded cannot say, and the hub's own quota reading files it under
// this. The sealed secret is opened, the field set, and sealed back at the
// same version — the token itself is untouched and never leaves here.
func (v *Vault) BindAccountUUID(principal, provider, account, uuid string) error {
	if provider == GitHub {
		return errors.New("a GitHub credential has no usage account")
	}
	sl, err := v.sealer()
	if err != nil {
		return err
	}
	l := v.lock(principal, provider, account)
	l.Lock()
	defer l.Unlock()
	c, err := v.Store.Credential(principal, provider, account)
	if err != nil {
		return err
	}
	var s Secret
	if err := sl.Open(c.SecretSealed, &s, principal, provider, account, "secret"); err != nil {
		return err
	}
	s.AccountUUID = uuid
	blob, err := sl.Seal(s, principal, provider, account, "secret")
	if err != nil {
		return err
	}
	return v.Store.RewriteSecret(principal, provider, account, c.Version, blob, v.now())
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
	c, err := v.Store.Credential(principal, provider, account)
	if err != nil {
		return Access{}, err
	}
	if c.ReauthRequired && provider != GitHub && c.Kind == KindSetupToken {
		return Access{}, reauthErr(c)
	}
	if provider == GitHub || c.Kind == KindSetupToken {
		// No refresh: the stored token IS the lease. Nothing is written, so
		// no row lock — any number of machines read the same token.
		var s Secret
		if err := sl.Open(c.SecretSealed, &s, principal, provider, account, "secret"); err != nil {
			return Access{}, err
		}
		if provider == GitHub {
			return Access{Token: s.Token, User: s.User}, nil
		}
		if s.ExpiresAt == nil || !s.ExpiresAt.After(v.now()) {
			at := ""
			if s.ExpiresAt != nil {
				at = " at " + s.ExpiresAt.UTC().Format(time.RFC3339)
			}
			return Access{}, fmt.Errorf("%w%s", ErrSetupTokenExpired, at)
		}
		scopes := s.Scopes
		if len(scopes) == 0 {
			scopes = []string{"user:inference"}
		}
		exp := s.ExpiresAt.UTC()
		return Access{AccessToken: s.SetupToken, Scopes: scopes, SubscriptionType: s.SubscriptionType, ExpiresAt: &exp}, nil
	}

	l := v.lock(principal, provider, account)
	l.Lock()
	defer l.Unlock()
	if v.CrossLock != nil {
		// The other replica may be refreshing this account right now: wait
		// for it, then read the row it saved like any other waiter.
		lctx, cancel := context.WithTimeout(ctx, crossLockWait)
		unlock, err := v.CrossLock(lctx, principal+"/"+provider+"/"+account)
		cancel()
		if err != nil {
			return Access{}, fmt.Errorf("credential lock across hub replicas: %w", err)
		}
		defer unlock()
	}

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
		if c.ReauthRequired {
			// The refresh token is dead; asking again only fails again. What
			// is still cached was never refused (a refused one was dropped),
			// so it runs out on its own — then nothing more is issued.
			if haveCached && cached.ExpiresAt != nil && cached.ExpiresAt.After(v.now()) {
				return cached, nil
			}
			return Access{}, reauthErr(c)
		}

		var s Secret
		if err := sl.Open(c.SecretSealed, &s, principal, provider, account, "secret"); err != nil {
			return Access{}, err
		}
		acc, next, via, rerr := v.refresh(ctx, provider, s)
		at := v.now()
		// The audit says where the refresh ran when a node carried it
		// (claude-fleet#1490): refresh_via=<login>@<host>.
		viaNote := ""
		if via != "" {
			viaNote = " · refresh_via=" + via
		}
		if v.Replica != "" {
			viaNote += " · replica=" + v.Replica
		}
		if rerr != nil {
			reauth := NeedsReauth(rerr)
			if reauth {
				// The provider refused the refresh token itself
				// (claude-fleet#2007): only a new login helps. Say so on the
				// row, so the pages and the next lease read it.
				_ = v.Store.MarkReauthRequired(principal, provider, account, truncate(rerr.Error(), 300), false, at)
			} else {
				_ = v.Store.NoteRefreshError(principal, provider, account, truncate(rerr.Error(), 300), at)
			}
			_ = v.Store.AddCredAudit(store.CredAudit{At: at, Action: store.CredRefresh, PrincipalID: principal,
				Provider: provider, Account: account, Detail: "failed: " + truncate(rerr.Error(), 300) + viaNote})
			if reauth {
				_ = v.Store.AddCredAudit(store.CredAudit{At: at, Action: store.CredReauth, PrincipalID: principal,
					Provider: provider, Account: account, Detail: "the provider refused the refresh token: " + truncate(rerr.Error(), 300)})
			}
			// A still-valid cached token beats nothing: the node gets a
			// shorter lease and asks again sooner.
			if haveCached && cached.ExpiresAt != nil && cached.ExpiresAt.After(at) {
				return cached, nil
			}
			if reauth {
				return Access{}, fmt.Errorf("%w (%v)", ErrReauthRequired, rerr)
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
			Provider: provider, Account: account, ExpiresAt: acc.ExpiresAt, Detail: "ok" + viaNote})
		return acc, nil
	}
	return Access{}, store.ErrCredConflict
}

// ErrReauthRequired: the provider has refused this account's refresh token
// (or a setup token was revoked upstream) — nothing is leased from it until
// the operator logs in again and stores the new credential. Its leading word
// is the status word the node, the pages and the doctor read.
var ErrReauthRequired = errors.New("reauth_required: the provider refused this account's credential; log in again and store the new one")

func reauthErr(c *store.Credential) error {
	since := ""
	if c.ReauthRequiredAt != nil {
		since = " since " + c.ReauthRequiredAt.UTC().Format(time.RFC3339)
	}
	return fmt.Errorf("%w%s", ErrReauthRequired, since)
}

// AccessFingerprint names one access token without carrying it: the hex
// SHA-256 of the token. A node reports an upstream refusal by it
// (upstream_rejected.fingerprint, claude-fleet#2007) and the vault compares it
// with what it has cached, so neither side sends a token back.
func AccessFingerprint(token string) string {
	return codex.AccessFingerprint(token)
}

// RejectUpstream records that the upstream refused the access token
// fingerprint names, for one credential (claude-fleet#2007): a revoked
// authorization (token_revoked — a logout, a revocation, or a refresh token
// reused after it rotated elsewhere) keeps its exp, so the clock alone would
// hand the dead token out for days. When fingerprint is the cached access,
// the cache is dropped — the next Lease refreshes from the stored refresh
// token, and a refresh the provider refuses marks the account
// reauth_required. A setup token (it cannot be refreshed) refused upstream is
// marked reauth_required at once. A fingerprint that matches nothing the
// vault holds — a report about a token already replaced — changes nothing:
// dropped is false. by names who reported it, for the audit.
func (v *Vault) RejectUpstream(principal, provider, account, fingerprint, code, by string) (dropped bool, err error) {
	if provider == GitHub || fingerprint == "" {
		return false, nil
	}
	sl, err := v.sealer()
	if err != nil {
		return false, err
	}
	l := v.lock(principal, provider, account)
	l.Lock()
	defer l.Unlock()
	c, err := v.Store.Credential(principal, provider, account)
	if err != nil {
		return false, err
	}
	at := v.now()
	detail := optionalCode(code) + optionalBy(by)
	if c.Kind == KindSetupToken {
		var s Secret
		if err := sl.Open(c.SecretSealed, &s, principal, provider, account, "secret"); err != nil {
			return false, err
		}
		if AccessFingerprint(s.SetupToken) != fingerprint || c.ReauthRequired {
			return false, nil
		}
		if err := v.Store.MarkReauthRequired(principal, provider, account, "upstream rejected the setup token: "+code, false, at); err != nil {
			return false, err
		}
		_ = v.Store.AddCredAudit(store.CredAudit{At: at, Action: store.CredUpstreamRejected, PrincipalID: principal,
			Provider: provider, Account: account, Detail: detail + " · setup token: reauth_required"})
		return true, nil
	}
	var cached Access
	if len(c.AccessSealed) == 0 || sl.Open(c.AccessSealed, &cached, principal, provider, account, "access") != nil ||
		AccessFingerprint(cached.AccessToken) != fingerprint {
		return false, nil
	}
	if err := v.Store.DropAccess(principal, provider, account, c.Version, at); err != nil {
		if errors.Is(err, store.ErrCredConflict) {
			return false, nil // refreshed meanwhile: the refused token is already gone
		}
		return false, err
	}
	_ = v.Store.AddCredAudit(store.CredAudit{At: at, Action: store.CredUpstreamRejected, PrincipalID: principal,
		Provider: provider, Account: account, ExpiresAt: cached.ExpiresAt, Detail: detail + " · cached access dropped"})
	return true, nil
}

func optionalCode(code string) string {
	if code == "" {
		return "rejected"
	}
	return truncate(code, 64)
}

func optionalBy(by string) string {
	if by == "" {
		return ""
	}
	return " · by " + truncate(by, 128)
}

// refresh runs the Refresher, asking a RefresherVia where it ran.
func (v *Vault) refresh(ctx context.Context, provider string, s Secret) (Access, Secret, string, error) {
	if rv, ok := v.Refresher.(RefresherVia); ok {
		return rv.RefreshVia(ctx, provider, s)
	}
	acc, next, err := v.Refresher.Refresh(ctx, provider, s)
	return acc, next, "", err
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "…"
}
