package api

import (
	"crypto/sha256"
	"encoding/hex"
	"net/http"
	"sort"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/credvault"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// The shared pool's manifest (claude-fleet#2850): what a machine's shared
// pool (/var/db/fleet-cred/.shared/pool/claude/<fingerprint>/) should hold,
// for the node's sweep to converge on every round — a token the hub holds
// that the node lacks is pulled (through a login's own lease), one the node
// holds that the hub no longer lists is deleted, one within 30 days of its
// end is warned about. Metadata only: the fingerprint is the node's own pool
// key, sha256("claude\0" + token)[:32], never the token.

// NodePoolPath is the route.
const NodePoolPath = "/v1/node/pool"

// NodePoolEntry is one pool account the hub holds.
type NodePoolEntry struct {
	Provider    string     `json:"provider"`
	Account     string     `json:"account"`
	Fingerprint string     `json:"fingerprint,omitempty"`
	ExpiresAt   *time.Time `json:"expires_at,omitempty"`
	Paused      bool       `json:"paused,omitempty"`
	// Error: the hub cannot hand this token out (expired, needs a new login);
	// with no fingerprint, a node's copy of it is not kept.
	Error string `json:"error,omitempty"`
}

// NodePoolResponse is the answer to GET /v1/node/pool.
type NodePoolResponse struct {
	At   time.Time       `json:"at"`
	Pool []NodePoolEntry `json:"pool"`
}

// PoolFingerprint is the node's pool key of one Claude access token.
func PoolFingerprint(provider, token string) string {
	sum := sha256.Sum256([]byte(provider + "\x00" + token))
	return hex.EncodeToString(sum[:])[:32]
}

// handleNodePool answers GET /v1/node/pool with any enrollment token — the
// machine's own included: the pool belongs to the machines, and nothing secret
// leaves. Only Claude setup tokens are listed: they are what the pool holds
// for a year; a refreshed account rides each login's lease.
func (s *Server) handleNodePool(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", "GET")
		httpError(w, http.StatusMethodNotAllowed, "GET")
		return
	}
	if _, ok := s.nodeEndpoint(w, r); !ok {
		return
	}
	if s.vaultOff(w) || s.vaultLocked(w) {
		return
	}
	rows, err := s.Store.Credentials(store.PoolPrincipal)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	paused := map[string]bool{}
	if settings, err := s.Store.FleetSettings(); err == nil {
		for _, a := range pausedAccounts(settings) {
			paused[a] = true
		}
	}
	out := NodePoolResponse{At: time.Now().UTC(), Pool: []NodePoolEntry{}}
	for _, c := range rows {
		if c.Provider != credvault.Claude || c.Kind != credvault.KindSetupToken {
			continue
		}
		e := NodePoolEntry{Provider: c.Provider, Account: c.Account, ExpiresAt: c.SecretExpiresAt, Paused: paused[c.Account]}
		// A setup token's lease writes nothing and refreshes nothing.
		if acc, err := s.Vault.Lease(r.Context(), c.PrincipalID, c.Provider, c.Account); err != nil {
			e.Error = err.Error()
		} else if acc.AccessToken != "" {
			e.Fingerprint = PoolFingerprint(c.Provider, acc.AccessToken)
			if acc.ExpiresAt != nil {
				e.ExpiresAt = acc.ExpiresAt
			}
		}
		out.Pool = append(out.Pool, e)
	}
	sort.Slice(out.Pool, func(i, j int) bool { return out.Pool[i].Account < out.Pool[j].Account })
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, out)
}
