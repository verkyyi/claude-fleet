package api

import (
	"encoding/json"
	"errors"
	"io"
	"log"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/credvault"
	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
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
// its detail. Which accounts are pool is the operator's `put`; which of them
// (and of the person's own) a machine and a person may lease is the
// subscription allowlists' (claude-fleet#3043, fleet_cred_policy.go) — none
// set, every active principal leases every pool row, as before.

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
	// State is CredStateReauth when nothing is leased because the account
	// needs a new login (claude-fleet#2007); "" otherwise.
	State string `json:"state,omitempty"`
}

// NodeCredentialsRequest is the (optional) body of POST /v1/node/credentials.
// An agent that predates it sends none, and is answered exactly as before.
type NodeCredentialsRequest struct {
	// UpstreamRejected: leased access tokens the upstream has refused since
	// (claude-fleet#2007) — token_revoked keeps its exp, so without this the
	// hub would hand the same dead token back until it ran out.
	UpstreamRejected []UpstreamRejected `json:"upstream_rejected,omitempty"`
}

// UpstreamRejected names one refused access token — by its fingerprint
// (credvault.AccessFingerprint), never the token — for one leased account.
type UpstreamRejected struct {
	Provider    string     `json:"provider"`
	Account     string     `json:"account"`
	Fingerprint string     `json:"fingerprint"`
	Error       string     `json:"error,omitempty"`
	At          *time.Time `json:"at,omitempty"`
}

// CredStateReauth is NodeCredential.State for an account the provider has
// refused (store.Credential.ReauthRequired): log in again and store it.
const CredStateReauth = "reauth_required"

// NodeCredentialsResponse is the answer to POST /v1/node/credentials.
type NodeCredentialsResponse struct {
	PrincipalID string           `json:"principal_id"`
	IssuedAt    time.Time        `json:"issued_at"`
	Credentials []NodeCredential `json:"credentials"`
	// Withdrawn (claude-fleet#3043): accounts this login would lease but a
	// subscription allowlist forbids — Error says why. The node removes its
	// copy of each (tenant-scoped on a shared proxy); no access travels.
	Withdrawn []NodeCredential `json:"withdrawn,omitempty"`
	// RecheckSecs: lease again within this many seconds, while any allowlist
	// exists, so a narrowing reaches the node (0 = the agent's own schedule).
	RecheckSecs int `json:"recheck_secs,omitempty"`
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
	// LeaseNotSeparated: a login whose newest heartbeat does not say
	// credsep=separated (claude-fleet#2295; every login since #4607). Nothing is issued —
	// its sessions take the proxy's central route instead (/v1/node/self
	// says so), so they still work but no token lands in the login's home.
	LeaseNotSeparated = "not_separated"
	// LeaseMachineOff: the person's machine allowlist leaves this machine
	// out (claude-fleet#3824) — the login stays, nothing is issued to it.
	LeaseMachineOff = "machine_off"
)

// credsepGated says whether a login must be refused real tokens
// because it is not credential-separated (claude-fleet#2295, EPIC #2293).
// Separation is not opt-in (claude-fleet#4607) and has no way out
// (claude-fleet#4675): every login is held to it — an admin's, the operator's
// own principals', a self-hosted box's, anyone's — so no real token is ever
// written into a home its sessions can read. credsep is the login's newest
// heartbeat's word; "" (an agent older than #2295) counts as not separated.
func credsepGated(credsep string) bool {
	return credsep != control.CredsepSeparated
}

// leaseServes says whether the lease would hand n's login pool credentials
// were it separated (claude-fleet#4622) — the logins the gate's cred-ttl item
// counts. It mirrors handleNodeCredentials' refusals before the credsep gate,
// plus what is never a person's node login: a lost row, a machine link, a
// cluster pod (a person's u-<nonce> or the shared workers: their sessions take
// the central route, nothing lands on the node), a login that only
// coordinates (a client computer: 登录即认人, compute off), an untrusted
// machine, a system account (root, _<name>), a login with no active fleet
// account (a deleted user: no_principal) or a revoked one.
func (s *Server) leaseServes(n NodeView) bool {
	if n.Status == "lost" || n.MachineLink || n.UserPod ||
		isClusterPodMachine(n.Hostname) || n.ComputeOff || n.Trust != TrustTrusted || systemLogin(n.OSUser) {
		return false
	}
	if s.Store == nil {
		return true
	}
	principal, err := s.principalOnNode(n.EndpointID, n.Hostname, n.OSUser)
	if err != nil {
		return !errors.Is(err, store.ErrNoPrincipal) // a read error still counts the login
	}
	rev, err := s.Store.RevokedFor(n.Hostname, principal)
	return err != nil || rev == nil
}

