package api

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"net/http"
	"regexp"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/credvault"
	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

// A service's standing pass: a long-running in-cluster service (svc:xiaoerge,
// the WeCom agent in kf-bot) calls Codex through the cluster credential proxy
// with a pass bound to its OWN service principal — no svc-run Job per request.
//
//	POST /v1/svc/pass         pass:issue   {ttl_seconds?, kind?, providers?, tenant?} → a pass
//	POST /v1/svc/pass/renew   pass:issue   {cred} → the same pass, a new exp
//
// The pass is a session pass like every other (fcp-h1 / fcp-h2, ≤
// SessionCredTTL, a fleet_session_creds row), with
//
//	principal svc:<name> · worker_id svc-standing/<name> · machine svc-standing
//	providers ["codex"] · svc <name> · optional tenant, no run
//
// Codex ONLY, by the owner's rule: inside the cluster the fleet's subscriptions
// serve Codex; Claude keeps going through the Mac mini, never the cluster.
// `providers` may be left out or be exactly ["codex"]; anything else is 400.
//
// Its usage is metered under svc:<name> and the signed tenant (empty for
// legacy callers). The whole service and effective tenant ceiling hold at
// mint and every resolve. Named tenants must remain on the service allowlist.
// The yield rule (fleet.svc.<name>.yield_pct) is applied at EVERY new Codex
// request of a standing pass, not only its first: a service that never ends
// would otherwise keep, forever, the account it was first bound to
// (sessionBind, svcStandingWorker).
//
// Refused: session passes off (503 session_cred_off), no pass:issue scope
// (403, svcOnly), no Codex subscription the service's allowlist permits (403
// no_credential), over the service's budget (429 quota_exceeded). The token
// that minted it is written on the row (worker_key fcs:<prefix>); every verify
// re-reads that token and the principal (cached ≤ sessionCredCacheTTL), so a
// revoked / expired token or a disabled principal ends its passes — new mints
// stop at once at the service door. Audit: svc.pass.issue · svc.pass.renew.

const (
	SvcPassPath      = "/v1/svc/pass"
	SvcPassRenewPath = "/v1/svc/pass/renew"

	// svcStandingMachine is a standing pass's machine.
	svcStandingMachine = "svc-standing"
	// svcStandingWorkerPrefix + <name> is its worker id.
	svcStandingWorkerPrefix = "svc-standing/"
	// svcStandingTokenWord + <prefix> is the minting token on the row.
	svcStandingTokenWord = "fcs:"
)

// svcStandingProviders is what a standing pass may cover: Codex alone.
var svcStandingProviders = []string{credvault.Codex}

var svcTenantRE = regexp.MustCompile(`^[a-z0-9-]{1,32}$`)

func svcTenantsKey(principal string) string {
	return "fleet.svc." + svcName(principal) + ".tenants"
}

// Empty is the legacy standing pass, independent of the named app allowlist.
func (s *Server) svcTenantAllowed(principal, tenant string) (bool, error) {
	if tenant == "" {
		return true, nil
	}
	settings, err := s.Store.FleetSettings()
	if err != nil {
		return false, err
	}
	for _, allowed := range strings.Split(settings[svcTenantsKey(principal)], ",") {
		if strings.TrimSpace(allowed) == tenant {
			return true, nil
		}
	}
	return false, nil
}

func svcStandingWorker(workerID string) bool {
	return strings.HasPrefix(workerID, svcStandingWorkerPrefix)
}

// svcPassMux mounts the standing pass's two routes.
func (s *Server) svcPassMux(m *http.ServeMux) {
	m.Handle(SvcPassPath, s.svcOnly(store.SvcPassIssue, http.HandlerFunc(s.handleSvcPassIssue)))
	m.Handle(SvcPassRenewPath, s.svcOnly(store.SvcPassIssue, http.HandlerFunc(s.handleSvcPassRenew)))
}

