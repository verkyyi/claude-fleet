package api

import (
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"sort"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/credvault"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// Subscription allowlists (claude-fleet#3043): which subscriptions a MACHINE
// and a PERSON may use, on top of everything that already decides it.
//
//	effective = eligible (own + shared pool, after the principal, revocation,
//	            drill, trust and credsep gates) ∩ node allowance ∩ person allowance
//
// An OS login is not a third policy: it resolves to its active hub owner
// (principalOnNode), and that person's allowance applies.
//
// Stored as two setting families, written ONLY through PUT /v1/fleet/cred-policy
// (admin; every write a fleet_cred_audit `policy` row) — the generic settings
// PUT refuses them:
//
//	fleet.cred_allow.node.<machine>     machine = the first label, lowercased, of
//	                                    the name the endpoint JOINED as
//	                                    (endpoints.enrolled_host) — pinned at
//	                                    enrollment and shared by every login of the
//	                                    machine; never the heartbeat's hostname
//	fleet.cred_allow.user.<principal>   principal = the stable principal ID (gh:<id>)
//
// The value is a JSON list of subscription IDs: a Claude account's UUID, or a
// Codex `codex:account:<32 hex>` — what Vault.AccountUUID reads off the sealed
// secret. Account labels are display only and never match.
//
//   - no key        denied (legacy installations keep unrestricted until reviewed);
//   - `"*"`         explicitly allow all current and future eligible subscriptions;
//   - `[]`          deny all;
//   - a list        only its entries;
//   - unparsable    deny all in that scope (reason names it) — a broken
//     restriction never reads as no restriction;
//   - a credential with no recorded account UUID (an old import, or a sealed
//     secret the hub cannot open) never matches a list: record it with
//     /v1/fleet/credentials action=bind;
//   - node policies exist but this endpoint's machine is unknown ⇒ denied.
//
// GitHub tokens are not subscriptions: no allowlist touches them.
//
// Enforced by ONE resolver (credPolicy) in: the node lease
// (handleNodeCredentials — forbidden accounts are listed in `withdrawn` so the
// node removes its copy), the pool manifest (handleNodePool, node scope: it is
// the machine's), and sessionBindChoices — the central proxy's resolve, an
// explicit bind, a retained binding's re-check and the 429 rebind all choose
// from it, so neither a manual account name nor a cached binding escapes.
//
// Timing (docs/SHARED-MACHINE.md «订阅白名单»): the central proxy sees a change
// within its verdict cache (≤ 30 s); a node's lease answers recheck_secs while
// any policy exists, so a narrowed account leaves the node within that
// (an agent that predates this ignores both and keeps a copy until its
// ≤ 6 h renewal — which also bounds the very first policy write). With the
// hub unreachable nothing new is leased and copies already on a node run to
// their expiry; a request already in flight finishes. A token already handed
// to a machine cannot be revoked at the provider by an allowlist: it lives
// until its own expiry (a Claude setup token: up to a year — revoke the
// machine, or rotate the subscription, to cut that short).

const (
	CredPolicyModeKey   = "fleet.cred_policy.mode"
	CredAllowNodePrefix = "fleet.cred_allow.node."
	CredAllowUserPrefix = "fleet.cred_allow.user."
	// CredPolicyPath is the admin route.
	CredPolicyPath = "/v1/fleet/cred-policy"
	// credPolicyRecheck is how soon a node leases again while any policy
	// exists, so a narrowing reaches it.
	credPolicyRecheck = 15 * time.Minute
	// credPolicyMax bounds one list.
	credPolicyMax = 256
)

// credAllow is one scope's allowance.
type credAllow struct {
	All bool            // explicit grant, including future subscriptions
	Set bool            // this scope requires an explicit match or all grant
	Bad string          // the key's value does not parse: deny all
	IDs map[string]bool // normalised subscription IDs
}

// credPolicy is the allowance that applies to one (machine, person).
type credPolicy struct {
	Machine   string
	Principal string
	Node      credAllow
	User      credAllow
	// NodeUnknown: some machine has a policy but this endpoint's machine
	// cannot be named — denied rather than unrestricted.
	NodeUnknown bool
}

// normSubID is a subscription ID as compared: a Claude UUID lowercased.
func normSubID(id string) string { return strings.ToLower(strings.TrimSpace(id)) }

// validSubID is a Claude account UUID or a Codex account ID.
func validSubID(id string) bool {
	return claudeAccountUUIDRE.MatchString(id) || codexAccountUUIDRE.MatchString(id)
}

// parseCredAllow reads one stored value: a JSON list of subscription IDs.
func parseCredAllow(raw string) (map[string]bool, error) {
	var ids []string
	if err := json.Unmarshal([]byte(raw), &ids); err != nil {
		return nil, fmt.Errorf("not a JSON list of subscription IDs: %v", err)
	}
	if ids == nil {
		return nil, errors.New("null is not a list (use [] to deny all)")
	}
	if len(ids) > credPolicyMax {
		return nil, fmt.Errorf("%d entries, at most %d", len(ids), credPolicyMax)
	}
	out := map[string]bool{}
	for _, id := range ids {
		n := normSubID(id)
		if !validSubID(n) {
			return nil, fmt.Errorf("%q is not a subscription ID (a Claude account UUID, or codex:account:<32 hex>)", id)
		}
		out[n] = true
	}
	return out, nil
}

func credAllowOf(settings map[string]string, key string) credAllow {
	raw, ok := settings[key]
	if !ok {
		return credAllow{Set: settings[CredPolicyModeKey] != "legacy"}
	}
	if raw == `"*"` {
		return credAllow{Set: true, All: true}
	}
	ids, err := parseCredAllow(raw)
	if err != nil {
		return credAllow{Set: true, Bad: err.Error()}
	}
	return credAllow{Set: true, IDs: ids}
}

// credNodeKey / credUserKey are the setting keys.
func credNodeKey(machine string) string {
	return CredAllowNodePrefix + strings.ToLower(firstLabel(machine))
}
func credUserKey(principal string) string { return CredAllowUserPrefix + principal }

// anyNodePolicy says whether some machine has an allowlist.
func anyNodePolicy(settings map[string]string) bool {
	if settings[CredPolicyModeKey] != "legacy" {
		return true
	}
	for k := range settings {
		if strings.HasPrefix(k, CredAllowNodePrefix) {
			return true
		}
	}
	return false
}

// anyCredPolicy says whether any allowlist exists at all.
func anyCredPolicy(settings map[string]string) bool {
	if settings[CredPolicyModeKey] != "legacy" {
		return true
	}
	for k := range settings {
		if strings.HasPrefix(k, CredAllowNodePrefix) || strings.HasPrefix(k, CredAllowUserPrefix) {
			return true
		}
	}
	return false
}

// credPolicyOf is the policy for machine ("" = unknown) and principal.
func credPolicyOf(settings map[string]string, machine, principal string) credPolicy {
	p := credPolicy{Machine: machine, Principal: principal}
	if machine != "" {
		p.Node = credAllowOf(settings, credNodeKey(machine))
	} else if anyNodePolicy(settings) {
		p.NodeUnknown = true
	}
	if principal != "" {
		p.User = credAllowOf(settings, credUserKey(principal))
	}
	return p
}

// Restricted says whether anything narrows this (machine, person).
func (p credPolicy) Restricted() bool { return p.Node.Set || p.User.Set || p.NodeUnknown }

// check is "" when subscription uuid of provider may be used, else why not.
func (p credPolicy) check(provider, uuid string) string {
	if provider == credvault.GitHub || !p.Restricted() {
		return ""
	}
	if p.NodeUnknown {
		return "this machine's identity is unknown (no enrolled name) and machine allowlists are in force"
	}
	u := normSubID(uuid)
	for _, sc := range []struct {
		what string
		a    credAllow
	}{{"machine " + p.Machine, p.Node}, {"person " + p.Principal, p.User}} {
		if !sc.a.Set || sc.a.All {
			continue
		}
		switch {
		case sc.a.Bad != "":
			return sc.what + "'s allowlist is malformed (" + sc.a.Bad + "): denied"
		case len(sc.a.IDs) == 0:
			return sc.what + "'s allowlist is empty: every subscription denied"
		case u == "":
			return "no account UUID recorded for it — it cannot match " + sc.what + "'s allowlist (record one: credentials action=bind)"
		case !sc.a.IDs[u]:
			return "not in " + sc.what + "'s allowlist"
		}
	}
	return ""
}

// policyMachine is the machine an endpoint's allowlist is keyed on: the name
// it joined as, never the hostname it reports now. "" when unknown.
func (s *Server) policyMachine(endpointID string) string {
	et, err := s.Store.EndpointTrustOf(endpointID)
	if err != nil || et.EnrolledHost == "" || et.EnrolledHost == "?" {
		return ""
	}
	return strings.ToLower(firstLabel(et.EnrolledHost))
}

// credPolicyFor reads the settings and builds the policy for an endpoint
// (its machine; "" = no endpoint, node scope unknown) and a person ("" = node
// scope only). A settings read error is an error: never "unrestricted".
func (s *Server) credPolicyFor(endpointID, principal string) (credPolicy, error) {
	settings, err := s.Store.FleetSettings()
	if err != nil {
		return credPolicy{}, err
	}
	machine := ""
	if endpointID != "" {
		machine = s.policyMachine(endpointID)
	}
	return credPolicyOf(settings, machine, principal), nil
}

// credVerdict judges one vault row: its subscription ID ("" when unrestricted
// — no secret is opened then) and why it is denied ("" = allowed).
func (s *Server) credVerdict(c store.Credential, p credPolicy) (uuid, why string) {
	if c.Provider == credvault.GitHub || !p.Restricted() {
		return "", ""
	}
	if s.Vault != nil {
		uuid = s.Vault.AccountUUID(c)
	}
	return uuid, p.check(c.Provider, uuid)
}

// credPolicyFilter keeps the rows p allows.
func (s *Server) credPolicyFilter(rows []store.Credential, p credPolicy) []store.Credential {
	if !p.Restricted() {
		return rows
	}
	out := rows[:0:0]
	for _, c := range rows {
		if _, why := s.credVerdict(c, p); why == "" {
			out = append(out, c)
		}
	}
	return out
}

// CredPolicyPut is the body of PUT /v1/fleet/cred-policy. Allow nil (JSON
// null, or absent) clears the scope (denied in strict mode); [] denies all.
// All explicitly grants all present and future eligible subscriptions.
type CredPolicyPut struct {
	Scope    string    `json:"scope"` // node | user
	ID       string    `json:"id"`    // a machine name, or a principal ID
	Allow    *[]string `json:"allow"`
	All      bool      `json:"all"`
	Action   string    `json:"action"`
	Revision string    `json:"revision"`
	Retain   []string  `json:"retain"`
}

// CredPolicyEntry is one account in the effective view.
type CredPolicyEntry struct {
	Provider    string `json:"provider"`
	Owner       string `json:"owner"`
	Account     string `json:"account"`
	AccountUUID string `json:"account_uuid,omitempty"`
	Allowed     bool   `json:"allowed"`
	Reason      string `json:"reason,omitempty"`
}

// handleCredPolicy: GET lists every allowlist (and, with machine= and/or
// principal=, or endpoint_id=, the effective view); PUT sets or clears one.
// Admin only.
func (s *Server) handleCredPolicy(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	switch r.Method {
	case http.MethodGet:
		s.credPolicyGet(w, r)
	case http.MethodPut, http.MethodPost:
		s.credPolicyPut(w, r)
	default:
		w.Header().Set("Allow", "GET, PUT")
		httpError(w, http.StatusMethodNotAllowed, "GET or PUT")
	}
}

func (s *Server) credPolicyGet(w http.ResponseWriter, r *http.Request) {
	settings, err := s.Store.FleetSettings()
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	type scope struct {
		ID    string   `json:"id"`
		Allow []string `json:"allow"`
		Error string   `json:"error,omitempty"`
		All   bool     `json:"all,omitempty"`
	}
	nodes, users := []scope{}, []scope{}
	for k, v := range settings {
		var id string
		var into *[]scope
		if m, ok := strings.CutPrefix(k, CredAllowNodePrefix); ok {
			id, into = m, &nodes
		} else if p, ok := strings.CutPrefix(k, CredAllowUserPrefix); ok {
			id, into = p, &users
		} else {
			continue
		}
		sc := scope{ID: id, Allow: []string{}}
		if v == `"*"` {
			sc.All = true
		} else if ids, err := parseCredAllow(v); err != nil {
			sc.Error = err.Error()
		} else {
			for x := range ids {
				sc.Allow = append(sc.Allow, x)
			}
			sort.Strings(sc.Allow)
		}
		*into = append(*into, sc)
	}
	sort.Slice(nodes, func(i, j int) bool { return nodes[i].ID < nodes[j].ID })
	sort.Slice(users, func(i, j int) bool { return users[i].ID < users[j].ID })
	out := map[string]any{"nodes": nodes, "users": users,
		"mode":        settings[CredPolicyModeKey],
		"semantics":   "unconfigured = denied in strict mode; all = explicit grant including future subscriptions; both machine and user must allow; legacy mode requires reviewed migration",
		"propagation": "central proxy ≤ 30 s; a node lease rechecks every " + credPolicyRecheck.String() + " while any list exists (older agents, and the first list ever set: ≤ 6 h); tokens already on a machine live to their own expiry"}

	if settings[CredPolicyModeKey] == "legacy" {
		review, err := s.credPolicyReview(settings)
		if err != nil {
			httpError(w, 500, err.Error())
			return
		}
		out["migration"] = review
	}
	q := r.URL.Query()
	machine, principal := q.Get("machine"), q.Get("principal")
	if epID := q.Get("endpoint_id"); epID != "" {
		ep, err := s.Store.EndpointByID(epID)
		if err != nil {
			httpError(w, http.StatusNotFound, "no endpoint "+epID)
			return
		}
		machine = s.policyMachine(ep.ID)
		host, osUser := s.nodeIdentity(ep)
		if principal == "" {
			if p, err := s.principalOnNode(ep.ID, host, osUser); err == nil {
				principal = p
			}
		}
		out["login"] = osUser + "@" + host
	}
	byEndpoint := q.Get("endpoint_id") != ""
	if machine != "" || principal != "" || byEndpoint {
		pol := credPolicyOf(settings, strings.ToLower(firstLabel(machine)), principal)
		if byEndpoint && principal == "" {
			pol.User = credAllow{Set: true, Bad: "no active owner"}
		}
		if machine == "" && !byEndpoint {
			pol.NodeUnknown = false // a person's view alone: the machine is the caller's question, not unknown
		}
		var rows []store.Credential
		for _, who := range []string{principal, store.PoolPrincipal} {
			if who == "" {
				continue
			}
			rs, err := s.Store.Credentials(who)
			if err != nil {
				httpError(w, http.StatusInternalServerError, err.Error())
				return
			}
			rows = append(rows, rs...)
		}
		eff := []CredPolicyEntry{}
		for _, c := range rows {
			if c.Provider == credvault.GitHub {
				continue
			}
			e := CredPolicyEntry{Provider: c.Provider, Owner: c.PrincipalID, Account: c.Account}
			if s.Vault != nil {
				e.AccountUUID = s.Vault.AccountUUID(c)
			}
			e.Reason = pol.check(c.Provider, e.AccountUUID)
			e.Allowed = e.Reason == ""
			eff = append(eff, e)
		}
		if machine != "" && principal != "" {
			if rev, err := s.Store.RevokedFor(machine, principal); err == nil && rev != nil {
				for i := range eff {
					eff[i].Allowed, eff[i].Reason = false, "revoked at "+rev.RevokedAt.Format(time.RFC3339)
				}
			}
		}
		out["effective"] = map[string]any{"machine": pol.Machine, "principal": principal, "restricted": pol.Restricted(), "accounts": eff}
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) credPolicyPut(w http.ResponseWriter, r *http.Request) {
	var req CredPolicyPut
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 64<<10)).Decode(&req); err != nil {
		httpError(w, http.StatusBadRequest, "malformed request: "+err.Error())
		return
	}
	if req.Action == "activate" {
		s.activateCredPolicy(w, r, req)
		return
	}
	if req.All && req.Allow != nil {
		httpError(w, 400, "choose all or allow, not both")
		return
	}
	var key string
	audit := store.CredAudit{Action: store.CredPolicy}
	switch req.Scope {
	case "node":
		if !nodeNameRE.MatchString(req.ID) {
			httpError(w, http.StatusBadRequest, "node scope needs id: a machine name")
			return
		}
		key, audit.Hostname = credNodeKey(req.ID), strings.ToLower(firstLabel(req.ID))
	case "user":
		if !principalKeyRE.MatchString(req.ID) || req.ID == store.PoolPrincipal {
			httpError(w, http.StatusBadRequest, "user scope needs id: a principal ID (gh:<id>)")
			return
		}
		if _, err := s.Store.Principal(req.ID); err != nil {
			// Administrators can authorize an invited user before their first login.
			known := false
			if gid, ok := githubIDOf(req.ID); ok {
				u, e := s.Store.HubUserByID(gid)
				if e != nil {
					httpError(w, 500, e.Error())
					return
				}
				role, e := s.githubRole(gid)
				if e != nil {
					httpError(w, 500, e.Error())
					return
				}
				known = u != nil || role == roleAdmin
			}
			if !known {
				httpError(w, http.StatusBadRequest, "unknown principal "+req.ID)
				return
			}
		}
		key, audit.PrincipalID = credUserKey(req.ID), req.ID
	default:
		httpError(w, http.StatusBadRequest, "scope must be node or user")
		return
	}
	value := ""
	if req.Allow != nil {
		norm := []string{}
		seen := map[string]bool{}
		for _, id := range *req.Allow {
			n := normSubID(id)
			if !validSubID(n) {
				httpError(w, http.StatusBadRequest, fmt.Sprintf("%q is not a subscription ID (a Claude account UUID, or codex:account:<32 hex>) — labels are display only", id))
				return
			}
			if !seen[n] {
				seen[n] = true
				norm = append(norm, n)
			}
		}
		if len(norm) > credPolicyMax {
			httpError(w, http.StatusBadRequest, fmt.Sprintf("at most %d subscription IDs", credPolicyMax))
			return
		}
		sort.Strings(norm)
		b, _ := json.Marshal(norm)
		value = string(b)
	}
	if req.All {
		value = `"*"`
	}
	settings, err := s.Store.FleetSettings()
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	before, had := settings[key]
	now := time.Now()
	if err := s.Store.SetFleetSetting(key, value, now); err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	show := func(v string, set bool) string {
		if !set {
			return "unconfigured (mode=" + settings[CredPolicyModeKey] + ")"
		}
		return v
	}
	audit.Detail = req.Scope + " " + req.ID + ": " + show(before, had) + " → " + show(value, value != "") + " · by " + actorOf(r)
	if err := s.Store.AddCredAudit(audit); err != nil {
		log.Printf("cred policy: audit %s: %v", key, err)
	}
	s.settingAudit(actorOf(r), key, before, value, now)
	s.sessCred.drop("") // the central proxy's next resolve re-reads its pass (#1969's cache)
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "key": key, "all": req.All, "allow": func() any {
		if req.All {
			return nil
		}
		return json.RawMessage(orNull(value))
	}()})
}

func orNull(v string) string {
	if v == "" {
		return "null"
	}
	return v
}
