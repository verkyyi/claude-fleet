package api

import (
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/credvault"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// The hub half of "credentials live at the entrance; machines lease the
// short-lived half" (claude-fleet#1415).
//
// A node leases with its enrollment token, so the hub knows exactly which
// (machine, login) is asking — and answers only for the person whose ACTIVE
// fleet account that login is (C4's table). Nothing in the request can name
// another person: there is no principal parameter to forge. Every answer,
// issued or refused, is an audit row; a revocation (of the machine, of the
// person, or of the person on that machine) refuses every lease after it.
//
// Shared-pool accounts (claude-fleet#1463, store.PoolPrincipal): a credential
// stored under principal_id "pool" belongs to the machines' pool, not to a
// person, and rides along in EVERY active principal's lease — after the same
// no-principal and revocation checks, so a revoked person or machine loses
// the pool too. The audit row names the person who leased it, with "pool" in
// its detail. Which accounts are pool is the operator's `put`; there is no
// per-principal allow-list in this phase (every active principal may lease
// every pool row — that IS the pool, docs/SHARED-MACHINE.md 2b).

// NodeCredential is one leased credential in a node's answer. Pool marks a
// shared-pool account (not the person's own); Kind says what was issued —
// a setup_token is handed down as is and runs out at ExpiresAt for good.
type NodeCredential struct {
	Provider string `json:"provider"`
	Account  string `json:"account"`
	Kind     string `json:"kind,omitempty"`
	Pool     bool   `json:"pool,omitempty"`
	// Paused: an admin paused this pool account (pool.paused.<account>,
	// claude-fleet#1990). It is still leased, so a session already on it
	// finishes; a node starts no new session on it.
	Paused    bool              `json:"paused,omitempty"`
	ExpiresAt *time.Time        `json:"expires_at,omitempty"`
	Access    *credvault.Access `json:"access,omitempty"`
	Error     string            `json:"error,omitempty"`
}

// NodeCredentialsResponse is the answer to POST /v1/node/credentials.
type NodeCredentialsResponse struct {
	PrincipalID string           `json:"principal_id"`
	IssuedAt    time.Time        `json:"issued_at"`
	Credentials []NodeCredential `json:"credentials"`
}

// Lease refusal reasons, the "error" of a non-200 answer — the agent branches
// on them.
const (
	LeaseRevoked     = "revoked"
	LeaseNoPrincipal = "no_principal"
	LeaseVaultOff    = "vault_off"
	// LeaseComputeOff: the login only coordinates (claude-fleet#1719,
	// CCQUOTA_FLEET_COMPUTE=0) — it borrows no account; it uses its own.
	LeaseComputeOff = "compute_off"
	// LeaseVaultLocked: the vault's key lives in KMS and KMS has not
	// unwrapped it (claude-fleet#1417). Nothing is issued meanwhile — there
	// is no plain key to fall back to — and the hub raises a critical finding.
	LeaseVaultLocked = "vault_locked"
)

// vaultLocked answers 503 vault_locked when the vault holds no key.
func (s *Server) vaultLocked(w http.ResponseWriter) bool {
	if l := s.Vault.Locked(); l != nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": LeaseVaultLocked,
			"message": "the credential vault is locked (KMS): " + l.Reason})
		return true
	}
	return false
}

func (s *Server) vaultOff(w http.ResponseWriter) bool {
	if s.Vault == nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": LeaseVaultOff,
			"message": "the credential vault is off on this hub (no CCQUOTA_FLEET_CRED_KMS_KEY_ID or CCQUOTA_FLEET_CRED_KEY / _FILE)"})
		return true
	}
	return false
}

// nodeIdentity is the (machine, login) a node is, as the roster names it —
// the names C4's accounts are keyed on — from its newest heartbeat, falling
// back to the enrollment's own for a node that has never sent one.
func (s *Server) nodeIdentity(ep *store.Endpoint) (hostname, osUser string) {
	hostname, osUser = ep.Hostname, ep.OSUser
	if nodes, err := s.Store.Nodes(); err == nil {
		for _, n := range nodes {
			if n.EndpointID == ep.ID {
				if n.Hostname != "" {
					hostname = n.Hostname
				}
				if n.OSUser != "" {
					osUser = n.OSUser
				}
			}
		}
	}
	return hostname, osUser
}

