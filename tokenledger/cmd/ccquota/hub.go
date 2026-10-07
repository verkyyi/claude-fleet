package main

import (
	"context"
	"crypto/tls"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/agent"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/api"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/credvault"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/mcp"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/pricing"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/scan"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/sshca"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
	"github.com/verkyyi/claude-fleet/tokenledger/web"
)

// envOr lets an environment variable override a compiled-in default while an
// unset variable still leaves the default in place -- unlike os.Getenv alone,
// which turns "not configured" into "configured as empty".
func envOr(key, def string) string {
	if v, ok := os.LookupEnv(key); ok {
		return v
	}
	return def
}

// fleetVault builds the credential vault (claude-fleet#1415) when the fleet
// module is on AND a key is configured. The key lives in its own k8s Secret,
// never in the database the blobs are in. A key that is set but unreadable is
// fatal: starting without it would silently stop every lease.
//
// CCQUOTA_FLEET_CRED_KMS_KEY_ID moves the key into Aliyun KMS
// (claude-fleet#1417): the vault starts LOCKED and opens only when KMS unwraps
// its data key; while KMS is unreachable it stays locked — no lease, no
// store, a critical finding — and never falls back to a plain key.
func fleetVault(fleetOn bool, st *store.Store) (*credvault.Vault, error) {
	if !fleetOn {
		return nil, nil
	}
	key, ok, err := credvault.LoadKey(os.Getenv)
	if err != nil {
		return nil, err
	}
	kmsKey := os.Getenv("CCQUOTA_FLEET_CRED_KMS_KEY_ID")
	if !ok && kmsKey == "" {
		log.Printf("fleet: credential vault off (set CCQUOTA_FLEET_CRED_KMS_KEY_ID, or CCQUOTA_FLEET_CRED_KEY_FILE / CCQUOTA_FLEET_CRED_KEY, to turn it on)")
		return nil, nil
	}
	minTTL := credvault.DefaultMinTTL
	if v := os.Getenv("CCQUOTA_FLEET_CRED_MIN_TTL"); v != "" {
		d, err := time.ParseDuration(v)
		if err != nil || d <= 0 {
			return nil, fmt.Errorf("CCQUOTA_FLEET_CRED_MIN_TTL: %q is not a positive duration", v)
		}
		minTTL = d
	}
	vault := &credvault.Vault{Store: st, MinTTL: minTTL, Refresher: &credvault.HTTPRefresher{
		ClaudeTokenURL: os.Getenv("CCQUOTA_FLEET_CLAUDE_TOKEN_URL"),
		CodexTokenURL:  os.Getenv("CCQUOTA_FLEET_CODEX_TOKEN_URL"),
	}}
	if kmsKey == "" {
		sealer, err := credvault.NewSealer(key)
		if err != nil {
			return nil, err
		}
		vault.Sealer = sealer
		log.Printf("fleet: credential vault on — nodes lease at /v1/node/credentials, audit at /credentials")
		return vault, nil
	}

	env, err := kmsEnvelope(kmsKey, st)
	if err != nil {
		return nil, err
	}
	if ok {
		env.Legacy = key
	}
	vault.SetLocked("unwrapping the data key from KMS", time.Now())
	log.Printf("fleet: credential vault on, key in KMS %s — locked until KMS unwraps it", kmsKey)
	go credvault.KeepUnlocked(context.Background(), vault, env, 15*time.Second, 5*time.Minute,
		func(locked bool, detail string) {
			a := store.CredAudit{Action: store.CredUnlock, Detail: "ok: " + detail}
			if locked {
				a.Detail = "LOCKED: " + detail
				log.Printf("credvault: ALERT vault LOCKED — no credential is issued until KMS answers: %s", detail)
			} else {
				log.Printf("credvault: vault unlocked — %s", detail)
			}
			if err := st.AddCredAudit(a); err != nil {
				log.Printf("credvault: audit unlock: %v", err)
			}
		})
	return vault, nil
}

// fleetRefreshVia wires how the vault refreshes a token (claude-fleet#1490).
// CCQUOTA_FLEET_OAUTH_REFRESH_VIA=node hands the one POST to an admin node
// whose network the provider accepts — the hub in Shenzhen cannot refresh a
// Codex token itself (auth.openai.com answers 403
// unsupported_country_region_territory) and must not keep trying from there.
// =relay (claude-fleet#1976) posts a Codex refresh to the Singapore relay's
// /openai-auth/ route (CCQUOTA_FLEET_CRED_RELAY_URL) with the hub's own pass,
// so no machine's memory ever holds the refresh token and no machine needs to
// be online; a relay that cannot be asked — and a Claude refresh — falls back
// to the node path. Unset or "direct" keeps the hub posting from its own
// network, exactly as before; anything else refuses to start rather than guess.
func fleetRefreshVia(srv *api.Server, vault *credvault.Vault) error {
	switch v := strings.ToLower(strings.TrimSpace(os.Getenv("CCQUOTA_FLEET_OAUTH_REFRESH_VIA"))); v {
	case "", "direct":
		return nil
	case "node", "relay":
		if vault == nil {
			log.Printf("fleet: CCQUOTA_FLEET_OAUTH_REFRESH_VIA=%s set, but the credential vault is off — nothing to relay", v)
			return nil
		}
		node := &credvault.ProxyRefresher{Via: srv.NodeOAuthRefresh}
		if v == "node" {
			vault.Refresher = node
			log.Printf("fleet: credential refreshes are relayed through an online admin node (CCQUOTA_FLEET_OAUTH_REFRESH_VIA=node); none online = refresh_unavailable")
			return nil
		}
		url := strings.TrimSpace(os.Getenv("CCQUOTA_FLEET_CRED_RELAY_URL"))
		if url == "" {
			return errors.New("CCQUOTA_FLEET_OAUTH_REFRESH_VIA=relay needs CCQUOTA_FLEET_CRED_RELAY_URL (the Singapore relay, docs/CRED-RELAY.md)")
		}
		if len(srv.SessionCredKey) == 0 {
			return errors.New("CCQUOTA_FLEET_OAUTH_REFRESH_VIA=relay needs CCQUOTA_FLEET_SESSION_CRED_KEY — the hub signs its relay pass with it")
		}
		vault.Refresher = &credvault.RelayRefresher{URL: url, Pass: srv.HubRelayPass, Fallback: node}
		log.Printf("fleet: OpenAI credential refreshes go through the relay %s (CCQUOTA_FLEET_OAUTH_REFRESH_VIA=relay); relay down = an admin node, Claude = an admin node", url)
		return nil
	default:
		return fmt.Errorf("CCQUOTA_FLEET_OAUTH_REFRESH_VIA: %q is not relay, node or direct", v)
	}
}

