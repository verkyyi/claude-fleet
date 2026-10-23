package api

import (
	"errors"
	"github.com/verkyyi/claude-fleet/tokenledger/hub/credvault"
	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/credproxy"
	"time"
)

var errClaudeAuthorization = errors.New("no_authorized_claude_subscription")

func (s *Server) claudeRouteBind(worker, principal, endpoint string, route credproxy.ClaudeRoute, now time.Time, configured ...store.ProviderCapacityCatalog) (store.SessionBind, store.ClaudeAffinity, error) {
	empty := store.ClaudeAffinity{}
	var cfg store.ProviderCapacityCatalog
	if len(configured) > 0 {
		cfg = configured[0]
	} else {
		cat, err := s.Store.PlanCapacities()
		if err != nil {
			return store.SessionBind{}, empty, err
		}
		cfg = cat.Catalog.Provider("claude")
	}
	if cfg.Mode != "active" {
		b, err := s.sessionBind(worker, principal, endpoint, credvault.Claude, now)
		return b, empty, err
	}
	if route.Unknown || route.Independent && len(route.References) > 0 {
		return store.SessionBind{}, empty, errors.New("unknown_request_shape")
	}
	choices, err := s.sessionBindChoices(principal, endpoint, credvault.Claude)
	if err != nil {
		return store.SessionBind{}, empty, err
	}
	if isSvcPrincipal(principal) {
		choices = s.svcYield(principal, choices, now)
	}
	b, err := s.Store.SessionBindFor(worker, credvault.Claude)
	if err != nil && !errors.Is(err, store.ErrNoSessionBind) {
		return b, empty, err
	}
	if errors.Is(err, store.ErrNoSessionBind) {
		b = store.SessionBind{WorkerID: worker, Provider: credvault.Claude}
	}
	if len(choices) == 0 {
		if s.providerInventoryEmpty(principal, credvault.Claude) {
			return b, empty, errNoProviderAccount
		}
		return b, empty, errClaudeAuthorization
	}
	inputs := s.claudeInputs(choices, b, cfg, route.Model, now)
	if !route.Independent {
		if !credproxy.ValidCodexReferences(route.References) {
			return b, empty, errors.New("unknown_reference")
		}
		a, err := s.Store.ClaudeAffinityFor(worker, route.References, now)
		if err != nil {
			return b, empty, err
		}
		for i, ch := range choices {
			if ch.PrincipalID == a.Owner && s.Vault.CredentialID(ch) == a.CredentialID {
				if !claudeEligible(inputs[i]) {
					return b, empty, errClaudeCapacity
				}
				return store.SessionBind{WorkerID: worker, Provider: credvault.Claude, Owner: ch.PrincipalID, Account: ch.Account}, a, nil
			}
		}
		return b, empty, errors.New("source_account_not_authorized")
	}
	pick, _ := claudeChoose(inputs, b, now, !isSvcPrincipal(principal))
	if pick < 0 {
		return b, empty, errClaudeCapacity
	}
	chosen := choices[pick]
	if b.Owner == chosen.PrincipalID && b.Account == chosen.Account {
		return b, empty, nil
	}
	next := store.SessionBind{WorkerID: worker, Provider: credvault.Claude, Owner: chosen.PrincipalID, Account: chosen.Account, SetBy: "claude:capacity"}
	if b.Rev == 0 {
		b, err = s.Store.PickSessionBind(next, now)
	} else {
		b, err = s.Store.CompareSessionBind(next, b.Rev, now)
	}
	// A concurrent winner must be reevaluated; never lease a different winner's
	// account using the losing request's quota/model decision.
	if err == nil && (b.Owner != next.Owner || b.Account != next.Account) {
		err = errors.New("binding_changed_retry")
	}
	return b, empty, err
}
