package api

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/credvault"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/fleetid"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// 会话通行证 — a session pass for a session on an untrusted machine
// (claude-fleet#1969, EPIC #1967 C2).
//
// C1 stopped handing subscription credentials to a machine the operator has
// not marked trusted. A session there still has to work, so it borrows a
// pass: good for ONE person and ONE session, at most a day, renewable while
// the session lives, and revocable at any moment. The machine's local proxy
// (C3/C5) hands it to the cluster credential proxy (C6) or the Singapore
// relay (C7) in place of a credential; they ask this hub whether it still
// holds, and swap in the real credential themselves — the credential never
// leaves the cluster.
//
//	fcp-h1.<base64url claims JSON>.<base64url HMAC-SHA256>
//
// keyed with SessionCredKey, which only the hub holds
// (CCQUOTA_FLEET_SESSION_CRED_KEY[_FILE]). Claims: v, id, principal,
// worker_id, machine, providers, iat, exp. The hub also keeps one row per
// pass (fleet_session_creds), which is what a revocation writes.
//
// Routes (all under /v1/fleet/session-cred):
//
//	POST   ""        issue — the node's enrollment token + the session's own
//	                 worker assertion (X-Fleet-Worker, #1810); body
//	                 {providers?, ttl_seconds?}
//	POST   /renew    the issuing node: {cred} → the same pass, a new exp
//	POST   /verify   the verifiers (CCQUOTA_FLEET_SESSION_CRED_VERIFY_TOKEN)
//	                 or the operator: {cred, principal?, provider?} →
//	                 {valid, principal, worker_id, machine, providers, exp, revoked}
//	GET|PUT /bind    a session's account binding, for the cluster credential
//	                 proxy (claude-fleet#1973): the issuing node or the operator
//	DELETE /<id>     the issuing node (the session wrapper at exit, C5) or the operator
//	GET    ""        the operator's list (?all=1 includes revoked / expired)
//
// A trusted machine may ask for one too (one interface for every machine);
// by default it leases credentials as before and never does. No key = the
// routes answer 503 session_cred_off and nothing else changes.

const (
	sessionCredPrefix = "fcp-h1"
	// SessionCredTTL is a pass's default (and longest) life.
	SessionCredTTL = 24 * time.Hour
	// sessionCredMinTTL is the shortest life a caller may ask for.
	sessionCredMinTTL = 5 * time.Minute
	// sessionCredRenewBefore is when the machine's proxy renews: this long
	// before exp (the answer's renew_after).
	sessionCredRenewBefore = 2 * time.Hour
	// SessionCredRenewGrace is how long after its newest expiry a pass that
	// was never revoked may still be renewed by its issuing node
	// (claude-fleet#2012): a laptop asleep through the renew window, or its
	// proxy down then, finds its session's pass lapsed — the session itself
	// is still alive (its wrapper revokes the pass at exit). Verify still
	// refuses a lapsed pass; only /renew takes it back. Mirrors
	// HUB_RENEW_GRACE in bin/fleet-cred-proxy.py.
	SessionCredRenewGrace = 7 * 24 * time.Hour
	// sessionCredCacheTTL bounds how stale a verify may be: a revocation
	// made on another replica (or straight in the store) is seen within it.
	// One made through this hub's own routes is seen at once.
	sessionCredCacheTTL = 30 * time.Second

	// Refusal reasons (the "error" of a non-200 answer).
	SessionCredOff = "session_cred_off"
)

// sessionCredProviders are what a pass can cover: the subscriptions. GitHub
// stays each person's own login (EPIC #1967 «这批不做»).
var sessionCredProviders = []string{credvault.Claude, credvault.Codex}

// sessionCredClaims is a pass's signed content.
type sessionCredClaims struct {
	V         int      `json:"v"`
	ID        string   `json:"id"`
	Principal string   `json:"principal"`
	WorkerID  string   `json:"worker_id"`
	Machine   string   `json:"machine"`
	Providers []string `json:"providers"`
	Iat       int64    `json:"iat"`
	Exp       int64    `json:"exp"`
}