// fleetHubQuota wires the hub reading every pool subscription's quota itself
// through the Singapore relay (claude-fleet#2169):
//
//	CCQUOTA_FLEET_HUB_QUOTA=relay           on; needs CCQUOTA_FLEET_CRED_RELAY_URL
//	                                        and CCQUOTA_FLEET_SESSION_CRED_KEY
//	CCQUOTA_FLEET_HUB_QUOTA_INTERVAL=5m     between reads (at least 1m)
//
// Unset or "off" leaves srv.HubQuota nil: nothing is read, no quota pass is
// signed or accepted, and every reading on the page is a node's — exactly as
// before. Anything else refuses to start rather than guess.
func fleetHubQuota(srv *api.Server, vault *credvault.Vault) error {
	switch v := strings.ToLower(strings.TrimSpace(os.Getenv("CCQUOTA_FLEET_HUB_QUOTA"))); v {
	case "", "off":
		return nil
	case "relay":
		if vault == nil {
			log.Printf("fleet: CCQUOTA_FLEET_HUB_QUOTA=relay set, but the credential vault is off — no credential to read")
			return nil
		}
		url := strings.TrimSpace(os.Getenv("CCQUOTA_FLEET_CRED_RELAY_URL"))
		if url == "" {
			return errors.New("CCQUOTA_FLEET_HUB_QUOTA=relay needs CCQUOTA_FLEET_CRED_RELAY_URL (the Singapore relay, docs/CRED-RELAY.md)")
		}
		if len(srv.SessionCredKey) == 0 {
			return errors.New("CCQUOTA_FLEET_HUB_QUOTA=relay needs CCQUOTA_FLEET_SESSION_CRED_KEY — the hub signs its quota pass with it")
		}
		every := api.DefaultHubQuotaInterval
		if raw := strings.TrimSpace(os.Getenv("CCQUOTA_FLEET_HUB_QUOTA_INTERVAL")); raw != "" {
			d, err := time.ParseDuration(raw)
			if err != nil || d < api.MinHubQuotaInterval {
				return fmt.Errorf("CCQUOTA_FLEET_HUB_QUOTA_INTERVAL: %q is not a duration of at least %s", raw, api.MinHubQuotaInterval)
			}
			every = d
		}
		srv.HubQuota = &api.HubQuota{RelayURL: url, Interval: every}
		log.Printf("fleet: the hub reads every pool subscription's quota itself through the relay %s every %s (CCQUOTA_FLEET_HUB_QUOTA=relay)", url, every)
		return nil
	default:
		return fmt.Errorf("CCQUOTA_FLEET_HUB_QUOTA: %q is not relay or off", v)
	}
}

// kmsEnvelope builds the KMS client from CCQUOTA_FLEET_CRED_KMS_ENDPOINT (or
// _REGION) and the hub's Aliyun identity (credvault.CredsFromEnv). An identity
// that is missing does not stop the hub: every unlock fails with that reason,
// which is the locked vault + critical finding the operator needs to see.
func kmsEnvelope(keyID string, st *store.Store) (*credvault.Envelope, error) {
	endpoint := os.Getenv("CCQUOTA_FLEET_CRED_KMS_ENDPOINT")
	if endpoint == "" {
		region := os.Getenv("CCQUOTA_FLEET_CRED_KMS_REGION")
		if region == "" {
			return nil, errors.New("CCQUOTA_FLEET_CRED_KMS_KEY_ID needs CCQUOTA_FLEET_CRED_KMS_REGION (e.g. cn-shenzhen) or CCQUOTA_FLEET_CRED_KMS_ENDPOINT")
		}
		endpoint = "https://kms." + region + ".aliyuncs.com"
	} else if !strings.Contains(endpoint, "://") {
		endpoint = "https://" + endpoint
	}
	creds, source, err := credvault.CredsFromEnv(os.Getenv, nil)
	if err != nil {
		cerr := err
		creds = func(context.Context) (credvault.AliyunCreds, error) { return credvault.AliyunCreds{}, cerr }
		source = "none"
	}
	if source == "static-key" {
		log.Printf("fleet: KMS identity is a static AccessKey — whoever holds that Secret can unwrap the vault too; use RRSA or an instance role")
	}
	log.Printf("fleet: KMS %s, identity %s", endpoint, source)
	return &credvault.Envelope{KMS: &credvault.AliyunKMS{Endpoint: endpoint, Creds: creds}, KeyID: keyID, Store: st}, nil
}

// fleetNudgePath is $FLEET_CONF_DIR/global/hub-nudge when the fleet's conf
// dir is named in the environment (claude-fleet#1481); empty lets the agent
// derive the default conf dir from its home.
func fleetNudgePath() string {
	if d := os.Getenv("FLEET_CONF_DIR"); d != "" {
		return filepath.Join(d, "global", "hub-nudge")
	}
	return ""
}

// fleetConfPath is $FLEET_CONF_DIR/<name> when the conf dir is named in the
// environment; empty lets the agent derive the default from its home.
func fleetConfPath(name string) string {
	if d := os.Getenv("FLEET_CONF_DIR"); d != "" {
		return filepath.Join(d, name)
	}
	return ""
}

// fleetEnabled reports CCQUOTA_FLEET=1, the one switch for the whole fleet
// module (claude-fleet#1408). Anything else — unset, empty, 0 — is off, and off
// is today's hub and agent exactly.
func fleetEnabled() bool {
	return os.Getenv("CCQUOTA_FLEET") == "1"
}

// loadFleetCerts wires the SSH certificate authority (claude-fleet#1412).
// CCQUOTA_FLEET_SSH_CA_KEY names the CA private key file — mounted from its
// own k8s Secret, never stored in the database. Unset: no certificates. Set
// but unreadable: the hub refuses to start rather than run half-configured.
func loadFleetCerts(srv *api.Server) error {
	routes, err := api.ParseFleetRoutes(os.Getenv("CCQUOTA_FLEET_ROUTES"))
	if err != nil {
		return err
	}
	srv.FleetRoutes = routes
	srv.FleetPublicURL = os.Getenv("CCQUOTA_FLEET_PUBLIC_URL")
	srv.FleetDistDir = os.Getenv("CCQUOTA_FLEET_DIST_DIR")
	srv.FleetJoinScriptURL = os.Getenv("CCQUOTA_FLEET_JOIN_SCRIPT_URL")
	// The client follows GitHub's stable through this hub (claude-fleet#1805);
	// "off" hands out the image's packed client only.
	if repo := os.Getenv("CCQUOTA_FLEET_STABLE_REPO"); repo != "off" {
		srv.Stable = &api.StableSource{Repo: repo}
		srv.Stable.Commit() // the first lookup, in the background
	}
	path := os.Getenv("CCQUOTA_FLEET_SSH_CA_KEY")
	if path == "" {
		log.Printf("fleet: no CCQUOTA_FLEET_SSH_CA_KEY — connection certificates are off")
		return nil
	}
	ca, err := sshca.Load(path)
	if err != nil {
		return fmt.Errorf("CCQUOTA_FLEET_SSH_CA_KEY: %w", err)
	}
	srv.SSHCA = ca
	log.Printf("fleet: SSH user CA %s — 12h certificates at /connect and `fleet login`", ca.Fingerprint())
	return nil
}

