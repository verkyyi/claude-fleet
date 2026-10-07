package api

import (
	"errors"
	"log"
	"net/http"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// Admin and user see different hubs (claude-fleet#1985, EPIC #1982 C3).
//
// An admin — a GitHub person CCQUOTA_GITHUB_ADMINS names, or the operator's
// shared doors (the viewer token, a tailnet peer) — sees and runs
// everything. A user — a GitHub person on the list, or a WeCom person — sees
// only their own: the usage, sessions and live rows whose os_user is the
// machine login the hub knows as theirs, their own devices, and the fleet
// through FleetScope. Subscriptions, machines, join codes, maintenance, SPOT
// machines, credentials, audits and the team configuration are an admin's.
//
// Every route the hub mounts is named in routeAccess. roles_test.go walks
// every pattern Handler registers and fails on one the table does not name,
// then asks each with a user's cookie: an admin route must answer 403, a
// user route must not, and the listing routes must carry only the user's
// own rows.

// Route classes.
const (
	// accessPublic needs no credential: the way in, health, the installer.
	accessPublic = "public"
	// accessSelf authenticates itself (a node token, an endpoint token, a
	// connection certificate, a signed share link) and scopes its own answer.
	accessSelf = "self"
	// accessAdmin is refused to a user (403) by adminOnly.
	accessAdmin = "admin"
	// accessUser is open to a user, scoped to their own rows.
	accessUser = "user"
)

// routeAccess is every pattern Handler mounts and who may use it. A route
// added to Handler without a row here fails roles_test.go.
var routeAccess = map[string]string{
	// The way in, and what a signed-out machine must reach.
	"/enter": accessPublic, "/logout": accessPublic, "/signin": accessPublic,
	"/auth/github/start": accessPublic, "/auth/github/callback": accessPublic,
	"/healthz": accessPublic, "/version": accessPublic,
	"/install": accessPublic, "/install/": accessPublic,
	// The public counter (claude-fleet#1988); the handler 404s it when off.
	"/meter.json": accessPublic, "/odometer.svg": accessPublic,
	"/v1/fleet/ssh-ca.pub":  accessPublic,
	"/v1/fleet/login/start": accessPublic, "/v1/fleet/login/poll": accessPublic,

	// Their own credential, checked by the handler.
	"/v1/ingest": accessSelf, "/v1/ingest/repo": accessSelf, "/v1/ingest/growth": accessSelf,
	"/v1/growth/latest": accessSelf, "/v1/live/report": accessSelf,
	"/v1/collectors/quota-lease": accessSelf,
	control.Path:                 accessSelf, "/v1/node/lease": accessSelf, "/v1/node/place": accessSelf,
	"/v1/node/move": accessSelf, "/v1/node/move/bundle": accessSelf, "/v1/node/move/bundle/": accessSelf,
	"/v1/node/join": accessSelf, "/v1/node/dist/": accessSelf, "/v1/node/self": accessSelf,
	"/v1/node/reclaim": accessSelf, "/v1/node/maintenance": accessSelf, "/v1/node/peer-cert": accessSelf,
	"/v1/node/client": accessSelf, "/v1/node/client/actions": accessSelf,
	"/v1/node/worker-records": accessSelf, "/v1/node/progress": accessSelf,
	"/v1/node/credentials": accessSelf,
	// The team layer is read by every machine that applies it — a node's
	// token, a client's certificate — and its PUT is refused to anyone but an
	// admin by the handler itself.
	control.TeamBundlePath: accessSelf, control.PersonBundlePath: accessSelf,
	// Session, token or certificate; the handler scopes a person's answer
	// through FleetScope.
	control.SessionsPath: accessUser, control.SummaryPath: accessUser,
	control.WritePath: accessSelf, control.ClientPath: accessSelf, ClientTestPath: accessSelf,
	control.ClientPath + "/actions": accessSelf, control.ClientPath + "/place": accessSelf,
	control.RenewPath: accessSelf, control.HomePath: accessSelf,
	"/v1/fleet/client-settings": accessSelf,
	"/v1/fleet/session-cred":    accessSelf, "/v1/fleet/session-cred/": accessSelf,
	control.SSHRelayPath: accessSelf, control.SSHRelayDataPath: accessSelf,
	control.RoutesPath: accessSelf,
	"/v1/share":        accessSelf, "/share": accessSelf, "/share/": accessSelf,

	// Drill people (claude-fleet#2010): the invite is a certificate signature
	// or the viewer gate + adminOnly inside the handler; the approve code is
	// the whole credential; a drill person deletes itself by cert or code.
	DrillPath: accessSelf, LoginApprovePath: accessSelf, DrillSelfPath: accessSelf,

	// An admin's: subscriptions, machines, join codes, SPOT, credentials,
	// audits, settings, the operator's own analytics.
	"/v1/fleet/join-codes": accessAdmin, "/v1/fleet/peer-certs": accessAdmin,
	"/v1/fleet/spot":     accessAdmin,
	"/v1/fleet/accounts": accessAdmin, "/v1/fleet/settings": accessAdmin, "/v1/fleet/users": accessAdmin,
	"/v1/fleet/credentials": accessAdmin, "/v1/fleet/credentials/revoke": accessAdmin,
	"/v1/fleet/credentials/audit": accessAdmin, "/credentials": accessAdmin,
	"/v1/fleet/ssh-relays": accessAdmin,
	"/v1/accounts":         accessAdmin, "/v1/accounts/label": accessAdmin,
	"/v1/collectors": accessAdmin, "/v1/account-usage": accessAdmin,
	"/v1/limits": accessAdmin, "/v1/limits/history": accessAdmin, "/v1/quota/history": accessAdmin,
	"/v1/endpoints": accessAdmin, "/v1/account-switches": accessAdmin, "/v1/endpoint-accounts": accessAdmin,
	"/v1/findings": accessAdmin, "/v1/findings/mutes": accessAdmin,
	"/v1/repos": accessAdmin, "/v1/repo/flow": accessAdmin, "/v1/repo/issues": accessAdmin,
	"/v1/repo/cost": accessAdmin, "/v1/repo/human-debt": accessAdmin,
	"/v1/access": accessAdmin, "/access": accessAdmin, "/access/": accessAdmin,
	"/growth": accessAdmin, "/growth/": accessAdmin,
	"/badge/": accessAdmin, "/embed/": accessAdmin,

	// A user's own: scoped to their machine login, their principal, or
	// FleetScope.
	"/": accessUser, "/v1/me": accessUser, "/v1/fx": accessUser,
	"/v1/usage": accessUser, "/v1/history": accessUser, "/v1/summary": accessUser,
	"/v1/sessions": accessUser, "/v1/sessions/": accessUser,
	"/v1/live": accessUser, "/v1/live/stream": accessUser,
	"/v1/user": accessUser, "/u/": accessUser, "/mcp": accessUser,
	"/sessions": accessUser, "/v1/fleet/me": accessUser, "/v1/fleet/": accessUser,
	// The roster, cut by FleetScope to the machines where their login runs
	// (claude-fleet#1411); maintenance, SPOT and join codes stay an admin's.
	"/v1/nodes": accessUser, "/nodes": accessUser,
	"/v1/fleet/connect": accessUser, "/v1/fleet/cert": accessUser,
	"/fleet/login": accessUser, "/connect": accessUser,
	"/v1/fleet/devices": accessUser, "/v1/fleet/devices/revoke": accessUser,
}

// routeMux records every pattern Handler mounts, so roles_test.go can hold
// the table to the router rather than to a list someone keeps by hand.
type routeMux struct {
	*http.ServeMux
	patterns []string
}

func (m *routeMux) Handle(p string, h http.Handler) {
	m.patterns = append(m.patterns, p)
	m.ServeMux.Handle(p, h)
}

func (m *routeMux) HandleFunc(p string, h func(http.ResponseWriter, *http.Request)) {
	m.Handle(p, http.HandlerFunc(h))
}

// noLogin is the os_user a user without a machine login is scoped to: no row
// carries it, so they see nothing rather than everything.
const noLogin = "\x00no machine login"

// errNoPerson is a user whose principal the hub cannot read.
var errNoPerson = errors.New("could not read who you are")

// machineLoginOf is the OS login the hub knows as principal's: a GitHub
// user's machine_login (set by an admin), a WeCom person's minted login.
// "" when there is none yet.
func (s *Server) machineLoginOf(principal string) (string, error) {
	if s.Store == nil || principal == "" {
		return "", nil
	}
	if id, ok := githubIDOf(principal); ok {
		u, err := s.Store.HubUserByID(id)
		if err != nil || u == nil {
			return "", err
		}
		return u.MachineLogin, nil
	}
	if !s.Fleet {
		return "", nil // no fleet module, no principals table: no login on record
	}
	p, err := s.Store.Principal(principal)
	if errors.Is(err, store.ErrNoPrincipal) {
		return "", nil
	}
	if err != nil || p == nil {
		return "", err
	}
	return p.Login, nil
}

// UserScope is the os_user a request's rows are cut to: scoped=false for an
// admin (everything), else the caller's machine login — noLogin when they
// have none, so a user never falls through to the whole hub.
func (s *Server) UserScope(r *http.Request) (login string, scoped bool, err error) {
	if roleOf(r.Context()) != roleUser {
		return "", false, nil
	}
	login, err = s.machineLoginOf(principalOf(r.Context()))
	if err != nil {
		return "", true, errNoPerson
	}
	if login == "" {
		login = noLogin
	}
	return login, true, nil
}

// userScope is UserScope answering the error itself.
func (s *Server) userScope(w http.ResponseWriter, r *http.Request) (string, bool, bool) {
	login, scoped, err := s.UserScope(r)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return "", false, false
	}
	return login, scoped, true
}

