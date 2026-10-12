package api

import (
	"fmt"
	"log"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// Removing a login becomes recycling it (claude-fleet#3504, EPIC #3500 C12).
//
// On a machine that keeps spares, the operator's `remove` of a person's login
// no longer deletes the OS user: the hub sends a reset, the admin node washes
// the login (the remove script's --recycle mode, bin/fleet-login-reset-check.py
// at its end) and re-joins it with a fresh join code, and an answer that says
// `reset: clean` + `credsep: separated` makes the same login a new ready spare
// — the next person is handed it at once. Anything else (dirty, not separated,
// a failed or cut-off run, no answer for accountUnknownGiveUp) leaves the
// person's row failed: that login is never handed out.
//
// The hub's own half of what the person leaves is cleared before the reset is
// sent (recycleClear) and checked again before the spare is recorded
// (recycleLeftovers — BREAK-IT spare-recycle-dirty): the login's node token(s)
// with their session passes, relay credential and open link; the work leases
// its sessions held; the person's 家 (entry home) on that login, pushed to the
// machine's entry; and every join code minted for it and not redeemed.
//
// Recycling only happens where spares are on, for a person (not a spare, not a
// drill), on a machine whose account-op node lists CapRecycle with separated
// logins and is no one's own computer. `remove` with delete: true, a spare
// shrinking, a drill's teardown, spares off or an older admin: the old remove,
// byte for byte.

// recycleOn says a remove of principal's login on host should be a reset.
func (s *Server) recycleOn(principal, host string) bool {
	if !s.Fleet || s.Store == nil || !s.sparesOn() || store.IsSparePrincipal(principal) || s.Store.IsDrill(principal) {
		return false
	}
	_, ok := s.nodes.recyclerFor(host)
	return ok
}

// recycleEndpoints is every live endpoint enrolled as login on host before
// cutoff — the person's nodes, never the one the reset's own join code makes.
func (s *Server) recycleEndpoints(host, login string, cutoff time.Time) ([]store.Endpoint, error) {
	eps, err := s.Store.ListEndpoints("")
	if err != nil {
		return nil, err
	}
	var out []store.Endpoint
	for i := range eps {
		ep := eps[i]
		if ep.RetiredAt != nil || !ep.EnrolledAt.Before(cutoff) {
			continue
		}
		h, u := s.nodeIdentity(&ep)
		if u == login && sameMachine(host, h) {
			out = append(out, ep)
		}
	}
	return out, nil
}

// recycleHomes is every 家 that is still login on host.
func (s *Server) recycleHomes(host, login string) ([]store.EntryHome, error) {
	hs, err := s.Store.EntryHomes()
	if err != nil {
		return nil, err
	}
	var out []store.EntryHome
	for _, h := range hs {
		if h.Login == login && sameMachine(host, h.Machine) {
			out = append(out, h)
		}
	}
	return out, nil
}

// recycleJoinLabel is the label loginJoinCode mints a login's codes under.
func recycleJoinLabel(a store.FleetAccount) string { return a.Hostname + "-" + a.Login }

// recycleClear takes the person's hub-side pieces off login a.Login on
// a.Hostname. Every step is idempotent; one that fails is logged and left to
// recycleLeftovers, which fails the recycle rather than hand the login on.
func (s *Server) recycleClear(a store.FleetAccount, now time.Time) {
	who := a.Login + "@" + a.Hostname
	eps, err := s.recycleEndpoints(a.Hostname, a.Login, a.RequestedAt)
	if err != nil {
		log.Printf("fleet: recycle %s: endpoints: %v", who, err)
	}
	for i := range eps {
		ep := &eps[i]
		if held, err := s.Store.ReleaseLeasesOfEndpoint(ep.ID); err != nil {
			log.Printf("fleet: recycle %s: leases of %s: %v", who, ep.ID, err)
		} else {
			for _, l := range held {
				s.leaseAudit("hub", "recycle_lease_release", l.FleetID,
					fmt.Sprintf("%s#%d (%s) — %s recycled", l.Repo, l.Issue, l.WorkerID, who), now)
			}
		}
		if _, err := s.retireNode(ep, "hub", "login "+a.Login+" recycled into a spare", now); err != nil {
			log.Printf("fleet: recycle %s: retire node %s: %v", who, ep.ID, err)
		}
	}
	// A relay credential the login holds with no endpoint left to name it.
	if settings, err := s.Store.FleetSettings(); err == nil {
		key := relayKey(a.Hostname)
		entries := relayEntries(settings[key])
		if _, ok := entries[a.Login]; ok {
			delete(entries, a.Login)
			if err := s.Store.SetFleetSetting(key, relayValue(entries), now); err != nil {
				log.Printf("fleet: recycle %s: relay credential: %v", who, err)
			}
			s.relayCacheReset()
		}
	}
	homes, err := s.recycleHomes(a.Hostname, a.Login)
	if err != nil {
		log.Printf("fleet: recycle %s: homes: %v", who, err)
	}
	for _, h := range homes {
		v, err := s.Store.ClearEntryHome(h.Person, h.Machine, h.Login)
		if err != nil {
			log.Printf("fleet: recycle %s: home of %s: %v", who, h.Person, err)
			continue
		}
		if v > 0 {
			s.broadcastEntry(v, h.Machine)
		}
	}
	if n, err := s.Store.ExpireJoinCodes(recycleJoinLabel(a), a.Hostname, now); err != nil {
		log.Printf("fleet: recycle %s: join codes: %v", who, err)
	} else if n > 0 {
		log.Printf("fleet: recycle %s: %d unused join code(s) ended", who, n)
	}
}

// recycleLeftovers is what of the person the hub still holds for a: the
// categories still there, in a fixed order, empty when clean. A category it
// cannot read is listed too — never called clean unread.
func (s *Server) recycleLeftovers(a store.FleetAccount, now time.Time) []string {
	var dirty []string
	eps, err := s.recycleEndpoints(a.Hostname, a.Login, a.RequestedAt)
	if err != nil || len(eps) > 0 {
		dirty = append(dirty, "node-token")
	}
	if err == nil {
		leases, lerr := s.Store.Leases(now)
		held := false
		for _, l := range leases {
			for _, ep := range eps {
				held = held || l.EndpointID == ep.ID
			}
		}
		if lerr != nil || held {
			dirty = append(dirty, "lease")
		}
	}
	if homes, err := s.recycleHomes(a.Hostname, a.Login); err != nil || len(homes) > 0 {
		dirty = append(dirty, "home")
	}
	if n, err := s.Store.LiveJoinCodes(recycleJoinLabel(a), a.Hostname, a.RequestedAt, now); err != nil || n > 0 {
		dirty = append(dirty, "join-code")
	}
	return dirty
}

// applyReset settles a reset's answer: a clean, separated wash whose hub side
// is clean too becomes a ready spare (store.RecycleAccount, audited
// spare.recycle); anything else fails the person's row. It reports the state
// recorded and whether the answer landed.
func (s *Server) applyReset(opID, epID string, res control.AccountResult, now time.Time) (string, bool, error) {
	a, err := s.Store.AccountByOp(opID)
	if err != nil || a.Op != control.AccountReset {
		// Stale or foreign: FinishAccountOp moves nothing and says so.
		ok, err := s.Store.FinishAccountOp(opID, epID, store.AccountFailed, truncate(res.Detail, 4000), now)
		return store.AccountFailed, ok, err
	}
	why := ""
	switch {
	case !res.OK && res.Exit == control.RemoveExitNoLogin:
		// The login is gone from the machine: nothing to wash, nothing to
		// hand on.
		ok, err := s.Store.FinishAccountOp(opID, epID, store.AccountRemoved,
			truncate("no such login on this machine: nothing to recycle. "+res.Detail, 4000), now)
		return store.AccountRemoved, ok, err
	case !res.OK:
		why = fmt.Sprintf("reset failed (exit %d)", res.Exit)
	case res.Reset != control.ResetClean:
		v := res.Reset
		if v == "" {
			v = "no verdict"
		}
		why = "reset: " + v
	case res.Credsep != control.CredsepSeparated:
		why = "reset without credential separation (credsep=" + res.Credsep + ")"
	}
	if why == "" {
		// The hub's half, once more: a write that failed at send time is
		// retried here, and what is still there fails the recycle.
		s.recycleClear(*a, now)
		if left := s.recycleLeftovers(*a, now); len(left) > 0 {
			why = "hub still holds " + strings.Join(left, ",") + " of the last person"
		}
	}
	if why != "" {
		detail := why + "; the login is not handed out — look at it there, then remove it with delete, or retry. " + res.Detail
		ok, err := s.Store.FinishAccountOp(opID, epID, store.AccountFailed, truncate(detail, 4000), now)
		return store.AccountFailed, ok, err
	}
	spare, from, ok, err := s.Store.RecycleAccount(opID, epID, "hub", now)
	if err != nil || !ok {
		return store.AccountActive, ok, err
	}
	log.Printf("fleet: recycled %s on %s from %s into spare %s", spare.Login, spare.Hostname, from, spare.PrincipalID)
	go func() {
		if s.replenishSpares(time.Now(), true) {
			s.dispatchAccounts()
		}
	}()
	return store.AccountActive, true, nil
}