func (s *Server) handleSvcPassIssue(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", "POST")
		httpError(w, http.StatusMethodNotAllowed, "POST {ttl_seconds?, kind?}")
		return
	}
	now := time.Now()
	p, prefix, _ := SvcCallerOf(r.Context())
	tenant := ""
	refuse := func(status int, code, msg string) {
		s.svcAudit(p.ID, "svc.pass.issue", p.ID, "REFUSED", fmt.Sprintf("tenant=%q · %s: %s", tenant, code, msg), now)
		svcRunError(w, status, code, msg)
	}
	if len(s.SessionCredKey) == 0 {
		refuse(http.StatusServiceUnavailable, SessionCredOff, "session passes are off on this hub")
		return
	}
	var req struct {
		Providers  []string `json:"providers"`
		TTLSeconds int      `json:"ttl_seconds"`
		Kind       string   `json:"kind"`
		Tenant     *string  `json:"tenant"`
	}
	if err := readOptionalJSON(r, &req); err != nil {
		svcRunError(w, http.StatusBadRequest, "invalid_argument", "body: "+err.Error())
		return
	}
	if req.Tenant != nil {
		tenant = *req.Tenant
		if !svcTenantRE.MatchString(tenant) {
			refuse(http.StatusBadRequest, "invalid_argument", "tenant must match [a-z0-9-]{1,32}")
			return
		}
	}
	if allowed, err := s.svcTenantAllowed(p.ID, tenant); err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	} else if !allowed {
		refuse(http.StatusForbidden, "tenant_not_allowed", "tenant is not allowed for this service")
		return
	}
	for _, pr := range req.Providers {
		if pr != credvault.Codex {
			svcRunError(w, http.StatusBadRequest, "invalid_argument",
				"a standing service pass covers codex only (in the cluster the subscriptions serve Codex; Claude stays on the Mac mini)")
			return
		}
	}
	ttl := SessionCredTTL
	if req.TTLSeconds != 0 {
		ttl = time.Duration(req.TTLSeconds) * time.Second
		if ttl < sessionCredMinTTL || ttl > SessionCredTTL {
			svcRunError(w, http.StatusBadRequest, "invalid_argument",
				fmt.Sprintf("ttl_seconds must be %d…%d", int(sessionCredMinTTL.Seconds()), int(SessionCredTTL.Seconds())))
			return
		}
	}
	choices, err := s.sessionBindChoices(p.ID, "", credvault.Codex)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if len(choices) == 0 {
		refuse(http.StatusForbidden, "no_credential", "no codex subscription that "+p.ID+"'s allowlist permits"+
			s.noBindWhy(p.ID, "", credvault.Codex))
		return
	}
	if st, over := s.svcBudgetRefusal(p.ID, tenant, s.budgetClock()); over {
		refuse(http.StatusTooManyRequests, st.ErrorCode, "this service is over its budget")
		return
	}
	var rnd [16]byte
	if _, err := rand.Read(rnd[:]); err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	iat := now.Truncate(time.Second)
	v := 1
	if (req.Kind == "" || req.Kind == SessionCredKindH2) && len(s.RelaySignKey) == ed25519.PrivateKeySize {
		v = 2
	}
	worker := svcStandingWorkerPrefix + p.Name
	claims := sessionCredClaims{V: v, ID: "sc_" + hex.EncodeToString(rnd[:]), Principal: p.ID, WorkerID: worker,
		Machine: svcStandingMachine, Providers: svcStandingProviders, Iat: iat.Unix(), Exp: iat.Add(ttl).Unix(),
		Svc: p.Name, Tenant: tenant}
	if err := s.Store.AddSessionCred(store.SessionCred{ID: claims.ID, PrincipalID: p.ID, WorkerID: worker,
		Tenant: tenant, WorkerKey: svcStandingTokenWord + prefix, Machine: svcStandingMachine, Providers: claims.Providers,
		IssuedAt: iat, ExpiresAt: time.Unix(claims.Exp, 0)}); err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	s.svcAudit(p.ID, "svc.pass.issue", p.ID, "ok", "pass "+claims.ID+" (codex) until "+
		time.Unix(claims.Exp, 0).UTC().Format(time.RFC3339)+" · token "+prefix+fmt.Sprintf(" · tenant=%q", tenant), now)
	writeJSON(w, http.StatusOK, sessionCredAnswer(s.signSessionPass(claims), claims))
}

