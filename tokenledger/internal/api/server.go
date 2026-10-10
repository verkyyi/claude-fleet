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
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"golang.org/x/crypto/ssh"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/credvault"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/leader"
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

	// LogWriter receives access-log lines; nil means the standard logger.
	// Tests capture it to assert that a signed-in request is logged with who
	// made it.
	LogWriter func(line string)

	// LimitsPollIntervalS is echoed to agents so a noisy fleet can be backed
	// off centrally without touching every machine.
	LimitsPollIntervalS int

	// Version is the binary's build stamp (main.Version, -ldflags), served
	// on GET /version with the commit it names (claude-fleet#1696).
	Version string

	// UI is the built dashboard, or nil when the binary was built without one.
	UI fs.FS

	// Listeners is where the hub command actually bound, so the door map at
	// /access can print a URL rather than "some port". Presentation only:
	// nothing routes on it, and the zero value just means the page names the
	// doors without their addresses.
	Listeners ListenerFacts

	// GitHub is the GitHub sign-in and its list (claude-fleet#1984). Nil
	// means not wired up — /signin and /auth/github/* 404 and nothing else
	// changes.
	GitHub *GitHubAuth

	// MCP handles /mcp when wired up.
	MCP http.Handler

	// ReadOnly is CCQUOTA_READONLY=1 (claude-fleet#2122): the hub's database
	// is being moved, so every write request is answered 503 + Retry-After and
	// every read is served as usual. The caller has also put the store itself
	// read-only (Store.SetReadOnly), which catches the writes no request makes.
	ReadOnly bool

	// counter caches the all-time token total behind the hero counter. Its
	// query is a full scan and the SSE stream pushes several times a second,
	// so it is recomputed on a timer rather than per push.
	counter        Counter
	meter          meterState
	sourceCounters scopedCounters
	quotaLeases    quotaLeases
	loadHist       loadHistory

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

	// FleetPersonScopes is the grant a person signed in with GitHub holds
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
	// clientLeases is each person's one connected client (claude-fleet#1715).
	clientLeases clientLeaseTable

	// fleetScopeHook replaces fleetScope in tests (claude-fleet#1409).
	fleetScopeHook func(*http.Request) (func(hostname, osUser string) bool, error)
	// certLoginsHook replaces the logins issueCert signs for, in tests that
	// split signing from checking on purpose (claude-fleet#2456).
	certLoginsHook func(pid string, logins []string) []string
	// Vault is the credential vault (claude-fleet#1415): long-lived Claude /
	// Codex credentials sealed under CCQUOTA_FLEET_CRED_KEY, leased to nodes
	// as short-lived tokens. nil (no key configured) leaves every credential
	// route answering 503 and the rest of the fleet module unaffected.
	Vault *credvault.Vault
	// HubQuota is the hub reading every pool subscription's quota itself
	// through the Singapore relay (claude-fleet#2169,
	// CCQUOTA_FLEET_HUB_QUOTA=relay). Nil: the hub reads none, signs no
	// quota pass and the subscriptions page shows the nodes' readings —
	// exactly as before.
	HubQuota *HubQuota
	// SessionCredKey signs session passes for untrusted machines
	// (claude-fleet#1969, CCQUOTA_FLEET_SESSION_CRED_KEY[_FILE]); it never
	// leaves the hub. Nil: /v1/fleet/session-cred answers 503.
	SessionCredKey []byte
	// SessionCredVerifyToken lets the cluster credential proxy and the relay
	// call POST /v1/fleet/session-cred/verify
	// (CCQUOTA_FLEET_SESSION_CRED_VERIFY_TOKEN[_FILE]); empty = the operator only.
	SessionCredVerifyToken string
	// CredProxyToken admits the cluster credential proxy (`ccquota
	// credproxy`, claude-fleet#1973) to POST /v1/fleet/credproxy/resolve
	// (CCQUOTA_FLEET_CREDPROXY_TOKEN[_FILE]); empty = the route answers 503.
	CredProxyToken string
	// sessCred caches verified passes' rows for ≤ 30 s.
	sessCred sessionCredCache
	// leaseNow replaces the lease clock in tests (claude-fleet#1422).
	leaseNow func() time.Time
	// budgetNow replaces the per-person budget clock in tests (claude-fleet#1977).
	budgetNow func() time.Time

	// NodeLostAfter is how long a node may be silent before the hub records a
	// node_lost alert (FLEET_NODE_LOST_ALERT_SECS, claude-fleet#1630); zero =
	// the 120 s default.
	NodeLostAfter time.Duration

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
	// Stable is where the client comes from (claude-fleet#1805): GitHub's
	// refs/tags/stable, reported by /version and proxied at
	// /install/stable/<sha>/ (CCQUOTA_FLEET_STABLE_REPO; "off" = nil). Nil:
	// the image's packed client, as before.
	Stable *StableSource
	// Releases keeps a signed node release per stable and serves it at
	// /v1/fleet/release/ (claude-fleet#2335; CCQUOTA_FLEET_RELEASE_KEY +
	// CCQUOTA_FLEET_RELEASE_DIR). Nil: those routes 404.
	Releases *ReleaseStore
	// joinClock replaces the join-code clock in tests.
	joinClock func() time.Time

	// Spot starts and releases SPOT execution nodes in the hub's cluster
	// (claude-fleet#1428); nil when CCQUOTA_FLEET_SPOT_IMAGE is unset.
	Spot *SpotController

	// Elector says which replica runs each background loop when two hubs
	// share one Postgres database (claude-fleet#2123). nil — every hub on
	// SQLite — leads everything, exactly as before.
	Elector *leader.Elector

	// nodes holds the open node control channels.
	nodes nodeConns
	// Replica is this process as one of several hub replicas
	// (claude-fleet#2124): a call for a node whose link another replica
	// holds is handed to it. Nil — a single hub — forwards nothing.
	Replica *Replica
	// forwarded counts the calls handed to another replica.
	forwarded atomic.Int64
	// replicaLife is when this replica started — its place in the state
	// holder order (claude-fleet#2190); stateForwarded counts the requests
	// handed to the holder, liveFanned the live reports handed to the others.
	replicaLife    replicaLife
	stateForwarded atomic.Int64
	liveFanned     atomic.Int64
	// recent is the starts just sent to each node that its heartbeat may not
	// show yet (claude-fleet#2077); judge counts them as running.
	recent recentTable
	// limits is the accounts the cluster proxy saw a quota 429 on
	// (claude-fleet#2115); the session pick puts them last.
	limits limitMemo

	// devices holds `fleet login` device-code logins in progress.
	devices deviceLogins

	// probe is /readyz's last verdict and the deploy probe's last write
	// (claude-fleet#2125).
	probe deployProbe

	// sshCAStatus is each admin node's last answer to the CA install.
	sshCAMu     sync.Mutex
	sshCAStatus map[string]string

	// accountsMu serialises account dispatch, so one queued op is never sent
	// twice by two triggers racing.
	accountsMu sync.Mutex

	// spareMu / spareScanAt pace the spare-login refill (claude-fleet#2263):
	// one scan per spareScanEvery, whichever beat comes first.
	spareMu     sync.Mutex
	spareScanAt time.Time

	// relayLocks serialises relay dispatch per target endpoint
	// (claude-fleet#1421), so two heartbeat triggers never push one relay
	// twice in the same instant.
	relayLocks sync.Map // endpoint ID → *sync.Mutex

	// orchHost is who asked to hold the orchestrator, and serialises the pick
	// (claude-fleet#2117, fleet_orchestrator.go).
	orchHost orchState
	// relayExpiredAt is when pending relays were last expired (UnixNano).
	relayExpiredAt atomic.Int64
}

