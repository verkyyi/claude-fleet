package api

import (
	"context"
	"errors"
	"log"
	"net/http"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

// Admin and user see different hubs (claude-fleet#1985, EPIC #1982 C3).
//
// An admin — a GitHub person CCQUOTA_GITHUB_ADMINS names, or the operator's
// shared door (the viewer token) — sees and runs everything. A user — a
// GitHub person on the list — sees
// only their own: the usage, sessions and live rows whose os_user is the
// machine login the hub knows as theirs, their own devices, and the fleet
// through FleetScope. Subscriptions, machines, join codes, maintenance,
// credentials, audits and the team configuration are an admin's.
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
// A console page keeps its row at its old path: app_mount.go serves it under
// /app (claude-fleet#3583) and TestAppPagesAreRoutes holds the two together.
var routeAccess = map[string]string{
	AttachmentPath:                 accessUser,
	control.AttachmentDataPath:     accessSelf,
	control.ChatAttachmentDataPath: accessSelf,
	// The way in, and what a signed-out machine must reach.
	"/logout": accessPublic, "/signin": accessPublic,
	"/auth/github/start": accessPublic, "/auth/github/callback": accessPublic,
	"/auth/wechat/start": accessPublic, "/auth/wechat/callback": accessPublic, "/auth/wechat/bind": accessPublic,
	wxQRPath: accessPublic, wxPollPath: accessPublic, wxRelayCBPath: accessPublic,
	// workbench handing over a 试用二维码 scan (MRGB): its own gate, the internal token
	WxTrialScanPath:     accessPublic,
	"/auth/email/start": accessPublic, "/auth/email/link": accessPublic, "/auth/email/code": accessPublic,
	ConsoleTicketPath: accessPublic, ConsoleTicketNodePath: accessSelf,
	// The applicant note (ccq_applicant) is its own credential, read only
	// here (claude-fleet#4051).
	ApplyPath: accessSelf, ApplyEditPath: accessSelf, ApplyWithdrawPath: accessSelf, ApplicantPath: accessSelf,
	"/healthz": accessPublic, "/version": accessPublic,
	"/readyz": accessPublic, "/v1/deploy-probe": accessPublic,
	"/install": accessPublic, "/install/": accessPublic,
	"/v1/fleet/release/":   accessPublic, // signed node releases (claude-fleet#2335)
	control.AccountKeyPath: accessPublic, // the admin seat's ticket key (claude-fleet#3557)
	ReleaseStatsPath:       accessAdmin,  // the release ledger (claude-fleet#3140)
	TermHealthPath:         accessAdmin,  // the browser terminals' numbers (RMVE)
	ReleaseKeysPath:        accessAdmin,  // the signing keys' state, 404 to a member (claude-fleet#3937)
	// The public counter (claude-fleet#1988); the handler 404s it when off.
	"/meter.json": accessPublic,
	// The tab icon, a copy of the site's logo (claude-fleet#3946).
	"/favicon.svg": accessPublic, "/favicon.ico": accessPublic, "/apple-touch-icon.png": accessPublic,
	"/v1/fleet/ssh-ca.pub":  accessPublic,
	"/v1/fleet/login/start": accessPublic, "/v1/fleet/login/poll": accessPublic,
	// Invites (claude-fleet#2261): the code in the path / the signed note
	// is the whole credential.
	InvitePath: accessPublic, LoginRefusedPath: accessPublic,

	// Their own credential, checked by the handler.
	"/v1/ingest": accessSelf, "/v1/live/report": accessSelf,
	"/v1/collectors/quota-lease": accessSelf,
	control.Path:                 accessSelf, "/v1/node/lease": accessSelf, "/v1/node/place": accessSelf,
	"/v1/node/move": accessSelf, "/v1/node/move/bundle": accessSelf, "/v1/node/move/bundle/": accessSelf,
	"/v1/node/attachment/": accessSelf,
	"/v1/node/join":        accessSelf, "/v1/node/dist/": accessSelf, "/v1/node/self": accessSelf, "/v1/node/gate": accessSelf,
	"/v1/node/maintenance": accessSelf, "/v1/node/peer-cert": accessSelf, "/v1/node/peers": accessSelf,
	NodeLeavePath:     accessSelf,
	"/v1/node/client": accessSelf, "/v1/node/client/actions": accessSelf,
	"/v1/node/worker-records": accessSelf, "/v1/node/progress": accessSelf,
	NodeTasksPath: accessSelf, NodeTasksPath + "/": accessSelf,
	NodeIDsPath: accessSelf, NodeIDsPath + "/": accessSelf, // the ID mirror (EPIC T497 C2)
	// a throwaway Job, the caller's own pod (claude-fleet#3552); a service run's Job, its own one-time key (#4005)
	NodeJobsPath: accessSelf, NodeJobsPath + "/": accessSelf, NodeSvcRunsPath + "/": accessSelf,
	"/v1/node/credentials": accessSelf,
	NodeKeyPath:            accessSelf, // a node's signing key (claude-fleet#3699)
	AdminTokenNodePath:     accessSelf, // the admin role account's token (claude-fleet#3724)
	// The direct door (claude-fleet#3068): a machine's own list and record.
	control.EntryKeysNodePath: accessSelf, control.EntryAuditNodePath: accessSelf,
	control.TrialEgressNodePath: accessSelf,
	// A machine's trial guard (claude-fleet WACK C4): who is on trial here, and what it did.
	TrialLimitsNodePath: accessSelf, TrialAlertNodePath: accessSelf,
	// … its reach, and the cluster door's table (claude-fleet#3549).
	control.EntryReachNodePath: accessSelf, control.EntryRoutesNodePath: accessSelf,
	control.DoorHomePath: accessSelf, control.DoorSessionPath: accessSelf,
	// … and a person's own keys, name and home; the handler scopes them.
	control.EntryKeysPath: accessUser, control.EntryKeysPath + "/": accessUser,
	control.EntryNamePath: accessUser, control.EntryHomePath: accessUser,
	// claude-fleet#2850: the pool manifest; #3826: which agents a login may
	// start — any enrollment token, each.
	NodePoolPath: accessSelf, NodeAgentsPath: accessSelf,
	// claude-fleet T673: the repos the person's machines host between them.
	NodeReposPath: accessSelf,
	// The Singapore relay (claude-fleet#1974): a node token mints a pass;
	// the check authenticates the pass the forwarder carries.
	"/v1/node/relay-credential": accessSelf, RelayCheckPath: accessSelf,
	RelayRevocationsPath: accessSelf, NodeRevocationsPath: accessSelf,
	// The service door (claude-fleet#4003): a service principal's fcs_ token,
	// scope by scope; nothing else opens it.
	SvcPrefix: accessSelf,
	// The team layer is read by every machine that applies it — a node's
	// token, a client's certificate — and its PUT is refused to anyone but an
	// admin by the handler itself.
	control.TeamBundlePath: accessSelf, control.PersonBundlePath: accessSelf,
	// Session, token or certificate; the handler scopes a person's answer
	// through FleetScope.
	control.SessionsPath: accessUser, control.SummaryPath: accessUser,
	control.ClientEventsPath: accessUser,
	control.WritePath:        accessSelf, control.ClientPath: accessSelf, ClientTestPath: accessSelf,
	control.ClientPath + "/actions": accessSelf, control.ClientPath + "/place": accessSelf,
	control.RenewPath: accessSelf, control.HomePath: accessSelf, control.LoginNodePath: accessSelf,
	"/v1/fleet/client-settings": accessSelf,
	"/v1/fleet/session-cred":    accessSelf, "/v1/fleet/session-cred/": accessSelf,
	CredProxyResolvePath: accessSelf, CredProxyRebindPath: accessSelf,
	// Per-person budgets (claude-fleet#1977): each proxy reports with its own
	// token; the list is the operator's, a user reads their own (我的用量,
	// claude-fleet#2519).
	CredProxyUsagePath: accessSelf, "/v1/node/usage": accessSelf, "/v1/fleet/person-usage": accessUser,
	control.SSHRelayPath: accessSelf, control.SSHRelayDataPath: accessSelf,
	control.ChatRelayDataPath: accessSelf, control.TermDataPath: accessSelf,
	// The browser terminal (claude-fleet#3838): each person their own.
	TermConnectPath: accessUser, TermHomePath: accessUser,
	TermClientPath: accessUser, TermClientPath + "/actions": accessUser,
	// The web chat (claude-fleet#3645): each person their own conversation.
	ChatPathPrefix: accessUser,
	// The 60-second trial (claude-fleet#3590): the start mints a trial
	// invite for a stranger; the claim and the timing are the person's own.
	TryStartPath: accessPublic, TryClaimPath: accessUser, TryTimingPath: accessUser, TryStatePath: accessUser,
	// The heartbeat and the pause (claude-fleet#4060): the person's own seat.
	TryBeatPath: accessUser, TryPausePath: accessUser,
	TryStatsPath: accessAdmin,
	// 管理侧「申请」(claude-fleet#4052): 404 to a member, as a page is
	AdminRequestsPath: accessAdmin, adminRequestsPrefix: accessAdmin,
	// 管理侧「发通知」(claude-fleet#4063): 404 to a member, as the requests
	AdminNoticesPath: accessAdmin,
	// 管理侧「试用二维码」(claude-fleet MRGB): 404 to a member, as the requests
	AdminTrialCodesPath: accessAdmin, adminTrialCodesPrefix: accessAdmin,
	// 紧急开关 (WACK C5): 403 to a member
	AdminEmergencyPath: accessAdmin,
	// A person's task authority (claude-fleet#4896): a node token or a person's own sign-in.
	FleetAuthorityPath: accessSelf, FleetAuthorityPath + "/": accessSelf,
	control.RoutesPath: accessSelf,

	// An admin's: subscriptions, machines, join codes, credentials,
	// audits, settings, the operator's own analytics.
	"/v1/fleet/join-codes": accessAdmin, "/v1/fleet/peer-certs": accessAdmin, OperationSettlePath: accessAdmin,
	FleetNodesPrefix: accessAdmin, "/v1/node/desired": accessSelf, // claude-fleet#2214
	CIRunnersPath:        accessAdmin, // claude-fleet#3144
	"/v1/fleet/accounts": accessAdmin, "/v1/fleet/settings": accessAdmin, "/v1/fleet/gate": accessAdmin, "/v1/fleet/users": accessAdmin, "/v1/fleet/users/sessions": accessAdmin, "/v1/fleet/invites": accessAdmin,
	"/v1/fleet/credentials": accessAdmin, "/v1/fleet/credentials/revoke": accessAdmin,
	"/v1/fleet/revocations":       accessAdmin,
	SvcAdminPath:                  accessAdmin,
	NodeRevokePath:                accessAdmin,
	NodeRolePath:                  accessAdmin, // claude-fleet#4886
	"/v1/fleet/credentials/audit": accessAdmin,
	CredPolicyPath:                accessAdmin,
	MachinePolicyPath:             accessAdmin,
	"/v1/fleet/ssh-relays":        accessAdmin,
	"/v1/accounts":                accessAdmin, "/v1/accounts/label": accessAdmin,
	"/v1/me/quota":   accessAdmin, // the pool's windows (claude-fleet#3227)
	"/v1/collectors": accessAdmin, "/v1/account-usage": accessAdmin,
	"/v1/limits": accessAdmin, "/v1/limits/history": accessAdmin, "/v1/quota/history": accessAdmin,
	"/v1/endpoints": accessAdmin, "/v1/account-switches": accessAdmin, "/v1/endpoint-accounts": accessAdmin,
	"/v1/access": accessAdmin,
	// The one audit the admin side reads (claude-fleet#1990).
	AuditPath: accessAdmin,
	// The whole hub an admin's daily pages used to show (claude-fleet#2515).
	AdminSessionsPath: accessAdmin, AdminOverviewPath: accessAdmin, AdminDevicesPath: accessAdmin,
	// 全队用量 reads each person as their own page does (claude-fleet#3936).
	AdminUsagePath: accessAdmin, TrialSpendPath: accessAdmin,
	// The new console's admin side (claude-fleet#3925): to anyone else, the
	// 404 an unknown address gets.
	AdminPrefix: accessAdmin, AdminPrefix + "/": accessAdmin,

	// A user's own: scoped to their machine login, their principal, or
	// FleetScope.
	"/": accessUser, "/v1/me": accessUser, "/v1/me/identities": accessUser,
	meWxBindQRPath: accessUser, meWxBindPollPath: accessUser, // claude-fleet#4057
	// 我的用量 in one answer (claude-fleet#3227): their limit, days, models
	// and where it went, off pool_usage under their principal.
	"/v1/me/usage":     accessUser,
	MeTrialUpgradePath: accessUser, // 申请转正 (claude-fleet T796)
	// 我自己的订阅 (claude-fleet#4035): each person their own rows only.
	AdminSubsLoginPath: accessAdmin, AdminSubsFinishPath: accessAdmin, AdminSubsTokenPath: accessAdmin, AdminSubsRefreshPath: accessAdmin,
	MeSubsPath: accessUser, MeSubsLoginPath: accessUser, MeSubsFinishPath: accessUser,
	MeSubsPausePath: accessUser, MeSubsDeletePath: accessUser,
	"/v1/usage": accessUser, "/v1/history": accessUser, "/v1/summary": accessUser,
	"/v1/sessions": accessUser, "/v1/sessions/": accessUser,
	"/v1/live": accessUser, "/v1/live/stream": accessUser,
	"/v1/user": accessUser, "/mcp": accessUser,
	// The app's push channel (claude-fleet#2794): each topic cut like its route.
	"/v1/fleet/stream": accessUser,
	// 我的会话 (claude-fleet#3927): live and ended, cut to their own.
	FleetSessionListPath: accessUser,
	"/v1/fleet/me":       accessUser, "/v1/fleet/": accessUser,
	// 任务 (claude-fleet#3325): the viewer's own records.
	"/v1/fleet/tasks": accessUser, "/v1/fleet/tasks/": accessUser,
	// The roster, cut by FleetScope to the machines where their login runs
	// (claude-fleet#1411); maintenance and join codes stay an admin's.
	"/v1/nodes": accessUser,
	// One machine (claude-fleet#2796): 404 unless one of their logins is on it.
	NodeDetailPrefix:    accessUser,
	"/v1/fleet/connect": accessUser, "/v1/fleet/cert": accessUser,
	"/fleet/login": accessUser,
	// 我的 (claude-fleet#3926): a page of the new console only, each person their own
	mePagePath: accessUser,
	// 设备 (claude-fleet#3930): a page of the new console only, each person their own
	devicesPagePath: accessUser,
	// 设置 (claude-fleet#3931): reads /v1/me, /v1/me/identities and their own
	// /v1/fleet/person-bundle — each person their own
	settingsPagePath:    accessUser,
	"/v1/fleet/devices": accessUser, "/v1/fleet/devices/revoke": accessUser,
	// Take a machine off the hub (claude-fleet#1928): a user only their own.
	NodeRetirePath: accessUser,
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
// carries it, so they see nothing rather than everything. A '/' and spaces no
// OS login can hold, and no NUL byte: Postgres refuses one in a text argument.
const noLogin = "/no machine login/"

// errNoPerson is a user whose principal the hub cannot read.
var errNoPerson = errors.New("could not read who you are")

// machineLoginOf is the OS login the hub knows as principal's: a GitHub
// user's machine_login (set by an admin), else the login minted for them.
// "" when there is none yet.
func (s *Server) machineLoginOf(principal string) (string, error) {
	if s.Store == nil || principal == "" {
		return "", nil
	}
	if isPerson(principal) {
		u, err := s.personRow(principal)
		if err != nil || u == nil {
			return "", err
		}
		if u.MachineLogin != "" {
			return u.MachineLogin, nil
		}
		// No admin mapping: the login fleet.auto_assign minted at their first
		// sign-in, below — without it a newcomer held a certificate for that
		// login and saw none of its sessions (claude-fleet#2096).
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

// loginPairsOf is principal's (machine, login) pairs: their ACTIVE
// fleet_accounts rows (claude-fleet#2514). A login NAME is not a person — the
// same `ubuntu` on two machines is two people — so this, not machineLoginOf,
// is who a person is on the machines. A 登录即认人 row (claude-fleet#2212) also
// carries the computer's own endpoint, so its usage stays theirs when the
// machine's name drifts: a person's own laptop counts by the device they
// signed in on, never by the local name it runs as.
func (s *Server) loginPairsOf(principal string) ([]store.LoginPair, error) {
	if !s.Fleet || s.Store == nil || principal == "" {
		return nil, nil
	}
	accts, err := s.Store.FleetAccounts(principal)
	if err != nil {
		return nil, err
	}
	out := []store.LoginPair{}
	for _, a := range accts {
		if a.State != store.AccountActive {
			continue
		}
		p := store.LoginPair{Hostname: a.Hostname, Login: a.Login}
		if !a.Managed() {
			p.EndpointID = a.EndpointID // a managed row's endpoint is the admin agent the op went to
		}
		out = append(out, p)
	}
	return out, nil
}

// UserLogins is what a user's rows are cut to (claude-fleet#1985,
// claude-fleet#2514). nil — an admin or the operator's doors — is no cut.
type UserLogins struct {
	// Login names the user's page: their machine login, noLogin when they
	// have none.
	Login string
	// Owner is their own (endpoint, login) pairs, resolved from their
	// (machine, login) accounts. nil on a hub without the fleet module, where
	// the login name is all the hub knows of anyone and Login is the cut.
	Owner *store.Owner
}

// Apply cuts f to the user's rows (the subscription is the caller's).
func (u *UserLogins) Apply(f *store.Filter) {
	if u == nil {
		return
	}
	if u.Owner != nil {
		f.Owner = u.Owner
		return
	}
	f.OSUser = u.Login
}

// Owns is whether a row reported by endpointID as osUser is the user's.
func (u *UserLogins) Owns(endpointID, osUser string) bool {
	if u == nil {
		return true
	}
	if u.Owner != nil {
		return u.Owner.Owns(endpointID, osUser)
	}
	return osUser == u.Login
}

// OwnerOf is the store cut for the user's own page, nil for none.
func (u *UserLogins) OwnerOf() *store.Owner {
	if u == nil {
		return nil
	}
	return u.Owner
}

func (u *UserLogins) key() string {
	if u == nil {
		return ""
	}
	if u.Owner != nil {
		return u.Owner.Key()
	}
	return "login\x01" + u.Login
}

// UserScope is what a request's rows are cut to: nil for an admin on an
// admin route and the operator's doors (everything), else the caller's own
// logins — none at all when they have none, so a user never falls through to
// the whole hub. An admin on a daily page's route is cut like a user
// (ownView, claude-fleet#2515).
func (s *Server) UserScope(r *http.Request) (*UserLogins, error) {
	if !cutToSelf(r.Context()) {
		return nil, nil
	}
	pid := principalOf(r.Context())
	login, err := s.machineLoginOf(pid)
	if err != nil {
		return nil, errNoPerson
	}
	if login == "" {
		login = noLogin
	}
	u := &UserLogins{Login: login}
	if s.Fleet {
		pairs, err := s.loginPairsOf(pid)
		if err != nil {
			return nil, errNoPerson
		}
		if u.Owner, err = s.Store.OwnerOf(pairs); err != nil {
			return nil, errNoPerson
		}
	}
	return u, nil
}

// userScope is UserScope answering the error itself.
func (s *Server) userScope(w http.ResponseWriter, r *http.Request) (*UserLogins, bool) {
	who, err := s.UserScope(r)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return nil, false
	}
	return who, true
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

// seesAll is whether the caller sees every person's rows: the operator's
// doors, or an admin anywhere but a daily page's route (ownView).
func seesAll(r *http.Request) bool { return !cutToSelf(r.Context()) }

// Admins see their own on the daily pages (claude-fleet#2515, EPIC #2512 C3).
// Overview, Sessions, Devices and Config show an admin exactly what they show a
// user — their own (machine, login) pairs, their own devices — and the whole
// hub moves to the admin routes (/v1/admin/sessions, /v1/admin/overview,
// /v1/admin/devices). The routes those pages read are mounted through ownView;
// every other route keeps what it gave an admin. The operator's doors (the
// viewer token, the sidebar's automation) are never cut.

// ownViewKey marks a request that came in on a daily page's route.
type ownViewKey struct{}

// ownView mounts a daily page's route: an admin there is cut to their own
// rows, as a user always is.
func ownView(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		next.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), ownViewKey{}, true)))
	})
}