// scopeRows keeps the rows whose os_user is login; every list a user gets
// that the store did not already cut goes through it.
func scopeRows[T any](rows []T, osUser func(T) string, login string) []T {
	out := make([]T, 0, len(rows))
	for _, r := range rows {
		if osUser(r) == login {
			out = append(out, r)
		}
	}
	return out
}

// seesAll is whether the caller sees every person's rows: an admin or the
// operator's doors.
func seesAll(r *http.Request) bool { return roleOf(r.Context()) != roleUser }

// adminOnly refuses a user: subscriptions, machines, join codes, credentials
// and the rest are an admin's, not something a colleague can read or widen
// for themselves. It lets through an admin (a GitHub person
// CCQUOTA_GITHUB_ADMINS names) and the operator's shared doors (the viewer
// token, a tailnet peer), and refuses everyone else roleOf calls a user — a
// GitHub user, a WeCom person (EPIC #1982 rule 3). Each refusal lands in the
// fleet audit. Mounted INSIDE viewerOnly, so it only ever sees an
// already-admitted request.
func (s *Server) adminOnly(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if roleOf(r.Context()) == roleUser {
			s.auditRoleDenied(r)
			httpError(w, http.StatusForbidden, "只有管理员可以使用这一项（only an admin can use this）")
			return
		}
		next.ServeHTTP(w, r)
	})
}

