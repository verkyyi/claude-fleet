package api

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/authz"
	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/fleetid"
)

// 只读控制台票据 — a read-only console ticket (task T844).
//
// An acceptance session the person dispatched has to photograph production's
// /app signed in as that person (phone 390 + desktop 1440, the A300 card),
// and had no lawful way in: no storageState, no sign-in it may do. Now the
// session asks the hub, as itself, for a ticket:
//
//	POST /v1/node/console-ticket   {"next": "/app/sessions", "ttl_sec": 900}
//
// authenticated by its node's enrollment token AND the session's own worker
// assertion (X-Fleet-Worker, the same pair /v1/fleet/session-cred takes). The
// hub reads whose login the node is (principalForLease — the person whose
// active fleet account it is; none ⇒ refused), checks that person is on the
// list, not revoked on that machine and the machine not off for them, and
// answers a ONE-TIME link good for consoleTicketTTL:
//
//	/auth/ticket?t=fct1.<claims>.<mac>
//
// Opened (once — its id is spent in fleet_sig_nonces, on every replica), it
// sets a session cookie marked RO (authz.Session.RO) for ttl_sec (at most
// consoleTicketSessionMax) and goes to next. That session is:
//
//   - the person's own, as a member (an admin's ticket never opens an admin
//     page, never looks through anyone else's eyes);
//   - reads only, whatever the route: viewAsGuard refuses every method but
//     GET/HEAD, a websocket and the conversation's relay, exactly as a view —
//     but for the person's own terminal session read along (ticketReadsSession,
//     task YP39), so an acceptance session can photograph it;
//   - never renewed and never anything else's: every reader but the gate's two
//     doors (personAdmit, sshRelayHTTPIdentity) takes it for no session.
//
// Every issuance and every redemption is one fleet_audit row
// (console_ticket / console_ticket_used), the issuing session's worker id on
// the first. Nothing bypasses a sign-in: the person signed in once to own the
// login the session runs on; a login no person owns gets no ticket.
const (
	ConsoleTicketNodePath = "/v1/node/console-ticket"
	ConsoleTicketPath     = "/auth/ticket"

	consoleTicketPrefix     = "fct1"
	consoleTicketTTL        = 2 * time.Minute
	consoleTicketSessionDef = 15 * time.Minute
	consoleTicketSessionMin = time.Minute
	consoleTicketSessionMax = 30 * time.Minute

	// consoleTicketNonceKey files a spent ticket's id in fleet_sig_nonces.
	consoleTicketNonceKey = "console-ticket"
)

const consoleTicketRefusal = "只读票据，不能改动（read-only console ticket: nothing can be changed）"

// consoleTicketClaims is a ticket's content.
type consoleTicketClaims struct {
	V        int    `json:"v"`
	ID       string `json:"jti"`
	Person   string `json:"pid"`
	WorkerID string `json:"wid,omitempty"`
	Next     string `json:"next"`
	TTLSec   int    `json:"ttl"`
	Iat      int64  `json:"iat"`
	Exp      int64  `json:"exp"`
}

// ConsoleTicketResponse is a granted POST /v1/node/console-ticket.
type ConsoleTicketResponse struct {
	// URL is the one-time link on the hub's public address; Path the same
	// without the address, for a caller that knows a better one.
	URL       string    `json:"url"`
	Path      string    `json:"path"`
	ID        string    `json:"id"`
	Person    string    `json:"person"`
	ExpiresAt time.Time `json:"expires_at"` // the link's
	TTLSec    int       `json:"session_ttl_sec"`
}

// consoleTicketKey signs tickets: the session key under a label of its own,
// so a ticket never verifies as a session and the other way round.
func (s *Server) consoleTicketKey() []byte {
	m := hmac.New(sha256.New, []byte(s.sessionKey()))
	m.Write([]byte("ccquota console ticket v1"))
	return m.Sum(nil)
}

func (s *Server) signConsoleTicket(c consoleTicketClaims) string {
	raw, _ := json.Marshal(c)
	body := consoleTicketPrefix + "." + base64.RawURLEncoding.EncodeToString(raw)
	m := hmac.New(sha256.New, s.consoleTicketKey())
	m.Write([]byte(body))
	return body + "." + base64.RawURLEncoding.EncodeToString(m.Sum(nil))
}

// verifyConsoleTicket is a ticket's claims when it is this hub's and in date.
func (s *Server) verifyConsoleTicket(t string, now time.Time) (*consoleTicketClaims, bool) {
	parts := strings.Split(t, ".")
	if len(parts) != 3 || parts[0] != consoleTicketPrefix {
		return nil, false
	}
	sig, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil {
		return nil, false
	}
	m := hmac.New(sha256.New, s.consoleTicketKey())
	m.Write([]byte(parts[0] + "." + parts[1]))
	if !hmac.Equal(sig, m.Sum(nil)) {
		return nil, false
	}
	raw, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return nil, false
	}
	var c consoleTicketClaims
	if json.Unmarshal(raw, &c) != nil || c.V != 1 || c.ID == "" || !isPerson(c.Person) || c.Exp < now.Unix() {
		return nil, false
	}
	return &c, true
}

