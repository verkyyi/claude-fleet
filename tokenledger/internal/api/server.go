// Package api serves the hub: endpoint ingest, the dashboard's query API, the
// dashboard itself, and the MCP endpoint.
//
// All four live in one process on one port so a self-hoster deploys one thing.
package api

import (
	"context"
	"fmt"
	"io/fs"
	"log"
	"net/http"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"golang.org/x/crypto/ssh"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/credvault"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/fx"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/sshca"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// Server is the hub's HTTP surface.
type Server struct {
	Store   *store.Store
	Pricing *Pricing

	// ViewerToken guards the dashboard, the query API and MCP. Endpoint
	// ingest uses per-endpoint enrollment tokens instead.
	ViewerToken string

	// Tailnet grants the viewer role to allowlisted tailnet logins with no
	// token, on the word of the local tailscaled. Nil means off.
	Tailnet *TailnetViewers

	// LogWriter receives access-log lines; nil means the standard logger.
	// Tests capture it to assert that a tailnet-authenticated request is
	// logged with who made it.
	LogWriter func(line string)

	// PublicBadges serves /badge/... without a viewer token, so an internal
	// README can actually render one (a README image sends no credential, and
	// camo strips cookies). Off by default: an operator who upgrades must not
	// silently start serving without auth.
	PublicBadges bool

	// FX converts a figure from the currency it was BILLED in to the one a
	// viewer reads. Presentation only: no stored figure and no total is ever
	// computed through it, and every converted figure travels with the rate and
	// its timestamp so it cannot be mistaken for the invoice. Nil means the
	// dashboard shows each figure in its own currency, which is always correct.
	FX *fx.Feed

	// LimitsPollIntervalS is echoed to agents so a noisy fleet can be backed
	// off centrally without touching every machine.
	LimitsPollIntervalS int

	// UI is the built dashboard, or nil when the binary was built without one.
	UI fs.FS

	// Listeners is where the hub command actually bound, so the door map at
	// /access can print a URL rather than "some port". Presentation only:
	// nothing routes on it, and the zero value just means the page names the
	// doors without their addresses.
	Listeners ListenerFacts

	// SSO connects the human-facing surfaces to the company's WeCom single
	// sign-on. Nil means not wired up — /enter 404s and nothing else changes.
	SSO *SSO

	// MCP handles /mcp when wired up.
	MCP http.Handler

	// counter caches the all-time token total behind the hero counter. Its
	// query is a full scan and the SSE stream pushes several times a second,
	// so it is recomputed on a timer rather than per push.
	counter        Counter
	sourceCounters scopedCounters
	quotaLeases    quotaLeases

	// LiveStore holds the seconds-scale view of running sessions. In memory
	// only: it describes this minute, and a restart legitimately knows nothing
	// until the agents report again.
	LiveStore *Live

	// osUsers caches the endpoint_id -> os_user map behind attachOSUsers.
	osUsers osUserCache

	// sessionsChanged fires on every recorded fleet heartbeat: a held
	// fleet_sessions long poll (claude-fleet#1526) wakes and reads again.
	sessionsChanged changeBroadcast

	// Fleet turns on the fleet module (CCQUOTA_FLEET=1, claude-fleet#1408):
	// the node control channel, the node roster and its page. Off, none of
	// those routes exist and the hub is what it was before them. The caller
	// must have run Store.EnsureNodes.
	Fleet bool

	// FleetAdmins is the OS logins whose agents may run account ops
	// (CCQUOTA_FLEET_ADMIN_USERS, claude-fleet#1411): the operator's login on
	// each machine. A node must ALSO say it is an admin in its hello, and
	// refuses the op itself if it was not started as one. Empty means no node
	// is ever sent an account op.
	FleetAdmins []string

	// FleetAutoAssign is the machines (roster hostnames) a person gets a
	// login on the first time they sign in through WeCom
	// (CCQUOTA_FLEET_AUTO_ASSIGN). Empty means accounts are only ever opened
	// by an explicit assignment. A person in FleetPrincipalLogins is never
	// auto-assigned: their login already exists, and is adopted instead.
	FleetAutoAssign []string

	// FleetPrincipalLogins maps a person (WeCom userid, the ticket's `uid`)
	// to the OS login that is theirs on every machine
	// (CCQUOTA_FLEET_PRINCIPAL_LOGINS=caojian=24haowan,yilianghui=verkyyi;
	// claude-fleet#1458). At sign-in a mapped person is recorded under that
	// login and the login is ADOPTED on every roster machine whose agent
	// runs as it — nothing is ever created. A person not in the map gets no
	// row and no op (unless FleetAutoAssign says otherwise). Empty means the
	// map is not in use. Keys are matched to the userid case-insensitively
	// (mappedLoginFor, claude-fleet#1472): WeCom's are, and `YiLiangHui` in
	// the directory is `yilianghui` as the operator typed it.
	FleetPrincipalLogins map[string]string

	// FleetPersonScopes is the grant a person signed in through WeCom holds
	// on their own logins (CCQUOTA_FLEET_PERSON_SCOPES, claude-fleet#1410);
	// nil means DefaultPersonScopes. The operator's doors hold every scope.
	FleetPersonScopes []string
	// FleetPersonConfigKeys is the config_set keys a person may write
	// (CCQUOTA_FLEET_PERSON_CONFIG_KEYS), with config:write in their scopes.
	// Empty by default: a fleet's caps are the operator's.
	FleetPersonConfigKeys []string

	// SSHRelayCA is the SSH CA whose user certificates admit a person to the
	// relay (CCQUOTA_FLEET_SSH_CA_PUB, claude-fleet#1413). Empty means a
	// relay needs a session or the viewer token.
	SSHRelayCA []ssh.PublicKey
	// SSHRelayMaxPerUser bounds one person's concurrent relays (0: 8).
	SSHRelayMaxPerUser int
	// SSHRelayRateBPS bounds one person's relay bytes per second, both ways,
	// across all their relays (0: 4 MiB/s; negative: unlimited).
	SSHRelayRateBPS int64

	// relays holds the relays in flight.
	sshRelays sshRelayTable

	// fleetScopeHook replaces fleetScope in tests (claude-fleet#1409).
	fleetScopeHook func(*http.Request) (func(hostname, osUser string) bool, error)
	// Vault is the credential vault (claude-fleet#1415): long-lived Claude /
	// Codex credentials sealed under CCQUOTA_FLEET_CRED_KEY, leased to nodes
	// as short-lived tokens. nil (no key configured) leaves every credential
	// route answering 503 and the rest of the fleet module unaffected.
	Vault *credvault.Vault
	// leaseNow replaces the lease clock in tests (claude-fleet#1422).
	leaseNow func() time.Time

	// NodeLostAfter is how long a node may be silent before the hub records a
	// node_lost alert (FLEET_NODE_LOST_ALERT_SECS, claude-fleet#1630); zero =
	// the 120 s default.
	NodeLostAfter time.Duration

	// Notifier pushes warning / critical findings to a WeCom robot
	// (claude-fleet#1469). Nil: off, and nothing about findings changes.
	Notifier *FindingNotifier

	// SSHCA signs people's connection certificates (claude-fleet#1412),
	// loaded from CCQUOTA_FLEET_SSH_CA_KEY — a file from its own k8s Secret,
	// never the database. Nil: no certificates, and no node is asked to trust
	// a CA.
	SSHCA *sshca.CA

	// FleetRoutes is the machines people connect to and the ways in
	// (CCQUOTA_FLEET_ROUTES), for the 连接 page and the ssh config snippet.
	FleetRoutes []FleetMachine

	// FleetPublicURL is the hub's address as people know it
	// (CCQUOTA_FLEET_PUBLIC_URL); empty means "as this request reached us".
	FleetPublicURL string
	// FleetDistDir holds the agent binaries a joining machine downloads,
	// named ccquota-<os>-<arch> (CCQUOTA_FLEET_DIST_DIR, claude-fleet#1418).
	// Empty: the hub serves none and the join script falls back to a local
	// binary or `go install`.
	FleetDistDir string
	// FleetJoinScriptURL is where the join command fetches the script
	// (CCQUOTA_FLEET_JOIN_SCRIPT_URL); empty means DefaultJoinScriptURL.
	FleetJoinScriptURL string
	// joinClock replaces the join-code clock in tests.
	joinClock func() time.Time

	// Spot starts and releases SPOT execution nodes in the hub's cluster
	// (claude-fleet#1428); nil when CCQUOTA_FLEET_SPOT_IMAGE is unset.
	Spot *SpotController

	// nodes holds the open node control channels.
	nodes nodeConns

	// devices holds `fleet login` device-code logins in progress.
	devices deviceLogins

	// sshCAStatus is each admin node's last answer to the CA install.
	sshCAMu     sync.Mutex
	sshCAStatus map[string]string

	// accountsMu serialises account dispatch, so one queued op is never sent
	// twice by two triggers racing.
	accountsMu sync.Mutex

	// relayLocks serialises relay dispatch per target endpoint
	// (claude-fleet#1421), so two heartbeat triggers never push one relay
	// twice in the same instant.
	relayLocks sync.Map // endpoint ID → *sync.Mutex
	// relayExpiredAt is when pending relays were last expired (UnixNano).
	relayExpiredAt atomic.Int64
}

// Handler builds the router.
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()

	// Every snapshot that leaves the hub carries the counter and each
	// session's os_user, including the ones broadcast from inside Live.
	// Enrich holds one hook, so the two are chained rather than one silently
	// replacing the other.
	if s.LiveStore != nil {
		s.LiveStore.Enrich(func(snap *Snapshot) {
			s.attachCounter(snap)
			s.attachOSUsers(snap)
		})
	}

	// Ingest authenticates per endpoint, so it is deliberately outside the
	// viewer-token gate.
	mux.HandleFunc("/v1/ingest", s.handleIngest)
	// Live reports authenticate per endpoint, like ingest.
	mux.HandleFunc("/v1/live/report", s.handleLiveReport)
	mux.HandleFunc("/v1/collectors/quota-lease", s.handleQuotaLease)
	// Repo progress ships on an enrollment token too, but carries no identity:
	// see handleRepoIngest for why it is a sibling of /v1/ingest rather than
	// another optional field on the usage batch.
	mux.HandleFunc("/v1/ingest/repo", s.handleRepoIngest)
	// The business ledger ships the same way and for the same reasons: its own
	// enrollment token, no identity in the body, one whole day per push.
	mux.HandleFunc("/v1/ingest/growth", s.handleGrowthIngest)
	// Reading the ledger back, for the Monday brief. Outside the viewer gate
	// for the same reason ingest is -- a headless job holds an enrollment
	// token, not an SSO session -- but gated a second time on the enrollment's
	// kind, because every shipper on this hub holds a token and only the growth
	// ones may read revenue. See handleGrowthRead.
	mux.HandleFunc("/v1/growth/latest", s.handleGrowthRead)

	// The way in. Outside the viewer-token gate on purpose, and mounted
	// unconditionally: when SSO is not configured the handler answers 404, so
	// whether the route exists never leaks whether the feature is on.
	mux.HandleFunc("/enter", s.handleEnter)
	// The way out (claude-fleet#1467): POST clears the cookies this hub
	// minted, GET is the signed-out page. Outside the gate for the same
	// reason /enter is -- a signed-out browser must be able to reach it.
	mux.HandleFunc("/logout", s.handleLogout)

	if s.Fleet {
		// The control channel authenticates per endpoint, like ingest.
		mux.HandleFunc(control.Path, s.handleNodeConnect)
		// Issue leases (claude-fleet#1422) authenticate the same way.
		mux.HandleFunc("/v1/node/lease", s.handleNodeLease)
		// Placement for a node's own spawn (claude-fleet#1425), the same way.
		mux.HandleFunc("/v1/node/place", s.handleNodePlace)
		// Moving a session between machines (claude-fleet#1426), the same way.
		mux.HandleFunc("/v1/node/move", s.handleNodeMove)
		mux.HandleFunc("/v1/node/move/bundle", s.handleNodeMoveBundle)
		mux.HandleFunc("/v1/node/move/bundle/", s.handleNodeMoveBundle)
		// Adding a machine in one command (claude-fleet#1418): join trades a
		// one-time code for an enrollment token; dist and self authenticate
		// with that token.
		mux.HandleFunc("/v1/node/join", s.handleNodeJoin)
		mux.HandleFunc("/v1/node/dist/", s.handleNodeDist)
		mux.HandleFunc("/v1/node/self", s.handleNodeSelf)
		mux.Handle("/v1/fleet/join-codes", s.viewerOnly(s.operatorOnly(http.HandlerFunc(s.handleFleetJoinCodes))))
		// SPOT nodes (claude-fleet#1428): the node's own reclaim notice
		// authenticates with its token; starting and releasing are the
		// operator's.
		mux.HandleFunc("/v1/node/reclaim", s.handleNodeReclaim)
		// 维护中 (claude-fleet#1427): a machine flags itself before a planned
		// outage, with its own token; the operator flags any machine through
		// /v1/fleet/settings.
		mux.HandleFunc("/v1/node/maintenance", s.handleNodeMaintenance)
		// Machine-to-machine access (claude-fleet#1626): a node asks, with its
		// own token, for a five-minute certificate to one other machine of
		// the same owner; the operator reads every issuance.
		mux.HandleFunc("/v1/node/peer-cert", s.handleNodePeerCert)
		// A worker's evidence and history, uploaded by the machine that
		// reaped it and read back by its owner's others (claude-fleet#1609).
		mux.HandleFunc("/v1/node/worker-records", s.handleNodeWorkerRecords)
		mux.Handle("/v1/fleet/peer-certs", s.viewerOnly(s.operatorOnly(http.HandlerFunc(s.handleFleetPeerCerts))))
		mux.Handle("/v1/fleet/spot", s.viewerOnly(s.operatorOnly(http.HandlerFunc(s.handleFleetSpot))))
		mux.Handle("/v1/nodes", s.viewerOnly(http.HandlerFunc(s.handleNodes)))
		mux.Handle("/nodes", s.viewerOnly(http.HandlerFunc(s.serveNodesPage)))
		// 我的会话 (claude-fleet#1429): the phone view of fleet_sessions.
		mux.Handle("/sessions", s.viewerOnly(http.HandlerFunc(s.serveSessionsPage)))
		mux.Handle("/v1/fleet/me", s.viewerOnly(http.HandlerFunc(s.handleFleetMe)))
		mux.Handle("/v1/fleet/accounts", s.viewerOnly(s.operatorOnly(http.HandlerFunc(s.handleFleetAccounts))))
		// Per-person node caps (claude-fleet#1410), the operator's.
		mux.Handle("/v1/fleet/settings", s.viewerOnly(s.operatorOnly(http.HandlerFunc(s.handleFleetSettings))))
		// The Fleet Hub's read tools (claude-fleet#1409), the same ones
		// /mcp lists when the module is on.
		mux.Handle("/v1/fleet/", s.viewerOnly(http.HandlerFunc(s.handleFleet)))
		// The sidebar's session list (claude-fleet#1475): the same doors,
		// plus a connection certificate proven by a signed timestamp — so
		// it authenticates itself, outside the viewer gate, like the routes.
		mux.HandleFunc(control.SessionsPath, s.handleFleetSessions)
		// The status bar's machine + account summaries (claude-fleet#1502):
		// the shapes of /v1/nodes and /v1/limits?account=all, by the same
		// doors as the session list — a colleague's certificate included.
		mux.HandleFunc(control.SummaryPath, s.handleFleetSummary)
		// A write by connection certificate (claude-fleet#1487): the other
		// machines' sidebars and the `fleet` shell act on their person's
		// workers with the one credential they hold, signed per write.
		mux.HandleFunc(control.WritePath, s.handleFleetWrite)
		// Connection certificates (claude-fleet#1412). start/poll carry no
		// credential — they are what a person runs before having one, and
		// grant nothing until a signed-in person confirms the code.
		mux.Handle("/v1/fleet/connect", s.viewerOnly(http.HandlerFunc(s.handleFleetConnect)))
		mux.Handle("/v1/fleet/cert", s.viewerOnly(http.HandlerFunc(s.handleFleetCert)))
		mux.HandleFunc("/v1/fleet/ssh-ca.pub", s.handleSSHCAPub)
		mux.HandleFunc("/v1/fleet/login/start", s.handleDeviceStart)
		mux.HandleFunc("/v1/fleet/login/poll", s.handleDevicePoll)
		mux.Handle("/fleet/login", s.rememberLoginCode(s.viewerOnly(http.HandlerFunc(s.handleFleetLoginPage))))
		mux.Handle("/connect", s.viewerOnly(http.HandlerFunc(s.serveConnectPage)))
		// Registered devices (claude-fleet#1470): a renewal is proven by the
		// device's own key, so it authenticates itself, outside the viewer
		// gate — like start/poll, it is what `fleet` runs before it holds a
		// live certificate. The device list and revocation are a person's
		// own (or the operator's), behind the gate.
		mux.HandleFunc(control.RenewPath, s.handleDeviceRenew)
		mux.Handle("/v1/fleet/devices", s.viewerOnly(http.HandlerFunc(s.handleFleetDevices)))
		mux.Handle("/v1/fleet/devices/revoke", s.viewerOnly(http.HandlerFunc(s.handleFleetDeviceRevoke)))
		// Which machine to enter (claude-fleet#1470): admits a certificate by a
		// signed timestamp like the route list, so it authenticates itself.
		mux.HandleFunc(control.HomePath, s.handleFleetHome)
		// The one-line install (claude-fleet#1470): a script and three
		// programs carrying no credential, public like the CA's public key;
		// 404 until the hub can sign someone in with nothing in hand.
		mux.HandleFunc("/install", s.handleInstall)
		mux.HandleFunc("/install/", s.handleInstallFile)
		// Credentials (claude-fleet#1415): the lease authenticates with the
		// node's enrollment token, like the control channel; everything else
		// is the operator's.
		mux.HandleFunc("/v1/node/credentials", s.handleNodeCredentials)
		mux.Handle("/v1/fleet/credentials", s.viewerOnly(s.operatorOnly(http.HandlerFunc(s.handleFleetCredentials))))
		mux.Handle("/v1/fleet/credentials/revoke", s.viewerOnly(s.operatorOnly(http.HandlerFunc(s.handleFleetRevoke))))
		mux.Handle("/v1/fleet/credentials/audit", s.viewerOnly(s.operatorOnly(http.HandlerFunc(s.handleFleetCredAudit))))
		mux.Handle("/credentials", s.viewerOnly(s.operatorOnly(http.HandlerFunc(s.serveCredentialsPage))))
		// The relay (claude-fleet#1413). Both halves authenticate
		// themselves: the client by session, token or certificate (the
		// last proven in-band, so outside the viewer gate), the agent by
		// its enrollment token.
		mux.HandleFunc(control.SSHRelayPath, s.handleSSHRelayConnect)
		mux.HandleFunc(control.SSHRelayDataPath, s.handleSSHRelayData)
		// The route list `fleet connect` measures (claude-fleet#1414): it
		// admits a certificate by a signed timestamp, so it authenticates
		// itself, outside the viewer gate.
		mux.HandleFunc(control.RoutesPath, s.handleFleetRoutes)
		mux.Handle("/v1/fleet/ssh-relays", s.viewerOnly(s.operatorOnly(http.HandlerFunc(s.handleSSHRelayAudit))))
	}

	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	})

	mux.Handle("/v1/accounts", s.viewerOnly(http.HandlerFunc(s.handleAccounts)))
	// Who the gate admitted, for the shared page header (claude-fleet#1467).
	// Unconditional: the header is on every hub's dashboard, fleet module or not.
	mux.Handle("/v1/me", s.viewerOnly(http.HandlerFunc(s.handleMe)))
	mux.Handle("/v1/fx", s.viewerOnly(http.HandlerFunc(s.handleFX)))
	mux.Handle("/v1/collectors", s.viewerOnly(http.HandlerFunc(s.handleCollectors)))
	mux.Handle("/v1/account-usage", s.viewerOnly(http.HandlerFunc(s.handleAccountUsage)))
	mux.Handle("/v1/limits", s.viewerOnly(http.HandlerFunc(s.handleLimits)))
	mux.Handle("/v1/endpoints", s.viewerOnly(http.HandlerFunc(s.handleEndpoints)))
	mux.Handle("/v1/usage", s.viewerOnly(http.HandlerFunc(s.handleUsage)))
	mux.Handle("/v1/history", s.viewerOnly(http.HandlerFunc(s.handleHistory)))
	mux.Handle("/v1/account-switches", s.viewerOnly(http.HandlerFunc(s.handleSwitches)))
	mux.Handle("/v1/endpoint-accounts", s.viewerOnly(http.HandlerFunc(s.handleEndpointAccounts)))
	mux.Handle("/v1/accounts/label", s.viewerOnly(http.HandlerFunc(s.handleAccountLabel)))
	mux.Handle("/v1/live", s.viewerOnly(http.HandlerFunc(s.handleLiveSnapshot)))
	mux.Handle("/v1/live/stream", s.viewerOnly(http.HandlerFunc(s.handleLiveStream)))
	mux.Handle("/v1/summary", s.viewerOnly(http.HandlerFunc(s.handleSummary)))
	mux.Handle("/v1/sessions", s.viewerOnly(http.HandlerFunc(s.handleSessions)))
	mux.Handle("/v1/sessions/", s.viewerOnly(http.HandlerFunc(s.handleSession)))
	mux.Handle("/v1/limits/history", s.viewerOnly(http.HandlerFunc(s.handleLimitsHistory)))
	// The quota windows on their own. /v1/limits/history still folds a copy in
	// for the dashboard, which draws both series on one axis; this is for a
	// caller that wants only the windows -- see handleQuotaHistory.
	mux.Handle("/v1/quota/history", s.viewerOnly(http.HandlerFunc(s.handleQuotaHistory)))
	mux.Handle("/v1/findings", s.viewerOnly(http.HandlerFunc(s.handleFindings)))
	// The hub's second viewer-facing WRITE, behind the same gate as the
	// first (/v1/accounts/label) and deliberately not behind a new one --
	// see internal/api/finding_mutes.go on the trust boundary.
	mux.Handle("/v1/findings/mutes", s.viewerOnly(http.HandlerFunc(s.handleFindingMutes)))
	mux.Handle("/v1/repos", s.viewerOnly(http.HandlerFunc(s.handleRepos)))
	mux.Handle("/v1/repo/flow", s.viewerOnly(http.HandlerFunc(s.handleRepoFlow)))
	mux.Handle("/v1/repo/issues", s.viewerOnly(http.HandlerFunc(s.handleRepoIssues)))
	mux.Handle("/v1/repo/cost", s.viewerOnly(http.HandlerFunc(s.handleRepoCost)))
	mux.Handle("/v1/repo/human-debt", s.viewerOnly(http.HandlerFunc(s.handleRepoHumanDebt)))

	if s.MCP != nil {
		mux.Handle("/mcp", s.viewerOnly(s.MCP))
	}

	// The public view. Mounted BEFORE "/" so the share token never reaches a
	// viewerOnly route, and viewerOnly never has to know share tokens exist.
	mux.Handle("/v1/share", s.shareOnly(s.handleShareData))
	mux.Handle("/share", s.shareOnly(s.serveSharePage))
	mux.Handle("/share/", s.shareOnly(s.serveSharePage))

	mux.Handle("/v1/user", s.viewerOnly(http.HandlerFunc(s.handleUserData)))
	mux.Handle("/u/", s.viewerOnly(http.HandlerFunc(s.serveUserPage)))

	// The door map: every way into this hub, what each costs in credentials,
	// and what is actually turned on here. Behind the viewer gate like every
	// other human surface -- it describes the configuration, and /enter's
	// unconditional 404 exists precisely so an uncredentialled prober cannot
	// learn that. Both spellings, so /access/ is the page rather than the SPA
	// fallback. See access.go.
	mux.Handle("/v1/access", s.viewerOnly(http.HandlerFunc(s.handleAccess)))
	mux.Handle("/access", s.viewerOnly(http.HandlerFunc(s.serveAccessPage)))
	mux.Handle("/access/", s.viewerOnly(http.HandlerFunc(s.serveAccessPage)))

	// The business board. Gated like every other human surface -- these are
	// the most sensitive figures this binary holds -- and mounted at a fixed
	// path rather than inside the dashboard's hash router because it is
	// server-rendered; see serveGrowthPage. Both spellings, so /growth/ is the
	// board rather than the SPA's index.html fallback.
	mux.Handle("/growth", s.viewerOnly(http.HandlerFunc(s.serveGrowthPage)))
	mux.Handle("/growth/", s.viewerOnly(http.HandlerFunc(s.serveGrowthPage)))

	// Badges are the one surface that may be unauthenticated, and only on
	// purpose. Everything else on this hub stays behind the viewer token.
	badges := http.NewServeMux()
	badges.HandleFunc("/badge/u/", s.handleUserBadge)
	badges.HandleFunc("/badge/team/", s.handleTeamBadge)
	// The live embed exposes exactly what a badge does, so it shares the gate.
	badges.HandleFunc("/embed/u/", s.serveEmbed)
	badges.HandleFunc("/embed/team/", s.serveEmbed)
	if s.PublicBadges {
		mux.Handle("/badge/", badges)
		mux.Handle("/embed/", badges)
	} else {
		mux.Handle("/badge/", s.viewerOnly(badges))
		mux.Handle("/embed/", s.viewerOnly(badges))
	}

	mux.Handle("/", s.viewerOnly(http.HandlerFunc(s.serveUI)))

	return s.logRequests(mux)
}