// LoadSessionCredKey reads the pass signing key:
// CCQUOTA_FLEET_SESSION_CRED_KEY_FILE (a Secret mount) wins over
// CCQUOTA_FLEET_SESSION_CRED_KEY. Either holds 32 bytes, base64 encoded.
// ok is false when neither is set.
func LoadSessionCredKey(getenv func(string) string) (key []byte, ok bool, err error) {
	raw := strings.TrimSpace(getenv("CCQUOTA_FLEET_SESSION_CRED_KEY"))
	if path := getenv("CCQUOTA_FLEET_SESSION_CRED_KEY_FILE"); path != "" {
		b, err := os.ReadFile(path)
		if err != nil {
			return nil, true, fmt.Errorf("read session pass key: %w", err)
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
	return nil, true, errors.New("session pass key must be 32 bytes, base64 encoded (openssl rand -base64 32)")
}

// signSessionCred is the hub's signature over a pass's claims.
func signSessionCred(c sessionCredClaims, key []byte) string {
	raw, _ := json.Marshal(c)
	body := sessionCredPrefix + "." + base64.RawURLEncoding.EncodeToString(raw)
	mac := hmac.New(sha256.New, key)
	mac.Write([]byte(body))
	return body + "." + base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
}

// parseSessionCred checks a pass's shape, signature and life — everything
// that needs no row. The reason is what verify reports.
func parseSessionCred(tok string, key []byte, now time.Time) (*sessionCredClaims, string) {
	parts := strings.Split(strings.TrimSpace(tok), ".")
	if len(parts) != 3 || parts[0] != sessionCredPrefix {
		return nil, "malformed"
	}
	got, err := base64.RawURLEncoding.DecodeString(strings.TrimRight(parts[2], "="))
	if err != nil {
		return nil, "malformed"
	}
	mac := hmac.New(sha256.New, key)
	mac.Write([]byte(parts[0] + "." + parts[1]))
	if !hmac.Equal(mac.Sum(nil), got) {
		return nil, "signature does not verify (not issued by this hub)"
	}
	raw, err := base64.RawURLEncoding.DecodeString(strings.TrimRight(parts[1], "="))
	if err != nil {
		return nil, "malformed"
	}
	var c sessionCredClaims
	if err := json.Unmarshal(raw, &c); err != nil || c.V != 1 || c.ID == "" {
		return nil, "malformed claims"
	}
	if !time.Unix(c.Exp, 0).After(now) {
		return &c, "expired"
	}
	return &c, ""
}

// sessionCredCache keeps each pass's row (and its machine / person
// revocation) for at most sessionCredCacheTTL.
type sessionCredCache struct {
	mu sync.Mutex
	m  map[string]sessionCredEntry
}

type sessionCredEntry struct {
	row    store.SessionCred
	revWhy string // a machine / person revocation, "" for none
	at     time.Time
}

func (c *sessionCredCache) get(id string, now time.Time) (sessionCredEntry, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	e, ok := c.m[id]
	if !ok || now.Sub(e.at) >= sessionCredCacheTTL || now.Before(e.at) {
		return e, false
	}
	return e, true
}

func (c *sessionCredCache) put(id string, e sessionCredEntry) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.m == nil {
		c.m = map[string]sessionCredEntry{}
	}
	for k, old := range c.m { // keep it small: drop what has gone stale
		if e.at.Sub(old.at) >= sessionCredCacheTTL {
			delete(c.m, k)
		}
	}
	c.m[id] = e
}

// drop forgets one pass, or every pass for id "".
func (c *sessionCredCache) drop(id string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if id == "" {
		c.m = nil
		return
	}
	delete(c.m, id)
}

// SessionCredView is verify's answer.
type SessionCredView struct {
	Valid     bool     `json:"valid"`
	Reason    string   `json:"reason,omitempty"`
	ID        string   `json:"id,omitempty"`
	Principal string   `json:"principal,omitempty"`
	WorkerID  string   `json:"worker_id,omitempty"`
	Machine   string   `json:"machine,omitempty"`
	Providers []string `json:"providers,omitempty"`
	Exp       int64    `json:"exp,omitempty"`
	Revoked   bool     `json:"revoked"`
}

// verifySessionCred is the whole check: signature, life, the row (cached
// ≤ sessionCredCacheTTL unless fresh), its revocation, and the machine's /
// person's. wantPrincipal / wantProvider narrow it when the verifier knows
// whom the request is for, or which provider it is going to.
func (s *Server) verifySessionCred(tok, wantPrincipal, wantProvider string, fresh bool, now time.Time) (SessionCredView, *sessionCredClaims) {
	if len(s.SessionCredKey) == 0 {
		return SessionCredView{Reason: SessionCredOff}, nil
	}
	c, why := parseSessionCred(tok, s.SessionCredKey, now)
	if c == nil {
		return SessionCredView{Reason: why}, nil
	}
	v := SessionCredView{ID: c.ID, Principal: c.Principal, WorkerID: c.WorkerID, Machine: c.Machine,
		Providers: c.Providers, Exp: c.Exp}
	if why != "" {
		v.Reason = why
		return v, c
	}
	e, ok := s.sessCred.get(c.ID, now)
	if !ok || fresh {
		row, err := s.Store.SessionCredByID(c.ID)
		if errors.Is(err, store.ErrNoSessionCred) {
			v.Reason = "unknown pass"
			return v, c
		}
		if err != nil {
			v.Reason = "hub error: " + err.Error()
			return v, c
		}
		e = sessionCredEntry{row: row, at: now}
		rev, err := s.Store.RevokedFor(row.Machine, row.PrincipalID)
		if err != nil {
			v.Reason = "hub error: " + err.Error()
			return v, c
		}
		if rev != nil {
			e.revWhy = "this machine"
			switch {
			case rev.Hostname != "" && rev.PrincipalID != "":
				e.revWhy = "this person on this machine"
			case rev.Hostname == "":
				e.revWhy = "this person"
			}
			e.revWhy += " was revoked at " + rev.RevokedAt.Format(time.RFC3339)
		}
		s.sessCred.put(c.ID, e)
	}
	row := e.row
	switch {
	case row.PrincipalID != c.Principal || row.WorkerID != c.WorkerID || row.Machine != c.Machine:
		v.Reason = "does not match the pass on record"
	case row.RevokedAt != nil:
		v.Revoked, v.Reason = true, "revoked at "+row.RevokedAt.Format(time.RFC3339)+optional(" by "+row.RevokedBy, row.RevokedBy != "")
	case e.revWhy != "":
		v.Revoked, v.Reason = true, e.revWhy
	case wantPrincipal != "" && wantPrincipal != c.Principal:
		v.Reason = "issued to another principal"
	case wantProvider != "" && !hasString(c.Providers, wantProvider):
		v.Reason = "does not cover " + wantProvider
	default:
		v.Valid = true
	}
	return v, c
}

// sessionCredNode is the node a bearer token enrolls, nil when it is none.
func (s *Server) sessionCredNode(r *http.Request) (*store.Endpoint, string) {
	tok := bearer(r)
	if tok == "" {
		return nil, ""
	}
	ep, err := s.Store.EndpointByTokenHash(HashToken(tok))
	if err != nil {
		return nil, ""
	}
	return ep, tok
}

func sessionCredRefuse(w http.ResponseWriter, code int, reason, msg string) {
	writeJSON(w, code, map[string]string{"error": reason, "message": msg})
}

// handleSessionCred routes /v1/fleet/session-cred[/…].
func (s *Server) handleSessionCred(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	if len(s.SessionCredKey) == 0 {
		sessionCredRefuse(w, http.StatusServiceUnavailable, SessionCredOff,
			"session passes are off on this hub (no CCQUOTA_FLEET_SESSION_CRED_KEY)")
		return
	}
	sub := strings.Trim(strings.TrimPrefix(r.URL.Path, "/v1/fleet/session-cred"), "/")
	ep, tok := s.sessionCredNode(r)
	operator := func(h http.HandlerFunc) { s.viewerOnly(s.adminOnly(h)).ServeHTTP(w, r) }
	switch {
	case sub == "" && r.Method == http.MethodPost:
		if ep == nil {
			sessionCredRefuse(w, http.StatusUnauthorized, "unauthenticated", "a node's enrollment token is required")
			return
		}
		s.issueSessionCred(w, r, ep, tok)
	case sub == "" && r.Method == http.MethodGet:
		operator(s.listSessionCreds)
	case sub == "verify" && r.Method == http.MethodPost:
		if s.SessionCredVerifyToken != "" && constantTimeEqual(bearer(r), s.SessionCredVerifyToken) {
			s.handleSessionCredVerify(w, r)
			return
		}
		operator(s.handleSessionCredVerify)
	case sub == "bind" && (r.Method == http.MethodGet || r.Method == http.MethodPut):
		// a session's account binding (claude-fleet#1973, fleet_credproxy.go)
		if ep != nil {
			s.handleSessionBind(w, r, ep)
			return
		}
		operator(func(w http.ResponseWriter, r *http.Request) { s.handleSessionBind(w, r, nil) })
	case sub == "renew" && r.Method == http.MethodPost:
		if ep == nil {
			sessionCredRefuse(w, http.StatusUnauthorized, "unauthenticated", "the issuing node's enrollment token is required")
			return
		}
		s.renewSessionCred(w, r, ep)
	case sub != "" && !strings.Contains(sub, "/") && sub != "verify" && sub != "renew" && sub != "bind" && r.Method == http.MethodDelete:
		if ep != nil {
			s.revokeSessionCred(w, r, sub, ep)
			return
		}
		operator(func(w http.ResponseWriter, r *http.Request) { s.revokeSessionCred(w, r, sub, nil) })
	default:
		httpError(w, http.StatusMethodNotAllowed, "POST (issue) · GET (list) · POST /verify · POST /renew · GET|PUT /bind · DELETE /<id>")
	}
}

// sessionCredIssueRequest is the (optional) body of an issue.
type sessionCredIssueRequest struct {
	Providers  []string `json:"providers"`
	TTLSeconds int      `json:"ttl_seconds"`
}

// SessionCredResponse is the answer to an issue or a renewal.
type SessionCredResponse struct {
	Cred        string    `json:"cred"`
	ID          string    `json:"id"`
	PrincipalID string    `json:"principal_id"`
	WorkerID    string    `json:"worker_id"`
	Machine     string    `json:"machine"`
	Providers   []string  `json:"providers"`
	IssuedAt    time.Time `json:"issued_at"`
	ExpiresAt   time.Time `json:"expires_at"`
	RenewAfter  time.Time `json:"renew_after"`
}

func sessionCredAnswer(tok string, c sessionCredClaims) SessionCredResponse {
	iat, exp := time.Unix(c.Iat, 0).UTC(), time.Unix(c.Exp, 0).UTC()
	renew := exp.Add(-sessionCredRenewBefore)
	if half := iat.Add(exp.Sub(iat) / 2); renew.Before(half) {
		renew = half // a short pass renews at half-life
	}
	return SessionCredResponse{Cred: tok, ID: c.ID, PrincipalID: c.Principal, WorkerID: c.WorkerID,
		Machine: c.Machine, Providers: c.Providers, IssuedAt: iat, ExpiresAt: exp, RenewAfter: renew}
}

func readOptionalJSON(r *http.Request, v any) error {
	b, err := io.ReadAll(io.LimitReader(r.Body, 64<<10))
	if err != nil {
		return err
	}
	if strings.TrimSpace(string(b)) == "" {
		return nil
	}
	return json.Unmarshal(b, v)
}

// issueSessionCred signs a pass for the session the node vouches for — and
// only when the statement holds: signed with this node's token, for a fleet
// this node runs, on a login that is some active person who is not revoked.
func (s *Server) issueSessionCred(w http.ResponseWriter, r *http.Request, ep *store.Endpoint, tok string) {
	now := time.Now()
	host, user := s.nodeIdentity(ep)
	actor := "node:" + user + "@" + host
	audit := func(c *workerClaims, fleetID, outcome string) {
		if err := s.Store.FleetAuditWorker(actor, c.id(), c.label(), "session_cred", fleetID, outcome, "", now); err != nil {
			log.Printf("fleet audit: %v", err)
		}
	}
	a := strings.TrimSpace(r.Header.Get(workerAssertHeader))
	if a == "" {
		audit(nil, "", "refused:no assertion")
		sessionCredRefuse(w, http.StatusUnauthorized, "unauthenticated",
			"a session pass is for a session: the "+workerAssertHeader+" assertion is required")
		return
	}
	c, err := verifyWorkerAssertion(a, HashToken(tok), now)
	if err != nil {
		audit(nil, "", "refused:UNAUTHENTICATED")
		sessionCredRefuse(w, http.StatusUnauthorized, "unauthenticated", err.Error())
		return
	}
	fl, err := s.Store.Fleet(c.FleetUUID)
	if errors.Is(err, sql.ErrNoRows) && c.FleetUUID == fleetid.ClientFleetID(HashToken(tok)) {
		// A client-only computer's own session (claude-fleet#2136): it runs no
		// fleet, so no registry row — its fleet UUID is derived from this node's
		// token, and the machine / login are the node's own.
		fl, err = store.FleetRow{FleetID: c.FleetUUID, EndpointID: ep.ID}, nil
	}
	if errors.Is(err, sql.ErrNoRows) || (err == nil && fl.EndpointID != ep.ID) {
		audit(c, c.FleetUUID, "refused:NOT_FOUND")
		sessionCredRefuse(w, http.StatusNotFound, "not_found", "no such session on this node")
		return
	}
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if fl.Hostname != "" {
		host = fl.Hostname
	}
	if fl.OSUser != "" {
		user = fl.OSUser
	}
	var req sessionCredIssueRequest
	if err := readOptionalJSON(r, &req); err != nil {
		sessionCredRefuse(w, http.StatusBadRequest, "invalid_argument", "body: "+err.Error())
		return
	}
	providers := sessionCredProviders
	if len(req.Providers) > 0 {
		providers = nil
		for _, p := range req.Providers {
			if !hasString(sessionCredProviders, p) {
				sessionCredRefuse(w, http.StatusBadRequest, "invalid_argument", "providers: "+p+" is not one of "+strings.Join(sessionCredProviders, ", "))
				return
			}
			if !hasString(providers, p) {
				providers = append(providers, p)
			}
		}
	}
	ttl := SessionCredTTL
	if req.TTLSeconds != 0 {
		ttl = time.Duration(req.TTLSeconds) * time.Second
		if ttl < sessionCredMinTTL || ttl > SessionCredTTL {
			sessionCredRefuse(w, http.StatusBadRequest, "invalid_argument",
				fmt.Sprintf("ttl_seconds must be %d…%d", int(sessionCredMinTTL.Seconds()), int(SessionCredTTL.Seconds())))
			return
		}
	}
	principal, err := s.Store.PrincipalForLogin(host, user)
	if errors.Is(err, store.ErrNoPrincipal) {
		audit(c, fl.FleetID, "refused:"+LeaseNoPrincipal)
		sessionCredRefuse(w, http.StatusForbidden, LeaseNoPrincipal, "no active fleet account is "+user+" on "+host)
		return
	}
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if s.Store.IsDrill(principal) {
		audit(c, fl.FleetID, "refused:"+LeaseDrill)
		sessionCredRefuse(w, http.StatusForbidden, LeaseDrill, "a drill person gets no session pass")
		return
	}
	if rev, err := s.Store.RevokedFor(host, principal); err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	} else if rev != nil {
		audit(c, fl.FleetID, "refused:"+LeaseRevoked)
		sessionCredRefuse(w, http.StatusForbidden, LeaseRevoked, "revoked at "+rev.RevokedAt.Format(time.RFC3339))
		return
	}
	var rnd [16]byte
	if _, err := rand.Read(rnd[:]); err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	iat := now.Truncate(time.Second)
	claims := sessionCredClaims{V: 1, ID: "sc_" + hex.EncodeToString(rnd[:]), Principal: principal, WorkerID: c.WorkerID,
		Machine: host, Providers: providers, Iat: iat.Unix(), Exp: iat.Add(ttl).Unix()}
	row := store.SessionCred{ID: claims.ID, PrincipalID: principal, WorkerID: c.WorkerID, WorkerKey: c.label(),
		FleetID: fl.FleetID, Machine: host, OSUser: user, EndpointID: ep.ID, Providers: providers,
		IssuedAt: iat, ExpiresAt: time.Unix(claims.Exp, 0)}
	if err := s.Store.AddSessionCred(row); err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	trustSet, _ := s.trustSettings(now)
	audit(c, fl.FleetID, "issued "+claims.ID+" to "+principal+" ("+strings.Join(providers, ",")+") until "+
		time.Unix(claims.Exp, 0).UTC().Format(time.RFC3339)+" · "+trustOf(host, trustSet))
	writeJSON(w, http.StatusOK, sessionCredAnswer(signSessionCred(claims, s.SessionCredKey), claims))
}