// systemLogin is a machine's own account, never a person's login: root, or a
// name macOS reserves for a service (_fleetadmin, _fleetnode, _fleetcred).
func systemLogin(login string) bool {
	return login == "root" || strings.HasPrefix(login, "_")
}

// credsepWord is how a heartbeat's credsep reads in an audit line.
func credsepWord(v string) string {
	if v == "" {
		return "unreported"
	}
	return v
}

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
	ep, ok := s.nodeEndpoint(w, r) // its signature, else its token (claude-fleet#3710)
	if !ok {
		return
	}
	if s.vaultOff(w) {
		return
	}
	var body NodeCredentialsRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 64<<10)).Decode(&body); err != nil && !errors.Is(err, io.EOF) {
		httpError(w, http.StatusBadRequest, "malformed request: "+err.Error())
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
		deny(http.StatusForbidden, LeaseComputeOff, "", osUser+" on "+host+" only coordinates — "+cv.Reason()+": no credentials are leased to it")
		return
	}
	principal, err := s.principalForLease(ep.ID, host, osUser, time.Now())
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
	// A drill person (claude-fleet#2010) leases as the newcomer it stands in
	// for — no gate of its own (claude-fleet#3155): own rows ∩ pool ∩ the
	// allowlists below, for its short life.
	// Trust (claude-fleet#1968): only a machine the operator marked trusted
	// leases subscription credentials; one that joined later, or was marked
	// untrusted, gets nothing — an untrusted machine's sessions borrow a
	// session pass instead (C2), never the credential.
	trustSet, err := s.trustSettings(time.Now())
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	// The endpoint's own trust first, a name only for the endpoint that
	// enrolled under it (claude-fleet#2214).
	if t, src := s.endpointTrust(ep.ID, host, trustSet); t != TrustTrusted {
		deny(http.StatusForbidden, LeaseUntrusted, principal, untrustedWhy(host, src))
		return
	}

	// Credential separation (claude-fleet#2295): a login that has not
	// put its tokens out of its own reach gets none — 拒发：未隔离.
	if credsepGated(hb.Credsep) {
		deny(http.StatusForbidden, LeaseNotSeparated, principal, "拒发：未隔离 — "+osUser+" on "+firstLabel(host)+
			" is not credential-separated (credsep="+credsepWord(hb.Credsep)+"); its sessions go through the hub's central proxy. "+
			"On a managed machine its daemon separates it within minutes (credsep-enforce); else, as root: "+
			"sudo bash ~/.claude/fleet/bin/fleet-credsep.sh install --login "+osUser)
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
	// Subscription allowlists (claude-fleet#3043): this machine's ∩ this
	// person's, after every gate above. A policy that cannot be read refuses
	// the lease rather than reading as no restriction.
	pol, err := s.credPolicyFor(ep.ID, principal)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	var withdrawn []NodeCredential
	if pol.Restricted() {
		kept := creds[:0:0]
		for _, c := range creds {
			uuid, why := s.credVerdict(c, pol)
			if why == "" {
				kept = append(kept, c)
				continue
			}
			isPool := c.PrincipalID == store.PoolPrincipal
			withdrawn = append(withdrawn, NodeCredential{Provider: c.Provider, Account: c.Account, Kind: c.Kind, Pool: isPool, Error: why})
			if err := s.Store.AddCredAudit(store.CredAudit{Action: store.CredDeny, PrincipalID: principal, Provider: c.Provider,
				Account: c.Account, Hostname: host, OSUser: osUser, EndpointID: ep.ID,
				Detail: optional("pool · ", isPool) + "policy: " + why + optional(" (account_uuid="+uuid+")", uuid != "")}); err != nil {
				log.Printf("credentials: audit policy deny for %s@%s: %v", osUser, host, err)
			}
		}
		creds = kept
	}
	// A node's local pool must not count or refresh token aliases twice.
	// Explicitly withdraw the redundant names so an older local copy is removed.
	seenIDs := map[string]bool{}
	unique := make([]store.Credential, 0, len(creds))
	for _, c := range creds {
		id := s.Vault.CredentialID(c)
		if id != "" && seenIDs[id] {
			withdrawn = append(withdrawn, NodeCredential{Provider: c.Provider, Account: c.Account, Kind: c.Kind, Pool: c.PrincipalID == store.PoolPrincipal, Error: "duplicate credential alias"})
			continue
		}
		seenIDs[id] = true
		unique = append(unique, c)
	}
	creds = unique
	// Machine allowlists (claude-fleet#3824): a person this machine is not
	// open to leases nothing here, and every copy the node holds is withdrawn
	// — a 200 that names them, so the node removes them and keeps rechecking;
	// the login itself stays as it is.
	mwhy, err := s.machineDeniedFor(ep.ID, host, principal)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if mwhy != "" {
		for _, c := range creds {
			isPool := c.PrincipalID == store.PoolPrincipal
			withdrawn = append(withdrawn, NodeCredential{Provider: c.Provider, Account: c.Account, Kind: c.Kind, Pool: isPool, Error: MachineDisabledWord + "：" + mwhy})
		}
		if err := s.Store.AddCredAudit(store.CredAudit{Action: store.CredDeny, PrincipalID: principal,
			Hostname: host, OSUser: osUser, EndpointID: ep.ID, Detail: "machine policy: " + mwhy}); err != nil {
			log.Printf("credentials: audit machine deny for %s@%s: %v", osUser, host, err)
		}
		creds = nil
	}
	paused := map[string]bool{}
	settings, _ = s.Store.FleetSettings()
	for _, a := range pausedAccounts(settings) {
		paused[a] = true
	}
	// Refusals first, so the lease below already answers with what replaced
	// the refused token. Only a row this login may lease can be named.
	for _, rj := range body.UpstreamRejected {
		for _, c := range creds {
			if c.Provider != rj.Provider || c.Account != rj.Account {
				continue
			}
			if _, err := s.Vault.RejectUpstream(c.PrincipalID, c.Provider, c.Account, rj.Fingerprint, rj.Error, osUser+"@"+host); err != nil {
				log.Printf("credentials: upstream rejection of %s/%s from %s@%s: %v", c.Provider, c.Account, osUser, host, err)
			}
		}
	}
	resp := NodeCredentialsResponse{PrincipalID: principal, IssuedAt: time.Now().UTC(), Credentials: []NodeCredential{}, Withdrawn: withdrawn}
	if st, err := s.Store.FleetSettings(); err == nil && (anyCredPolicy(st) || anyMachinePolicy(st)) {
		resp.RecheckSecs = int(credPolicyRecheck / time.Second)
	}
	for _, c := range creds {
		isPool := c.PrincipalID == store.PoolPrincipal
		nc := NodeCredential{Provider: c.Provider, Account: c.Account, Kind: c.Kind, Pool: isPool,
			Paused: isPool && paused[c.Account] || ownPaused(settings, c)} // a member's own, paused by them (#4035)
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
			if errors.Is(err, credvault.ErrReauthRequired) {
				nc.State = CredStateReauth
			}
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
	Action      string           `json:"action"` // put | delete | bind | plan | source
	PrincipalID string           `json:"principal_id"`
	Provider    string           `json:"provider"`
	Account     string           `json:"account"`
	Secret      credvault.Secret `json:"secret"`
	// AccountUUID is bind's one argument (claude-fleet#2169): which usage
	// account an existing credential belongs to. No secret travels with it.
	AccountUUID string `json:"account_uuid,omitempty"`
	// Plan and RateLimitTier are plan's arguments (claude-fleet EEJD): the
	// subscription an existing credential is on, as an admin says — the
	// provider's own value (max, pro, prolite …), never a label. "" clears.
	Plan          string                 `json:"plan,omitempty"`
	RateLimitTier string                 `json:"rate_limit_tier,omitempty"`
	PlanEvidence  credvault.PlanEvidence `json:"plan_evidence,omitempty"`
	// SourceClass is source's argument (WACK C1): subscription or api, for
	// a pool row; "" clears.
	SourceClass string `json:"source_class,omitempty"`
}

// planValueRE is a provider plan value or tier: lower-case words, as the
// providers spell them (max, prolite, default_claude_max_20x).
var planValueRE = regexp.MustCompile(`^[a-z0-9_]{1,48}$`)

var (
	claudeAccountUUIDRE = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)
	codexAccountUUIDRE  = regexp.MustCompile(`^codex:account:[0-9a-f]{32}$`)
)