// auditRoleDenied is one fleet_audit row per refusal: actor, role_denied,
// route:<method> <path>, FORBIDDEN — hub_audit on a hub without the fleet
// module.
func (s *Server) auditRoleDenied(r *http.Request) {
	if s.Store == nil {
		return
	}
	actor := principalOf(r.Context())
	if sess := sessionOf(r.Context()); sess != nil && sess.Name != "" {
		actor += " (" + sess.Name + ")"
	}
	target, now := "route:"+r.Method+" "+r.URL.Path, time.Now()
	var err error
	if s.Fleet {
		err = s.Store.FleetAudit(actor, "role_denied", target, "FORBIDDEN", "", now)
	} else {
		// No fleet module, no fleet_audit: the people audit C2 keeps.
		err = s.Store.HubAudit(actor, "role_denied", target, "refused", "admin only", now)
	}
	if err != nil {
		log.Printf("role audit: %v", err)
	}
}

// Pages, as /v1/me lists them for the menu (C7, C8). A user's four; an
// admin's every one.
var (
	userPages  = []string{"overview", "sessions", "devices", "config"}
	adminPages = []string{"overview", "sessions", "devices", "config",
		"subscriptions", "machines", "people", "credentials", "audit", "access"}
)

func pagesFor(role string) []string {
	switch role {
	case roleUser:
		return append([]string(nil), userPages...)
	case "":
		return []string{}
	}
	return append([]string(nil), adminPages...)
}

// IsUserTool is whether an MCP tool may answer a user, scoped to their
// machine login. The rest read subscriptions, machines or the whole hub.
func IsUserTool(name string) bool {
	switch name {
	case "get_live", "get_fx", "get_user", "list_sessions", "get_session",
		"usage_summary", "usage_history",
		"usage_by_source", "usage_by_provider", "usage_by_project", "usage_by_session",
		"usage_by_model", "usage_by_branch", "usage_by_effort", "usage_by_entrypoint":
		return true
	}
	// The fleet tools scope themselves through FleetScope.
	for _, t := range FleetTools {
		if t == name {
			return true
		}
	}
	return false
}
