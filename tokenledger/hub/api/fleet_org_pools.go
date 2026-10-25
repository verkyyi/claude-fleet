package api

import (
	"errors"
	"sort"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

// Subscription pools in the policy resolver (task PNWW, store/hub_orgs.go).
//
// A person reaches, in this order: the pools they own (their personal pool,
// holding their own subscriptions, and any pool an admin made for them) →
// their organization's pools → the platform's pools — the last only while
// their organization allows it (allow_platform_pool, default on) — and inside
// a level by priority (smaller first), then pool id. A disabled pool, or a
// disabled organization's pools and platform access, is reached by nobody.
//
// It is one more scope of credPolicy, so every road that chooses an account
// obeys it: the node lease (a pool the person does not reach is `withdrawn`),
// sessionBindChoices (the central proxy's resolve, a bind, the re-check, the
// 429 rebind) and the effective view. The allowlists (cred_allow.*) still
// apply on top: a pool only narrows, never widens.
//
// The gate narrows only when some pool is out of the person's reach: with
// only the bootstrap's pools (platform-default and everyone's personal pool)
// it denies nothing, Restricted() is unchanged and the order is today's — own
// first, then the shared pool (TestOrgBootstrapKeepsEveryonesAccounts).

// poolAccess is one person's reach.
type poolAccess struct {
	principal string
	org       string
	rank      map[string]int    // reachable pool → its place in the order
	unreach   map[string]string // pool out of reach → why
	gate      bool              // some pool is out of reach
}

func (a *poolAccess) gates() bool { return a != nil && a.gate }

// why is "" when c's pool is the person's to use, else why not.
func (a *poolAccess) why(c store.Credential) string {
	if !a.gates() {
		return ""
	}
	id := store.EffectivePoolID(c)
	if _, ok := a.rank[id]; ok {
		return ""
	}
	if w := a.unreach[id]; w != "" {
		return w
	}
	return "pool " + id + " is not one of " + a.principal + "'s pools"
}

// order sorts rows by their pool's place (stable: the caller's order inside
// one pool is kept); a row of no reachable pool goes last.
func (a *poolAccess) order(rows []store.Credential) []store.Credential {
	if a == nil || len(rows) < 2 {
		return rows
	}
	place := func(c store.Credential) int {
		if r, ok := a.rank[store.EffectivePoolID(c)]; ok {
			return r
		}
		return len(a.rank)
	}
	out := append([]store.Credential(nil), rows...)
	sort.SliceStable(out, func(i, j int) bool { return place(out[i]) < place(out[j]) })
	return out
}

// Pool levels.
const (
	poolLevelOwn = iota
	poolLevelOrg
	poolLevelPlatform
)

// poolAccessFor is principal's reach; nil for no one (a machine's scope),
// the shared pool's sentinel and a service principal (svc:), whose own list
// is their whole policy.
func (s *Server) poolAccessFor(principal string) (*poolAccess, error) {
	if s.Store == nil || principal == "" || principal == store.PoolPrincipal || isSvcPrincipal(principal) {
		return nil, nil
	}
	orgID, _, err := s.Store.PersonOrg(principal)
	if err != nil {
		return nil, err
	}
	org, err := s.Store.Org(orgID)
	if errors.Is(err, store.ErrNoOrg) {
		org, err = &store.Org{ID: orgID, Status: store.OrgActive, AllowPlatformPool: true}, nil
	}
	if err != nil {
		return nil, err
	}
	pools, err := s.Store.Pools()
	if err != nil {
		return nil, err
	}
	have := map[string]bool{}
	for _, p := range pools {
		have[p.ID] = true
	}
	for _, id := range []string{store.PoolPlatformDefault, store.PersonalPoolID(principal)} {
		if !have[id] {
			p, err := s.Store.PoolByID(id)
			if err != nil {
				return nil, err
			}
			pools = append(pools, *p)
		}
	}
	a := &poolAccess{principal: principal, org: orgID, rank: map[string]int{}, unreach: map[string]string{}}
	orgActive := org.Status != store.OrgDisabled
	type cand struct {
		id          string
		level, prio int
	}
	var cs []cand
	out := func(id, why string) { a.unreach[id], a.gate = why, true }
	for _, p := range pools {
		level := -1
		switch p.OwnerKind {
		case store.PoolOwnerPerson:
			if p.OwnerID == principal {
				level = poolLevelOwn
			} else if who, auto := store.IsPersonalPool(p.ID); auto && who == p.OwnerID {
				continue // another person's own subscriptions: never fetched for this one
			} else {
				out(p.ID, "pool "+p.ID+" belongs to person "+p.OwnerID)
				continue
			}
		case store.PoolOwnerOrg:
			switch {
			case p.OwnerID != orgID:
				out(p.ID, "pool "+p.ID+" belongs to organization "+p.OwnerID+", not "+principal+"'s ("+orgID+")")
				continue
			case !orgActive:
				out(p.ID, "organization "+orgID+" is disabled")
				continue
			}
			level = poolLevelOrg
		case store.PoolOwnerPlatform:
			switch {
			case !orgActive:
				out(p.ID, "organization "+orgID+" is disabled")
				continue
			case !org.AllowPlatformPool:
				out(p.ID, "organization "+orgID+" does not use the platform's pools (allow_platform_pool off)")
				continue
			}
			level = poolLevelPlatform
		default:
			out(p.ID, "pool "+p.ID+" has an unknown owner kind "+p.OwnerKind)
			continue
		}
		if !p.Enabled {
			out(p.ID, "pool "+p.ID+" is disabled")
			continue
		}
		cs = append(cs, cand{p.ID, level, p.Priority})
	}
	sort.SliceStable(cs, func(i, j int) bool {
		if cs[i].level != cs[j].level {
			return cs[i].level < cs[j].level
		}
		if cs[i].prio != cs[j].prio {
			return cs[i].prio < cs[j].prio
		}
		return cs[i].id < cs[j].id
	})
	for i, c := range cs {
		a.rank[c.id] = i
	}
	return a, nil
}
