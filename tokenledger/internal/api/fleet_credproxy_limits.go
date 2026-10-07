package api

import (
	"errors"
	"log"
	"net/http"
	"strconv"
	"sync"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/credvault"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// An account at its limit is not picked (claude-fleet#2115, EPIC #2133 C2).
//
// The first pick of a session's account (sessionBind) used to take the first
// choice by name, so a pool account at its weekly limit kept being handed out
// and every session on it opened onto a 429. Now the pick puts an account
// known to be at its limit after the rest:
//
//   - its latest reading (limit_snapshots, by the account the vault label
//     names — ResolveCredentialLabel) has the five-hour or the seven-day
//     window at 100% and that window has not reset yet; or
//   - the cluster proxy reported a quota 429 for it (POST
//     /v1/fleet/credproxy/rebind), remembered until the reset the answer
//     carried, else for limitMemoDefault.
//
// Every account full ⇒ the old order, byte for byte. A session already bound
// is not moved by a reading — only by its own 429, through rebind: the proxy
// asks once per request, the hub moves the binding only while it still names
// the account that answered 429 (so concurrent 429s on one session move it
// once), to the first choice not at its limit; none ⇒ nothing moves and the
// proxy passes the 429 on.

// CredProxyRebindPath is the route the proxy reports a quota 429 to.
const CredProxyRebindPath = "/v1/fleet/credproxy/rebind"

// limitMemoDefault is how long a reported 429 keeps an account out of the
// pick when its answer named no reset.
const limitMemoDefault = time.Hour

// limitMemoMax bounds a reported reset (a weekly window is at most 7 days).
const limitMemoMax = 7 * 24 * time.Hour

// limitMemo is the 429s the proxy reported, by (provider, owner, account).
type limitMemo struct {
	mu    sync.Mutex
	until map[string]time.Time
}

func limitKey(provider, owner, account string) string {
	return provider + "\x00" + owner + "\x00" + account
}

func (m *limitMemo) mark(provider, owner, account string, until time.Time) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.until == nil {
		m.until = map[string]time.Time{}
	}
	m.until[limitKey(provider, owner, account)] = until
}

func (m *limitMemo) limited(provider, owner, account string, now time.Time) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	k := limitKey(provider, owner, account)
	u, ok := m.until[k]
	if ok && !now.Before(u) {
		delete(m.until, k)
		return false
	}
	return ok
}

// credAtLimit says why one vault account is known to be at its limit, or "".
func (s *Server) credAtLimit(c store.Credential, now time.Time) string {
	if s.limits.limited(c.Provider, c.PrincipalID, c.Account, now) {
		return "429"
	}
	uuid, err := s.Store.ResolveCredentialLabel(c.Provider, c.Account)
	if err != nil || uuid == "" {
		return ""
	}
	snap, err := s.Store.LatestLimits(uuid)
	if err != nil || snap == nil {
		return ""
	}
	full := func(pct float64, reset *time.Time) bool {
		return pct >= 100 && (reset == nil || reset.After(now))
	}
	switch {
	case full(snap.SevenDay.Utilization, snap.SevenDay.ResetsAt):
		return "7d"
	case full(snap.FiveHour.Utilization, snap.FiveHour.ResetsAt):
		return "5h"
	}
	return ""
}

// byHeadroom is choices with every account known to be at its limit moved
// after the rest, each part in its own order; all full ⇒ choices unchanged.
func (s *Server) byHeadroom(choices []store.Credential, now time.Time) []store.Credential {
	var open, full []store.Credential
	for _, c := range choices {
		if s.credAtLimit(c, now) != "" {
			full = append(full, c)
		} else {
			open = append(open, c)
		}
	}
	return append(open, full...)
}

// CredProxyRebind is rebind's answer: the session's resolve after the move
// (or as it stands), and the account it moved from ("" = nothing moved).
type CredProxyRebind struct {
	CredProxyResolve
	RebindFrom string `json:"rebind_from,omitempty"`
}

