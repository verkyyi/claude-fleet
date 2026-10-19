package api

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/credvault"
	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/codex"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/limits"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/model"
)

// The hub reads the pool's quota itself (claude-fleet#2169).
//
// Until now every reading on the subscriptions page came from a node: a
// Claude setup token probed by `ccquota agent`, its account guessed by the
// seven-day reset fingerprint and the credential's label; a Codex account
// read by whichever machine held its quota lease. Changing how a reading is
// attributed meant waiting for every machine to upgrade, and one broken
// collector could hold a Codex account's lease for good.
//
// With CCQUOTA_FLEET_HUB_QUOTA=relay the hub reads every pool credential in
// its vault (github and paused ones excepted) every CCQUOTA_FLEET_HUB_QUOTA_INTERVAL
// (default 5m) through the Singapore relay (CCQUOTA_FLEET_CRED_RELAY_URL):
//
//   - Claude: the same one-token probe a node sends (limits.FetchViaInference)
//     to <relay>/anthropic/v1/messages, read from the rate-limit headers;
//   - Codex: <relay>/chatgpt/wham/usage with the vault's access token (the
//     vault refreshes it itself), parsed by codex.ParseUsage.
//
// Readings are filed under an owner/provider-scoped credential identity. The
// optional verified upstream account association is kept separately; neither
// a label nor a reset schedule can establish it. Bound legacy accounts still
// receive a compatibility copy for older account readers.
//
// The relay's forward_auth is answered by this hub: the quota pass
//
//	frq1.<exp unix>.<base64url HMAC-SHA256>
//
// is minted per read, good for hubRelayPassTTL, keyed apart from the refresh
// pass (frh1.), and opens exactly the two quota routes — nothing else on
// /anthropic/ or /chatgpt/. It is accepted only while this feature is on.
// No token is ever logged, audited or answered: errors carry a status code.

const (
	// HubQuotaEndpoint is the endpoint_id of the hub's own readings.
	HubQuotaEndpoint = "hub:quota"
	// HubQuotaVia / NodeQuotaVia are LimitsView.ReadVia's words.
	HubQuotaVia  = "hub"
	NodeQuotaVia = "node"

	hubQuotaPassPrefix = "frq1."
	hubQuotaClaudePath = "/anthropic/v1/messages"
	hubQuotaCodexPath  = "/chatgpt" + codex.UsagePath

	// DefaultHubQuotaInterval is how often the hub reads each account.
	DefaultHubQuotaInterval = 5 * time.Minute
	// MinHubQuotaInterval keeps a mistyped interval from burning quota: each
	// Claude read is a one-token inference call.
	MinHubQuotaInterval = time.Minute
)

// hubQuotaRoutes are the only paths the quota pass opens.
var hubQuotaRoutes = []string{hubQuotaClaudePath, hubQuotaCodexPath}

// HubQuota is the hub's own quota reader.
type HubQuota struct {
	RelayURL string        // e.g. https://relay.example.com
	Interval time.Duration // between reads of one account
	Client   *http.Client  // nil: 20s timeout
	Now      func() time.Time

	mu   sync.Mutex
	last map[string]HubQuotaRead // by provider/label
}

// HubQuotaRead is the outcome of the last read of one credential — what
// read_note quotes when the page falls back to a node. Never a token.
type HubQuotaRead struct {
	Provider     string    `json:"provider"`
	Account      string    `json:"account"`
	AccountUUID  string    `json:"account_uuid,omitempty"`
	CredentialID string    `json:"credential_id,omitempty"`
	Owner        string    `json:"owner"`
	At           time.Time `json:"at"`
	OK           bool      `json:"ok"`
	Error        string    `json:"error,omitempty"`
}

func (h *HubQuota) now() time.Time {
	if h.Now != nil {
		return h.Now()
	}
	return time.Now()
}

func (h *HubQuota) client() *http.Client {
	if h.Client != nil {
		return h.Client
	}
	return &http.Client{Timeout: 20 * time.Second}
}