// isOwnView is whether r came in on an ownView route.
func isOwnView(ctx context.Context) bool {
	v, _ := ctx.Value(ownViewKey{}).(bool)
	return v
}

// cutToSelf is whether the caller's rows are cut to their own: always a
// user's, an admin's on a daily page's route, never the operator's.
func cutToSelf(ctx context.Context) bool {
	switch roleOf(ctx) {
	case roleUser, roleTrial:
		return true
	case roleAdmin:
		return isOwnView(ctx) && principalOf(ctx) != ""
	}
	return false
}

// adminOnly refuses a user: subscriptions, machines, join codes, credentials
// and the rest are an admin's, not something a colleague can read or widen
// for themselves. It lets through an admin (a GitHub person
// CCQUOTA_GITHUB_ADMINS names) and the operator's shared doors (the viewer
// token), and refuses everyone else roleOf calls a user (EPIC #1982 rule 3). Each refusal lands in the
// fleet audit. Mounted INSIDE viewerOnly, so it only ever sees an
// already-admitted request.
func (s *Server) adminOnly(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if memberRole(roleOf(r.Context())) {
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

// Pages, as /v1/me lists them for the menu (C7, C8). A user's own; an
// admin's every one: the same (their own, claude-fleet#2515), then All
// sessions, By person and All devices — the whole hub those pages used to
// show an admin — then Subscriptions, Machines, Users, Settings and Audit
// (claude-fleet#1990). mymachines is 我的机器 (#2518), quota is 我的额度 (#2517)
// — the pool's windows, an admin's since #3227 — usage is 我的用量 (#2519).
// chat is 对话 (#3646): the website's /chat/, every role's.
var (
	userPages  = []string{"overview", "sessions", "tasks", "mymachines", "chat", "devices", "phone", "connection", "usage", "config"}
	adminPages = []string{"overview", "sessions", "tasks", "mymachines", "chat", "devices", "phone", "connection", "quota", "usage", "config",
		"all-sessions", "by-person", "all-devices",
		"subscriptions", "machines", "people", "settings", "audit"}
)

func pagesFor(role string) []string {
	switch role {
	case roleUser:
		return append([]string(nil), userPages...)
	case roleTrial:
		return []string{"chat"}
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