// handleNodeCredentials answers one node's lease.
func (s *Server) handleNodeCredentials(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		httpError(w, http.StatusMethodNotAllowed, "POST only")
		return
	}
	tok := bearer(r)
	if tok == "" {
		httpError(w, http.StatusUnauthorized, "missing bearer token")
		return
	}
	ep, err := s.Store.EndpointByTokenHash(HashToken(tok))
	if err != nil {
		httpError(w, http.StatusUnauthorized, "unrecognised enrollment token")
		return
	}
	if s.vaultOff(w) {
		return
	}
	host, osUser := s.nodeIdentity(ep)
	deny := func(code int, reason, principal, detail string) {
		if err := s.Store.AddCredAudit(store.CredAudit{Action: store.CredDeny, PrincipalID: principal,
			Hostname: host, OSUser: osUser, EndpointID: ep.ID, Detail: reason + ": " + detail}); err != nil {
			log.Printf("credentials: audit deny for %s@%s: %v", osUser, host, err)
		}
		writeJSON(w, code, map[string]string{"error": reason, "message": detail})
	}
	if l := s.Vault.Locked(); l != nil {
		deny(http.StatusServiceUnavailable, LeaseVaultLocked, "", "the credential vault is locked (KMS): "+l.Reason)
		return
	}

	hb, _, _ := s.nodeStatusOf(ep.ID, time.Now())
	settings, _ := s.Store.FleetSettings()
	if cv := s.computeOf(ep.ID, hb, settings, time.Now()); cv.Off {
		deny(http.StatusForbidden, LeaseComputeOff, "", osUser+" on "+host+" only coordinates — "+cv.Why+": no credentials are leased to it")
		return
	}
	principal, err := s.Store.PrincipalForLogin(host, osUser)
	if errors.Is(err, store.ErrNoPrincipal) {
		deny(http.StatusForbidden, LeaseNoPrincipal, "", "no active fleet account is "+osUser+" on "+host)
		return
	}
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	rev, err := s.Store.RevokedFor(host, principal)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if rev != nil {
		what := "this machine"
		switch {
		case rev.Hostname != "" && rev.PrincipalID != "":
			what = "this person on this machine"
		case rev.Hostname == "":
			what = "this person"
		}
		deny(http.StatusForbidden, LeaseRevoked, principal, what+" was revoked at "+rev.RevokedAt.Format(time.RFC3339)+
			optional(" ("+rev.Reason+")", rev.Reason != ""))
		return
	}
	// A drill person (claude-fleet#2010) borrows nothing: not its own rows
	// (it has none) and never the shared pool.
	if s.Store.IsDrill(principal) {
		deny(http.StatusForbidden, LeaseDrill, principal, "a drill person gets no credentials")
		return
	}
	// Trust (claude-fleet#1968): only a machine the operator marked trusted
	// leases subscription credentials; one that joined later, or was marked
	// untrusted, gets nothing — an untrusted machine's sessions borrow a
	// session pass instead (C2), never the credential.
	trustSet, err := s.trustSettings(time.Now())
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if trustOf(host, trustSet) != TrustTrusted {
		deny(http.StatusForbidden, LeaseUntrusted, principal, firstLabel(host)+" is not a trusted machine — the operator marks it with fleet-node-trust.sh set "+
			strings.ToLower(firstLabel(host))+" trusted")
		return
	}

	creds, err := s.Store.Credentials(principal)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	pool, err := s.Store.Credentials(store.PoolPrincipal)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	creds = append(creds, pool...)
	paused := map[string]bool{}
	if settings, err := s.Store.FleetSettings(); err == nil {
		for _, a := range pausedAccounts(settings) {
			paused[a] = true
		}
	}
	resp := NodeCredentialsResponse{PrincipalID: principal, IssuedAt: time.Now().UTC(), Credentials: []NodeCredential{}}
	for _, c := range creds {
		isPool := c.PrincipalID == store.PoolPrincipal
		nc := NodeCredential{Provider: c.Provider, Account: c.Account, Kind: c.Kind, Pool: isPool, Paused: isPool && paused[c.Account]}
		// The row is sealed to ITS principal — "pool" for a pool row — while
		// the audit names the person who leased it.
		acc, err := s.Vault.Lease(r.Context(), c.PrincipalID, c.Provider, c.Account)
		audit := store.CredAudit{PrincipalID: principal, Provider: c.Provider, Account: c.Account,
			Hostname: host, OSUser: osUser, EndpointID: ep.ID}
		if isPool {
			audit.Detail = "pool"
		}
		if err != nil {
			nc.Error = err.Error()
			audit.Action, audit.Detail = store.CredDeny, optional("pool · ", isPool)+"lease failed: "+err.Error()
		} else {
			a := acc
			nc.Access, nc.ExpiresAt = &a, acc.ExpiresAt
			audit.Action, audit.ExpiresAt = store.CredIssue, acc.ExpiresAt
		}
		if err := s.Store.AddCredAudit(audit); err != nil {
			log.Printf("credentials: audit %s for %s@%s: %v", audit.Action, osUser, host, err)
		}
		resp.Credentials = append(resp.Credentials, nc)
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, resp)
}