// envOrFile reads a secret from NAME_FILE (a Secret mount) or NAME.
func envOrFile(name string) (string, error) {
	v := strings.TrimSpace(os.Getenv(name))
	if path := os.Getenv(name + "_FILE"); path != "" {
		b, err := os.ReadFile(path)
		if err != nil {
			return "", fmt.Errorf("%s_FILE: %w", name, err)
		}
		v = strings.TrimSpace(string(b))
	}
	return v, nil
}

// replicaConfig reads CCQUOTA_REPLICA (this replica's name — the pod name),
// CCQUOTA_REPLICA_URL (where the other replicas reach this one, in-cluster) and
// CCQUOTA_REPLICA_TOKEN[_FILE] (their shared token, from a k8s Secret). None
// set: a single hub. Some but not all: refused (claude-fleet#2124).
func replicaConfig(srv *api.Server) error {
	tok, err := envOrFile("CCQUOTA_REPLICA_TOKEN")
	if err != nil {
		return err
	}
	r, err := api.ParseReplica(os.Getenv, tok)
	if err != nil {
		return err
	}
	srv.Replica = r
	return nil
}

// loadSessionCreds wires session passes for untrusted machines
// (claude-fleet#1969): CCQUOTA_FLEET_SESSION_CRED_KEY[_FILE] is the signing
// key (its own k8s Secret, never the database);
// CCQUOTA_FLEET_SESSION_CRED_VERIFY_TOKEN[_FILE] admits the cluster
// credential proxy and the relay to /verify;
// CCQUOTA_FLEET_CREDPROXY_TOKEN[_FILE] admits `ccquota credproxy` to
// resolve (claude-fleet#1973). No key: the routes answer 503
// and nothing else changes. A key that is set but unreadable is fatal.
func loadSessionCreds(srv *api.Server) error {
	key, ok, err := api.LoadSessionCredKey(os.Getenv)
	if err != nil {
		return err
	}
	if !ok {
		log.Printf("fleet: no CCQUOTA_FLEET_SESSION_CRED_KEY — session passes are off")
		return nil
	}
	srv.SessionCredKey = key
	vt := strings.TrimSpace(os.Getenv("CCQUOTA_FLEET_SESSION_CRED_VERIFY_TOKEN"))
	if path := os.Getenv("CCQUOTA_FLEET_SESSION_CRED_VERIFY_TOKEN_FILE"); path != "" {
		b, err := os.ReadFile(path)
		if err != nil {
			return fmt.Errorf("CCQUOTA_FLEET_SESSION_CRED_VERIFY_TOKEN_FILE: %w", err)
		}
		vt = strings.TrimSpace(string(b))
	}
	srv.SessionCredVerifyToken = vt
	pt, err := envOrFile("CCQUOTA_FLEET_CREDPROXY_TOKEN")
	if err != nil {
		return err
	}
	srv.CredProxyToken = pt
	if pt != "" {
		log.Printf("fleet: cluster credential proxy admitted — %s", api.CredProxyResolvePath)
	}
	log.Printf("fleet: session passes on — /v1/fleet/session-cred (verify: %s)",
		map[bool]string{true: "verifier token + operator", false: "operator only"}[vt != ""])
	return nil
}

