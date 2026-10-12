package api

import (
	"context"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
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