// viewerOnly gates a handler behind the viewer token.
//
// The token may arrive as a bearer header (API and MCP clients) or as a
// `ccquota_token` cookie, which is what lets a browser follow ?token=... once
// and then navigate normally.
func (s *Server) viewerOnly(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Every admitting branch below records WHICH door let the request in
		// (withDoor), so /v1/me can say so and the page header can show it
		// (claude-fleet#1467). A branch that redirects records nothing: the
		// request it redirects to is admitted again, by one of these.
		if s.ViewerToken == "" {
			// An unset viewer token means the operator explicitly opted out
			// (see the hub's --no-auth flag, which refuses a public bind).
			next.ServeHTTP(w, r.WithContext(withDoor(r.Context(), doorOpen)))
			return
		}

		if tok := r.URL.Query().Get("token"); tok != "" && constantTimeEqual(tok, s.ViewerToken) {
			// Move the secret out of the URL bar and into a cookie so it stops
			// appearing in browser history, referrers and screenshots.
			http.SetCookie(w, &http.Cookie{
				Name: viewerCookie, Value: tok, Path: "/",
				HttpOnly: true, SameSite: http.SameSiteLaxMode,
				Secure: r.TLS != nil || strings.EqualFold(r.Header.Get("X-Forwarded-Proto"), "https"),
				MaxAge: 30 * 24 * 3600,
			})
			http.Redirect(w, r, stripToken(r), http.StatusFound)
			return
		}
		if constantTimeEqual(bearer(r), s.ViewerToken) {
			next.ServeHTTP(w, r.WithContext(withDoor(r.Context(), doorToken)))
			return
		}
		if c, err := r.Cookie(viewerCookie); err == nil && constantTimeEqual(c.Value, s.ViewerToken) {
			next.ServeHTTP(w, r.WithContext(withDoor(r.Context(), doorToken)))
			return
		}
		// A WeCom session this hub minted itself, from a ticket the company's
		// authorization service signed. Checked after the token so the token
		// stays the fallback that works when WeCom does not.
		if sess, ok := s.ssoSession(r); ok {
			// The signed-in person (the ticket's `uid`, else its role
			// subject) is also the fleet principal: the one identity whose
			// views are narrowed to that person's own machines. The session
			// itself rides along for /v1/me, which shows the name it carries.
			sub := sess.Principal()
			ctx := context.WithValue(withViewer(r.Context(), sub), principalKey{}, sub)
			ctx = withDoor(withSession(ctx, sess), doorWeCom)
			next.ServeHTTP(w, r.WithContext(ctx))
			return
		}
		// No token. A named tailnet peer may still be let in -- on the word
		// of the local tailscaled, never of anything in the request.
		if login, ok := s.Tailnet.Lookup(r.RemoteAddr); ok {
			next.ServeHTTP(w, r.WithContext(withDoor(withViewer(r.Context(), login), doorTailnet)))
			return
		}
		// A browser with no credential is someone who has not signed in yet;
		// send them to do that. Everything else gets the honest 401.
		if to, ok := s.ssoSignInURL(r); ok {
			http.Redirect(w, r, to, http.StatusFound)
			return
		}

		w.Header().Set("WWW-Authenticate", `Bearer realm="ccquota"`)
		httpError(w, http.StatusUnauthorized, "a viewer token is required")
	})
}

