package api

import (
	"errors"
	"log"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/credvault"
	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/credproxy"
)

func (s *Server) codexAffinityChoice(principal, endpoint string, affinity store.CodexAffinity, now time.Time) (store.Credential, error) {
	choices, err := s.sessionBindChoices(principal, endpoint, credvault.Codex)
	if err != nil {
		return store.Credential{}, err
	}
	for _, ch := range choices {
		if ch.PrincipalID == affinity.Owner && s.Vault.CredentialID(ch) == affinity.CredentialID {
			if ch.RefreshError != "" || s.credAtLimit(ch, now) != "" {
				return ch, errors.New("source_account_unavailable")
			}
			return ch, nil
		}
	}
	return store.Credential{}, errors.New("source_account_not_authorized")
}

func (s *Server) codexAffinityBind(worker, principal, endpoint string, route credproxy.CodexRoute, now time.Time) (store.SessionBind, store.CodexAffinity, error) {
	fail := func(why string) (store.SessionBind, store.CodexAffinity, error) {
		log.Printf("credproxy affinity: worker_id=%s reason=%s", worker, why)
		return store.SessionBind{}, store.CodexAffinity{}, errors.New(why)
	}
	if route.Unknown || (route.Independent && len(route.References) > 0) {
		return fail("unknown_request_shape")
	}
	if route.Independent {
		b, err := s.sessionBind(worker, principal, endpoint, credvault.Codex, now, true)
		return b, store.CodexAffinity{}, err
	}
	if !credproxy.ValidCodexReferences(route.References) {
		return fail("unknown_reference")
	}
	affinity, err := s.Store.CodexAffinityFor(worker, route.References, now)
	if err != nil {
		return fail(err.Error())
	}
	ch, err := s.codexAffinityChoice(principal, endpoint, affinity, now)
	if err != nil {
		return fail(err.Error())
	}
	log.Printf("credproxy affinity: worker_id=%s reason=source_account references=%d", worker, len(route.References))
	// This lease does not mutate sticky state, including an operator's newer
	// binding. An in-flight response's own account remains authoritative.
	return store.SessionBind{WorkerID: worker, Provider: credvault.Codex, Owner: ch.PrincipalID, Account: ch.Account}, affinity, nil
}
