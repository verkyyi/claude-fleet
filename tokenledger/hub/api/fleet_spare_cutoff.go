package api

import (
	"errors"
	"log"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

// A spare whose op was interrupted, not refused (claude-fleet NKTP). The node
// agent restarting while it ran a create or a wash (a release switch, a hub
// deploy that took the link — macmini fleetu12, 2026-10-21) is answered
// failed by the new agent (#2918's cutOffResult: «the node agent (pid N)
// stopped while this op ran»), and an op whose link dropped and never came
// back is failed by reaskAccounts after accountUnknownGiveUp. Counted as a
// failed spare, it held its machine's refill until an operator looked — for a
// cause that was never the spare's. The hub now retries it itself: a cut-off
// wash is washed again (the wash re-checks the login, #4673), a cut-off create
// is removed (a remove of a login that never got made is done at once,
// RemoveExitNoLogin) and the refill opens a fresh one. At most
// spareCutOffTries per spare (in memory: a hub restart starts the count
// again); past that it is an ordinary failed spare, held for the operator as
// before.
const spareCutOffTries = 2

// spareCutOff says a failed spare's detail is an interruption, not a refusal.
func spareCutOff(a store.FleetAccount) bool {
	return store.IsSparePrincipal(a.PrincipalID) && a.State == store.AccountFailed &&
		(a.Op == control.AccountCreate || a.Op == control.AccountReset) &&
		(strings.Contains(a.Detail, control.AccountCutOffMark) || strings.Contains(a.Detail, accountGiveUpMark))
}

// spareCutOffRetry says the hub still retries this cut-off spare itself.
func (s *Server) spareCutOffRetry(a store.FleetAccount) bool {
	if !spareCutOff(a) {
		return false
	}
	s.spareCutMu.Lock()
	defer s.spareCutMu.Unlock()
	return s.spareCutTries[strings.ToLower(a.PrincipalID)] < spareCutOffTries
}

// healCutOffSpares retries m's cut-off spares (see above). It reports
// whether anything was queued; the caller dispatches.
func (s *Server) healCutOffSpares(m *spareMachine, now time.Time) bool {
	queued := false
	for _, a := range m.cutoff {
		req, how := s.Store.RequestAccountRemoval, "removing it (the refill opens a fresh one)"
		if a.Op == control.AccountReset {
			req, how = s.Store.RequestAccountReset, "washing it again"
		}
		if err := req(a.PrincipalID, a.Hostname, now); err != nil {
			if !errors.Is(err, store.ErrAccountState) {
				log.Printf("fleet: spares: retry %s on %s: %v", a.Login, a.Hostname, err)
			}
			continue
		}
		s.spareCutMu.Lock()
		if s.spareCutTries == nil {
			s.spareCutTries = map[string]int{}
		}
		k := strings.ToLower(a.PrincipalID)
		s.spareCutTries[k]++
		n := s.spareCutTries[k]
		s.spareCutMu.Unlock()
		why := "its " + a.Op + " was cut off, not refused (" + truncate(a.Detail, 200) + ") — " + how
		log.Printf("fleet: spares: %s on %s: %s (try %d/%d)", a.Login, a.Hostname, why, n, spareCutOffTries)
		_ = s.Store.HubAudit("hub", "spare.cutoff", a.Login, "queued", a.Hostname+": "+why, now)
		queued = true
	}
	return queued
}