// Handler builds the router.
func (s *Server) Handler() http.Handler {
	return s.logRequests(s.readOnlyGate(s.routes()))
}

// readOnlyRetryAfter is the Retry-After a write gets while the hub is
// read-only: the runbook's write stop is under a minute, so a client that
// waits this long and retries lands on the moved database or one more 503.
const readOnlyRetryAfter = 15

// readOnlyGate answers every write request 503 + Retry-After while the hub is
// read-only. A write is any method but GET / HEAD / OPTIONS — a WebSocket
// upgrade is a GET and stays up — except /mcp, whose POSTs are JSON-RPC reads
// (a tool that writes fails at the read-only store instead). Off, it is not in
// the chain at all.
func (s *Server) readOnlyGate(next http.Handler) http.Handler {
	if !s.ReadOnly {
		return next
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.Method == http.MethodGet, r.Method == http.MethodHead, r.Method == http.MethodOptions,
			r.URL.Path == "/mcp":
			next.ServeHTTP(w, r)
			return
		}
		w.Header().Set("Retry-After", strconv.Itoa(readOnlyRetryAfter))
		writeJSON(w, http.StatusServiceUnavailable, map[string]any{
			"error":       "read_only",
			"message":     "the hub is read-only while its database is moved; retry shortly",
			"retry_after": readOnlyRetryAfter,
		})
	})
}

