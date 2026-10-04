package api

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"strings"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// People and their logins on every machine (claude-fleet#1411).
//
// A person signs in through WeCom; the SSO subject (their WeCom userid) is
// their principal. The hub mints ONE login name for them and keeps, per
// machine, whether that login exists there. Opening it is not the hub's to do
// — the hub cannot reach a machine — so it is an op sent down the machine's
// control channel to its admin agent: the operator's own login there, which
// already has password-less sudo, running claude-fleet's own onboarding
// script with arguments the node fixes itself.
//
// Two rails keep "only see your own" true at the hub: every view of the fleet
// a signed-in person gets is filtered through FleetScope, and only the
// operator (a shared viewer token or a tailnet identity — never a WeCom
// session) can assign, adopt or remove.

// principalKey carries the WeCom subject of an SSO-authenticated request.
type principalKey struct{}

// principalOf names the person behind r, or "" when the request did not come
// through WeCom (the shared viewer token or a tailnet identity — the
// operator's doors, which see every node as they always have).
func principalOf(ctx context.Context) string {
	p, _ := ctx.Value(principalKey{}).(string)
	return p
}

// FleetScope is the hub-side half of "only see your own" for every fleet view
// (the roster here, C2's fleet and session lists): nil means the caller sees
// everything; otherwise only the (machine, login) pairs it returns true for.
// A person sees exactly their ACTIVE logins — a pending or failed one has no
// fleet to show, and a login merely sharing their name on a machine the hub
// never assigned them is not theirs.
func (s *Server) FleetScope(r *http.Request) (func(hostname, osUser string) bool, error) {
	pid := principalOf(r.Context())
	if pid == "" {
		return nil, nil
	}
	accts, err := s.Store.FleetAccounts(pid)
	if err != nil {
		return nil, err
	}
	mine := map[[2]string]bool{}
	for _, a := range accts {
		if a.State == store.AccountActive {
			mine[[2]string{a.Hostname, a.Login}] = true
		}
	}
	return func(hostname, osUser string) bool { return mine[[2]string{hostname, osUser}] }, nil
}

// operatorOnly refuses a signed-in person: account assignment is the
// operator's, not something a colleague can widen for themselves. Mounted
// INSIDE viewerOnly, so it only ever sees an already-admitted request.
func (s *Server) operatorOnly(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if principalOf(r.Context()) != "" {
			httpError(w, http.StatusForbidden, "only the operator can change accounts")
			return
		}
		next.ServeHTTP(w, r)
	})
}

func (s *Server) isFleetAdmin(osUser string) bool {
	if osUser == "" {
		return false
	}
	for _, a := range s.FleetAdmins {
		if a == osUser {
			return true
		}
	}
	return false
}

// onPrincipalSignIn records a person at their WeCom sign-in and queues their
// login on every auto-assigned machine. Never in the way of the sign-in: a
// failure here is logged, and the person is still let in.
func (s *Server) onPrincipalSignIn(sub string) {
	if !s.Fleet {
		return
	}
	now := time.Now()
	p, err := s.Store.EnsurePrincipal(sub, "", control.MaxLoginLen, control.ValidLogin, now)
	if err != nil {
		log.Printf("fleet: record principal %q: %v", sub, err)
		return
	}
	queued := false
	for _, host := range s.FleetAutoAssign {
		created, err := s.Store.RequestAccount(p, host, false, now)
		if err != nil {
			log.Printf("fleet: queue %s on %s: %v", p.Login, host, err)
			continue
		}
		if created {
			log.Printf("fleet: first sign-in of %s: queued login %s on %s", sub, p.Login, host)
			queued = true
		}
	}
	if queued {
		go s.dispatchAccounts()
	}
}

// fullNameFor is the display name sysadminctl gets: the person's name when the
// hub knows one the node will accept, else their userid, else the login.
func fullNameFor(p *store.Principal) string {
	for _, n := range []string{p.DisplayName, p.ID} {
		if control.ValidFullName(n) {
			return n
		}
	}
	return p.Login
}