// consoleTicketNext is where a redeemed ticket goes: a console page, never
// anything else (no open redirect) — the console's front page otherwise.
func consoleTicketNext(p string) string {
	p = strings.TrimSpace(p)
	if p == "" || strings.ContainsAny(p, "\\\r\n") || strings.HasPrefix(p, "//") {
		return AppPrefix
	}
	if p != AppPrefix && !strings.HasPrefix(p, AppPrefix+"/") && !strings.HasPrefix(p, AppPrefix+"?") {
		return AppPrefix
	}
	return p
}

// consoleTicketSub is the sign-in kind a ticket's session records: the
// person's GitHub, else the first way they have; "" when they have none.
func (s *Server) consoleTicketSub(pid string) string {
	if _, ok := githubIDOf(pid); ok {
		return store.IdentityGitHub
	}
	ids, err := s.Store.HubIdentities(pid)
	if err != nil {
		return ""
	}
	for _, i := range ids {
		if store.SignInKind(i.Kind) {
			return i.Kind
		}
	}
	return ""
}

// handleNodeConsoleTicket serves POST /v1/node/console-ticket.
func (s *Server) handleNodeConsoleTicket(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", "POST")
		httpError(w, http.StatusMethodNotAllowed, "POST")
		return
	}
	if !s.signinOn() || s.Store == nil {
		http.NotFound(w, r)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	ep, tokHash := s.sessionCredNode(r)
	if ep == nil {
		httpError(w, http.StatusUnauthorized, "a node's enrollment token is required")
		return
	}
	now := time.Now()
	host, user := s.nodeIdentity(ep)
	actor := "node:" + user + "@" + host
	audit := func(c *workerClaims, fleetID, outcome string) {
		if err := s.Store.FleetAuditWorker(actor, c.id(), c.label(), "console_ticket", fleetID, outcome, "", now); err != nil {
			log.Printf("fleet audit: %v", err)
		}
	}
	a := strings.TrimSpace(r.Header.Get(workerAssertHeader))
	if a == "" {
		audit(nil, "", "refused:no assertion")
		httpError(w, http.StatusUnauthorized, "a console ticket is for a session: the "+workerAssertHeader+" assertion is required")
		return
	}
	c, err := verifyWorkerAssertion(a, tokHash, now)
	if err != nil {
		audit(nil, "", "refused:UNAUTHENTICATED")
		httpError(w, http.StatusUnauthorized, err.Error())
		return
	}
	fl, err := s.Store.Fleet(c.FleetUUID)
	if errors.Is(err, sql.ErrNoRows) && c.FleetUUID == fleetid.ClientFleetID(tokHash) {
		fl, err = store.FleetRow{FleetID: c.FleetUUID, EndpointID: ep.ID}, nil
	}
	if errors.Is(err, sql.ErrNoRows) || (err == nil && fl.EndpointID != ep.ID) {
		audit(c, c.FleetUUID, "refused:NOT_FOUND")
		httpError(w, http.StatusNotFound, "no such session on this node")
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
	var req struct {
		Next   string `json:"next"`
		TTLSec int    `json:"ttl_sec"`
	}
	if err := readOptionalJSON(r, &req); err != nil {
		httpError(w, http.StatusBadRequest, "body: "+err.Error())
		return
	}
	ttl := consoleTicketSessionDef
	if req.TTLSec != 0 {
		ttl = time.Duration(req.TTLSec) * time.Second
		if ttl < consoleTicketSessionMin || ttl > consoleTicketSessionMax {
			httpError(w, http.StatusBadRequest, "ttl_sec must be 60…1800")
			return
		}
	}
	principal, err := s.principalForLease(ep.ID, host, user, now)
	if errors.Is(err, store.ErrNoPrincipal) {
		audit(c, fl.FleetID, "refused:"+LeaseNoPrincipal)
		httpError(w, http.StatusForbidden, "no active fleet account is "+user+" on "+host+": a ticket is only ever its owner's")
		return
	}
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	role, err := s.personRole(principal)
	if err != nil {
		httpError(w, http.StatusInternalServerError, "could not read the people list")
		return
	}
	if role != roleUser && role != roleAdmin {
		audit(c, fl.FleetID, "refused:not on the list")
		httpError(w, http.StatusForbidden, principal+" is not a member on this hub's list")
		return
	}
	if rev, err := s.Store.RevokedFor(host, principal); err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	} else if rev != nil {
		audit(c, fl.FleetID, "refused:"+LeaseRevoked)
		httpError(w, http.StatusForbidden, "revoked at "+rev.RevokedAt.Format(time.RFC3339))
		return
	}
	if mwhy, err := s.machineDeniedFor(ep.ID, host, principal); err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	} else if mwhy != "" {
		audit(c, fl.FleetID, "refused:"+LeaseMachineOff)
		httpError(w, http.StatusForbidden, MachineDisabledWord+"："+mwhy)
		return
	}
	if s.consoleTicketSub(principal) == "" {
		audit(c, fl.FleetID, "refused:no sign-in")
		httpError(w, http.StatusForbidden, principal+" has no way to sign in on this hub")
		return
	}
	var rnd [16]byte
	if _, err := rand.Read(rnd[:]); err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	iat := now.Truncate(time.Second)
	claims := consoleTicketClaims{V: 1, ID: "ct_" + hex.EncodeToString(rnd[:]), Person: principal, WorkerID: c.WorkerID,
		Next: consoleTicketNext(req.Next), TTLSec: int(ttl.Seconds()), Iat: iat.Unix(), Exp: iat.Add(consoleTicketTTL).Unix()}
	path := ConsoleTicketPath + "?t=" + s.signConsoleTicket(claims)
	audit(c, fl.FleetID, "issued "+claims.ID+" to "+principal+" read-only "+claims.Next+" for "+ttl.String())
	writeJSON(w, http.StatusOK, ConsoleTicketResponse{URL: s.hubURL(r) + path, Path: path, ID: claims.ID,
		Person: principal, ExpiresAt: time.Unix(claims.Exp, 0).UTC(), TTLSec: claims.TTLSec})
}