// handleCredProxyRebind is POST /v1/fleet/credproxy/rebind
// {cred, provider, account, owner?, reset_at?}: the proxy saw a quota 429 on
// account for this pass's session.
func (s *Server) handleCredProxyRebind(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	if r.Method != http.MethodPost {
		httpError(w, http.StatusMethodNotAllowed, "POST {cred, provider, account}")
		return
	}
	if s.CredProxyToken == "" {
		sessionCredRefuse(w, http.StatusServiceUnavailable, CredProxyOff,
			"the cluster credential proxy is off on this hub (no CCQUOTA_FLEET_CREDPROXY_TOKEN)")
		return
	}
	if !constantTimeEqual(bearer(r), s.CredProxyToken) {
		sessionCredRefuse(w, http.StatusUnauthorized, "unauthenticated", "the credential proxy's token is required")
		return
	}
	var req struct {
		Cred     string `json:"cred"`
		Provider string `json:"provider"`
		Account  string `json:"account"`
		Owner    string `json:"owner"`
		ResetAt  int64  `json:"reset_at"`
	}
	if err := readOptionalJSON(r, &req); err != nil || req.Cred == "" || req.Account == "" || !hasString(sessionCredProviders, req.Provider) {
		sessionCredRefuse(w, http.StatusBadRequest, "invalid_argument",
			"body must be {\"cred\": \"fcp-h1.…\", \"provider\": \"claude|codex\", \"account\": \"…\"}")
		return
	}
	if len(s.SessionCredKey) == 0 {
		sessionCredRefuse(w, http.StatusServiceUnavailable, SessionCredOff, "session passes are off on this hub")
		return
	}
	if s.vaultOff(w) || s.vaultLocked(w) {
		return
	}
	now := time.Now()
	v, c := s.verifySessionCred(req.Cred, "", req.Provider, false, now)
	out := CredProxyRebind{CredProxyResolve: CredProxyResolve{Valid: v.Valid, Reason: v.Reason, ID: v.ID,
		Principal: v.Principal, WorkerID: v.WorkerID, Machine: v.Machine, Exp: v.Exp, Provider: req.Provider}}
	if !v.Valid {
		writeJSON(w, http.StatusOK, out)
		return
	}
	owner := req.Owner
	if owner == "" {
		owner = c.Principal
	}
	until := now.Add(limitMemoDefault)
	if req.ResetAt > 0 {
		if t := time.Unix(req.ResetAt, 0); t.After(now) && t.Before(now.Add(limitMemoMax)) {
			until = t
		}
	}
	s.limits.mark(req.Provider, owner, req.Account, until)

	b, err := s.sessionBind(c.WorkerID, c.Principal, req.Provider, now)
	if err == nil && b.Owner == owner && b.Account == req.Account {
		var choices []store.Credential
		if choices, err = s.sessionBindChoices(c.Principal, req.Provider); err == nil {
			for _, ch := range choices {
				if (ch.PrincipalID == b.Owner && ch.Account == b.Account) || s.credAtLimit(ch, now) != "" {
					continue
				}
				nb, serr := s.Store.SetSessionBind(store.SessionBind{WorkerID: c.WorkerID, Provider: req.Provider,
					Owner: ch.PrincipalID, Account: ch.Account, SetBy: "credproxy:429"}, now)
				if serr != nil {
					err = serr
					break
				}
				out.RebindFrom = optional("pool · ", b.Owner == store.PoolPrincipal) + b.Account
				log.Printf("credproxy rebind: worker_id=%s provider=%s rebind_from=%s to=%s rev=%d",
					c.WorkerID, req.Provider, out.RebindFrom, ch.Account, nb.Rev)
				if aerr := s.Store.FleetAuditWorker("credproxy", c.WorkerID, "", "session_bind", "",
					"quota 429 on "+out.RebindFrom+": bound "+req.Provider+" to "+
						optional("pool · ", ch.PrincipalID == store.PoolPrincipal)+ch.Account+
						" (rev "+strconv.FormatInt(nb.Rev, 10)+")", "", now); aerr != nil {
					log.Printf("fleet audit: %v", aerr)
				}
				b = nb
				break
			}
		}
	}
	if err != nil {
		out.Valid, out.Error, out.Reason = false, "no_credential", err.Error()
		writeJSON(w, http.StatusOK, out)
		return
	}
	out.Owner, out.Account, out.BindRev = b.Owner, b.Account, b.Rev
	acc, err := s.Vault.Lease(r.Context(), b.Owner, req.Provider, b.Account)
	if err != nil {
		if errors.Is(err, credvault.ErrLocked) {
			sessionCredRefuse(w, http.StatusServiceUnavailable, LeaseVaultLocked, err.Error())
			return
		}
		out.Valid, out.Error, out.Reason = false, "no_credential", "account "+b.Account+": "+err.Error()
		writeJSON(w, http.StatusOK, out)
		return
	}
	out.AccessToken, out.AccountID, out.ExpiresAt = acc.AccessToken, acc.AccountID, acc.ExpiresAt
	writeJSON(w, http.StatusOK, out)
}