func runHub(args []string) error {
	fs := flag.NewFlagSet("hub", flag.ExitOnError)
	addr := fs.String("addr", "127.0.0.1:8787",
		"listen address(es), comma-separated. Binding a tailnet address alone\n"+
			"means localhost does not work from the machine itself, which is\n"+
			"where you usually are: `127.0.0.1:8787,100.x.y.z:8787` gives both")
	dbPath := fs.String("db", "", "path to the SQLite database (default: $CCQUOTA_DB, else ~/.ccquota/ccquota.db)")
	token := secretEnvFlag(fs, "token", "CCQUOTA_VIEWER_TOKEN", "viewer `token` for the dashboard, API and MCP")
	noAuth := fs.Bool("no-auth", false, "serve without a viewer token (loopback binds only)")
	tailscaleBin := fs.String("tailscale-bin", "", "path to the tailscale CLI, for --https-addr (default: search PATH and the usual places)")
	httpsAddr := fs.String("https-addr", "",
		"also serve HTTPS here (e.g. :443) with a certificate from tailscale cert\n"+
			"for this node's MagicDNS name, renewed by the hub. Only tailnet peers\n"+
			"and loopback are accepted, whatever the socket can hear -- macOS lets\n"+
			"an unprivileged process take :443 only on the wildcard address.\n"+
			"The URL becomes https://<node>.<tailnet>.ts.net")
	tlsHost := fs.String("tls-host", "", "the name to get a certificate for (default: detected from tailscale status)")
	insecurePublic := fs.Bool("insecure-public", false, "acknowledge binding to a public address without TLS in front")
	pricingFile := fs.String("pricing", "", "path to a pricing override file")
	pollInterval := fs.Int("limits-poll-interval", 120, "seconds between agents' limit polls")
	retentionDays := fs.Int("retention-days", 90, "days of raw events to keep (0 disables pruning)")
	rebuild := fs.Bool("rebuild-rollup", false,
		"rebuild the hourly rollup from raw events at startup, then continue.\n"+
			"Open already does this automatically after a schema change; pass this\n"+
			"to force it after fixing corrupted rows by hand, for instance.\n"+
			"Refuses (see the error) rather than rebuild over hours usage_events\n"+
			"can no longer reconstruct -- retention pruning has already deleted\n"+
			"their only other record. Pass --rebuild-rollup-force too to proceed\n"+
			"anyway and accept losing them")
	reprice := fs.Bool("reprice", false,
		"recompute every stored event's cost from the pricing table as it\n"+
			"stands now, then refold the rollup -- then continue serving.\n"+
			"Pricing happens at ingest, so a rate added today otherwise reaches\n"+
			"only the events that arrive after it: the month you could not price\n"+
			"last month stays unpriced forever, and --rebuild-rollup does not\n"+
			"help (it refolds the same stale figures). Use this after correcting\n"+
			"--pricing")
	repriceSince := fs.String("reprice-since", "",
		"with --reprice, only touch events at or after this RFC3339 instant\n"+
			"(for example 2026-09-01T00:00:00Z). Default: every event")
	rebuildForce := fs.Bool("rebuild-rollup-force", false,
		"with --rebuild-rollup, proceed even when the rollup holds hours\n"+
			"usage_events can no longer reconstruct, accepting that those older\n"+
			"rows are left exactly as they are (not deleted, not rebuilt).\n"+
			"Read the refusal error before reaching for this: it says how many\n"+
			"hours are at stake")
	migrateOnly := fs.Bool("migrate-only", false,
		"open the database, run its pending migrations, print what they did,\n"+
			"and exit -- no port is bound. hub-deploy runs the new image this\n"+
			"way on a copy of the live database before it switches images, so a\n"+
			"migration that cannot pass stops the release instead of the hub\n"+
			"(claude-fleet#2050). Refuses a --db that does not exist")
	check := fs.Bool("check", false,
		"start up as far as serving and stop there: run the database's pending\n"+
			"migrations, read every setting and secret the hub refuses to start\n"+
			"without (GitHub sign-in pairs, the CA and credential keys, --pricing,\n"+
			"...), then exit 0 = this image may be switched to -- no port is\n"+
			"bound. hub-deploy runs the new image this way, with the live pod's\n"+
			"environment, on a copy of the live database before it switches\n"+
			"images (claude-fleet#2052). Refuses a --db that does not exist")
	simulateMigrationFailure := fs.Bool("simulate-migration-failure", false,
		"with --migrate-only or --check, fail as a migration that cannot pass\n"+
			"would: the drill that proves hub-deploy's rehearsal stops a release")
	if err := fs.Parse(args); err != nil {
		return err
	}

	// Parse before anything opens a database or binds a port: an operator who
	// mistyped the instant should get the complaint immediately, not after a
	// restart has already taken the hub down.
	var repriceFrom time.Time
	if *repriceSince != "" {
		if !*reprice {
			return errors.New("--reprice-since without --reprice: nothing would be repriced")
		}
		t, err := time.Parse(time.RFC3339, *repriceSince)
		if err != nil {
			return fmt.Errorf("--reprice-since: %w (want an RFC3339 instant such as 2026-09-01T00:00:00Z)", err)
		}
		repriceFrom = t
	}

	dbFile, err := resolveDB(*dbPath)
	if err != nil {
		return err
	}
	if *simulateMigrationFailure && !*migrateOnly && !*check {
		return errors.New("--simulate-migration-failure without --migrate-only or --check: it only drills the rehearsal")
	}
	if *migrateOnly && *check {
		return errors.New("--migrate-only and --check: --check already runs the migrations")
	}
	if *migrateOnly {
		return migrateOnlyRun(dbFile, os.Stdout, *simulateMigrationFailure)
	}
	if *check {
		// The migrations first, on their own (same refusal of a missing file,
		// same report); then the ordinary start below, which stops short of
		// the listeners.
		if err := migrateOnlyRun(dbFile, os.Stdout, *simulateMigrationFailure); err != nil {
			return fmt.Errorf("--check: %w", err)
		}
	}
	// The hub is the one command allowed to bring a database into being, so
	// say when it does. A hub silently starting on an empty database looks
	// exactly like a hub that has lost everything.
	if store.UsesPostgres() {
		// --db names no file then: the database is the server CCQUOTA_DB_URL
		// points at (claude-fleet#2120), and Open creates its tables.
		log.Printf("database: Postgres (%s); --db %s is not used", "CCQUOTA_DB_URL", dbFile)
	} else if _, statErr := os.Stat(dbFile); errors.Is(statErr, os.ErrNotExist) {
		if err := os.MkdirAll(filepath.Dir(dbFile), 0o700); err != nil {
			return fmt.Errorf("create %s: %w", filepath.Dir(dbFile), err)
		}
		log.Printf("no database at %s yet; creating an empty one", dbFile)
	}

	addrs := splitList(*addr)
	if len(addrs) == 0 {
		return errors.New("--addr is empty")
	}
	for _, a := range addrs {
		if err := checkExposure(a, *token, *noAuth, *insecurePublic); err != nil {
			return err
		}
	}

	st, err := store.Open(dbFile)
	if err != nil {
		return err
	}
	defer st.Close()
	if st.BackfilledRollup > 0 {
		log.Printf("rollup: built %d hourly rows from usage_events", st.BackfilledRollup)
	}
	fleetOn := fleetEnabled()
	if fleetOn {
		if err := st.EnsureNodes(); err != nil {
			return err
		}
		log.Printf("fleet module on (CCQUOTA_FLEET=1): nodes connect at %s, roster at /nodes, fleet reads at /v1/fleet/", control.Path)
	}
	vault, err := fleetVault(fleetOn, st)
	if err != nil {
		return err
	}
	if *rebuild {
		n, err := st.RebuildRollup(*rebuildForce)
		if err != nil {
			return fmt.Errorf("--rebuild-rollup: %w", err)
		}
		log.Printf("rollup: rebuilt %d hourly rows from usage_events", n)
	}

	table := pricing.Default()
	if *pricingFile != "" {
		if err := table.LoadOverrides(*pricingFile); err != nil {
			return err
		}
		// Subscription prices ride in the same file but land in the database,
		// not in the rate table: they are real money and the rate table is
		// notional, and the two must never meet. Recording them on every start
		// keeps the file the source of truth for a hub that manages prices
		// that way, while `ccquota plan --set` stays available for a hub that
		// does not.
		plans, err := pricing.LoadPlanPrices(*pricingFile)
		if err != nil {
			return err
		}
		for _, pl := range plans {
			if err := st.SetPlanPrice(pl); err != nil {
				return fmt.Errorf("--pricing: record %s/%s: %w", pl.Source, pl.Plan, err)
			}
		}
		if len(plans) > 0 {
			log.Printf("pricing: recorded %d subscription plan price(s) from %s", len(plans), *pricingFile)
		}
	}

	// After the table is loaded, and after any --pricing overrides are merged
	// into it: repricing against the built-in table alone would undo every
	// operator correction, which is the opposite of the point.
	if *reprice {
		scope := "every event"
		if !repriceFrom.IsZero() {
			scope = "events at or after " + repriceFrom.Format(time.RFC3339)
		}
		log.Printf("reprice: applying the current rate table to %s", scope)
		res, err := st.Reprice(table, repriceFrom)
		if err != nil {
			return fmt.Errorf("--reprice: %w", err)
		}
		log.Printf("reprice: scanned %d event(s), changed %d (%d newly priced, %d back to unpriced), "+
			"net %+.6f USD, largest single change %.6f USD, refolded %d hourly row(s)",
			res.Scanned, res.Changed, res.NewlyPriced, res.Unpriced, res.NetUSD, res.MaxAbsUSD, res.RollupRows)
	}

	// Resolve the HTTPS name HERE rather than in the TLS block below, so the
	// Server is complete before Handler() is called and nothing writes to it
	// again once requests are being served. /access reports these addresses,
	// and a field filled in after the first listener is up is a data race, not
	// a late initialisation.
	//
	// It also fails earlier: a missing tailscale binary now stops the hub
	// before it binds anything, with the same message it always gave.
	var tlsBin, tlsName, httpsURL string
	if *httpsAddr != "" {
		var err error
		if tlsBin, err = api.FindTailscaleBin(*tailscaleBin); err != nil {
			return fmt.Errorf("--https-addr: %w", err)
		}
		if tlsName = *tlsHost; tlsName == "" {
			if tlsName, err = detectMagicDNSName(tlsBin); err != nil {
				return fmt.Errorf("--https-addr: %w", err)
			}
		}
		httpsURL = "https://" + tlsName + "/"
	}

	gh, err := githubAuthFromEnv(os.Getenv)
	if err != nil {
		return err
	}
	// CCQUOTA_READONLY=1 (claude-fleet#2122): hold the database still while
	// `ccquota db migrate` copies it. Last of the startup writes above.
	readOnly := os.Getenv("CCQUOTA_READONLY") == "1"
	if readOnly {
		if err := st.SetReadOnly(); err != nil {
			return err
		}
		log.Printf("read-only (CCQUOTA_READONLY=1): writes answer 503 + Retry-After, reads as usual")
	}

	srv := &api.Server{
		Store:               st,
		GitHub:              gh,
		Pricing:             table,
		ViewerToken:         *token,
		LimitsPollIntervalS: *pollInterval,
		Version:             Version,
		UI:                  web.Assets(),
		LiveStore:           api.NewLive(),
		Fleet:               fleetOn,
		ReadOnly:            readOnly,
		FleetAdmins:         splitList(os.Getenv("CCQUOTA_FLEET_ADMIN_USERS")),
		// A person's grant on their own logins (claude-fleet#1410).
		FleetPersonScopes:     fleetPersonScopes(),
		FleetPersonConfigKeys: splitList(os.Getenv("CCQUOTA_FLEET_PERSON_CONFIG_KEYS")),
		Vault:                 vault,
		// Where we are about to bind, so /access can print a URL instead of
		// "some port". The HTTPS half is filled in below, once the certificate
		// has told us the name it is actually for.
		Listeners: api.ListenerFacts{HTTP: addrs, HTTPS: *httpsAddr, HTTPSURL: httpsURL},
	}
	if fleetOn {
		if err := loadFleetCerts(srv); err != nil {
			return err
		}
		if err := sshRelayConfig(srv); err != nil {
			return err
		}
		if err := loadSessionCreds(srv); err != nil {
			return err
		}
		// After the session pass key: the relay path signs its pass with it.
		if err := fleetRefreshVia(srv, vault); err != nil {
			return err
		}
		// The hub reads the pool's quota itself (claude-fleet#2169).
		if err := fleetHubQuota(srv, vault); err != nil {
			return err
		}
		// One of several replicas behind one address (claude-fleet#2124):
		// a node call for a link another replica holds is handed to it.
		// Unset: a single hub, nothing forwarded and no table written.
		if err := replicaConfig(srv); err != nil {
			return err
		}
		// SPOT nodes (claude-fleet#1428): on only with an image to run.
		// A configured image whose cluster cannot be reached refuses to
		// start rather than run a hub that silently never scales.
		spotCfg, spotOn, err := api.ParseSpotConfig(os.Getenv, srv.FleetPublicURL)
		if err != nil {
			return err
		}
		if spotOn {
			sc, err := api.NewSpotController(srv, spotCfg)
			if err != nil {
				return fmt.Errorf("CCQUOTA_FLEET_SPOT_IMAGE is set but the Kubernetes API is not usable: %w", err)
			}
			srv.Spot = sc
		} else {
			log.Printf("fleet: SPOT nodes off (set CCQUOTA_FLEET_SPOT_IMAGE to turn them on)")
		}
	}
	srv.MCP = mcp.Handler(srv)
	// The settings an admin changes on the web (claude-fleet#1986): the one
	// old value still read is a SPOT image (fleet.spot), copied into the
	// database once at a real start. --public-badges,
	// CCQUOTA_FLEET_AUTO_ASSIGN and CCQUOTA_FLEET_PRINCIPAL_LOGINS are no
	// longer read (claude-fleet#2087): hub.public_badges, fleet.auto_assign and
	// user.<id>.machine_login are the only source.
	if *check {
		// Everything that can refuse a start has run; what is left (the
		// listeners, the background loops) is not configuration.
		fmt.Fprintf(os.Stdout, "check: ok — %s migrated and every startup setting read; this image may be switched to\n", dbFile)
		return nil
	}
	if err := srv.StartReplica(); err != nil {
		return err
	}
	if err := srv.MigrateLegacySettings(time.Now()); err != nil {
		log.Printf("WARN hub settings: copying the old variables: %v", err)
	}
	if err := srv.DropLegacyMachineLogins(time.Now()); err != nil {
		// An old identity's machine-login map with no reader left
		// (claude-fleet#2108).
		log.Printf("WARN hub settings: dropping old machine-login maps: %v", err)
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	if srv.Spot != nil {
		go srv.Spot.Run(ctx)
	}
	if srv.Fleet {
		// Node-lost / lease-conflict alerts (claude-fleet#1630).
		srv.NodeLostAfter = api.NodeLostAfterFromEnv()
		go srv.RunNodeAlerts(ctx)
		// Off (srv.HubQuota nil): returns at once.
		go srv.RunHubQuota(ctx)
	}
	// Pin each CCQUOTA_GITHUB_ADMINS name to its GitHub ID (claude-fleet#1984).
	// In the background: GitHub being slow must not hold the hub's start.
	go srv.ResolveGitHubAdmins(ctx)

	if *retentionDays > 0 {
		go pruneLoop(ctx, st, *retentionDays)
	}

	handler := srv.Handler()
	servers := make([]*http.Server, 0, len(addrs)+1)
	errCh := make(chan error, len(addrs)+1) // +1: the optional TLS listener

	for _, a := range addrs {
		// Listen before serving, so a bad address fails here with a clear
		// message rather than in a goroutine nobody is reading.
		ln, err := net.Listen("tcp", a)
		if err != nil {
			return fmt.Errorf("listen on %s: %w", a, err)
		}
		hs := &http.Server{Handler: handler, ReadHeaderTimeout: 10 * time.Second}
		servers = append(servers, hs)

		log.Printf("ccquota hub listening on %s (db %s)", a, dbFile)
		if *token != "" {
			// The token itself is deliberately NOT logged: hub.log is readable
			// by anyone on the machine and gets pasted into bug reports.
			log.Printf("  dashboard: http://%s/?token=<viewer token>", a)
		}
		go func() { errCh <- hs.Serve(ln) }()
	}

	if *httpsAddr != "" {
		// tlsBin and tlsName were resolved above, before the Server was built.
		tc := newTailscaleCert(tlsBin, tlsName, filepath.Join(filepath.Dir(dbFile), "tls"))
		if err := tc.refresh(); err != nil {
			return fmt.Errorf("--https-addr: obtain certificate: %w", err)
		}
		go tc.renewLoop(ctx, 12*time.Hour)

		rawLn, err := net.Listen("tcp", *httpsAddr)
		if err != nil {
			return fmt.Errorf("listen on %s: %w", *httpsAddr, err)
		}
		// Tailnet peers and loopback only, whatever the socket can hear.
		ln := net.Listener(tailnetOnly{rawLn})
		hs := &http.Server{
			Handler:           handler,
			ReadHeaderTimeout: 10 * time.Second,
			TLSConfig:         &tls.Config{GetCertificate: tc.get, MinVersion: tls.VersionTLS12},
		}
		servers = append(servers, hs)
		log.Printf("ccquota hub listening on %s (https, tailnet peers only) -> %s", *httpsAddr, httpsURL)
		go func() { errCh <- hs.ServeTLS(ln, "", "") }()
	}

	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		for _, hs := range servers {
			_ = hs.Shutdown(shutdownCtx)
		}
	}()

	// Any listener dying unexpectedly takes the hub down: a half-bound hub
	// that answers on one address and not another is worse than a dead one,
	// because the missing half looks like a network problem.
	for range servers {
		if err := <-errCh; err != nil && !errors.Is(err, http.ErrServerClosed) {
			return err
		}
	}
	return nil
}