// handleConsoleTicket serves GET /auth/ticket?t=…: spends the ticket and sets
// its read-only session. Public: the ticket is the credential.
func (s *Server) handleConsoleTicket(w http.ResponseWriter, r *http.Request) {
	if !s.signinOn() || s.Store == nil || !s.Fleet {
		http.NotFound(w, r)
		return
	}
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Allow", "GET")
		httpError(w, http.StatusMethodNotAllowed, "GET only")
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Referrer-Policy", "no-referrer")
	now := time.Now()
	c, ok := s.verifyConsoleTicket(r.URL.Query().Get("t"), now)
	if !ok {
		http.Redirect(w, r, appURL("/signin")+"?e=expired", http.StatusFound)
		return
	}
	if r.Method == http.MethodHead {
		return // a link preview spends nothing
	}
	spent, err := s.Store.SpendSigNonce(consoleTicketNonceKey, c.ID, now, consoleTicketTTL+time.Minute)
	if err != nil {
		httpError(w, http.StatusInternalServerError, "could not read the ticket")
		return
	}
	if !spent {
		s.auditConsoleTicket(c, "refused:already used", now)
		http.Redirect(w, r, appURL("/signin")+"?e=expired", http.StatusFound)
		return
	}
	role, err := s.personRole(c.Person)
	if err != nil {
		httpError(w, http.StatusInternalServerError, "could not read the people list")
		return
	}
	sub := s.consoleTicketSub(c.Person)
	if (role != roleUser && role != roleAdmin) || sub == "" {
		s.auditConsoleTicket(c, "refused:not on the list", now)
		http.Redirect(w, r, appURL("/signin")+"?e=expired", http.StatusFound)
		return
	}
	ttl := time.Duration(c.TTLSec) * time.Second
	if ttl < consoleTicketSessionMin || ttl > consoleTicketSessionMax {
		ttl = consoleTicketSessionDef
	}
	http.SetCookie(w, &http.Cookie{
		Name:     authz.CookieName,
		Value:    authz.SignReadOnly(sub, c.Person, s.viewAsName(c.Person), roleUser, s.sessionKey(), now, ttl),
		Path:     "/",
		HttpOnly: true,
		SameSite: http.SameSiteLaxMode,
		Secure:   isHTTPS(r),
		MaxAge:   int(ttl.Seconds()),
	})
	s.auditConsoleTicket(c, "OK read-only "+c.Next+" for "+ttl.String(), now)
	http.Redirect(w, r, c.Next, http.StatusFound)
}

func (s *Server) auditConsoleTicket(c *consoleTicketClaims, outcome string, now time.Time) {
	if err := s.Store.FleetAuditWorker(c.Person, c.WorkerID, c.ID, "console_ticket_used", "", outcome, "", now); err != nil {
		log.Printf("fleet audit: %v", err)
	}
}

// consoleTicketAdmit is personAdmit's branch for a read-only ticket's
// session: the person's own pages as a member, reads only.
func (s *Server) consoleTicketAdmit(w http.ResponseWriter, r *http.Request, sess *authz.Session, role string) (context.Context, bool, bool) {
	if role != roleUser && role != roleAdmin {
		s.notFoundPage(w, r)
		return nil, true, true
	}
	if !viewAsReadable(r) && !ticketReadsSession(r) {
		httpError(w, http.StatusForbidden, consoleTicketRefusal)
		return nil, true, true
	}
	sub := sess.Principal()
	ctx := context.WithValue(withViewer(r.Context(), sub+" (read-only ticket)"), principalKey{}, sub)
	return withRole(withDoor(withSession(ctx, sess), doorGitHub), roleUser), true, false
}

// consoleTicketCookie: r's session cookie is a read-only ticket's.
func (s *Server) consoleTicketCookie(r *http.Request) bool {
	sess, _, ok := s.personSessionTicket(r)
	return ok && sess.RO
}
