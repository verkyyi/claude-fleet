package api

import (
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/credvault"
	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

// Organizations, membership and pools — the API (task PNWW).
//
// Who may do what:
//   - an admin (and the operator's door): everything — create, change and
//     remove organizations, put any person in any organization with any role,
//     create and change any pool, move any subscription;
//   - an organization's admin (hub_users.org_role = admin): their own
//     organization only — its members' roles, its pools (create, rename,
//     priority, enable), moving a subscription between its pools, its budget
//     and its usage. They never pull a person in from, or push one out to,
//     another organization, and never touch the platform's pools;
//   - a member: reads their own organization, their own row, the pools they
//     reach and their organization's budget standing.
//
// The routes are a user's in routeAccess (a member's GET answers their own);
// every write is decided here and lands in hub_audit.
const (
	OrgsPath       = "/v1/fleet/orgs"
	OrgMembersPath = "/v1/fleet/orgs/members"
	OrgBudgetPath  = "/v1/fleet/orgs/budget"
	OrgUsagePath   = "/v1/fleet/orgs/usage"
	PoolsPath      = "/v1/fleet/pools"
	PoolMovePath   = "/v1/fleet/pools/move"
)

var poolIDRE = regexp.MustCompile(`^[a-z0-9][a-z0-9._:-]{0,95}$`)

// orgCaller is who is asking.
type orgCaller struct {
	admin     bool   // an admin or the operator's door
	principal string // "" for the operator's door
	org       string // their organization
	orgAdmin  bool   // an admin of org
}

func (s *Server) orgCallerOf(r *http.Request) (orgCaller, error) {
	c := orgCaller{admin: !memberRole(roleOf(r.Context())), principal: principalOf(r.Context())}
	if c.principal == "" {
		return c, nil
	}
	org, role, err := s.Store.PersonOrg(c.principal)
	if err != nil {
		return c, err
	}
	c.org, c.orgAdmin = org, role == store.OrgRoleAdmin
	return c, nil
}

// manages says whether c may change org.
func (c orgCaller) manages(org string) bool {
	return c.admin || (c.orgAdmin && org != "" && org == c.org)
}

func (s *Server) orgDeny(w http.ResponseWriter, r *http.Request, what string) {
	s.auditRoleDenied(r)
	httpError(w, http.StatusForbidden, "只有管理员或该组织的管理员可以"+what+"（only an admin or the organization's admin may do this）")
}

func (s *Server) orgAudit(r *http.Request, action, target, detail string) {
	if err := s.Store.HubAudit(actorOf(r), action, target, "ok", detail, time.Now()); err != nil {
		log.Printf("orgs: audit %s %s: %v", action, target, err)
	}
}

func decodeOrgBody(w http.ResponseWriter, r *http.Request, v any) bool {
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 64<<10)).Decode(v); err != nil {
		httpError(w, http.StatusBadRequest, "malformed request: "+err.Error())
		return false
	}
	return true
}

// OrgView is one organization as the API answers it.
type OrgView struct {
	store.Org
	Members int    `json:"members"`
	Pools   int    `json:"pools"`
	Budget  string `json:"budget,omitempty"`
	Manage  bool   `json:"manage"`
}

// OrgPut is POST OrgsPath's body.
type OrgPut struct {
	Action            string `json:"action"` // put (default) | delete
	OrgID             string `json:"org_id"`
	Name              string `json:"name"`
	Kind              string `json:"kind"`
	Status            string `json:"status"`
	AllowPlatformPool *bool  `json:"allow_platform_pool"`
}