func (h *HubQuota) interval() time.Duration {
	if h.Interval < MinHubQuotaInterval {
		return DefaultHubQuotaInterval
	}
	return h.Interval
}

// Fresh is how long a hub reading outranks a node's: two rounds, never less
// than ten minutes.
func (h *HubQuota) Fresh() time.Duration {
	return max(2*h.interval(), 10*time.Minute)
}

func (h *HubQuota) record(r HubQuotaRead) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.last == nil {
		h.last = map[string]HubQuotaRead{}
	}
	h.last[r.CredentialID] = r
}

// Reads is every credential's last read, for the doctor and tests.
func (h *HubQuota) Reads() []HubQuotaRead {
	h.mu.Lock()
	defer h.mu.Unlock()
	out := make([]HubQuotaRead, 0, len(h.last))
	for _, r := range h.last {
		out = append(out, r)
	}
	return out
}

// noteFor is why the hub has no fresh reading of account, "" when it does not
// know (nothing read yet, or the account is none of the vault's).
func (h *HubQuota) noteFor(account string) string {
	h.mu.Lock()
	defer h.mu.Unlock()
	for _, r := range h.last {
		if r.AccountUUID == account && !r.OK {
			return "hub reading failed (" + r.Error + "); showing a node's reading"
		}
	}
	return ""
}

// --- the quota pass ----------------------------------------------------------

func (s *Server) hubQuotaPassMAC(body string) []byte {
	return hubQuotaPassMACWith(s.SessionCredKey, body)
}

// hubQuotaPassOK checks a frq1 MAC under the current key and, while a
// rotation overlaps (claude-fleet#4138), the retiring one.
func (s *Server) hubQuotaPassOK(body string, got []byte) bool {
	return hmac.Equal(got, s.hubQuotaPassMAC(body)) ||
		(len(s.SessionCredKeyPrev) > 0 && hmac.Equal(got, hubQuotaPassMACWith(s.SessionCredKeyPrev, body)))
}

func hubQuotaPassMACWith(key []byte, body string) []byte {
	k := hmac.New(sha256.New, key)
	k.Write([]byte("claude-fleet hub quota pass v1"))
	mac := hmac.New(sha256.New, k.Sum(nil))
	mac.Write([]byte(body))
	return mac.Sum(nil)
}

// HubQuotaPass mints the hub's pass for one quota read through the relay.
func (s *Server) HubQuotaPass() (string, error) {
	if len(s.SessionCredKey) == 0 {
		return "", errHubRelayPassOff
	}
	body := hubQuotaPassPrefix + strconv.FormatInt(time.Now().Add(hubRelayPassTTL).Unix(), 10)
	return body + "." + base64.RawURLEncoding.EncodeToString(s.hubQuotaPassMAC(body)), nil
}

func hubQuotaRouteOK(uri string) bool {
	path, _, _ := strings.Cut(uri, "?")
	for _, r := range hubQuotaRoutes {
		if path == r {
			return true
		}
	}
	return false
}

// verifyHubQuotaPass is the relay check for a frq1. pass.
func (s *Server) verifyHubQuotaPass(tok, uri string, now time.Time) relayVerdict {
	if s.HubQuota == nil {
		return relayVerdict{why: "hub quota pass refused: the hub's own quota reading is off"}
	}
	if len(s.SessionCredKey) == 0 {
		return relayVerdict{why: "hub quota pass refused: " + SessionCredOff}
	}
	if !hubQuotaRouteOK(uri) {
		return relayVerdict{why: "hub quota pass refused: it opens " + strings.Join(hubQuotaRoutes, ", ") + " only"}
	}
	i := strings.LastIndexByte(tok, '.')
	if i <= len(hubQuotaPassPrefix) {
		return relayVerdict{why: "hub quota pass refused: malformed"}
	}
	body := tok[:i]
	got, err := base64.RawURLEncoding.DecodeString(tok[i+1:])
	if err != nil || !s.hubQuotaPassOK(body, got) {
		return relayVerdict{why: "hub quota pass refused: signature does not verify"}
	}
	exp, err := strconv.ParseInt(body[len(hubQuotaPassPrefix):], 10, 64)
	if err != nil {
		return relayVerdict{why: "hub quota pass refused: malformed"}
	}
	if !time.Unix(exp, 0).After(now) {
		return relayVerdict{why: "hub quota pass refused: expired"}
	}
	if time.Unix(exp, 0).After(now.Add(hubRelayPassTTL + time.Minute)) {
		return relayVerdict{why: "hub quota pass refused: lives longer than a hub pass may"}
	}
	return relayVerdict{ok: true, who: "hub"}
}

