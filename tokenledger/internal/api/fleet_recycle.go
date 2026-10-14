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
// Recycling only happens where spares are on, for a person or a drill
// identity (not a spare), on a machine whose account-op node lists CapRecycle
// with separated logins and is no one's own computer. A drill's teardown
// recycles the logins the hub opened or handed it (claude-fleet#3509, #2947),
// so a drill leaves the machine's spare count where it found it. `remove`
// with delete: true, a spare shrinking, spares off or an older admin: the old
// remove, byte for byte.

// recycleOn says a remove of principal's login on host should be a reset.
func (s *Server) recycleOn(principal, host string) bool {
	if !s.Fleet || s.Store == nil || !s.sparesOn() || store.IsSparePrincipal(principal) {
		return false
	}
	if s.clusterPodOf(host) != nil {
		return false // a pod is destroyed, never washed (claude-fleet#3553)
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

// recycleKeepAll is recycleClearAs's keep while a keeping reset runs: every
// node of the login stays enrolled (which one the wash kept is known only
// from its answer).
const recycleKeepAll = "*"

// recycleClear takes the person's hub-side pieces off login a.Login on
// a.Hostname, its node tokens with them. Every step is idempotent; one that
// fails is logged and left to recycleLeftovers, which fails the recycle rather
// than hand the login on.
func (s *Server) recycleClear(a store.FleetAccount, now time.Time) { s.recycleClearAs(a, now, "") }

// recycleClearAs is recycleClear with keep (claude-fleet#4195): the node(s)
// whose token the wash keeps — "" none (each is retired), recycleKeepAll every
// one, else that endpoint id. A kept node stays enrolled; the last person's
// pieces of it go all the same: the passes it issued (revoked, on the list),
// its leases, its open link. And kept or not, the last person's credentials on
// this machine go on the revocation list (recycleRevokePerson).
func (s *Server) recycleClearAs(a store.FleetAccount, now time.Time, keep string) {
	who := a.Login + "@" + a.Hostname
	eps, err := s.recycleEndpoints(a.Hostname, a.Login, a.RequestedAt)
	if err != nil {
		log.Printf("fleet: recycle %s: endpoints: %v", who, err)
	}
	passes := 0
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
		if keep == recycleKeepAll || keep == ep.ID {
			n, err := s.Store.RevokeEndpointSessionCreds(ep.ID, "hub", "login "+a.Login+" recycled: the last person's passes end", now)
			if err != nil {
				log.Printf("fleet: recycle %s: passes of kept node %s: %v", who, ep.ID, err)
			}
			passes += n
			s.sessCred.drop("")
			s.revNodePasses(ep, now)
			if s.nodes.get(ep.ID) != nil {
				// it reconnects with the same token once the wash is done
				s.nodes.closeRevoked(ep.ID)
			}
			continue
		}
		if _, err := s.retireNode(ep, "hub", "login "+a.Login+" recycled into a spare", now); err != nil {
			log.Printf("fleet: recycle %s: retire node %s: %v", who, ep.ID, err)
		}
	}
	s.recycleRevokePerson(a, now, keep, passes)
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
	return s.recycleLeftoversAs(a, now, "")
}

// recycleLeftoversAs is recycleLeftovers with the node the wash kept (its
// endpoint id, claude-fleet#4195): that one may stay enrolled, but no pass it
// issued before the reset may still be live, and neither may a certificate of
// the last person's that names the login.
func (s *Server) recycleLeftoversAs(a store.FleetAccount, now time.Time, kept string) []string {
	var dirty []string
	all, err := s.recycleEndpoints(a.Hostname, a.Login, a.RequestedAt)
	var eps []store.Endpoint
	for _, ep := range all {
		if ep.ID != kept || kept == "" {
			eps = append(eps, ep)
		}
	}
	if err != nil || len(eps) > 0 {
		dirty = append(dirty, "node-token")
	}
	if kept != "" {
		if n, err := s.Store.LiveEndpointSessionCreds(kept, now, now); err != nil || n > 0 {
			dirty = append(dirty, "pass")
		}
	}
	if left, err := s.recycleCertsLeft(a, now); err != nil || left > 0 {
		dirty = append(dirty, "cert")
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
	if t := resetTiming(res.Detail); t != "" {
		log.Printf("fleet: reset %s on %s: %s", a.Login, a.Hostname, t)
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
		kept := ""
		if nodeKept(res.Detail) {
			// The wash kept the login's node token (claude-fleet#4195): the one
			// node enrolled before the reset is that one — two or none, and the
			// hub cannot tell which, so none is kept and the recycle fails.
			if eps, err := s.recycleEndpoints(a.Hostname, a.Login, a.RequestedAt); err == nil && len(eps) == 1 {
				kept = eps[0].ID
			} else {
				why = fmt.Sprintf("the wash kept the login's node token, but the hub has %d node(s) of it from before the reset", len(eps))
			}
		}
		s.recycleClearAs(*a, now, kept)
		if left := s.recycleLeftoversAs(*a, now, kept); len(left) > 0 && why == "" {
			why = "hub still holds " + strings.Join(left, ",") + " of the last person"
		}
	}
	if why != "" {
		detail := why + "; the login is not handed out — look at it there, then remove it with delete, or retry. " + res.Detail
		ok, err := s.Store.FinishAccountOp(opID, epID, store.AccountFailed, truncate(detail, 4000), now)
		return store.AccountFailed, ok, err
	}
	spare, from, ok, err := s.Store.RecycleAccount(opID, epID, "hub", resetTiming(res.Detail), now)
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

// resetTiming is the wash's last `timing:` line (bin/fleet-login-reset.sh,
// claude-fleet#4044: each phase's seconds, isolated = until the check said
// clean, total), "" when the answer carries none — an older node.
func resetTiming(detail string) string {
	lines := strings.Split(detail, "\n")
	for i := len(lines) - 1; i >= 0; i-- {
		if l := strings.TrimSpace(lines[i]); strings.HasPrefix(l, "timing: ") {
			return truncate(l, 300)
		}
	}
	return ""
}

// nodeKept says the wash's answer kept the login's node token: a `node: kept`
// line (bin/fleet-login-reset.sh, claude-fleet#4195) among its last lines.
func nodeKept(detail string) bool {
	for _, l := range strings.Split(detail, "\n") {
		if strings.HasPrefix(strings.TrimRight(l, " \t\r"), "node: kept") {
			return true
		}
	}
	return false
}

// recycleCerts is the last person's live SSH certificates that name the
// recycled login: with them the person could still sign in as it.
func (s *Server) recycleCerts(a store.FleetAccount, now time.Time) ([]store.FleetCert, error) {
	if store.IsSparePrincipal(a.PrincipalID) {
		return nil, nil
	}
	certs, err := s.Store.LiveFleetCerts(a.PrincipalID, now)
	if err != nil {
		return nil, err
	}
	var out []store.FleetCert
	for _, c := range certs {
		for _, p := range c.Principals {
			if p == a.Login {
				out = append(out, c)
				break
			}
		}
	}
	return out, nil
}

// recycleRevokePerson puts what the last person still holds for this machine
// on the revocation list (claude-fleet#4195) — every credential of theirs
// issued here before now (the scope a credential revoke writes) and each live
// SSH certificate naming the login — refused at every door within the list's
// 10 seconds, kept token or not; and leaves one hub_audit spare.revoke line
// with what went.
func (s *Server) recycleRevokePerson(a store.FleetAccount, now time.Time, keep string, passes int) {
	who := a.Login + "@" + a.Hostname
	src := "recycle:" + revMachine(a.Hostname) + "|" + a.Login
	var entries []store.Revocation
	if !store.IsSparePrincipal(a.PrincipalID) {
		entries = append(entries, store.Revocation{Machine: revMachine(a.Hostname), Principal: a.PrincipalID,
			Before: now.Unix(), Exp: now.Add(revScopeKeep).Unix(), Src: src, Reason: "login " + a.Login + " recycled"})
	}
	certs, err := s.recycleCerts(a, now)
	if err != nil {
		log.Printf("fleet: recycle %s: certificates: %v", who, err)
	}
	for _, c := range certs {
		entries = append(entries, store.Revocation{JTI: "ssh:" + c.Serial, Principal: a.PrincipalID,
			Exp: c.ValidBefore.Unix(), Src: src})
	}
	s.revRecord(entries, now)
	node := "re-joined"
	switch keep {
	case "":
	case recycleKeepAll:
		node = "kept while washing"
	default:
		node = "kept " + keep
	}
	list := "on"
	if !s.revOn() {
		list = "off"
	}
	detail := fmt.Sprintf("%s · login %s → spare · node %s · passes %d · certs %d · list %s",
		a.PrincipalID, a.Login, node, passes, len(certs), list)
	if err := s.Store.HubAudit("hub", "spare.revoke", a.Login, "ok", detail, now); err != nil {
		log.Printf("fleet: recycle %s: audit: %v", who, err)
	}
}

// recycleCertsLeft counts the last person's live certificates naming the
// login that the list does not carry (0 when the list is off: no door reads it).
func (s *Server) recycleCertsLeft(a store.FleetAccount, now time.Time) (int, error) {
	if !s.revOn() {
		return 0, nil
	}
	certs, err := s.recycleCerts(a, now)
	if err != nil || len(certs) == 0 {
		return 0, err
	}
	_, list, err := s.Store.RevocationList(now)
	if err != nil {
		return 0, err
	}
	on := map[string]bool{}
	for _, r := range list {
		on[r.JTI] = true
	}
	n := 0
	for _, c := range certs {
		if !on["ssh:"+c.Serial] {
			n++
		}
	}
	return n, nil
}