func (s *Server) handleOrgs(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	c, err := s.orgCallerOf(r)
	if err != nil {
		httpError(w, 500, err.Error())
		return
	}
	switch r.Method {
	case http.MethodGet:
		orgs, err := s.Store.Orgs()
		if err != nil {
			httpError(w, 500, err.Error())
			return
		}
		members, err := s.Store.OrgMembers("")
		if err != nil {
			httpError(w, 500, err.Error())
			return
		}
		pools, err := s.Store.Pools()
		if err != nil {
			httpError(w, 500, err.Error())
			return
		}
		settings, err := s.Store.FleetSettings()
		if err != nil {
			httpError(w, 500, err.Error())
			return
		}
		out := []OrgView{}
		for _, o := range orgs {
			if !c.admin && o.ID != c.org {
				continue
			}
			v := OrgView{Org: o, Budget: settings[OrgBudgetPrefix+o.ID], Manage: c.manages(o.ID)}
			for _, m := range members {
				if m.OrgID == o.ID {
					v.Members++
				}
			}
			for _, p := range pools {
				if p.OwnerKind == store.PoolOwnerOrg && p.OwnerID == o.ID {
					v.Pools++
				}
			}
			out = append(out, v)
		}
		writeJSON(w, 200, map[string]any{"orgs": out, "me": map[string]any{"principal": c.principal, "org_id": c.org,
			"org_admin": c.orgAdmin, "admin": c.admin}})
	case http.MethodPost, http.MethodPut:
		if !c.admin {
			s.orgDeny(w, r, "管理组织")
			return
		}
		var req OrgPut
		if !decodeOrgBody(w, r, &req) {
			return
		}
		if !orgIDRE.MatchString(req.OrgID) {
			httpError(w, 400, "org_id: lowercase letters, digits, . _ - (up to 64)")
			return
		}
		if req.Action == "delete" {
			if err := s.Store.DeleteOrg(req.OrgID); err != nil {
				code := 409
				if errors.Is(err, store.ErrNoOrg) {
					code = 404
				}
				httpError(w, code, err.Error())
				return
			}
			s.orgAudit(r, "org_delete", "org:"+req.OrgID, "")
			s.sessCred.drop("")
			writeJSON(w, 200, map[string]any{"ok": true})
			return
		}
		o := store.Org{ID: req.OrgID, Name: req.Name, Kind: req.Kind, Status: req.Status, AllowPlatformPool: true}
		if old, err := s.Store.Org(req.OrgID); err == nil {
			if o.Name == "" {
				o.Name = old.Name
			}
			if o.Kind == "" {
				o.Kind = old.Kind
			}
			if o.Status == "" {
				o.Status = old.Status
			}
			o.AllowPlatformPool = old.AllowPlatformPool
		} else if !errors.Is(err, store.ErrNoOrg) {
			httpError(w, 500, err.Error())
			return
		}
		if req.AllowPlatformPool != nil {
			o.AllowPlatformPool = *req.AllowPlatformPool
		}
		if o.Kind == "" {
			o.Kind = store.OrgKindCustomer
		}
		if o.Name == "" {
			o.Name = o.ID
		}
		if o.Status == "" {
			o.Status = store.OrgActive
		}
		if !store.ValidOrgKind(o.Kind) || (o.Status != store.OrgActive && o.Status != store.OrgDisabled) {
			httpError(w, 400, "kind: platform | trial | customer; status: active | disabled")
			return
		}
		if err := s.Store.PutOrg(o, time.Now()); err != nil {
			httpError(w, 500, err.Error())
			return
		}
		s.orgAudit(r, "org_put", "org:"+o.ID, "kind="+o.Kind+" status="+o.Status+" allow_platform_pool="+strconv.FormatBool(o.AllowPlatformPool))
		s.sessCred.drop("") // the central proxy's next resolve re-reads its pass
		writeJSON(w, 200, map[string]any{"ok": true, "org": o})
	default:
		w.Header().Set("Allow", "GET, POST")
		httpError(w, 405, "GET or POST")
	}
}

// OrgMemberPut is POST OrgMembersPath's body.
type OrgMemberPut struct {
	Principal string `json:"principal"`
	OrgID     string `json:"org_id"`
	Role      string `json:"org_role"`
}

func (s *Server) handleOrgMembers(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	c, err := s.orgCallerOf(r)
	if err != nil {
		httpError(w, 500, err.Error())
		return
	}
	switch r.Method {
	case http.MethodGet:
		org := r.URL.Query().Get("org_id")
		if !c.admin {
			org = c.org
		}
		ms, err := s.Store.OrgMembers(org)
		if err != nil {
			httpError(w, 500, err.Error())
			return
		}
		if !c.manages(org) && !c.admin {
			// a member: their own row only
			mine := []store.OrgMember{}
			for _, m := range ms {
				if m.Principal == c.principal {
					mine = append(mine, m)
				}
			}
			ms = mine
		}
		writeJSON(w, 200, map[string]any{"members": ms})
	case http.MethodPost, http.MethodPut:
		var req OrgMemberPut
		if !decodeOrgBody(w, r, &req) {
			return
		}
		if !principalKeyRE.MatchString(req.Principal) || req.Principal == store.PoolPrincipal || isSvcPrincipal(req.Principal) {
			httpError(w, 400, "principal: a person's principal ID")
			return
		}
		if req.Role == "" {
			req.Role = store.OrgRoleMember
		}
		if !store.ValidOrgRole(req.Role) {
			httpError(w, 400, "org_role: admin | member")
			return
		}
		cur, _, err := s.Store.PersonOrg(req.Principal)
		if err != nil {
			httpError(w, 500, err.Error())
			return
		}
		if req.OrgID == "" {
			req.OrgID = cur
		}
		// an organization's admin changes roles inside their organization only
		if !c.admin && !(c.manages(cur) && req.OrgID == cur) {
			s.orgDeny(w, r, "调整成员")
			return
		}
		if err := s.Store.SetPersonOrg(req.Principal, req.OrgID, req.Role); err != nil {
			switch {
			case errors.Is(err, store.ErrNoOrg):
				httpError(w, 404, err.Error())
			case errors.Is(err, store.ErrNoMember):
				httpError(w, 409, err.Error())
			default:
				httpError(w, 500, err.Error())
			}
			return
		}
		s.orgAudit(r, "org_member", req.Principal, cur+" → "+req.OrgID+" ("+req.Role+")")
		s.sessCred.drop("")
		writeJSON(w, 200, map[string]any{"ok": true, "principal": req.Principal, "org_id": req.OrgID, "org_role": req.Role})
	default:
		w.Header().Set("Allow", "GET, POST")
		httpError(w, 405, "GET or POST")
	}
}