// handleSvcPassRenew is renewSessionCred for a standing pass: the caller is
// the pass's own principal (any of its live tokens), not a node.
func (s *Server) handleSvcPassRenew(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", "POST")
		httpError(w, http.StatusMethodNotAllowed, "POST {cred}")
		return
	}
	now := time.Now()
	p, _, _ := SvcCallerOf(r.Context())
	if len(s.SessionCredKey) == 0 {
		svcRunError(w, http.StatusServiceUnavailable, SessionCredOff, "session passes are off on this hub")
		return
	}
	var req struct {
		Cred string `json:"cred"`
	}
	if err := readOptionalJSON(r, &req); err != nil || req.Cred == "" {
		svcRunError(w, http.StatusBadRequest, "invalid_argument", "body must be {\"cred\": \"fcp-h1.…\" | \"fcp-h2.…\"}")
		return
	}
	tenant := ""
	refuse := func(status int, code, msg string) {
		s.svcAudit(p.ID, "svc.pass.renew", p.ID, "REFUSED", fmt.Sprintf("tenant=%q · %s: %s", tenant, code, msg), now)
		svcRunError(w, status, code, msg)
	}
	at := now
	pc, why := s.parseSessionPass(req.Cred, now)
	if pc != nil {
		tenant = pc.Tenant
	}
	if why == "expired" && pc != nil {
		at = time.Unix(pc.Exp-1, 0) // a lapsed pass is judged as of its last second (#2012)
	}
	v, c := s.verifySessionCred(req.Cred, "", "", true, at)
	if !v.Valid {
		refuse(http.StatusForbidden, "invalid", v.Reason)
		return
	}
	if c.Principal != p.ID || c.Machine != svcStandingMachine {
		refuse(http.StatusNotFound, "not_found", "no such standing pass for "+p.ID)
		return
	}
	row, err := s.Store.SessionCredByID(c.ID)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	lapsed := !row.ExpiresAt.After(now)
	if lapsed && !row.ExpiresAt.Add(SessionCredRenewGrace).After(now) {
		refuse(http.StatusForbidden, "invalid", "the pass ran out "+row.ExpiresAt.UTC().Format(time.RFC3339)+", past the renewal grace")
		return
	}
	ttl := time.Duration(c.Exp-c.Iat) * time.Second
	if ttl < sessionCredMinTTL || ttl > SessionCredTTL {
		ttl = SessionCredTTL
	}
	iat := now.Truncate(time.Second)
	nc := *c
	nc.Iat, nc.Exp = iat.Unix(), iat.Add(ttl).Unix()
	ok, err := s.Store.RenewSessionCred(c.ID, time.Unix(nc.Exp, 0), now, now.Add(-SessionCredRenewGrace))
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	s.sessCred.drop(c.ID)
	if !ok {
		refuse(http.StatusForbidden, "invalid", "the pass was revoked or ran out")
		return
	}
	s.svcAudit(p.ID, "svc.pass.renew", p.ID, "ok", "pass "+c.ID+optional(" (lapsed)", lapsed)+" until "+
		time.Unix(nc.Exp, 0).UTC().Format(time.RFC3339)+fmt.Sprintf(" · tenant=%q", c.Tenant), now)
	writeJSON(w, http.StatusOK, sessionCredAnswer(s.signSessionPass(nc), nc))
}

// svcStandingRevoked is why a standing pass no longer holds — the token that
// minted it is revoked or expired, or its principal disabled or gone — or "".
func (s *Server) svcStandingRevoked(row store.SessionCred, now time.Time) (string, error) {
	prefix, ok := strings.CutPrefix(row.WorkerKey, svcStandingTokenWord)
	if !ok {
		return "its service token is not on record", nil
	}
	t, err := s.Store.SvcTokenByPrefix(prefix)
	if errors.Is(err, store.ErrNoSvcToken) {
		return "its service token " + prefix + " is gone", nil
	}
	if err != nil {
		return "", err
	}
	if t.Principal != row.PrincipalID {
		return "its service token is another principal's", nil
	}
	if !t.Live(now) {
		return "its service token " + prefix + " was revoked or ran out", nil
	}
	p, err := s.Store.SvcPrincipal(row.PrincipalID)
	if errors.Is(err, store.ErrNoSvcPrincipal) {
		return "the service " + row.PrincipalID + " is gone", nil
	}
	if err != nil {
		return "", err
	}
	if !p.Enabled {
		return "the service " + row.PrincipalID + " is disabled", nil
	}
	return "", nil
}