// --- the reader --------------------------------------------------------------

// RunHubQuota reads every pool account now and then every interval, until ctx
// ends. A no-op when the feature is off.
func (s *Server) RunHubQuota(ctx context.Context) {
	if s.HubQuota == nil || s.Vault == nil {
		return
	}
	t := time.NewTicker(s.HubQuota.interval())
	defer t.Stop()
	for {
		s.ReadHubQuota(ctx)
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
	}
}

// ReadHubQuota is one round: every readable pool credential, one at a time.
func (s *Server) ReadHubQuota(ctx context.Context) {
	h := s.HubQuota
	if h == nil || s.Vault == nil {
		return
	}
	if st := s.Vault.Locked(); st != nil {
		log.Printf("hub quota: vault locked, nothing read this round")
		return
	}
	creds, err := s.Store.Credentials("")
	if err != nil {
		log.Printf("hub quota: list pool credentials: %v", err)
		return
	}
	settings, err := s.Store.FleetSettings()
	if err != nil {
		log.Printf("hub quota: read settings: %v", err)
		return
	}
	paused := map[string]bool{}
	for _, a := range pausedAccounts(settings) {
		paused[a] = true
	}
	seen := map[string]bool{}
	for _, c := range creds {
		if ctx.Err() != nil {
			return
		}
		if c.Provider == credvault.GitHub || (c.PrincipalID == store.PoolPrincipal && paused[c.Account]) || ownPaused(settings, c) {
			continue
		}
		id := s.Vault.CredentialID(c)
		if id == "" || seen[id] {
			continue
		}
		seen[id] = true
		rctx, cancel := context.WithTimeout(ctx, 45*time.Second)
		r := s.readHubQuotaOne(rctx, c)
		cancel()
		h.record(r)
		if !r.OK {
			log.Printf("hub quota: %s/%s: %s", c.Provider, c.Account, r.Error)
		}
	}
}