// PoolView is one pool as the API answers it.
type PoolView struct {
	store.Pool
	Credentials int  `json:"credentials"`
	Manage      bool `json:"manage"`
}

// PoolPut is POST PoolsPath's body.
type PoolPut struct {
	Action    string `json:"action"` // put (default) | delete
	PoolID    string `json:"pool_id"`
	Name      string `json:"name"`
	OwnerKind string `json:"owner_kind"`
	OwnerID   string `json:"owner_id"`
	Priority  *int   `json:"priority"`
	Enabled   *bool  `json:"enabled"`
}

// poolManages says whether c may change pool p.
func (c orgCaller) poolManages(p store.Pool) bool {
	return c.admin || (p.OwnerKind == store.PoolOwnerOrg && c.manages(p.OwnerID))
}

func (s *Server) handlePools(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	c, err := s.orgCallerOf(r)
	if err != nil {
		httpError(w, 500, err.Error())
		return
	}
	switch r.Method {
	case http.MethodGet:
		pools, err := s.Store.Pools()
		if err != nil {
			httpError(w, 500, err.Error())
			return
		}
		have := map[string]bool{}
		for _, p := range pools {
			have[p.ID] = true
		}
		if !have[store.PoolPlatformDefault] {
			p, _ := s.Store.PoolByID(store.PoolPlatformDefault)
			pools = append(pools, *p)
		}
		out := []PoolView{}
		for _, p := range pools {
			visible := c.admin || p.OwnerKind == store.PoolOwnerPlatform ||
				(p.OwnerKind == store.PoolOwnerOrg && p.OwnerID == c.org) ||
				(p.OwnerKind == store.PoolOwnerPerson && p.OwnerID == c.principal && c.principal != "")
			if !visible {
				continue
			}
			v := PoolView{Pool: p, Manage: c.poolManages(p)}
			if c.admin || v.Manage {
				if v.Credentials, err = s.Store.PoolCredentials(p.ID); err != nil {
					httpError(w, 500, err.Error())
					return
				}
			}
			out = append(out, v)
		}
		sort.Slice(out, func(i, j int) bool { return out[i].ID < out[j].ID })
		writeJSON(w, 200, map[string]any{"pools": out})
	case http.MethodPost, http.MethodPut:
		var req PoolPut
		if !decodeOrgBody(w, r, &req) {
			return
		}
		if !poolIDRE.MatchString(req.PoolID) {
			httpError(w, 400, "pool_id: lowercase letters, digits, . _ : - (up to 96)")
			return
		}
		old, err := s.Store.PoolByID(req.PoolID)
		if err != nil && !errors.Is(err, store.ErrNoPool) {
			httpError(w, 500, err.Error())
			return
		}
		if req.Action == "delete" {
			if old == nil || !c.poolManages(*old) {
				if old == nil {
					httpError(w, 404, store.ErrNoPool.Error())
				} else {
					s.orgDeny(w, r, "删除这个池")
				}
				return
			}
			if err := s.Store.DeletePool(req.PoolID); err != nil {
				code := 409
				if errors.Is(err, store.ErrNoPool) {
					code = 404
				}
				httpError(w, code, err.Error())
				return
			}
			s.orgAudit(r, "pool_delete", "pool:"+req.PoolID, "")
			s.sessCred.drop("")
			writeJSON(w, 200, map[string]any{"ok": true})
			return
		}
		p := store.Pool{ID: req.PoolID, Name: req.Name, OwnerKind: req.OwnerKind, OwnerID: req.OwnerID, Enabled: true}
		if old != nil {
			if p.Name == "" {
				p.Name = old.Name
			}
			if p.OwnerKind == "" {
				p.OwnerKind, p.OwnerID = old.OwnerKind, old.OwnerID
			}
			p.Priority, p.Enabled = old.Priority, old.Enabled
			if !c.poolManages(*old) {
				s.orgDeny(w, r, "修改这个池")
				return
			}
		}
		if req.Priority != nil {
			p.Priority = *req.Priority
		}
		if req.Enabled != nil {
			p.Enabled = *req.Enabled
		}
		if p.Name == "" {
			p.Name = p.ID
		}
		if p.OwnerKind == store.PoolOwnerPlatform {
			p.OwnerID = ""
		}
		switch {
		case !store.ValidPoolOwner(p.OwnerKind):
			httpError(w, 400, "owner_kind: platform | org | person")
			return
		case p.OwnerKind != store.PoolOwnerPlatform && p.OwnerID == "":
			httpError(w, 400, "owner_id: the organization or the person who owns it")
			return
		case p.ID == store.PoolPlatformDefault && p.OwnerKind != store.PoolOwnerPlatform:
			httpError(w, 400, "platform-default stays the platform's")
			return
		}
		if who, personal := store.IsPersonalPool(p.ID); personal && (p.OwnerKind != store.PoolOwnerPerson || p.OwnerID != who) {
			httpError(w, 400, "a personal: pool stays its person's")
			return
		}
		if p.OwnerKind == store.PoolOwnerOrg {
			if _, err := s.Store.Org(p.OwnerID); err != nil {
				httpError(w, 404, err.Error())
				return
			}
		}
		if !c.poolManages(p) {
			s.orgDeny(w, r, "管理这个池")
			return
		}
		if err := s.Store.PutPool(p, time.Now()); err != nil {
			httpError(w, 500, err.Error())
			return
		}
		s.orgAudit(r, "pool_put", "pool:"+p.ID, "owner="+p.OwnerKind+":"+p.OwnerID+" priority="+strconv.Itoa(p.Priority)+" enabled="+strconv.FormatBool(p.Enabled))
		s.sessCred.drop("")
		writeJSON(w, 200, map[string]any{"ok": true, "pool": p})
	default:
		w.Header().Set("Allow", "GET, POST")
		httpError(w, 405, "GET or POST")
	}
}