// renewSessionCred hands the issuing node the same pass with a new expiry —
// as long as it still holds (fresh read, not the cache) and the login is
// still that person.
func (s *Server) renewSessionCred(w http.ResponseWriter, r *http.Request, ep *store.Endpoint) {
	now := time.Now()
	var req struct {
		Cred string `json:"cred"`
	}
	if err := readOptionalJSON(r, &req); err != nil || req.Cred == "" {
		sessionCredRefuse(w, http.StatusBadRequest, "invalid_argument", "body must be {\"cred\": \"fcp-h1.…\"}")
		return
	}
	// A lapsed pass (#2012) is checked as of its own last second: the row,
	// its revocation, the machine's and the person's all still apply.
	at := now
	if pc, why := parseSessionCred(req.Cred, s.SessionCredKey, now); why == "expired" && pc != nil {
		at = time.Unix(pc.Exp-1, 0)
	}
	v, c := s.verifySessionCred(req.Cred, "", "", true, at)
	if !v.Valid {
		sessionCredRefuse(w, http.StatusForbidden, "invalid", v.Reason)
		return
	}
	row, err := s.Store.SessionCredByID(c.ID)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	// The grace runs from the newest expiry on record — the session may
	// still hold the string it was born with, older than its last renewal.
	lapsed := !row.ExpiresAt.After(now)
	if lapsed && !row.ExpiresAt.Add(SessionCredRenewGrace).After(now) {
		sessionCredRefuse(w, http.StatusForbidden, "invalid", "the pass ran out "+row.ExpiresAt.UTC().Format(time.RFC3339)+", past the renewal grace")
		return
	}
	host, user := s.nodeIdentity(ep)
	actor := "node:" + user + "@" + host
	if row.EndpointID != ep.ID {
		sessionCredRefuse(w, http.StatusNotFound, "not_found", "no such pass on this node")
		return
	}
	if p, err := s.Store.PrincipalForLogin(row.Machine, row.OSUser); err != nil || p != row.PrincipalID {
		sessionCredRefuse(w, http.StatusForbidden, LeaseNoPrincipal, row.OSUser+" on "+row.Machine+" is no longer "+row.PrincipalID)
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
		sessionCredRefuse(w, http.StatusForbidden, "invalid", "the pass was revoked or ran out")
		return
	}
	if err := s.Store.FleetAuditWorker(actor, row.WorkerID, row.WorkerKey, "session_cred", row.FleetID,
		"renewed "+c.ID+optional(" (lapsed)", lapsed)+" until "+time.Unix(nc.Exp, 0).UTC().Format(time.RFC3339), "", now); err != nil {
		log.Printf("fleet audit: %v", err)
	}
	writeJSON(w, http.StatusOK, sessionCredAnswer(signSessionCred(nc, s.SessionCredKey), nc))
}

