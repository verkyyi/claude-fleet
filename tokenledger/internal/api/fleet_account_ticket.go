package api

import (
	"crypto/ed25519"
	"net/http"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/release"
)

// The admin seat's tickets (claude-fleet#3557, EPIC #3500 C15).
//
// A machine's admin agent moves off its admin login onto a role account that
// may run only two root-owned scripts, and those run an op only with a ticket
// this hub signed with its account-op key (CCQUOTA_FLEET_ACCOUNT_KEY, its own
// Secret — never the release key). Every op sent to a node that listed
// control.CapAdminSeat carries one: {op, login, machine, nonce = the op's
// OpID, exp}. No key: no ticket, no seat is ever picked, every op goes the old
// way — byte for byte (TestAccountTicketOffAddsNothing).

// SetAccountKey arms (or, with nil, disarms) ticket signing.
func (s *Server) SetAccountKey(key ed25519.PrivateKey) {
	s.accountKey = key
	s.nodes.seats.Store(key != nil)
}

// accountMessage is the TypeAccountOp message for op under opID, sent to
// endpointID on hostname: an admin seat's op carries its signed ticket.
func (s *Server) accountMessage(op control.AccountOp, opID, endpointID, hostname string, now time.Time) (control.Message, error) {
	if s.accountKey != nil && s.nodes.isAdminSeat(endpointID) {
		t, err := control.SignAccountTicket(s.accountKey, control.AccountTicket{Op: op.Op, Login: op.Login,
			Machine: hostname, Nonce: opID, Exp: now.Add(control.AccountTicketTTL).Unix()})
		if err != nil {
			return control.Message{}, err
		}
		op.Ticket = t
	}
	msg, err := control.New(control.TypeAccountOp, op)
	if err != nil {
		return msg, err
	}
	msg.OpID = opID
	return msg, nil
}

// handleAccountKey serves control.AccountKeyPath: the account-op public key,
// what a machine's root installer pins for its two scripts. 404 while off.
func (s *Server) handleAccountKey(w http.ResponseWriter, r *http.Request) {
	if s.accountKey == nil {
		http.NotFound(w, r)
		return
	}
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Allow", "GET, HEAD")
		httpError(w, http.StatusMethodNotAllowed, "GET only")
		return
	}
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	_, _ = w.Write([]byte(release.FormatPublicKey(s.accountKey.Public().(ed25519.PublicKey)) + "\n"))
}