// PoolMove is POST PoolMovePath's body: one vault row into a pool.
type PoolMove struct {
	Owner    string `json:"owner"` // the row's principal; "" = the shared pool
	Provider string `json:"provider"`
	Account  string `json:"account"`
	PoolID   string `json:"pool_id"`
}

func (s *Server) handlePoolMove(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	if r.Method != http.MethodPost && r.Method != http.MethodPut {
		w.Header().Set("Allow", "POST")
		httpError(w, 405, "POST")
		return
	}
	c, err := s.orgCallerOf(r)
	if err != nil {
		httpError(w, 500, err.Error())
		return
	}
	var req PoolMove
	if !decodeOrgBody(w, r, &req) {
		return
	}
	if req.Owner == "" {
		req.Owner = store.PoolPrincipal
	}
	cred, err := s.Store.Credential(req.Owner, req.Provider, req.Account)
	if err != nil {
		if errors.Is(err, store.ErrNoCredential) {
			httpError(w, 404, err.Error())
		} else {
			httpError(w, 500, err.Error())
		}
		return
	}
	if cred.Provider == credvault.GitHub {
		httpError(w, 400, "a GitHub token is not a subscription: it is in no pool")
		return
	}
	to, err := s.Store.PoolByID(req.PoolID)
	if err != nil {
		if errors.Is(err, store.ErrNoPool) {
			httpError(w, 404, err.Error())
		} else {
			httpError(w, 500, err.Error())
		}
		return
	}
	from, err := s.Store.PoolByID(store.EffectivePoolID(*cred))
	if err != nil && !errors.Is(err, store.ErrNoPool) {
		httpError(w, 500, err.Error())
		return
	}
	// A person's own subscription is only ever theirs: it moves among the
	// pools that person owns. A shared one goes to any pool but a personal
	// one (which holds its person's own rows only).
	if req.Owner != store.PoolPrincipal {
		if to.OwnerKind != store.PoolOwnerPerson || to.OwnerID != req.Owner {
			httpError(w, 400, "a person's own subscription stays in a pool that person owns")
			return
		}
	} else if _, personal := store.IsPersonalPool(to.ID); personal {
		httpError(w, 400, "a personal: pool holds its person's own subscriptions only — make a pool owned by the person instead")
		return
	}
	if !c.admin && (from == nil || !c.poolManages(*from) || !c.poolManages(*to)) {
		s.orgDeny(w, r, "移动这个订阅")
		return
	}
	if err := s.Store.SetCredentialPool(req.Owner, req.Provider, req.Account, to.ID); err != nil {
		httpError(w, 500, err.Error())
		return
	}
	fromID := ""
	if from != nil {
		fromID = from.ID
	}
	if err := s.Store.AddCredAudit(store.CredAudit{Action: store.CredPool, PrincipalID: req.Owner, Provider: req.Provider,
		Account: req.Account, Detail: fromID + " → " + to.ID + " · by " + actorOf(r)}); err != nil {
		log.Printf("pools: audit move: %v", err)
	}
	s.sessCred.drop("")
	writeJSON(w, 200, map[string]any{"ok": true, "from": fromID, "to": to.ID})
}