// joinDetail is a · b, or whichever is set.
func joinDetail(a, b string) string {
	switch {
	case a == "":
		return b
	case b == "":
		return a
	}
	return a + " · " + b
}

func optional(s string, ok bool) string {
	if ok {
		return s
	}
	return ""
}

// FleetCredentialRequest is the body of POST /v1/fleet/credentials.
// PrincipalID is a person, or store.PoolPrincipal ("pool") for a shared-pool
// account every active principal may lease.
type FleetCredentialRequest struct {
	Action      string           `json:"action"` // put | delete
	PrincipalID string           `json:"principal_id"`
	Provider    string           `json:"provider"`
	Account     string           `json:"account"`
	Secret      credvault.Secret `json:"secret"`
}

// handleFleetCredentials lists credential metadata (GET — never a secret) or
// stores / removes one (POST). Operator only.
func (s *Server) handleFleetCredentials(w http.ResponseWriter, r *http.Request) {
	if s.vaultOff(w) {
		return
	}
	switch r.Method {
	case http.MethodGet:
		creds, err := s.Store.Credentials(r.URL.Query().Get("principal_id"))
		if err != nil {
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
		revs, err := s.Store.Revocations()
		if err != nil {
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
		settings, err := s.Store.FleetSettings()
		if err != nil {
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
		// account_uuid: the usage account a Codex credential belongs to,
		// so the subscriptions page pairs them by identity, not by label
		// (claude-fleet#2127). Computed here, never stored or a secret.
		type credRow struct {
			store.Credential
			AccountUUID string `json:"account_uuid,omitempty"`
		}
		rows := make([]credRow, 0, len(creds))
		for _, c := range creds {
			rows = append(rows, credRow{Credential: c, AccountUUID: s.Vault.AccountUUID(c)})
		}
		w.Header().Set("Cache-Control", "no-store")
		// paused: the pool accounts an admin paused (claude-fleet#1990).
		writeJSON(w, http.StatusOK, map[string]any{"credentials": rows, "revocations": revs, "paused": pausedAccounts(settings)})
	case http.MethodPost:
		var req FleetCredentialRequest
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 64<<10)).Decode(&req); err != nil {
			httpError(w, http.StatusBadRequest, "malformed request: "+err.Error())
			return
		}
		if req.PrincipalID == "" || req.Account == "" || !credvault.ValidProvider(req.Provider) {
			httpError(w, http.StatusBadRequest, "principal_id (a person, or \"pool\" for a shared-pool account), account and a provider of claude|codex|github are required")
			return
		}
		if !validAccountLabel(req.Account) {
			httpError(w, http.StatusBadRequest, "account must be 1-64 of [A-Za-z0-9._-], not starting with '.'")
			return
		}
		if req.PrincipalID != store.PoolPrincipal {
			if _, err := s.Store.Principal(req.PrincipalID); err != nil {
				httpError(w, http.StatusBadRequest, "unknown principal "+req.PrincipalID)
				return
			}
		}
		audit := store.CredAudit{PrincipalID: req.PrincipalID, Provider: req.Provider, Account: req.Account}
		switch req.Action {
		case "put":
			if s.vaultLocked(w) {
				return
			}
			if err := s.Vault.Put(req.PrincipalID, req.Provider, req.Account, req.Secret); err != nil {
				code := http.StatusBadRequest
				if errors.Is(err, credvault.ErrLocked) {
					code = http.StatusServiceUnavailable
				}
				httpError(w, code, err.Error())
				return
			}
			audit.Action = store.CredPut
		case "delete":
			if err := s.Store.DeleteCredential(req.PrincipalID, req.Provider, req.Account); err != nil {
				code := http.StatusInternalServerError
				if errors.Is(err, store.ErrNoCredential) {
					code = http.StatusNotFound
				}
				httpError(w, code, err.Error())
				return
			}
			audit.Action = store.CredDelete
		default:
			httpError(w, http.StatusBadRequest, "action must be put or delete")
			return
		}
		// Who did it (claude-fleet#1990): the audit page names the admin.
		audit.Detail = "by " + actorOf(r)
		_ = s.Store.AddCredAudit(audit)
		writeJSON(w, http.StatusOK, map[string]string{"ok": req.Action})
	default:
		httpError(w, http.StatusMethodNotAllowed, "GET or POST")
	}
}

// validAccountLabel is the shape a node can safely turn into a file name in
// its accounts directory.
func validAccountLabel(s string) bool {
	if s == "" || len(s) > 64 || s[0] == '.' {
		return false
	}
	for _, c := range s {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '.' || c == '_' || c == '-') {
			return false
		}
	}
	return true
}