// splitList parses a comma-separated flag value, ignoring blanks.
// fleetPersonScopes reads CCQUOTA_FLEET_PERSON_SCOPES: unset keeps the
// default grant (nil), set — even to nothing — is the whole list. A scope
// this build does not know is dropped and said so, never silently widened.
func fleetPersonScopes() []string {
	v, ok := os.LookupEnv("CCQUOTA_FLEET_PERSON_SCOPES")
	if !ok {
		return nil
	}
	out := []string{}
	for _, sc := range splitList(v) {
		known := false
		for _, k := range api.FleetScopes {
			known = known || k == sc
		}
		if !known {
			log.Printf("CCQUOTA_FLEET_PERSON_SCOPES: unknown scope %q ignored", sc)
			continue
		}
		out = append(out, sc)
	}
	return out
}

// githubAuthFromEnv wires the GitHub sign-in (claude-fleet#1984) from its
// three settings: CCQUOTA_GITHUB_CLIENT_ID and CCQUOTA_GITHUB_CLIENT_SECRET
// (the k8s Secret only — never a flag, which `ps` shows) and
// CCQUOTA_GITHUB_ADMINS (comma-separated usernames). Neither client value:
// off, nil. One without the other refuses to start — half a sign-in is a
// door the operator thinks is there.
func githubAuthFromEnv(getenv func(string) string) (*api.GitHubAuth, error) {
	id, secret := strings.TrimSpace(getenv("CCQUOTA_GITHUB_CLIENT_ID")), getenv("CCQUOTA_GITHUB_CLIENT_SECRET")
	admins := splitList(getenv("CCQUOTA_GITHUB_ADMINS"))
	if id == "" && secret == "" {
		if len(admins) > 0 {
			log.Printf("WARN github sign-in: CCQUOTA_GITHUB_ADMINS is set but the client is not — GitHub sign-in is off")
		}
		return nil, nil
	}
	if id == "" || secret == "" {
		return nil, errors.New("GitHub sign-in is half configured: " +
			"CCQUOTA_GITHUB_CLIENT_ID and CCQUOTA_GITHUB_CLIENT_SECRET are both required")
	}
	log.Printf("github sign-in: on, %d admin name(s) from CCQUOTA_GITHUB_ADMINS", len(admins))
	// CCQUOTA_GITHUB_API_BASE: GitHub's REST API (`fleet users add` looks a
	// username up there), for a hub on 127.0.0.1 that must not reach
	// api.github.com — the newcomer e2e (claude-fleet#2096). The authorize and
	// token endpoints never move, so no sign-in can be completed against it.
	return &api.GitHubAuth{ClientID: id, ClientSecret: secret, Admins: admins,
		APIBase: strings.TrimSpace(getenv("CCQUOTA_GITHUB_API_BASE"))}, nil
}