func (s *Server) handleOrgBudget(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	c, err := s.orgCallerOf(r)
	if err != nil {
		httpError(w, 500, err.Error())
		return
	}
	switch r.Method {
	case http.MethodGet:
		org := r.URL.Query().Get("org_id")
		if org == "" || !c.admin {
			org = c.org
		}
		if org == "" {
			writeJSON(w, 200, OrgBudgetState{})
			return
		}
		st, err := s.orgBudgetState(org, s.budgetClock())
		if err != nil {
			httpError(w, 500, err.Error())
			return
		}
		writeJSON(w, 200, st)
	case http.MethodPost, http.MethodPut:
		var req struct {
			OrgID  string `json:"org_id"`
			Budget string `json:"budget"`
		}
		if !decodeOrgBody(w, r, &req) {
			return
		}
		if !orgIDRE.MatchString(req.OrgID) {
			httpError(w, 400, "org_id")
			return
		}
		if !c.manages(req.OrgID) {
			s.orgDeny(w, r, "设置组织额度")
			return
		}
		if _, err := s.Store.Org(req.OrgID); err != nil {
			httpError(w, 404, err.Error())
			return
		}
		value := strings.TrimSpace(req.Budget)
		if value != "" {
			b, err := parseOrgBudget(value)
			if err != nil {
				httpError(w, 400, err.Error())
				return
			}
			value = b.String()
		}
		settings, err := s.Store.FleetSettings()
		if err != nil {
			httpError(w, 500, err.Error())
			return
		}
		key, now := OrgBudgetPrefix+req.OrgID, time.Now()
		if err := s.Store.SetFleetSetting(key, value, now); err != nil {
			httpError(w, 500, err.Error())
			return
		}
		s.settingAudit(actorOf(r), key, settings[key], value, now)
		writeJSON(w, 200, map[string]any{"ok": true, "key": key, "budget": value})
	default:
		w.Header().Set("Allow", "GET, POST")
		httpError(w, 405, "GET or POST")
	}
}

// OrgUsage is OrgUsagePath's answer: the organization's pool tokens over the
// range, by person and by pool.
type OrgUsage struct {
	OrgID    string           `json:"org_id"`
	Since    time.Time        `json:"since"`
	Tokens   int64            `json:"tokens"`
	ByPerson map[string]int64 `json:"by_person"`
	ByPool   map[string]int64 `json:"by_pool"`
}

func (s *Server) handleOrgUsage(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", "GET")
		httpError(w, 405, "GET")
		return
	}
	c, err := s.orgCallerOf(r)
	if err != nil {
		httpError(w, 500, err.Error())
		return
	}
	org := r.URL.Query().Get("org_id")
	if org == "" || !c.admin {
		org = c.org
	}
	days := 7
	if v, err := strconv.Atoi(r.URL.Query().Get("days")); err == nil && v > 0 && v <= 90 {
		days = v
	}
	now := s.budgetClock()
	out := OrgUsage{OrgID: org, Since: now.Add(-time.Duration(days) * 24 * time.Hour), ByPerson: map[string]int64{}, ByPool: map[string]int64{}}
	if org == "" {
		writeJSON(w, 200, out)
		return
	}
	who := ""
	if !c.manages(org) {
		who = c.principal // a member: their own rows only
		if who == "" {
			writeJSON(w, 200, out)
			return
		}
	}
	rows, err := s.Store.PoolUsageFor(who, out.Since, time.Time{})
	if err != nil {
		httpError(w, 500, err.Error())
		return
	}
	for _, u := range rows {
		if u.OrgID != org {
			continue
		}
		out.Tokens += u.Tokens()
		out.ByPerson[u.Principal] += u.Tokens()
		out.ByPool[u.PoolID] += u.Tokens()
	}
	writeJSON(w, 200, out)
}