// dispatchAccounts sends every queued account op whose machine has an admin
// node connected. Each op is recorded as sent BEFORE it is written to the
// link; one that provably never left goes back in the queue, one whose write
// failed half-way is unknown and waits for the operator or the node's answer.
func (s *Server) dispatchAccounts() {
	if !s.Fleet {
		return
	}
	s.accountsMu.Lock()
	defer s.accountsMu.Unlock()
	rows, err := s.Store.FleetAccountsInState(store.AccountPending, store.AccountRemovePending)
	if err != nil {
		log.Printf("fleet: read queued account ops: %v", err)
		return
	}
	for _, a := range rows {
		epID, ok := s.nodes.adminFor(a.Hostname)
		if !ok {
			continue
		}
		op := control.AccountOp{Op: control.AccountCreate, Login: a.Login}
		from, to := store.AccountPending, store.AccountCreating
		if a.State == store.AccountRemovePending {
			op.Op, from, to = control.AccountRemove, store.AccountRemovePending, store.AccountRemoving
		} else {
			p, err := s.Store.Principal(a.PrincipalID)
			if err != nil {
				log.Printf("fleet: principal %q for %s: %v", a.PrincipalID, a.Hostname, err)
				continue
			}
			op.FullName = fullNameFor(p)
		}
		msg, err := control.New(control.TypeAccountOp, op)
		if err != nil {
			continue
		}
		now := time.Now()
		sent, err := s.Store.MarkAccountSent(a.PrincipalID, a.Hostname, from, to, msg.OpID, epID, now)
		if err != nil || !sent {
			continue
		}
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		err = s.SendNodeWrite(ctx, epID, msg)
		cancel()
		switch {
		case err == nil:
			log.Printf("fleet: sent %s %s to %s (op %s)", op.Op, a.Login, a.Hostname, msg.OpID)
		case errors.Is(err, ErrNodeOffline), errors.Is(err, control.ErrIncompatible):
			_ = s.Store.RevertAccountSent(msg.OpID, from, "not sent: "+err.Error(), time.Now())
		default:
			_, _ = s.Store.FinishAccountOp(msg.OpID, epID, store.AccountUnknown, "send failed: "+err.Error(), time.Now())
		}
	}
}

// applyAccountResult records a node's answer to an account op and acks it, so
// the node stops re-sending it. A result from a node that is not an admin is
// refused; a duplicate or stale one is acked and changes nothing.
func (s *Server) applyAccountResult(ctx context.Context, conn *websocket.Conn, epID string, nc *nodeConn, m control.Message) {
	if !nc.admin {
		refuse(ctx, conn, m.OpID, control.CodeNotAdmin, "this node is not an admin node")
		return
	}
	var res control.AccountResult
	if err := json.Unmarshal(m.Payload, &res); err != nil {
		refuse(ctx, conn, m.OpID, control.CodeBadMessage, "malformed account result")
		return
	}
	state, detail := store.AccountFailed, res.Detail
	switch {
	case res.OK && res.Op == control.AccountCreate:
		state = store.AccountActive
	case res.OK && res.Op == control.AccountRemove:
		state = store.AccountRemoved
	case res.Exists:
		// Never success: the name may be someone else's login. The operator
		// adopts it if it is this person's.
		detail = "a login with this name already exists on this machine; adopt it only if it is theirs. " + detail
	}
	if _, err := s.Store.FinishAccountOp(m.OpID, epID, state, truncate(detail, 4000), time.Now()); err != nil {
		log.Printf("fleet: record account result %s: %v", m.OpID, err)
		return // no ack: the node re-sends it on the next connection
	}
	ack := control.Message{Type: control.TypeAck, OpID: m.OpID, Proto: control.Proto}
	wctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	_ = wsjson.Write(wctx, conn, ack)
}

// applyAccountRefusal records a node refusing an op outright (not an admin,
// arguments off its whitelist): the op did not run.
func (s *Server) applyAccountRefusal(epID string, m control.Message) {
	if _, err := s.Store.FinishAccountOp(m.OpID, epID, store.AccountFailed,
		"node refused: "+m.Error.Code+": "+m.Error.Message, time.Now()); err != nil {
		log.Printf("fleet: record account refusal %s: %v", m.OpID, err)
	}
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[len(s)-n:]
}

// FleetMe is the body of /v1/fleet/me.
type FleetMe struct {
	Principal *store.Principal     `json:"principal"`
	Accounts  []store.FleetAccount `json:"accounts"`
}