func splitList(s string) []string {
	var out []string
	for _, p := range strings.Split(s, ",") {
		if p = strings.TrimSpace(p); p != "" {
			out = append(out, p)
		}
	}
	return out
}

// checkExposure refuses the combination that quietly puts an unauthenticated
// dashboard on the internet.
//
// The hub holds several people's usage patterns and working-directory names.
// Making the operator say --insecure-public out loud is cheap; discovering the
// mistake from a search engine is not.
func checkExposure(addr, token string, noAuth, insecurePublic bool) error {
	if token == "" && !noAuth {
		return errors.New("no viewer token: pass --token, set CCQUOTA_VIEWER_TOKEN, " +
			"or pass --no-auth if this really should be open")
	}
	if token != "" {
		return nil
	}
	host, _, err := net.SplitHostPort(addr)
	if err != nil {
		return fmt.Errorf("parse --addr: %w", err)
	}
	if isLoopback(host) || insecurePublic {
		return nil
	}
	return fmt.Errorf("refusing to serve %s without a viewer token; "+
		"bind to loopback, pass --token, or acknowledge with --insecure-public", addr)
}

func isLoopback(host string) bool {
	if host == "localhost" || host == "" {
		return true
	}
	ip := net.ParseIP(strings.Trim(host, "[]"))
	return ip != nil && ip.IsLoopback()
}

// pruneLoop trims raw events past the retention window once a day. Rollups and
// limit snapshots are kept: they are small and are the long-term record.
func pruneLoop(ctx context.Context, st *store.Store, days int) {
	t := time.NewTicker(24 * time.Hour)
	defer t.Stop()
	for {
		cut := time.Now().AddDate(0, 0, -days)
		n, err := st.PruneEvents(cut)
		if err != nil {
			log.Printf("prune: %v", err)
		} else if n > 0 {
			log.Printf("pruned %d events older than %d days", n, days)
		}
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
	}
}

func runEnroll(args []string) error {
	fs := flag.NewFlagSet("enroll", flag.ExitOnError)
	dbPath := fs.String("db", "", "the hub's database (default: $CCQUOTA_DB, else ~/.ccquota/ccquota.db)")
	label := fs.String("name", "", "a human name for this endpoint, e.g. web-01")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *label == "" {
		return errors.New("--name is required")
	}
	// Refuses to create one: a token minted into a fresh database is printed
	// exactly like a real one and fails only later, on another machine.
	dbFile, err := resolveExistingDB(*dbPath)
	if err != nil {
		return err
	}
	st, err := store.Open(dbFile)
	if err != nil {
		return err
	}
	defer st.Close()

	tok, err := api.MintToken()
	if err != nil {
		return err
	}
	id := fmt.Sprintf("ep_%d", time.Now().UnixNano())
	if err := st.Enroll(id, *label, api.HashToken(tok)); err != nil {
		return err
	}

	fmt.Printf(`Enrolled %q as %s (in %s).

Run this on that endpoint (the token is shown once and is not recoverable):

  export CCQUOTA_HUB_URL=https://your-hub.example.com
  export CCQUOTA_TOKEN=%s
  ccquota agent

`, *label, id, dbFile, tok)
	return nil
}

