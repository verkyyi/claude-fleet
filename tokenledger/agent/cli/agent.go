package cli

import (
	"context"
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"

	"github.com/verkyyi/claude-fleet/tokenledger/agent"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/nodesig"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/scan"
)

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
	// This login's signing key (claude-fleet#3710): beside node.env, made and
	// registered at start. A separated login's token comes down a pipe and its
	// key is the launcher's to name (CCQUOTA_NODE_KEY), never one in the home.
	keyFile := nodesig.LoginKeyPath()
	if *token == "" {
		// Separated (claude-fleet#1971): the root launcher hands the token
		// down a pipe, never the environment a session could `ps -E`.
		t, err := tokenFromFD(os.Getenv("CCQUOTA_TOKEN_FD"))
		if err != nil {
			return err
		}
		*token = t
		if t != "" && os.Getenv("CCQUOTA_NODE_KEY") == "" {
			keyFile = ""
		}
	}
	if *token == "" {
		// The admin seat's agent (claude-fleet#3724): root's file, read by
		// the role account's group only.
		t, err := tokenFromFile(os.Getenv("CCQUOTA_TOKEN_FILE"))
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

	cfg := agentFleetConfig(os.Getenv, nodeRoutes)
	cfg.HubURL = strings.TrimRight(*hub, "/")
	cfg.Token = *token
	if !*once {
		cfg.KeyFile = keyFile
	}
	cfg.Home = h
	cfg.Sources = *sources
	cfg.CodexHome = *codexHome
	cfg.CodexHomes = *codexHomes
	cfg.CodexBinary = *codexBinary
	cfg.CodexDisableRefresh = !*codexAutoRefresh
	cfg.StateDir = stateDir
	cfg.SessionsDir = *sessionsDir
	cfg.ScanInterval = *scanEvery
	cfg.LimitsInterval = *limitsEvery
	cfg.LiveInterval = *liveEvery
	cfg.SpoolMaxBytes = *spoolMB << 20
	cfg.MaxBackfill = *maxBackfill
	cfg.Version = Version
	cfg.Once = *once
	cfg.AccountsDir = *accountsDir
	cfg.ProbeModels = splitList(*probeModels)
	// This machine's own CPU-busy ceiling for new sessions (claude-fleet#2882);
	// a managed machine's comes from machine.env through the machine agent.
	agent.SetMaxCPUBusy(os.Getenv("FLEET_MAX_CPU_BUSY"))
	a, err := agent.New(cfg)
	if err != nil {
		return err
	}

	if !*once {
		log.Printf("ccquota agent %s -> %s (scan every %s)", Version, *hub, scanEvery)
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	err = a.Run(ctx)
	if to := a.HubMoved(); to != "" && err == nil {
		// The hub moved (task PNWW): this login's configuration names the new
		// address; the service that keeps this agent up starts it there.
		log.Printf("ccquota agent: the hub moved to %s — exiting so this agent starts again on the rewritten configuration", to)
	}
	return err
}

// agentFleetConfig is the part of an agent's Config its environment sets — the
// fleet module's switches. One copy for both a plain agent (os.Getenv) and each
// login of `ccquota agent --machine` (that login's env file,
// claude-fleet#2333).
func agentFleetConfig(getenv func(string) string, nodeRoutes []control.NodeRoute) agent.Config {
	fleet := getenv("CCQUOTA_FLEET") == "1"
	confPath := func(name string) string {
		if d := getenv("FLEET_CONF_DIR"); d != "" {
			return filepath.Join(d, filepath.FromSlash(name))
		}
		return ""
	}
	return agent.Config{
		Fleet: fleet,
		// Only meaningful with the fleet module on: the admin agent is a
		// role on the control channel.
		FleetAdmin: fleet && getenv("CCQUOTA_FLEET_ADMIN") == "1",
		// The admin role account's agent (claude-fleet#3696): ops only with
		// the hub's ticket, run through the root gate's sudo.
		FleetAdminSeat: fleet && getenv("CCQUOTA_FLEET_ADMIN") == "1" && getenv("CCQUOTA_FLEET_ADMIN_SEAT") == "1",
		AdminGateDir:   getenv("CCQUOTA_FLEET_ADMIN_GATE_DIR"),
		// Coordinate only (claude-fleet#1719): no placement, no lease. Only
		// an explicit 0 — a node joined before #1719 has no line and runs.
		FleetComputeOff: fleet && getenv("CCQUOTA_FLEET_COMPUTE") == "0",
		// Lease this login's credentials from the hub's vault (#1415).
		FleetCreds:         fleet && getenv("CCQUOTA_FLEET_CREDS") == "1",
		FleetCodexHomesDir: getenv("CCQUOTA_FLEET_CODEX_HOMES"),
		// Separated (claude-fleet#1971): the lease goes to the proxy's socket.
		FleetCredStore: getenv("CCQUOTA_FLEET_CRED_STORE"),
		// The relay rides the control channel, so it is on wherever that is
		// unless explicitly refused (claude-fleet#1413).
		FleetSSHRelay: fleet && getenv("CCQUOTA_FLEET_SSH_RELAY") != "0",
		// The chat relay likewise (claude-fleet#3644).
		FleetChat: fleet && getenv("CCQUOTA_FLEET_CHAT") != "0",
		// The terminal relay likewise (claude-fleet#3838).
		FleetTerm: fleet && getenv("CCQUOTA_FLEET_TERM") != "0",
		// A service login (claude-fleet#4086): service run attempts, as it.
		FleetSvc: fleet && getenv("CCQUOTA_FLEET_SVC") == "1",
		// fleet-ops: the cluster's provisioner it hands tickets to (claude-fleet#3553).
		FleetClusterOps: func() string {
			if fleet {
				return getenv("CCQUOTA_FLEET_PROVISIONER")
			}
			return ""
		}(),
		// …and reads a throwaway Job back for the hub (claude-fleet#3552).
		FleetKubeAPI:   getenv("CCQUOTA_FLEET_KUBE_API"),
		FleetKubeSADir: getenv("CCQUOTA_FLEET_KUBE_SA_DIR"),
		// A user pod's login writes its pod's reading here (claude-fleet#3734).
		FleetConfDir: getenv("FLEET_CONF_DIR"),
		// An admin agent carries the hub's token refreshes unless refused
		// (claude-fleet#1490); the endpoint overrides are for a fake provider.
		FleetOAuthRefresh: fleet && getenv("CCQUOTA_FLEET_OAUTH_REFRESH") != "0",
		OAuthTokenURLs: map[string]string{
			"claude": getenv("CCQUOTA_FLEET_CLAUDE_TOKEN_URL"),
			"codex":  getenv("CCQUOTA_FLEET_CODEX_TOKEN_URL"),
		},
		// Routes for `fleet connect` ride the heartbeat (#1414).
		FleetRoutes:       nodeRoutes,
		FleetTailnetRoute: fleet && getenv("CCQUOTA_FLEET_NODE_TAILNET") != "0",
		FleetLANRoute:     fleet && getenv("CCQUOTA_FLEET_NODE_LAN") != "0",
		// The state nudge (claude-fleet#1481): the fleet's conf dir when
		// the environment names one, else the agent's default under home.
		FleetNudgePath: confPath("global/hub-nudge"),
		// node.env + node-probe.json, re-read every beat (claude-fleet#1720).
		FleetNodeEnvPath: confPath("node.env"),
		FleetProbePath:   confPath("node-probe.json"),
	}
}

// envOr lets an environment variable override a compiled-in default while an
// unset variable still leaves the default in place -- unlike os.Getenv alone,
// which turns "not configured" into "configured as empty".
func envOr(key, def string) string {
	if v, ok := os.LookupEnv(key); ok {
		return v
	}
	return def
}

func fleetEnabled() bool {
	return os.Getenv("CCQUOTA_FLEET") == "1"
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