func stripToken(r *http.Request) string {
	u := *r.URL
	q := u.Query()
	q.Del("token")
	u.RawQuery = q.Encode()
	if u.Path == "" {
		u.Path = "/"
	}
	return u.RequestURI()
}

// serveUI serves the embedded dashboard, falling back to index.html so the SPA
// owns its own routing.
func (s *Server) serveUI(w http.ResponseWriter, r *http.Request) {
	if s.UI == nil {
		writeJSON(w, http.StatusOK, map[string]string{
			"service": "ccquota hub",
			"note":    "this binary was built without the dashboard; the API is at /v1/",
		})
		return
	}

	path := strings.TrimPrefix(r.URL.Path, "/")
	if path == "" {
		path = "index.html"
	}
	f, err := s.UI.Open(path)
	if err != nil {
		f, err = s.UI.Open("index.html")
		if err != nil {
			http.NotFound(w, r)
			return
		}
		path = "index.html"
	}
	defer f.Close()

	st, err := f.Stat()
	if err != nil || st.IsDir() {
		http.NotFound(w, r)
		return
	}
	rs, ok := f.(interface {
		Read([]byte) (int, error)
		Seek(int64, int) (int64, error)
	})
	if !ok {
		http.Error(w, "unreadable asset", http.StatusInternalServerError)
		return
	}
	// The embedded dashboard is rebuilt into the SAME binary on every deploy,
	// with no cache-busting filename. A browser that cached an old bundle
	// under this path would keep serving it past a release until someone
	// force-refreshed, silently running stale JS against a live API.
	w.Header().Set("Cache-Control", "no-cache")
	http.ServeContent(w, r, path, st.ModTime(), rs)
}