func runAgent(args []string) error {
	fs := flag.NewFlagSet("agent", flag.ExitOnError)
	hub := fs.String("hub", os.Getenv("CCQUOTA_HUB_URL"), "hub base URL")
	token := secretEnvFlag(fs, "token", "CCQUOTA_TOKEN", "enrollment `token`")
	home := fs.String("home", "", "user home directory (default: your home)")
	sources := fs.String("sources", os.Getenv("CCQUOTA_SOURCES"), "usage sources: all (default), claude, codex, or claude,codex")
	codexHome := fs.String("codex-home", "", "Codex data directory (default: CODEX_HOME or <home>/.codex)")
	codexHomes := fs.String("codex-homes", os.Getenv("CCQUOTA_CODEX_HOMES"), "additional Codex data directories, comma-separated")
	codexBinary := fs.String("codex-bin", os.Getenv("CCQUOTA_CODEX_BINARY"), "Codex CLI executable for account queries and renewal")
	codexAutoRefresh := fs.Bool("codex-auto-refresh", true, "renew Codex ChatGPT file logins through the official CLI before expiry")
	state := fs.String("state", "", "state directory (default: <home>/.ccquota)")
	sessionsDir := fs.String("sessions-dir", "",
		"where `ccquota stamp` writes session stamps (default: <home>/.ccquota).\n"+
			"Must match the hook's --state; it is separate from this agent's own\n"+
			"state directory because the hook does not know which agent reads it")
	scanEvery := fs.Duration("scan-interval", agent.DefaultScanInterval, "how often to scan transcripts")
	limitsEvery := fs.Duration("limits-interval", agent.DefaultLimitsInterval, "how often to read account-wide limits")
	liveEvery := fs.Duration("live-interval", agent.DefaultLiveInterval, "how often to report running sessions")
	accountsDir := fs.String("accounts-dir", os.Getenv("CCQUOTA_ACCOUNTS_DIR"),
		"directory of `label -> OAuth token` files, one per subscription.\n"+
			"Lets this agent read the meter for subscriptions nothing else can see:\n"+
			"an idle account, or one whose local credentials have expired. Each\n"+
			"reading costs one minimal inference call against that subscription,\n"+
			"so it is opt-in and only runs when no cheaper source has reported")
	probeModels := fs.String("probe-model", os.Getenv("CCQUOTA_PROBE_MODELS"),
		"models to probe each --accounts-dir subscription with, comma-separated\n"+
			"(e.g. claude-fable-5-1). A per-model cap such as the weekly Fable limit\n"+
			"only shows up on a request for that model, so this is the only way to\n"+
			"read it. A capped account answers with a 429 and costs nothing; an\n"+
			"uncapped one costs one output token of that model")
	spoolMB := fs.Int64("spool-mb", 64, "cap on the on-disk queue, in MB")
	maxBackfill := fs.Duration("max-backfill", 0,
		"ignore turns older than this (e.g. 720h). Turns older than the account\n"+
			"itself are always ignored; this narrows the window further, because\n"+
			"attribution gets less trustworthy the further back a scan reaches")
	once := fs.Bool("once", false, "run a single cycle and exit (for cron)")
	install := fs.Bool("install", false, "print a service unit for this platform and exit")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *token == "" {
		// Separated (claude-fleet#1971): the root launcher hands the token
		// down a pipe, never the environment a session could `ps -E`.
		t, err := tokenFromFD(os.Getenv("CCQUOTA_TOKEN_FD"))
		if err != nil {
			return err
		}
		*token = t
	}

	h, err := homeDir(*home)
	if err != nil {
		return err
	}
	stateDir := *state
	if stateDir == "" {
		stateDir = filepath.Join(h, ".ccquota")
	}

	if *install {
		selected, err := scan.ParseSources(*sources)
		if err != nil {
			return err
		}
		return printServiceUnit(*hub, stateDir, strings.Join(selected, ","), scan.CodexHome(h, *codexHome), *codexHomes, *codexBinary, h, *codexAutoRefresh)
	}

	// This machine's advertised ways in (claude-fleet#1414).
	var nodeRoutes []control.NodeRoute
	if fleetEnabled() {
		r, perr := agent.ParseNodeRoutes(os.Getenv("CCQUOTA_FLEET_NODE_ROUTES"))
		if perr != nil {
			return perr
		}
		nodeRoutes = r
	}

	a, err := agent.New(agent.Config{
		HubURL:              strings.TrimRight(*hub, "/"),
		Token:               *token,
		Home:                h,
		Sources:             *sources,
		CodexHome:           *codexHome,
		CodexHomes:          *codexHomes,
		CodexBinary:         *codexBinary,
		CodexDisableRefresh: !*codexAutoRefresh,
		StateDir:            stateDir,
		SessionsDir:         *sessionsDir,
		ScanInterval:        *scanEvery,
		LimitsInterval:      *limitsEvery,
		LiveInterval:        *liveEvery,
		SpoolMaxBytes:       *spoolMB << 20,
		MaxBackfill:         *maxBackfill,
		Version:             Version,
		Once:                *once,
		AccountsDir:         *accountsDir,
		ProbeModels:         splitList(*probeModels),
		Fleet:               fleetEnabled(),
		// Only meaningful with the fleet module on: the admin agent is a
		// role on the control channel.
		FleetAdmin: fleetEnabled() && os.Getenv("CCQUOTA_FLEET_ADMIN") == "1",
		// Coordinate only (claude-fleet#1719): no placement, no lease. Only
		// an explicit 0 — a node joined before #1719 has no line and runs.
		FleetComputeOff: fleetEnabled() && os.Getenv("CCQUOTA_FLEET_COMPUTE") == "0",
		// Lease this login's credentials from the hub's vault (#1415).
		FleetCreds:         fleetEnabled() && os.Getenv("CCQUOTA_FLEET_CREDS") == "1",
		FleetCodexHomesDir: os.Getenv("CCQUOTA_FLEET_CODEX_HOMES"),
		// Separated (claude-fleet#1971): the lease goes to the proxy's socket.
		FleetCredStore: os.Getenv("CCQUOTA_FLEET_CRED_STORE"),
		// The relay rides the control channel, so it is on wherever that is
		// unless explicitly refused (claude-fleet#1413).
		FleetSSHRelay: fleetEnabled() && os.Getenv("CCQUOTA_FLEET_SSH_RELAY") != "0",
		// An admin agent carries the hub's token refreshes unless refused
		// (claude-fleet#1490); the endpoint overrides are for a fake provider.
		FleetOAuthRefresh: fleetEnabled() && os.Getenv("CCQUOTA_FLEET_OAUTH_REFRESH") != "0",
		OAuthTokenURLs: map[string]string{
			"claude": os.Getenv("CCQUOTA_FLEET_CLAUDE_TOKEN_URL"),
			"codex":  os.Getenv("CCQUOTA_FLEET_CODEX_TOKEN_URL"),
		},
		// Routes for `fleet connect` ride the heartbeat (#1414).
		FleetRoutes:       nodeRoutes,
		FleetTailnetRoute: fleetEnabled() && os.Getenv("CCQUOTA_FLEET_NODE_TAILNET") != "0",
		// A SPOT node (claude-fleet#1428): the join wrote
		// CCQUOTA_FLEET_NODE_KIND=ephemeral from the hub's answer. SIGTERM is
		// then the cloud taking the machine, not a restart.
		FleetEphemeral:      fleetEnabled() && os.Getenv("CCQUOTA_FLEET_NODE_KIND") == "ephemeral",
		FleetReclaimCmd:     os.Getenv("CCQUOTA_FLEET_RECLAIM_CMD"),
		FleetReclaimTimeout: reclaimTimeout,
		// The state nudge (claude-fleet#1481): the fleet's conf dir when
		// the environment names one, else the agent's default under home.
		FleetNudgePath: fleetNudgePath(),
		// node.env + node-probe.json, re-read every beat (claude-fleet#1720).
		FleetNodeEnvPath: fleetConfPath("node.env"),
		FleetProbePath:   fleetConfPath("node-probe.json"),
	})
	if err != nil {
		return err
	}

	if !*once {
		log.Printf("ccquota agent %s -> %s (scan every %s)", Version, *hub, scanEvery)
	}
	if a.Ephemeral() && !*once {
		// SIGTERM on a SPOT node is the kubelet's warning (the pod's
		// terminationGracePeriodSeconds): tell the hub, move idle sessions
		// off, THEN stop. A second signal stops at once.
		ctx, cancel := context.WithCancel(context.Background())
		defer cancel()
		sigs := make(chan os.Signal, 2)
		signal.Notify(sigs, os.Interrupt, syscall.SIGTERM)
		go func() {
			sig := <-sigs
			log.Printf("reclaim: %s — this is a SPOT node; telling the hub and moving idle sessions off (up to %s). A second signal stops at once", sig, reclaimTimeout)
			done := make(chan struct{})
			go func() { a.Reclaim(ctx); close(done) }()
			select {
			case <-done:
			case <-sigs:
				log.Printf("reclaim: second signal — stopping now")
			}
			cancel()
		}()
		return a.Run(ctx)
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	return a.Run(ctx)
}

// reclaimTimeout is how long a SPOT node's agent spends moving sessions off
// after SIGTERM: CCQUOTA_FLEET_RECLAIM_SECS, default 240 — inside the pod's
// default 300s grace, leaving the kubelet's SIGKILL a margin.
var reclaimTimeout = func() time.Duration {
	if v := os.Getenv("CCQUOTA_FLEET_RECLAIM_SECS"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			return time.Duration(n) * time.Second
		}
	}
	return 240 * time.Second
}()