// validBindUUID is an account_uuid of the shape the usage side names that
// provider's accounts — never a win_ fingerprint or a pool stand-in.
func validBindUUID(provider, uuid string) bool {
	switch provider {
	case credvault.Claude:
		return claudeAccountUUIDRE.MatchString(uuid)
	case credvault.Codex:
		return codexAccountUUIDRE.MatchString(uuid)
	}
	return false
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
		// account_uuid: the usage account a credential belongs to (a Codex
		// one's from its id_token, a Claude one's as recorded at import), so
		// the subscriptions page pairs them by identity, not by label
		// (claude-fleet#2127). Never a secret.
		type credRow struct {
			store.Credential
			CredentialID string      `json:"credential_id,omitempty"`
			Limits       *LimitsView `json:"limits,omitempty"`
			AccountUUID  string      `json:"account_uuid,omitempty"`
			Plan         string      `json:"plan,omitempty"`
			PlanSource   string      `json:"plan_source,omitempty"`
			PlanAt       *time.Time  `json:"plan_at,omitempty"`
			PlanTier     string      `json:"plan_tier,omitempty"`
			// Source: the row's source class as fleet.trial.sources reads
			// it (subscription · api · byo — WACK C1).
			Source string `json:"source"`
			// What the plan costs a month now (subscription_plans, by plan ×
			// provider — claude-fleet EEJD); absent when nobody priced it.
			MonthlyCost *float64 `json:"monthly_cost,omitempty"`
			Currency    string   `json:"currency,omitempty"`
		}
		now := time.Now()
		// A credential the vault holds no plan for is priced by its usage
		// account's plan — the one the pool page names it by (EEJD).
		accts, err := s.Store.ListAccounts()
		if err != nil {
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
		acctPlan := make(map[string]string, len(accts))
		for _, a := range accts {
			acctPlan[a.AccountUUID] = a.SubscriptionType
		}
		rows := make([]credRow, 0, len(creds))
		for _, c := range creds {
			view, err := s.credentialLimits(c)
			if err != nil {
				httpError(w, http.StatusInternalServerError, "quota read failed")
				return
			}
			plan, source := s.Vault.PlanMetadata(c)
			var planAt *time.Time
			if source == "provider" {
				planAt = c.RefreshedAt
				if planAt == nil {
					planAt = &c.CreatedAt
				}
			}
			row := credRow{Credential: c, AccountUUID: s.Vault.AccountUUID(c), CredentialID: s.Vault.CredentialID(c), Limits: view, Plan: plan, PlanSource: source, PlanAt: planAt, Source: c.Source()}
			row.PlanTier = s.Vault.PlanTier(c)
			priced := plan
			if priced == "" {
				priced = acctPlan[row.AccountUUID]
			}
			if priced != "" {
				price, err := s.Store.PlanPriceAt(priced, c.Provider, now)
				if err != nil {
					httpError(w, http.StatusInternalServerError, "plan price read failed")
					return
				}
				if price != nil {
					row.MonthlyCost, row.Currency = &price.MonthlyCost, price.Currency
				}
			}
			rows = append(rows, row)
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
		case "bind":
			// Record which usage account an existing credential belongs to
			// (claude-fleet#2169): the hub's own quota reading files it under
			// this. No secret in the request, none in the audit.
			uuid := strings.TrimSpace(req.AccountUUID)
			if !validBindUUID(req.Provider, uuid) {
				httpError(w, http.StatusBadRequest, "bind needs account_uuid: a Claude account's UUID, or a Codex codex:account:<32 hex>")
				return
			}
			if s.vaultLocked(w) {
				return
			}
			if err := s.Vault.BindAccountUUID(req.PrincipalID, req.Provider, req.Account, uuid); err != nil {
				code := http.StatusInternalServerError
				switch {
				case errors.Is(err, store.ErrNoCredential):
					code = http.StatusNotFound
				case errors.Is(err, credvault.ErrLocked):
					code = http.StatusServiceUnavailable
				}
				httpError(w, code, err.Error())
				return
			}
			audit.Action = store.CredBind
			audit.Detail = "account_uuid=" + uuid + " · "
		case "plan":
			// Record the subscription an existing credential is on
			// (claude-fleet EEJD): a setup token cannot say. No secret
			// travels, none in the audit.
			plan, tier := strings.TrimSpace(req.Plan), strings.TrimSpace(req.RateLimitTier)
			if (plan != "" && !planValueRE.MatchString(plan)) || (tier != "" && !planValueRE.MatchString(tier)) || (plan == "" && tier != "") || req.Provider == credvault.GitHub {
				httpError(w, http.StatusBadRequest, "plan needs a claude or codex credential and the provider's plan value (e.g. max, prolite) and optionally rate_limit_tier (e.g. default_claude_max_20x); an empty plan clears it")
				return
			}
			if s.vaultLocked(w) {
				return
			}
			if req.Provider == credvault.Claude && (plan != "" || tier != "") {
				e := req.PlanEvidence
				if strings.TrimSpace(e.Source) == "" || len(e.Source) > 512 || strings.ContainsAny(e.Source, "\r\n\x00") || (e.Confidence != "verified" && e.Confidence != "provisional") || e.ObservedAt.IsZero() || e.ObservedAt.After(time.Now()) {
					httpError(w, 400, "Claude registration requires source, confidence and nonfuture observed_at")
					return
				}
			}
			if err := s.Vault.SetPlan(req.PrincipalID, req.Provider, req.Account, plan, tier, req.PlanEvidence); err != nil {
				code := http.StatusInternalServerError
				switch {
				case errors.Is(err, store.ErrNoCredential):
					code = http.StatusNotFound
				case errors.Is(err, credvault.ErrLocked):
					code = http.StatusServiceUnavailable
				}
				httpError(w, code, err.Error())
				return
			}
			audit.Action = store.CredPlan
			audit.Detail = "plan=" + plan
			if tier != "" {
				audit.Detail += " tier=" + tier
			}
			audit.Detail += " · "
		case "source":
			// Record what a pool subscription is (WACK C1): a personal
			// subscription or a commercial API key — what fleet.trial.sources
			// chooses by. "" clears it (read as a subscription).
			class := strings.TrimSpace(req.SourceClass)
			if req.PrincipalID != store.PoolPrincipal || req.Provider == credvault.GitHub || (class != "" && !store.ValidPoolSource(class)) {
				httpError(w, http.StatusBadRequest, "source needs a pool claude or codex subscription and source_class subscription or api (\"\" clears it); a person's own subscription is always byo")
				return
			}
			if err := s.setCredentialSource(req.PrincipalID, req.Provider, req.Account, class, time.Now()); err != nil {
				code := http.StatusInternalServerError
				if errors.Is(err, store.ErrNoCredential) {
					code = http.StatusNotFound
				}
				httpError(w, code, err.Error())
				return
			}
			audit.Action = store.CredSource
			audit.Detail = "source_class=" + class + " · "
		default:
			httpError(w, http.StatusBadRequest, "action must be put, delete, bind, plan or source")
			return
		}
		// Who did it (claude-fleet#1990): the audit page names the admin.
		audit.Detail += "by " + actorOf(r)
		_ = s.Store.AddCredAudit(audit)
		if req.Action != "bind" && req.Action != "plan" && req.Action != "source" {
			s.BroadcastCreds("credential " + req.Action) // every node leases now (#3744)
		}
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
		s.revLift(revCredSrc(req.Hostname, req.PrincipalID))
	} else {
		now := time.Now()
		if err := s.Store.Revoke(req.Hostname, req.PrincipalID, req.Reason, now); err != nil {
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
		audit.Action = store.CredRevoke
		if s.revOn() {
			s.revRecord(s.revForCredRevoke(req.Hostname, req.PrincipalID, req.Reason, now), now)
		}
	}
	s.relayCacheReset() // a revoked machine's relay pass stops now (#1974)
	audit.Detail = joinDetail(audit.Detail, "by "+actorOf(r))
	_ = s.Store.AddCredAudit(audit)
	s.sessCred.drop("") // a session pass of the revoked machine / person stops at once (#1969)
	// … and every node leases again at once (#3744)
	s.BroadcastCreds(audit.Action)
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