// routes mounts every route; roles.go's routeAccess names each one
// (claude-fleet#1985).
func (s *Server) routes() *routeMux {
	mux := &routeMux{ServeMux: http.NewServeMux()}

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
	if s.Replica != nil {
		// A report another replica received (claude-fleet#2190).
		mux.HandleFunc(LiveFanoutPath, s.handleLiveFanout)
	}
	mux.HandleFunc("/v1/collectors/quota-lease", s.handleQuotaLease)
	// The way out (claude-fleet#1467): POST clears the cookies this hub
	// minted, GET is the signed-out page. Outside the gate on purpose -- a
	// signed-out browser must be able to reach it.
	mux.HandleFunc("/logout", s.handleLogout)
	// Sign in with GitHub (claude-fleet#1984): the page, the hop to GitHub
	// and the way back. Outside the gate, mounted unconditionally and 404
	// when not configured, so whether the route exists never leaks whether
	// the feature is on.
	mux.HandleFunc("/signin", s.handleSignin)
	mux.HandleFunc("/auth/github/start", s.handleGitHubStart)
	mux.HandleFunc("/auth/github/callback", s.handleGitHubCallback)
	// Who may sign in with GitHub (claude-fleet#1986): the admin's, with or
	// without the fleet module.
	mux.Handle("/v1/fleet/users", s.viewerOnly(s.adminOnly(http.HandlerFunc(s.handleFleetUsers))))
	// Invites (claude-fleet#2261): an admin mints one; the newcomer's
	// install command fetches /i/<code>, public — the code is the credential.
	mux.Handle("/v1/fleet/invites", s.viewerOnly(s.adminOnly(http.HandlerFunc(s.handleFleetInvites))))
	mux.HandleFunc(InvitePath, s.handleInviteInstall)

	if s.Fleet {
		// The control channel authenticates per endpoint, like ingest.
		mux.HandleFunc(control.Path, s.handleNodeConnect)
		if s.Replica != nil {
			// A node call another replica hands over (claude-fleet#2124);
			// in-cluster, behind the replicas' shared token.
			mux.HandleFunc(NodeRoutePath, s.handleNodeRoute)
			// The client leases' read for another replica (claude-fleet#2190).
			mux.HandleFunc(StateLeasePath, s.handleStateLease)
		}
		// Issue leases (claude-fleet#1422) authenticate the same way.
		mux.HandleFunc("/v1/node/lease", s.handleNodeLease)
		// Placement for a node's own spawn (claude-fleet#1425), the same way.
		mux.HandleFunc("/v1/node/place", s.handleNodePlace)
		// Moving a session between machines (claude-fleet#1426), the same way.
		mux.HandleFunc("/v1/node/move", s.handleNodeMove)
		mux.HandleFunc("/v1/node/move/bundle", s.handleNodeMoveBundle)
		mux.HandleFunc("/v1/node/move/bundle/", s.handleNodeMoveBundle)
		// A writing area's attachments, for the start's node (claude-fleet#2393).
		mux.HandleFunc("/v1/node/attachment/", s.handleNodeAttachment)
		// Adding a machine in one command (claude-fleet#1418): join trades a
		// one-time code for an enrollment token; dist and self authenticate
		// with that token.
		mux.HandleFunc("/v1/node/join", s.handleNodeJoin)
		mux.HandleFunc("/v1/node/dist/", s.handleNodeDist)
		mux.HandleFunc("/v1/node/self", s.handleNodeSelf)
		mux.Handle("/v1/fleet/join-codes", s.viewerOnly(s.adminOnly(http.HandlerFunc(s.handleFleetJoinCodes))))
		// A managed machine (claude-fleet#2214): trusted join codes and each
		// machine's desired state are the operator's; the node reads its own.
		// The exact /v1/fleet/nodes/revoke and /retire routes still win.
		mux.Handle(FleetNodesPrefix, s.viewerOnly(s.adminOnly(http.HandlerFunc(s.handleFleetNodes))))
		mux.HandleFunc("/v1/node/desired", s.handleNodeDesired)
		// SPOT nodes (claude-fleet#1428): the node's own reclaim notice
		// authenticates with its token; starting and releasing are the
		// operator's.
		mux.HandleFunc("/v1/node/reclaim", s.handleNodeReclaim)
		// 维护中 (claude-fleet#1427): a machine flags itself before a planned
		// outage, with its own token; the operator flags any machine through
		// /v1/fleet/settings.
		mux.HandleFunc("/v1/node/maintenance", s.handleNodeMaintenance)
		// The ticket registry (claude-fleet#2676): a node registers a ticket it
		// opened, with its own token — exact, so the /v1/fleet/ viewer gate is not
		// in the way.
		mux.HandleFunc(FleetTicketRegisterPath, s.handleFleetTicketRegister)
		// The person's one orchestrator (claude-fleet#2117): each machine asks,
		// with its own token, whether it is the one to hold it.
		mux.HandleFunc("/v1/node/orchestrator", s.handleNodeOrchestrator)
		// Machine-to-machine access (claude-fleet#1626): a node asks, with its
		// own token, for a five-minute certificate to one other machine of
		// the same owner; the operator reads every issuance.
		mux.HandleFunc("/v1/node/peer-cert", s.handleNodePeerCert)
		// Where the owner is (claude-fleet#1716): the client they are
		// connected through right now, read by a node with its own token.
		mux.Handle("/v1/node/client", s.stateRouteFunc(s.handleNodeClient))
		// Open it on the owner's device (claude-fleet#1717): a node sends
		// an action to that client; the client polls for its lease's.
		mux.Handle("/v1/node/client/actions", s.stateRouteFunc(s.handleNodeClientActions))
		// A worker's evidence and history, uploaded by the machine that
		// reaped it and read back by its owner's others (claude-fleet#1609).
		mux.HandleFunc("/v1/node/worker-records", s.handleNodeWorkerRecords)
		mux.HandleFunc("/v1/node/progress", s.handleNodeProgress)
		mux.Handle("/v1/fleet/peer-certs", s.viewerOnly(s.adminOnly(http.HandlerFunc(s.handleFleetPeerCerts))))
		mux.Handle("/v1/fleet/spot", s.viewerOnly(s.adminOnly(http.HandlerFunc(s.handleFleetSpot))))
		mux.Handle("/v1/nodes", s.viewerOnly(http.HandlerFunc(s.handleNodes)))
		// Machines (claude-fleet#1990): an admin's page; a user gets the
		// shell's 403 (admin_pages.go).
		mux.Handle("/nodes", s.viewerOnly(s.adminPage("machines", "admin/nodes.html")))
		// 我的机器 (claude-fleet#2518): a user's own machines, off the same
		// /v1/nodes cut.
		mux.Handle("/machines", s.viewerOnly(http.HandlerFunc(s.serveMachinesPage)))
		// 我的会话 (claude-fleet#1429): the phone view of fleet_sessions.
		mux.Handle("/sessions", s.viewerOnly(http.HandlerFunc(s.serveSessionsPage)))
		mux.Handle("/v1/fleet/me", s.viewerOnly(http.HandlerFunc(s.handleFleetMe)))
		mux.Handle("/v1/fleet/accounts", s.viewerOnly(s.adminOnly(http.HandlerFunc(s.handleFleetAccounts))))
		// Per-person node caps (claude-fleet#1410), the operator's.
		mux.Handle("/v1/fleet/settings", s.viewerOnly(s.adminOnly(http.HandlerFunc(s.handleFleetSettings))))
		// The team configuration layer (claude-fleet#1726): read by every
		// door — a node's token and a client's certificate included — so it
		// authenticates itself; a PUT is the operator's alone.
		mux.HandleFunc(control.TeamBundlePath, s.handleFleetTeamBundle)
		// Each person's own layer (claude-fleet#1856): the same doors, each
		// reading and writing its own; the operator reads and restores.
		mux.HandleFunc(control.PersonBundlePath, s.handleFleetPersonBundle)
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
		// The client lease (claude-fleet#1715): one person, one connected
		// client — a certificate proven by a signed timestamp, like the
		// session list, so it authenticates itself outside the viewer gate.
		mux.Handle(control.ClientPath, s.stateRouteFunc(s.handleFleetClient))
		mux.Handle(ClientTestPath, s.stateRouteFunc(s.handleFleetClient)) // #1931
		mux.Handle(control.ClientPath+"/actions", s.stateRouteFunc(s.handleFleetClientActions))
		// Open a session from the client (claude-fleet#1777): the current
		// lease, proven by its action key, asks the hub to open it.
		mux.Handle(control.ClientPath+"/place", s.stateRouteFunc(s.handleFleetClientPlace))
		// Connection certificates (claude-fleet#1412). start/poll carry no
		// credential — they are what a person runs before having one, and
		// grant nothing until a signed-in person confirms the code.
		mux.Handle("/v1/fleet/connect", s.viewerOnly(http.HandlerFunc(s.handleFleetConnect)))
		mux.Handle("/v1/fleet/cert", s.viewerOnly(http.HandlerFunc(s.handleFleetCert)))
		mux.HandleFunc("/v1/fleet/ssh-ca.pub", s.handleSSHCAPub)
		mux.Handle("/v1/fleet/login/start", s.stateRouteFunc(s.handleDeviceStart))
		mux.Handle("/v1/fleet/login/poll", s.stateRouteFunc(s.handleDevicePoll))
		mux.Handle("/fleet/login", s.stateRoute(s.rememberLoginCode(s.viewerOnly(http.HandlerFunc(s.handleFleetLoginPage)))))
		// A sign-in refused while a `fleet login` waits (claude-fleet#2261):
		// a signed note, so the terminal hears why — public, like start/poll.
		mux.Handle(LoginRefusedPath, s.stateRouteFunc(s.handleLoginRefused))
		// Drill people (claude-fleet#2010): an approve code confirms a scan
		// as the drill person — it is the whole credential, so outside the
		// viewer gate; the invite authenticates itself (cert or gate).
		mux.Handle(LoginApprovePath, s.stateRouteFunc(s.handleLoginApprove))
		mux.HandleFunc(DrillPath, s.handleAdminDrill)
		mux.HandleFunc(DrillSelfPath, s.handleSelf)
		mux.Handle("/connect", s.viewerOnly(http.HandlerFunc(s.serveConnectPage)))
		// Config (claude-fleet#1989): my settings and the team layer, read
		// from the bundle routes below.
		mux.Handle("/config", s.viewerOnly(http.HandlerFunc(s.serveConfigPage)))
		// Registered devices (claude-fleet#1470): a renewal is proven by the
		// device's own key, so it authenticates itself, outside the viewer
		// gate — like start/poll, it is what `fleet` runs before it holds a
		// live certificate. The device list and revocation are a person's
		// own (or the operator's), behind the gate.
		mux.HandleFunc(control.RenewPath, s.handleDeviceRenew)
		// 登录即登记 (claude-fleet#2212): the same device signature buys the
		// device's node pass — untrusted, coordinate-only — with no second scan.
		mux.HandleFunc(control.LoginNodePath, s.handleLoginNode)
		// Devices shows an admin their own too (claude-fleet#2515); everyone's
		// is AdminDevicesPath. Revoke stays where it was: an admin revokes any.
		mux.Handle("/v1/fleet/devices", s.viewerOnly(ownView(http.HandlerFunc(s.handleFleetDevices))))
		mux.Handle(AdminDevicesPath, s.viewerOnly(s.adminOnly(http.HandlerFunc(s.handleFleetDevices))))
		mux.Handle(AdminSessionsPath, s.viewerOnly(s.adminOnly(http.HandlerFunc(s.handleAdminSessions))))
		mux.Handle("/v1/fleet/devices/revoke", s.viewerOnly(http.HandlerFunc(s.handleFleetDeviceRevoke)))
		// Which machine to enter (claude-fleet#1470): admits a certificate by a
		// signed timestamp like the route list, so it authenticates itself.
		mux.HandleFunc(control.HomePath, s.handleFleetHome)
		// The one-line install (claude-fleet#1470): a script and three
		// programs carrying no credential, public like the CA's public key;
		// 404 until the hub can sign someone in with nothing in hand.
		mux.HandleFunc("/install", s.handleInstall)
		mux.HandleFunc("/install/", s.handleInstallFile)
		// Node releases (claude-fleet#2335): stable's files, binaries and
		// installers, signed — public like /install; the signature is the trust.
		mux.HandleFunc("/v1/fleet/release/", s.handleRelease)
		// A client's team defaults (claude-fleet#1722): whitelisted, never
		// a credential, read by every client's start — public like /install.
		mux.HandleFunc("/v1/fleet/client-settings", s.handleClientSettings)
		// Credentials (claude-fleet#1415): the lease authenticates with the
		// node's enrollment token, like the control channel; everything else
		// is the operator's.
		mux.HandleFunc("/v1/node/credentials", s.handleNodeCredentials)
		// The Singapore relay (claude-fleet#1974): a trusted node mints its
		// own relay credential with its token; the forwarder's forward_auth
		// asks the check, which authenticates the pass it carries.
		mux.HandleFunc("/v1/node/relay-credential", s.handleNodeRelayCredential)
		mux.HandleFunc(RelayCheckPath, s.handleRelayCheck)
		mux.Handle("/v1/fleet/credentials", s.viewerOnly(s.adminOnly(http.HandlerFunc(s.handleFleetCredentials))))
		// Take a machine's enrollment back (claude-fleet#1403): the token,
		// its open link, its session passes and relay credential at once.
		mux.Handle(NodeRevokePath, s.viewerOnly(s.adminOnly(http.HandlerFunc(s.handleNodeRevoke))))
		// Take a machine off the hub (claude-fleet#1928): the revoke plus its
		// roster row — an admin any machine, a person their own; a node itself
		// with its own token (`fleet node leave`).
		mux.Handle(NodeRetirePath, s.viewerOnly(http.HandlerFunc(s.handleNodeRetire)))
		mux.HandleFunc(NodeLeavePath, s.handleNodeLeave)
		mux.Handle("/v1/fleet/credentials/revoke", s.viewerOnly(s.adminOnly(http.HandlerFunc(s.handleFleetRevoke))))
		mux.Handle("/v1/fleet/credentials/audit", s.viewerOnly(s.adminOnly(http.HandlerFunc(s.handleFleetCredAudit))))
		// Session passes for untrusted machines (claude-fleet#1969): issue /
		// renew / revoke by the node's token, verify by the verifiers' token,
		// the list by the operator — each route checks its own.
		mux.HandleFunc("/v1/fleet/session-cred", s.handleSessionCred)
		mux.HandleFunc("/v1/fleet/session-cred/", s.handleSessionCred)
		// The cluster credential proxy's one question (claude-fleet#1973):
		// its own token, checked by the handler.
		mux.HandleFunc(CredProxyResolvePath, s.handleCredProxyResolve)
		// …and its quota 429s (claude-fleet#2115): the hub moves the
		// session to an account with room, once.
		mux.HandleFunc(CredProxyRebindPath, s.handleCredProxyRebind)
		// Per-person budgets (claude-fleet#1977): what a person used,
		// reported by both proxies, each with its own token; the list is
		// the operator's.
		mux.HandleFunc(CredProxyUsagePath, s.handleCredProxyUsage)
		mux.HandleFunc("/v1/node/usage", s.handleNodeUsage)
		mux.Handle("/v1/fleet/person-usage", s.viewerOnly(http.HandlerFunc(s.handleFleetPersonUsage)))
		// 我的用量 (claude-fleet#2519): a person's own usage and budget.
		mux.Handle("/usage", s.viewerOnly(http.HandlerFunc(s.serveUsagePage)))
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
		mux.Handle("/v1/fleet/ssh-relays", s.viewerOnly(s.adminOnly(http.HandlerFunc(s.handleSSHRelayAudit))))
	}

	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		body := map[string]string{"status": "ok"}
		if s.ReadOnly {
			body["mode"] = "read-only"
		}
		writeJSON(w, http.StatusOK, body)
	})
	// What a rolling release asks (claude-fleet#2125, deploy_probe.go): may
	// this replica take traffic, and does a write go through.
	mux.HandleFunc("/readyz", s.handleReadyz)
	mux.HandleFunc("/v1/deploy-probe", s.handleDeployProbe)
	// Which commit this image was built from (claude-fleet#1696): public like
	// /healthz, so `fleet-doctor`'s hub-image row can compare it with
	// refs/tags/stable from any machine, with no cluster access and no token.
	mux.HandleFunc("/version", s.handleVersion)

	mux.Handle("/v1/accounts", s.viewerOnly(s.adminOnly(http.HandlerFunc(s.handleAccounts))))
	// Who the gate admitted, for the shared page header (claude-fleet#1467).
	// Unconditional: the header is on every hub's dashboard, fleet module or not.
	mux.Handle("/v1/me", s.viewerOnly(http.HandlerFunc(s.handleMe)))
	// 我的额度 (claude-fleet#2517): the API and its page.
	mux.Handle("/v1/me/quota", s.viewerOnly(http.HandlerFunc(s.handleMeQuota)))
	mux.Handle("/quota", s.viewerOnly(http.HandlerFunc(s.serveQuotaPage)))
	mux.Handle("/v1/collectors", s.viewerOnly(s.adminOnly(http.HandlerFunc(s.handleCollectors))))
	mux.Handle("/v1/account-usage", s.viewerOnly(s.adminOnly(http.HandlerFunc(s.handleAccountUsage))))
	mux.Handle("/v1/limits", s.viewerOnly(s.adminOnly(http.HandlerFunc(s.handleLimits))))
	mux.Handle("/v1/endpoints", s.viewerOnly(s.adminOnly(http.HandlerFunc(s.handleEndpoints))))
	// Overview's reads: an admin's own there too (claude-fleet#2515); the hub
	// by login is AdminOverviewPath.
	mux.Handle("/v1/usage", s.viewerOnly(ownView(http.HandlerFunc(s.handleUsage))))
	mux.Handle("/v1/history", s.viewerOnly(ownView(http.HandlerFunc(s.handleHistory))))
	mux.Handle("/v1/account-switches", s.viewerOnly(s.adminOnly(http.HandlerFunc(s.handleSwitches))))
	mux.Handle("/v1/endpoint-accounts", s.viewerOnly(s.adminOnly(http.HandlerFunc(s.handleEndpointAccounts))))
	mux.Handle("/v1/accounts/label", s.viewerOnly(s.adminOnly(http.HandlerFunc(s.handleAccountLabel))))
	mux.Handle("/v1/live", s.viewerOnly(http.HandlerFunc(s.handleLiveSnapshot)))
	mux.Handle("/v1/live/stream", s.viewerOnly(http.HandlerFunc(s.handleLiveStream)))
	mux.Handle("/v1/summary", s.viewerOnly(ownView(http.HandlerFunc(s.handleSummary))))
	mux.Handle("/v1/sessions", s.viewerOnly(http.HandlerFunc(s.handleSessions)))
	mux.Handle("/v1/sessions/", s.viewerOnly(http.HandlerFunc(s.handleSession)))
	mux.Handle("/v1/limits/history", s.viewerOnly(s.adminOnly(http.HandlerFunc(s.handleLimitsHistory))))
	// The quota windows on their own. /v1/limits/history still folds a copy in
	// for the dashboard, which draws both series on one axis; this is for a
	// caller that wants only the windows -- see handleQuotaHistory.
	mux.Handle("/v1/quota/history", s.viewerOnly(s.adminOnly(http.HandlerFunc(s.handleQuotaHistory))))
	mux.Handle("/v1/findings", s.viewerOnly(s.adminOnly(http.HandlerFunc(s.handleFindings))))
	// The hub's second viewer-facing WRITE, behind the same gate as the
	// first (/v1/accounts/label) and deliberately not behind a new one --
	// see internal/api/finding_mutes.go on the trust boundary.
	mux.Handle("/v1/findings/mutes", s.viewerOnly(s.adminOnly(http.HandlerFunc(s.handleFindingMutes))))

	if s.MCP != nil {
		mux.Handle("/mcp", s.viewerOnly(s.MCP))
	}

	mux.Handle("/v1/user", s.viewerOnly(http.HandlerFunc(s.handleUserData)))

	// The door map: every way into this hub, what each costs in credentials,
	// and what is actually turned on here. Behind the viewer gate like every
	// other human surface -- it describes the configuration, and /signin's
	// unconditional 404 exists precisely so an uncredentialled prober cannot
	// learn that. Its page retired with claude-fleet#1990; Settings reads it.
	// See access.go.
	mux.Handle("/v1/access", s.viewerOnly(s.adminOnly(http.HandlerFunc(s.handleAccess))))

	// The admin pages (claude-fleet#1990): Subscriptions, Users, Settings,
	// Audit (Machines is /nodes, above). A user gets the 403 page.
	for _, p := range adminPageRoutes {
		mux.Handle(p.path, s.viewerOnly(s.adminPage(p.id, p.file)))
	}
	mux.Handle(AuditPath, s.viewerOnly(s.adminOnly(http.HandlerFunc(s.handleAdminAudit))))
	mux.Handle(AdminOverviewPath, s.viewerOnly(s.adminOnly(http.HandlerFunc(s.handleAdminOverview))))

	// Badges are the one surface that may be unauthenticated, and only on
	// purpose. Everything else on this hub stays behind the viewer token.
	badges := http.NewServeMux()
	badges.HandleFunc("/badge/u/", s.handleUserBadge)
	badges.HandleFunc("/badge/team/", s.handleTeamBadge)
	// The live embed exposes exactly what a badge does, so it shares the gate.
	badges.HandleFunc("/embed/u/", s.serveEmbed)
	badges.HandleFunc("/embed/team/", s.serveEmbed)
	// hub.public_badges (claude-fleet#1986) is read per request, so an
	// admin's switch applies at once.
	gatedBadges := s.viewerOnly(s.adminOnly(badges))
	badgeGate := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if s.publicBadges() {
			badges.ServeHTTP(w, r)
			return
		}
		gatedBadges.ServeHTTP(w, r)
	})
	mux.Handle("/badge/", badgeGate)
	mux.Handle("/embed/", badgeGate)

	// The public counter (claude-fleet#1988): the hub's one lifetime total,
	// readable by anyone while hub.public_meter is on, so 24haowan.com's
	// homepage takes it straight from here instead of through a token.
	mux.HandleFunc("/meter.json", s.handleMeter)
	mux.HandleFunc("/odometer.svg", s.handleOdometer)

	// Signed out, "/" is the front page; signed in, the app. Every page under
	// it settles its language first (claude-fleet#2023). Every other path that
	// reaches here is one of the app's own files or a 404 -- for everyone,
	// before the gate: the file list is the repository's web/dist, so whether
	// a path exists tells a stranger nothing, and a removed route answers 404
	// rather than the app's index (claude-fleet#1987).
	mux.Handle("/", s.uiPathOr404(s.withPageLang(s.viewerOr(http.HandlerFunc(s.serveUI), s.serveLanding))))

	return mux
}