// bindHosts is the list of hosts in a comma-separated --addr. The tailnet
// identity gate treats these as "self" and never trusts them: the hub's own
// tailnet address resolves to the machine's owner.
func bindHosts(addr string) []string {
	var hosts []string
	for _, a := range strings.Split(addr, ",") {
		host, _, err := net.SplitHostPort(strings.TrimSpace(a))
		if err != nil {
			continue
		}
		hosts = append(hosts, host)
	}
	return hosts
}

// sshRelayConfig reads the relay's knobs (claude-fleet#1413):
//
//	CCQUOTA_FLEET_SSH_CA_PUB      the SSH CA public key(s) whose user
//	                              certificates admit a person (a file of
//	                              authorized_keys lines); unset: sessions and
//	                              the viewer token only
//	CCQUOTA_FLEET_SSH_RELAY_MAX       concurrent relays per person (default 8)
//	CCQUOTA_FLEET_SSH_RELAY_RATE_BPS  bytes/second per person, both ways (default
//	                              4 MiB/s; -1 unlimited)
func sshRelayConfig(srv *api.Server) error {
	if path := os.Getenv("CCQUOTA_FLEET_SSH_CA_PUB"); path != "" {
		b, err := os.ReadFile(path)
		if err != nil {
			return fmt.Errorf("CCQUOTA_FLEET_SSH_CA_PUB: %w", err)
		}
		if srv.SSHRelayCA, err = api.ParseSSHRelayCA(b); err != nil {
			return fmt.Errorf("CCQUOTA_FLEET_SSH_CA_PUB: %w", err)
		}
	}
	for _, kv := range []struct {
		name string
		set  func(int64)
	}{
		{"CCQUOTA_FLEET_SSH_RELAY_MAX", func(n int64) { srv.SSHRelayMaxPerUser = int(n) }},
		{"CCQUOTA_FLEET_SSH_RELAY_RATE_BPS", func(n int64) { srv.SSHRelayRateBPS = n }},
	} {
		v := os.Getenv(kv.name)
		if v == "" {
			continue
		}
		n, err := strconv.ParseInt(v, 10, 64)
		if err != nil {
			return fmt.Errorf("%s: %w", kv.name, err)
		}
		kv.set(n)
	}
	log.Printf("fleet relay at %s (%d CA key(s) for certificates)", control.SSHRelayPath, len(srv.SSHRelayCA))
	return nil
}

// migrateOnlyRun is `ccquota hub --migrate-only`: Open runs every pending
// numbered migration in its own transaction, so a failing one returns here
// with the database as it was. A missing file is refused rather than created —
// a rehearsal on an empty database proves nothing.
// simulate is the drill: a migration that fails, after the real ones ran, the
// way a broken one would — the caller exits non-zero and the copy is thrown
// away.
func migrateOnlyRun(dbFile string, out io.Writer, simulate bool) error {
	if _, err := os.Stat(dbFile); err != nil && !store.UsesPostgres() {
		return fmt.Errorf("--migrate-only: %w", err)
	}
	st, err := store.Open(dbFile)
	if err != nil {
		return fmt.Errorf("--migrate-only %s: %w", dbFile, err)
	}
	defer st.Close()
	ms, err := st.Migrations()
	if err != nil {
		return err
	}
	for _, m := range ms {
		fmt.Fprintf(out, "migration %d %s applied %s %s\n", m.ID, m.Name, m.AppliedAt, m.Detail)
	}
	if simulate {
		return errors.New("--migrate-only: simulated migration failure (--simulate-migration-failure)")
	}
	fmt.Fprintf(out, "migrate-only: %s ok (%d migrations recorded)\n", dbFile, len(ms))
	return nil
}
