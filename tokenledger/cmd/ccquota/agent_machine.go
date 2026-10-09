package main

import (
	"bufio"
	"context"
	"errors"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"os/user"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"syscall"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/agent"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
)

// `ccquota agent --machine` (claude-fleet#2333, EPIC #2329 C5): ONE node
// program for the whole machine, run as root by the node supervisor. It opens
// one control connection with the machine's own node token and serves every
// login listed in the logins directory:
//
//	<logins dir>/<login>.env    root-owned, 0600 — the login's agent settings,
//	                            KEY=VALUE lines (the same CCQUOTA_* /
//	                            FLEET_CONF_DIR keys its own agent's service
//	                            set), CCQUOTA_TOKEN = the login's node token.
//
// The file is PARSED, never sourced: root reading what an installer wrote.
// A file another user can read or write is refused — it holds a token.

const (
	defaultMachineLogins = "/var/db/fleet-node/logins"
	defaultMachineState  = "/var/db/fleet-node/agent"
)

func runAgentMachine(args []string) error {
	fs := flag.NewFlagSet("agent --machine", flag.ExitOnError)
	_ = fs.Bool("machine", true, "serve every login of this machine over one connection")
	hub := fs.String("hub", os.Getenv("CCQUOTA_HUB_URL"), "hub base URL")
	token := secretEnvFlag(fs, "token", "CCQUOTA_TOKEN", "the machine's own node `token`")
	machineEnv := fs.String("machine-env", "", "root-only file with the machine's CCQUOTA_TOKEN (and CCQUOTA_HUB_URL);\n"+
		"how the node supervisor starts it, so the token is in neither argv nor the environment")
	logins := fs.String("logins", envOr("CCQUOTA_MACHINE_LOGINS", defaultMachineLogins), "directory of <login>.env files, one per login served")
	state := fs.String("state", envOr("CCQUOTA_MACHINE_STATE", defaultMachineState), "state directory; each login's under <state>/<login>")
	liveEvery := fs.Duration("live-interval", agent.DefaultLiveInterval, "how often to report running sessions")
	scanEvery := fs.Duration("scan-interval", agent.DefaultScanInterval, "how often to scan transcripts")
	limitsEvery := fs.Duration("limits-interval", agent.DefaultLimitsInterval, "how often to read account-wide limits")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *token == "" {
		t, err := tokenFromFD(os.Getenv("CCQUOTA_TOKEN_FD"))
		if err != nil {
			return err
		}
		*token = t
	}
	if *machineEnv != "" {
		env, err := readLoginEnv(*machineEnv, os.Geteuid() == 0)
		if err != nil {
			return err
		}
		if *token == "" {
			*token = env["CCQUOTA_TOKEN"]
		}
		if *hub == "" {
			*hub = env["CCQUOTA_HUB_URL"]
		}
	}
	tenants, err := machineTenants(*logins, *state, os.Geteuid() == 0)
	if err != nil {
		return err
	}
	for i := range tenants {
		tenants[i].LiveInterval = *liveEvery
		tenants[i].ScanInterval = *scanEvery
		tenants[i].LimitsInterval = *limitsEvery
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	return agent.RunMachine(ctx, agent.MachineConfig{
		HubURL: strings.TrimRight(*hub, "/"), Token: *token, Version: Version,
		LiveInterval: *liveEvery, Tenants: tenants,
		// The daemon's own state file sits beside the agent's state
		// directory (/var/db/fleet-node/{agent,state.json}) — claude-fleet#2526.
		ServicesFile: envOr("CCQUOTA_MACHINE_SERVICES", filepath.Join(filepath.Dir(filepath.Clean(*state)), "state.json")),
	})
}

// machineTenants reads the logins directory into one agent Config per login.
// strict (running as root) refuses a file anyone but root may read or write.
func machineTenants(dir, state string, strict bool) ([]agent.Config, error) {
	ents, err := os.ReadDir(dir)
	if err != nil {
		return nil, fmt.Errorf("logins directory: %w", err)
	}
	var names []string
	for _, e := range ents {
		if !e.IsDir() && strings.HasSuffix(e.Name(), ".env") {
			names = append(names, e.Name())
		}
	}
	sort.Strings(names)
	var out []agent.Config
	for _, n := range names {
		login := strings.TrimSuffix(n, ".env")
		if !control.ValidCreateLogin(login, true) {
			return nil, fmt.Errorf("%s: %q is not a login name", n, login)
		}
		path := filepath.Join(dir, n)
		env, err := readLoginEnv(path, strict)
		if err != nil {
			return nil, err
		}
		u, err := user.Lookup(login)
		if err != nil {
			return nil, fmt.Errorf("%s: %w", n, err)
		}
		ra, err := runAsFor(u)
		if err != nil {
			return nil, fmt.Errorf("%s: %w", n, err)
		}
		getenv := func(k string) string { return env[k] }
		var routes []control.NodeRoute
		if getenv("CCQUOTA_FLEET") == "1" {
			if routes, err = agent.ParseNodeRoutes(getenv("CCQUOTA_FLEET_NODE_ROUTES")); err != nil {
				return nil, fmt.Errorf("%s: %w", n, err)
			}
		}
		cfg := agentFleetConfig(getenv, routes)
		cfg.Token = getenv("CCQUOTA_TOKEN")
		if cfg.Token == "" {
			return nil, fmt.Errorf("%s: no CCQUOTA_TOKEN", n)
		}
		ra.ConfDir = getenv("FLEET_CONF_DIR")
		cfg.Home = ra.Home
		cfg.RunAs = ra
		cfg.Sources = getenv("CCQUOTA_SOURCES")
		cfg.CodexHomes = getenv("CCQUOTA_CODEX_HOMES")
		cfg.CodexBinary = getenv("CCQUOTA_CODEX_BINARY")
		cfg.AccountsDir = getenv("CCQUOTA_ACCOUNTS_DIR")
		cfg.ProbeModels = splitList(getenv("CCQUOTA_PROBE_MODELS"))
		cfg.StateDir = filepath.Join(state, login)
		cfg.SessionsDir = filepath.Join(ra.Home, ".ccquota")
		cfg.SpoolMaxBytes = 64 << 20
		out = append(out, cfg)
	}
	if len(out) == 0 {
		return nil, fmt.Errorf("logins directory %s lists no <login>.env", dir)
	}
	return out, nil
}

func runAsFor(u *user.User) (*agent.RunAs, error) {
	uid, err := strconv.ParseUint(u.Uid, 10, 32)
	if err != nil {
		return nil, fmt.Errorf("uid %q: %w", u.Uid, err)
	}
	gid, err := strconv.ParseUint(u.Gid, 10, 32)
	if err != nil {
		return nil, fmt.Errorf("gid %q: %w", u.Gid, err)
	}
	if uid == 0 {
		return nil, errors.New("refusing to serve root as a login")
	}
	ra := &agent.RunAs{Login: u.Username, UID: uint32(uid), GID: uint32(gid), Home: u.HomeDir}
	if gs, err := u.GroupIds(); err == nil {
		for _, g := range gs {
			if n, err := strconv.ParseUint(g, 10, 32); err == nil {
				ra.Groups = append(ra.Groups, uint32(n))
			}
		}
	}
	return ra, nil
}

// readLoginEnv parses KEY=VALUE lines (an optional `export `, one level of
// matching quotes, # comments). Nothing is expanded or run.
func readLoginEnv(path string, strict bool) (map[string]string, error) {
	fi, err := os.Lstat(path)
	if err != nil {
		return nil, err
	}
	if !fi.Mode().IsRegular() {
		return nil, fmt.Errorf("%s: not a regular file", path)
	}
	if strict {
		if fi.Mode().Perm()&0o077 != 0 {
			return nil, fmt.Errorf("%s: mode %o — it holds a token; only root may read it (chmod 600)", path, fi.Mode().Perm())
		}
		if uid, ok := fileUID(fi); ok && uid != 0 {
			return nil, fmt.Errorf("%s: owned by uid %d, not root", path, uid)
		}
	}
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	env := map[string]string{}
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		line = strings.TrimPrefix(line, "export ")
		k, v, ok := strings.Cut(line, "=")
		if !ok || k == "" {
			continue
		}
		v = strings.TrimSpace(v)
		if len(v) >= 2 && (v[0] == '"' || v[0] == '\'') && v[len(v)-1] == v[0] {
			v = v[1 : len(v)-1]
		}
		env[strings.TrimSpace(k)] = v
	}
	return env, sc.Err()
}

// machineFlag says the agent was started as the machine's node program.
func machineFlag(args []string) bool {
	for _, a := range args {
		switch a {
		case "--machine", "-machine", "--machine=true", "-machine=true":
			return true
		}
	}
	return false
}