// viewerOnly gates a handler behind the viewer token.
//
// The token may arrive as a bearer header (API and MCP clients) or as a
// `ccquota_token` cookie, which is what lets a browser follow ?token=... once
// and then navigate normally.
func (s *Server) viewerOnly(next http.Handler) http.Handler {
	return s.viewerOr(next, nil)
}

// viewerOr is viewerOnly with a say in what a request holding NO credential
// gets: signedOut answers it when it returns true, else the gate's usual
// sign-in redirect or 401 follows. Only the front page uses it
// (claude-fleet#1988): a stranger opening "/" reads what claudefleet is
// instead of a refusal, while everyone the gate admits still gets the app.
func (s *Server) viewerOr(next http.Handler, signedOut func(http.ResponseWriter, *http.Request) bool) http.Handler {
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
		// A GitHub session (claude-fleet#1984), re-checked against the list
		// on every request: someone taken off it is refused here, now.
		if ctx, ok, handled := s.githubAdmit(w, r); handled {
			return
		} else if ok {
			next.ServeHTTP(w, r.WithContext(ctx))
			return
		}
		if signedOut != nil && signedOut(w, r) {
			return
		}
		// A browser with no credential is someone who has not signed in yet;
		// send them to GitHub's page when it is wired up. Everything else gets
		// the honest 401.
		if s.GitHub.ready() && wantsHTML(r) {
			http.Redirect(w, r, "/signin", http.StatusFound)
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

// uiPathOr404 lets through "/" and the paths the built UI holds, and answers
// 404 to every other path. The dashboard routes by its URL fragment
// (#/?view=…), so it never needed a path fallback, and an unknown path —
// a route this hub no longer has, an API path that never existed — is a 404.
func (s *Server) uiPathOr404(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/" {
			next.ServeHTTP(w, r)
			return
		}
		if s.UI == nil {
			http.NotFound(w, r)
			return
		}
		st, err := fs.Stat(s.UI, strings.TrimPrefix(r.URL.Path, "/"))
		if err != nil || st.IsDir() {
			http.NotFound(w, r)
			return
		}
		next.ServeHTTP(w, r)
	})
}

