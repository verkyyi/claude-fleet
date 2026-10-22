package api

import (
	"errors"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

// Capacity and authentication failures must remain distinguishable. An empty
// provider inventory is capacity; an existing paused, restricted or expired
// credential stays the original refusal. Storage/policy errors never qualify.
var errNoProviderAccount = errors.New("provider has no subscription accounts")

func (s *Server) providerInventoryEmpty(principal, provider string) bool {
	for _, who := range []string{principal, store.PoolPrincipal} {
		rows, err := s.Store.Credentials(who)
		if err != nil {
			return false
		}
		for _, c := range rows {
			if c.Provider == provider {
				return false
			}
		}
	}
	return true
}