// handleSessionCredVerify answers a verifier.
func (s *Server) handleSessionCredVerify(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Cred      string `json:"cred"`
		Principal string `json:"principal"`
		Provider  string `json:"provider"`
	}
	if err := readOptionalJSON(r, &req); err != nil || req.Cred == "" {
		sessionCredRefuse(w, http.StatusBadRequest, "invalid_argument", "body must be {\"cred\": \"fcp-h1.…\"}")
		return
	}
	v, _ := s.verifySessionCred(req.Cred, req.Principal, req.Provider, false, time.Now())
	writeJSON(w, http.StatusOK, v)
}

// revokeSessionCred revokes one pass: the issuing node's (ep) or the
// operator's (ep nil). Effective at once on this hub; within
// sessionCredCacheTTL on any other.
func (s *Server) revokeSessionCred(w http.ResponseWriter, r *http.Request, id string, ep *store.Endpoint) {
	now := time.Now()
	row, err := s.Store.SessionCredByID(id)
	if errors.Is(err, store.ErrNoSessionCred) || (err == nil && ep != nil && row.EndpointID != ep.ID) {
		sessionCredRefuse(w, http.StatusNotFound, "not_found", "no such pass"+optional(" on this node", ep != nil))
		return
	}
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	actor := "operator"
	if ep != nil {
		host, user := s.nodeIdentity(ep)
		actor = "node:" + user + "@" + host
	}
	reason := strings.TrimSpace(r.URL.Query().Get("reason"))
	ok, err := s.Store.RevokeSessionCred(id, actor, reason, now)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	s.sessCred.drop(id)
	if ok {
		if err := s.Store.FleetAuditWorker(actor, row.WorkerID, row.WorkerKey, "session_cred", row.FleetID,
			"revoked "+id+optional(" ("+reason+")", reason != ""), "", now); err != nil {
			log.Printf("fleet audit: %v", err)
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"id": id, "revoked": true, "already": !ok})
}

// listSessionCreds is the operator's view: metadata only, never a pass.
func (s *Server) listSessionCreds(w http.ResponseWriter, r *http.Request) {
	all := r.URL.Query().Get("all") == "1"
	rows, err := s.Store.SessionCreds(!all, time.Now(), 500)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"session_creds": rows})
}
