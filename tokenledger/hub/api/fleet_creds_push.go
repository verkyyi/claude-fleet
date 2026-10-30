package api

import (
	"context"
	"log"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

// A changed credential, pushed (claude-fleet#3744).
//
// A node leased on its own clock — up to six hours apart — and kept every
// account its last lease wrote. So a pool subscription the operator deleted
// stayed on every machine, the proxy went on picking it, and a session bound
// to it got the upstream's 401 («OAuth token revoked · Please run /login»).
// Now the moment what a node may lease changes — a credential stored or
// deleted, a pool account paused or resumed, a revocation made or lifted —
// every connection whose hello listed CapCreds hears TypeCreds and leases at
// once; that lease's answer is the whole truth, and the node removes what it no
// longer lists. Nothing is remembered per connection: a push it misses is the
// next lease on its own clock. No capability → nothing sent, byte for byte.

// BroadcastCreds wakes every connection that leases on TypeCreds; why is for
// the node's log only (never a secret, never an account name).
func (s *Server) BroadcastCreds(why string) {
	msg, err := control.New(control.TypeCreds, control.Creds{Why: why})
	if err != nil {
		return
	}
	s.nodes.each(func(id string, c *nodeConn) {
		if !c.canCreds {
			return
		}
		go func(id string, c *nodeConn) {
			wctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			if s.nodes.get(id) != c {
				return
			}
			_ = s.SendNodeWrite(wctx, id, msg)
		}(id, c)
	})
}

// kickCredsFor wakes the lease of every login principal holds, on whichever
// replica holds its link (task GXR5). A spare's node leased while the spare sat
// idle and was denied everything; claiming it for a person, or writing that
// person's list, changed what the login may lease — and the node only heard on
// its 15-minute recheck, so a new member's first line got the proxy's 403
// 「this login holds no claude account」. Now it leases at once.
func (s *Server) kickCredsFor(principal, why string) {
	if s.Store == nil || principal == "" {
		return
	}
	accts, err := s.Store.FleetAccounts(principal)
	if err != nil {
		log.Printf("fleet: wake the leases of %s: %v", principal, err)
		return
	}
	for _, a := range accts {
		if a.Hostname != "" && a.Login != "" {
			s.kickCredsLogin(a.Hostname, a.Login, why)
		}
	}
}

// kickCredsLogin sends TypeCreds to login's own link on host: this replica's,
// else another's. No link, or one without CapCreds ⇒ its own recheck, as before.
func (s *Server) kickCredsLogin(host, login, why string) {
	msg, err := control.New(control.TypeCreds, control.Creds{Why: why})
	if err != nil {
		return
	}
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if id, _, err := s.loginRelayNode(host, login, func(c *nodeConn) bool { return c.canCreds }, "NO_CREDS", "a credential push"); err == nil {
			_ = s.SendNodeWrite(ctx, id, msg)
			return
		}
		if peer, ok := s.peerLoginLink(host, login, control.CapCreds); ok {
			if msg.Proto == 0 {
				msg.Proto = control.Proto
			}
			_ = s.forwardSend(ctx, peer, msg)
		}
	}()
}