// serveUI serves the embedded dashboard: index.html at "/", else the file
// the path names (uiPathOr404 has already refused one the UI does not hold).
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
		// "/" is the overview page: the app document, like every page path
		// (claude-fleet#2793), else a build's own index.html.
		path = "index.html"
		if _, err := fs.Stat(s.UI, appPage); err == nil {
			path = appPage
		}
	}
	// An admin page's files are refused a user whole, by where they sit
	// (claude-fleet#2516) -- the direct path as much as the route.
	if isAdminUIFile(path) && roleOf(r.Context()) == roleUser {
		s.denyAdminPage(w, r)
		return
	}
	f, err := s.UI.Open(path)
	if err != nil {
		http.NotFound(w, r)
		return
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
// signed-in identity let the request in. Query strings are omitted: they can
// carry the viewer token. So is an invite's code (claude-fleet#2261): the
// path /i/<code> is logged as /i/….
func (s *Server) logRequests(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		sw := &statusWriter{ResponseWriter: w, status: http.StatusOK}
		// The gate fills this in if it grants by identity; the pointer is
		// how a value set downstream reaches this outer layer.
		var viewer string
		r = r.WithContext(context.WithValue(r.Context(), viewerKey{}, &viewer))
		next.ServeHTTP(sw, r)
		path := r.URL.Path
		if strings.HasPrefix(path, InvitePath) {
			path = InvitePath + "…"
		}
		line := fmt.Sprintf("%s %s %d %s", r.Method, path, sw.status, time.Since(start).Round(time.Millisecond))
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
