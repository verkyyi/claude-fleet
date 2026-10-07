package api

import (
	"errors"
	"log"
	"net/http"
	"sort"
	"strconv"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/credvault"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// The hub half of the cluster credential proxy (claude-fleet#1973, EPIC #1967
// C6). `ccquota credproxy` runs beside the hub as its own Deployment: it takes
// a session's pass (fcp-h1., C2) and sends the request on with the real
// credential. It holds no database and no vault key — the hub is the only
// writer of a SQLite file and runs one replica — so it asks the hub ONE
// question per pass, and caches the answer:
//
//	POST /v1/fleet/credproxy/resolve   Bearer CCQUOTA_FLEET_CREDPROXY_TOKEN
//	     {cred, provider} → {valid, reason?, id, principal, worker_id, machine,
//	                         exp, provider, owner, account, bind_rev,
//	                         access_token, account_id, expires_at}
//
// valid=false is the hub's verdict (forged / expired / revoked / another
// provider) and always a 200: a non-200 means the hub could not answer, which
// the proxy rides out on its cache. The access token is the vault's lease
// read (Vault.Lease — the cached short-lived half, refreshed by the hub when
// it runs low); nothing else stores it.
//
// The account is the session's binding (store.SessionBind, by worker_id): the
// first resolve picks one — the person's own account for the provider, else a
// shared-pool one — and keeps it; a rebind changes it:
//
//	PUT /v1/fleet/session-cred/bind    {worker_id, provider, account, owner?}
//	GET /v1/fleet/session-cred/bind?worker_id=…
//
// by the operator, or by the node that issued the session a live pass. The
// proxy sees a rebind on its next resolve (its cache is ≤ 30 s).
//
// No CCQUOTA_FLEET_CREDPROXY_TOKEN = resolve answers 503 credproxy_off and
// nothing else changes.

// CredProxyOff is resolve's refusal when the hub has no credproxy token.
const CredProxyOff = "credproxy_off"

// CredProxyResolvePath is the route the proxy asks.
const CredProxyResolvePath = "/v1/fleet/credproxy/resolve"

// CredProxyResolve is resolve's answer.
type CredProxyResolve struct {
	Valid       bool       `json:"valid"`
	Reason      string     `json:"reason,omitempty"`
	Error       string     `json:"error,omitempty"`
	ID          string     `json:"id,omitempty"`
	Principal   string     `json:"principal,omitempty"`
	WorkerID    string     `json:"worker_id,omitempty"`
	Machine     string     `json:"machine,omitempty"`
	Exp         int64      `json:"exp,omitempty"`
	Provider    string     `json:"provider,omitempty"`
	Owner       string     `json:"owner,omitempty"`
	Account     string     `json:"account,omitempty"`
	BindRev     int64      `json:"bind_rev,omitempty"`
	AccessToken string     `json:"access_token,omitempty"`
	AccountID   string     `json:"account_id,omitempty"`
	ExpiresAt   *time.Time `json:"expires_at,omitempty"`
}

// handleCredProxyResolve answers the cluster credential proxy.
func (s *Server) handleCredProxyResolve(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	if r.Method != http.MethodPost {
		httpError(w, http.StatusMethodNotAllowed, "POST {cred, provider}")
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
	}
	if err := readOptionalJSON(r, &req); err != nil || req.Cred == "" || !hasString(sessionCredProviders, req.Provider) {
		sessionCredRefuse(w, http.StatusBadRequest, "invalid_argument",
			"body must be {\"cred\": \"fcp-h1.…\", \"provider\": \"claude|codex\"}")
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
	out := CredProxyResolve{Valid: v.Valid, Reason: v.Reason, ID: v.ID, Principal: v.Principal,
		WorkerID: v.WorkerID, Machine: v.Machine, Exp: v.Exp, Provider: req.Provider}
	if !v.Valid {
		writeJSON(w, http.StatusOK, out)
		return
	}
	b, err := s.sessionBind(c.WorkerID, c.Principal, req.Provider, now)
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

// sessionBindChoices are the accounts a person's session may be bound to for
// one provider: their own first, then the shared pool's, each by name.
func (s *Server) sessionBindChoices(principal, provider string) ([]store.Credential, error) {
	var out []store.Credential
	for _, who := range []string{principal, store.PoolPrincipal} {
		rows, err := s.Store.Credentials(who)
		if err != nil {
			return nil, err
		}
		var mine []store.Credential
		for _, c := range rows {
			if c.Provider == provider {
				mine = append(mine, c)
			}
		}
		sort.SliceStable(mine, func(i, j int) bool {
			// one that refreshed cleanly before one that did not
			if (mine[i].RefreshError == "") != (mine[j].RefreshError == "") {
				return mine[i].RefreshError == ""
			}
			return mine[i].Account < mine[j].Account
		})
		out = append(out, mine...)
	}
	return out, nil
}

// sessionBind is the session's binding for provider, picked (and kept) on
// first use. A binding whose account is no longer the person's to use — the
// row was deleted, or it is another person's — is picked again.
func (s *Server) sessionBind(workerID, principal, provider string, now time.Time) (store.SessionBind, error) {
	choices, err := s.sessionBindChoices(principal, provider)
	if err != nil {
		return store.SessionBind{}, err
	}
	allowed := func(owner, account string) bool {
		for _, c := range choices {
			if c.PrincipalID == owner && c.Account == account {
				return true
			}
		}
		return false
	}
	b, err := s.Store.SessionBindFor(workerID, provider)
	if err == nil && allowed(b.Owner, b.Account) {
		return b, nil
	}
	if err != nil && !errors.Is(err, store.ErrNoSessionBind) {
		return b, err
	}
	if len(choices) == 0 {
		return b, errors.New("no " + provider + " account in the vault for " + principal + " (nor a shared-pool one)")
	}
	pick := store.SessionBind{WorkerID: workerID, Provider: provider, Owner: choices[0].PrincipalID,
		Account: choices[0].Account, SetBy: "auto"}
	if err == nil { // the bound account went away: re-pick, counted as a rebind
		return s.Store.SetSessionBind(pick, now)
	}
	return s.Store.PickSessionBind(pick, now)
}

// handleSessionBind is GET / PUT /v1/fleet/session-cred/bind: the operator,
// or the node holding a live pass for the session.
func (s *Server) handleSessionBind(w http.ResponseWriter, r *http.Request, ep *store.Endpoint) {
	now := time.Now()
	var req struct {
		WorkerID string `json:"worker_id"`
		Provider string `json:"provider"`
		Account  string `json:"account"`
		Owner    string `json:"owner"`
	}
	if r.Method == http.MethodGet {
		req.WorkerID = r.URL.Query().Get("worker_id")
	} else if err := readOptionalJSON(r, &req); err != nil {
		sessionCredRefuse(w, http.StatusBadRequest, "invalid_argument", "body: "+err.Error())
		return
	}
	if req.WorkerID == "" {
		sessionCredRefuse(w, http.StatusBadRequest, "invalid_argument", "worker_id is required")
		return
	}
	live, err := s.Store.SessionCredsForWorker(req.WorkerID, now)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	actor := "operator"
	if ep != nil {
		host, user := s.nodeIdentity(ep)
		actor = "node:" + user + "@" + host
		var mine []store.SessionCred
		for _, c := range live {
			if c.EndpointID == ep.ID {
				mine = append(mine, c)
			}
		}
		live = mine
	}
	if len(live) == 0 {
		sessionCredRefuse(w, http.StatusNotFound, "not_found", "no live session pass for "+req.WorkerID+optional(" on this node", ep != nil))
		return
	}
	if r.Method == http.MethodGet {
		binds, err := s.Store.SessionBinds(req.WorkerID)
		if err != nil {
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"worker_id": req.WorkerID, "principal_id": live[0].PrincipalID, "binds": binds})
		return
	}
	if !hasString(sessionCredProviders, req.Provider) || req.Account == "" {
		sessionCredRefuse(w, http.StatusBadRequest, "invalid_argument", "provider (claude|codex) and account are required")
		return
	}
	principal := live[0].PrincipalID
	choices, err := s.sessionBindChoices(principal, req.Provider)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	var pick *store.Credential
	for i, c := range choices {
		if c.Account == req.Account && (req.Owner == "" || req.Owner == c.PrincipalID) {
			pick = &choices[i]
			break
		}
	}
	if pick == nil {
		sessionCredRefuse(w, http.StatusNotFound, "not_found", "no "+req.Provider+" account "+req.Account+
			" that "+principal+" may use (their own, or the shared pool's)")
		return
	}
	b, err := s.Store.SetSessionBind(store.SessionBind{WorkerID: req.WorkerID, Provider: req.Provider,
		Owner: pick.PrincipalID, Account: pick.Account, SetBy: actor}, now)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if err := s.Store.FleetAuditWorker(actor, req.WorkerID, live[0].WorkerKey, "session_bind", live[0].FleetID,
		"bound "+req.Provider+" to "+optional("pool · ", pick.PrincipalID == store.PoolPrincipal)+pick.Account+
			" (rev "+strconv.FormatInt(b.Rev, 10)+")", "", now); err != nil {
		log.Printf("fleet audit: %v", err)
	}
	writeJSON(w, http.StatusOK, b)
}