// FleetRevokeRequest is the body of POST /v1/fleet/credentials/revoke.
type FleetRevokeRequest struct {
	Hostname    string `json:"hostname"`
	PrincipalID string `json:"principal_id"`
	Reason      string `json:"reason"`
	Lift        bool   `json:"lift"`
}

// handleFleetRevoke revokes (or, with lift, un-revokes) a machine, a person,
// or a person on a machine. Operator only.
func (s *Server) handleFleetRevoke(w http.ResponseWriter, r *http.Request) {
	if s.vaultOff(w) {
		return
	}
	if r.Method != http.MethodPost {
		httpError(w, http.StatusMethodNotAllowed, "POST only")
		return
	}
	var req FleetRevokeRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 16<<10)).Decode(&req); err != nil {
		httpError(w, http.StatusBadRequest, "malformed request: "+err.Error())
		return
	}
	if req.Hostname == "" && req.PrincipalID == "" {
		httpError(w, http.StatusBadRequest, "hostname, principal_id, or both")
		return
	}
	audit := store.CredAudit{PrincipalID: req.PrincipalID, Hostname: req.Hostname, Detail: req.Reason}
	if req.Lift {
		ok, err := s.Store.Unrevoke(req.Hostname, req.PrincipalID)
		if err != nil {
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
		if !ok {
			httpError(w, http.StatusNotFound, "no such revocation")
			return
		}
		audit.Action = store.CredUnrevoke
	} else {
		if err := s.Store.Revoke(req.Hostname, req.PrincipalID, req.Reason, time.Now()); err != nil {
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
		audit.Action = store.CredRevoke
	}
	s.relayCacheReset() // a revoked machine's relay pass stops now (#1974)
	audit.Detail = joinDetail(audit.Detail, "by "+actorOf(r))
	_ = s.Store.AddCredAudit(audit)
	s.sessCred.drop("") // a session pass of the revoked machine / person stops at once (#1969)
	writeJSON(w, http.StatusOK, map[string]string{"ok": audit.Action})
}

// handleFleetCredAudit returns the audit log, newest first. Operator only.
func (s *Server) handleFleetCredAudit(w http.ResponseWriter, r *http.Request) {
	if s.vaultOff(w) {
		return
	}
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	rows, err := s.Store.CredAuditLog(r.URL.Query().Get("principal_id"), limit)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, map[string]any{"audit": rows})
}