func (s *Server) readHubQuotaOne(ctx context.Context, c store.Credential) (r HubQuotaRead) {
	h := s.HubQuota
	r = HubQuotaRead{Provider: c.Provider, Owner: c.PrincipalID, Account: c.Account, At: h.now().UTC(), AccountUUID: s.Vault.AccountUUID(c), CredentialID: s.Vault.CredentialID(c)}
	defer func() {
		if r.CredentialID != "" {
			if err := s.Store.SaveCredentialQuotaRead(r.CredentialID, r.At, r.Error); err != nil {
				r.OK = false
				r.Error = "could not persist quota read status"
			}
		}
	}()
	fail := func(err error) HubQuotaRead {
		r.Error = truncate(err.Error(), 200)
		return r
	}
	uuid, err := s.hubQuotaAccount(c)
	if err != nil {
		return fail(err)
	}
	acc, err := s.Vault.Lease(ctx, c.PrincipalID, c.Provider, c.Account)
	if err != nil {
		return fail(fmt.Errorf("lease: %w", err))
	}
	current, err := s.Store.Credential(c.PrincipalID, c.Provider, c.Account)
	if err != nil || current == nil || s.Vault.CredentialID(*current) != uuid {
		return fail(errors.New("credential changed during read; retry next round"))
	}
	base := strings.TrimRight(h.RelayURL, "/")
	switch c.Provider {
	case credvault.Claude:
		cl := &limits.Client{HTTP: h.client(), MessagesURL: base + hubQuotaClaudePath, Decorate: s.hubQuotaDecorate}
		snap, err := cl.FetchViaInference(ctx, acc.AccessToken)
		if err != nil {
			return fail(err)
		}
		snap.AccountUUID, snap.EndpointID, snap.CredentialLabel = uuid, HubQuotaEndpoint, c.Account
		if err := s.Store.InsertLimits(snap); err != nil {
			return fail(err)
		}
		if r.AccountUUID != "" {
			if err := s.hubQuotaEnsureAccount(r.AccountUUID, model.SourceClaude, c.Account); err != nil {
				return fail(err)
			}
			snap.AccountUUID = r.AccountUUID
			if err := s.Store.InsertLimits(snap); err != nil {
				return fail(err)
			}
		}
	case credvault.Codex:
		q, err := s.hubQuotaCodex(ctx, base, acc)
		if err != nil {
			return fail(err)
		}
		q.AccountUUID, q.Source, q.EndpointID, q.ProfileID = uuid, model.SourceCodex, HubQuotaEndpoint, "hub"
		if err := s.Store.InsertQuota(*q); err != nil {
			return fail(err)
		}
		if r.AccountUUID != "" {
			if err := s.hubQuotaEnsureAccount(r.AccountUUID, model.SourceCodex, c.Account); err != nil {
				return fail(err)
			}
			q.AccountUUID = r.AccountUUID
			if err := s.Store.InsertQuota(*q); err != nil {
				return fail(err)
			}
		}
	default:
		return fail(errors.New("no quota reading for provider " + c.Provider))
	}
	r.OK = true
	return r
}

// hubQuotaAccount is an internal quota subject, never a guessed account UUID.
func (s *Server) hubQuotaAccount(c store.Credential) (string, error) {
	if id := s.Vault.CredentialID(c); id != "" {
		return id, nil
	}
	return "", errors.New("credential identity unavailable")
}

// hubQuotaEnsureAccount gives a reading of a known identity its account row:
// without one the page reads the uuid as a Claude account.
func (s *Server) hubQuotaEnsureAccount(uuid, source, label string) error {
	ok, err := s.Store.AccountExists(uuid)
	if err != nil || ok {
		return err
	}
	return s.Store.UpsertAccount(model.Identity{Source: source, AccountUUID: uuid, DisplayName: label}, "", "")
}

func (s *Server) hubQuotaDecorate(req *http.Request) error {
	pass, err := s.HubQuotaPass()
	if err != nil {
		return err
	}
	req.Header.Set(credvault.RelayPassHeader, pass)
	return nil
}

func (s *Server) hubQuotaCodex(ctx context.Context, base string, acc credvault.Access) (*model.QuotaSnapshot, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, base+hubQuotaCodexPath, nil)
	if err != nil {
		return nil, err
	}
	if err := s.hubQuotaDecorate(req); err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+acc.AccessToken)
	if acc.AccountID != "" {
		req.Header.Set("ChatGPT-Account-Id", acc.AccountID)
	}
	req.Header.Set("User-Agent", "codex_cli_rs")
	req.Header.Set("Accept", "application/json")
	resp, err := s.HubQuota.client().Do(req)
	if err != nil {
		return nil, fmt.Errorf("relay unreachable: %v", err)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if resp.StatusCode != http.StatusOK {
		// The status only: an upstream body is not ours to log.
		if resp.StatusCode == http.StatusForbidden && strings.Contains(string(raw), "relay_refused") {
			return nil, errors.New("the relay refused the hub's quota pass")
		}
		return nil, fmt.Errorf("HTTP %d from %s", resp.StatusCode, hubQuotaCodexPath)
	}
	return codex.ParseUsage(raw, s.HubQuota.now().UTC())
}