// handleFleetMe tells a signed-in person who the hub thinks they are and where
// their login exists. The operator's doors name no person: principal null.
func (s *Server) handleFleetMe(w http.ResponseWriter, r *http.Request) {
	out := FleetMe{Accounts: []store.FleetAccount{}}
	if pid := principalOf(r.Context()); pid != "" {
		p, err := s.Store.Principal(pid)
		if err != nil && !errors.Is(err, store.ErrNoPrincipal) {
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
		if p != nil {
			out.Principal = p
			if out.Accounts, err = s.Store.FleetAccounts(pid); err != nil {
				httpError(w, http.StatusInternalServerError, err.Error())
				return
			}
		}
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, out)
}

// FleetAccountsView is the body of GET /v1/fleet/accounts.
type FleetAccountsView struct {
	Principals []store.Principal    `json:"principals"`
	Accounts   []store.FleetAccount `json:"accounts"`
}

// FleetAccountRequest is the body of POST /v1/fleet/accounts.
//
//	assign  queue the person's login on hostname (creates the person if new)
//	retry   re-queue a create that failed, went unknown or was removed
//	remove  close the login on hostname (the home is archived, not deleted)
//	adopt   record a login that already exists there as theirs; runs nothing
type FleetAccountRequest struct {
	Action      string `json:"action"`
	PrincipalID string `json:"principal_id"`
	Hostname    string `json:"hostname"`
	Login       string `json:"login,omitempty"`
	DisplayName string `json:"display_name,omitempty"`
}

// handleFleetAccounts is the operator's view and control of every account.
func (s *Server) handleFleetAccounts(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		ps, err := s.Store.Principals()
		if err != nil {
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
		as, err := s.Store.FleetAccounts("")
		if err != nil {
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
		w.Header().Set("Cache-Control", "no-store")
		writeJSON(w, http.StatusOK, FleetAccountsView{Principals: ps, Accounts: as})
	case http.MethodPost:
		var req FleetAccountRequest
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<16)).Decode(&req); err != nil {
			httpError(w, http.StatusBadRequest, "malformed request")
			return
		}
		req.PrincipalID, req.Hostname = strings.TrimSpace(req.PrincipalID), strings.TrimSpace(req.Hostname)
		if req.PrincipalID == "" || req.Hostname == "" {
			httpError(w, http.StatusBadRequest, "principal_id and hostname are required")
			return
		}
		if req.DisplayName != "" && !control.ValidFullName(req.DisplayName) {
			httpError(w, http.StatusBadRequest, "display_name must be 1-64 printable characters")
			return
		}
		if err := s.changeAccount(req); err != nil {
			code := http.StatusBadRequest
			if errors.Is(err, store.ErrAccountState) {
				code = http.StatusConflict
			}
			httpError(w, code, err.Error())
			return
		}
		go s.dispatchAccounts()
		as, err := s.Store.FleetAccounts(req.PrincipalID)
		if err != nil {
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"accounts": as})
	default:
		w.Header().Set("Allow", "GET, POST")
		httpError(w, http.StatusMethodNotAllowed, "GET or POST")
	}
}

func (s *Server) changeAccount(req FleetAccountRequest) error {
	now := time.Now()
	switch req.Action {
	case "assign", "retry":
		p, err := s.Store.EnsurePrincipal(req.PrincipalID, req.DisplayName, control.MaxLoginLen, control.ValidLogin, now)
		if err != nil {
			return err
		}
		_, err = s.Store.RequestAccount(p, req.Hostname, req.Action == "retry", now)
		return err
	case "adopt":
		if !control.ValidLogin(req.Login) {
			return errors.New("adopt needs a login of 2-16 lowercase letters and digits")
		}
		p, err := s.Store.AdoptPrincipal(req.PrincipalID, req.Login, req.DisplayName, now)
		if err != nil {
			return err
		}
		return s.Store.AdoptAccount(p, req.Hostname, now)
	case "remove":
		return s.Store.RequestAccountRemoval(req.PrincipalID, req.Hostname, now)
	default:
		return errors.New("action must be assign, retry, remove or adopt")
	}
}