// logRequests logs method, path, status and duration, plus who it was when a
// tailnet identity let the request in. Query strings are omitted: they can
// carry the viewer token.
func (s *Server) logRequests(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		sw := &statusWriter{ResponseWriter: w, status: http.StatusOK}
		// The gate fills this in if it grants by identity; the pointer is
		// how a value set downstream reaches this outer layer.
		var viewer string
		r = r.WithContext(context.WithValue(r.Context(), viewerKey{}, &viewer))
		next.ServeHTTP(sw, r)
		line := fmt.Sprintf("%s %s %d %s", r.Method, r.URL.Path, sw.status, time.Since(start).Round(time.Millisecond))
		if viewer != "" {
			line += " viewer=" + viewer
		}
		if s.LogWriter != nil {
			s.LogWriter(line)
			return
		}
		log.Print(line)
	})
}

type statusWriter struct {
	http.ResponseWriter
	status int
}

func (w *statusWriter) WriteHeader(code int) {
	w.status = code
	w.ResponseWriter.WriteHeader(code)
}

// Unwrap lets http.ResponseController (and the websocket upgrade on the node
// control channel) reach the connection underneath.
func (w *statusWriter) Unwrap() http.ResponseWriter { return w.ResponseWriter }

// Flush lets streaming handlers (MCP) work through the wrapper.
func (w *statusWriter) Flush() {
	if f, ok := w.ResponseWriter.(http.Flusher); ok {
		f.Flush()
	}
}
