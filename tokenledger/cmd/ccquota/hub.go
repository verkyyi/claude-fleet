package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/verkyyi/ccquota/internal/agent"
	"github.com/verkyyi/ccquota/internal/api"
	"github.com/verkyyi/ccquota/internal/mcp"
	"github.com/verkyyi/ccquota/internal/pricing"
	"github.com/verkyyi/ccquota/internal/store"
	"github.com/verkyyi/ccquota/web"
)

func runHub(args []string) error {
	fs := flag.NewFlagSet("hub", flag.ExitOnError)
	addr := fs.String("addr", "127.0.0.1:8787",
		"listen address(es), comma-separated. Binding a tailnet address alone\n"+
			"means localhost does not work from the machine itself, which is\n"+
			"where you usually are: `127.0.0.1:8787,100.x.y.z:8787` gives both")
	dbPath := fs.String("db", "", "path to the SQLite database (default: $CCQUOTA_DB, else ~/.ccquota/ccquota.db)")
	token := fs.String("token", os.Getenv("CCQUOTA_VIEWER_TOKEN"), "viewer token for the dashboard, API and MCP")
	noAuth := fs.Bool("no-auth", false, "serve without a viewer token (loopback binds only)")
	insecurePublic := fs.Bool("insecure-public", false, "acknowledge binding to a public address without TLS in front")
	pricingFile := fs.String("pricing", "", "path to a pricing override file")
	pollInterval := fs.Int("limits-poll-interval", 120, "seconds between agents' limit polls")
	retentionDays := fs.Int("retention-days", 90, "days of raw events to keep (0 disables pruning)")
	if err := fs.Parse(args); err != nil {
		return err
	}

	dbFile, err := resolveDB(*dbPath)
	if err != nil {
		return err
	}
	// The hub is the one command allowed to bring a database into being, so
	// say when it does. A hub silently starting on an empty database looks
	// exactly like a hub that has lost everything.
	if _, statErr := os.Stat(dbFile); errors.Is(statErr, os.ErrNotExist) {
		if err := os.MkdirAll(filepath.Dir(dbFile), 0o700); err != nil {
			return fmt.Errorf("create %s: %w", filepath.Dir(dbFile), err)
		}
		log.Printf("no database at %s yet; creating an empty one", dbFile)
	}

	addrs := splitAddrs(*addr)
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

	table := pricing.Default()
	if *pricingFile != "" {
		if err := table.LoadOverrides(*pricingFile); err != nil {
			return err
		}
	}

	srv := &api.Server{
		Store:               st,
		Pricing:             table,
		ViewerToken:         *token,
		LimitsPollIntervalS: *pollInterval,
		UI:                  web.Assets(),
		LiveStore:           api.NewLive(),
	}
	srv.MCP = mcp.Handler(srv)

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	if *retentionDays > 0 {
		go pruneLoop(ctx, st, *retentionDays)
	}

	handler := srv.Handler()
	servers := make([]*http.Server, 0, len(addrs))
	errCh := make(chan error, len(addrs))

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
			log.Printf("  dashboard: http://%s/?token=%s", a, *token)
		}
		go func() { errCh <- hs.Serve(ln) }()
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

// splitAddrs parses a comma-separated listen list, ignoring blanks.
func splitAddrs(s string) []string {
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
		n, err := st.PruneEvents(time.Now().AddDate(0, 0, -days))
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
	token := fs.String("token", os.Getenv("CCQUOTA_TOKEN"), "enrollment token")
	home := fs.String("home", "", "Claude Code home directory (default: your home)")
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

	h, err := homeDir(*home)
	if err != nil {
		return err
	}
	stateDir := *state
	if stateDir == "" {
		stateDir = filepath.Join(h, ".ccquota")
	}

	if *install {
		return printServiceUnit(*hub, stateDir)
	}

	a, err := agent.New(agent.Config{
		HubURL:         strings.TrimRight(*hub, "/"),
		Token:          *token,
		Home:           h,
		StateDir:       stateDir,
		SessionsDir:    *sessionsDir,
		ScanInterval:   *scanEvery,
		LimitsInterval: *limitsEvery,
		LiveInterval:   *liveEvery,
		SpoolMaxBytes:  *spoolMB << 20,
		MaxBackfill:    *maxBackfill,
		Version:        Version,
		Once:           *once,
		AccountsDir:    *accountsDir,
	})
	if err != nil {
		return err
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	if !*once {
		log.Printf("ccquota agent %s -> %s (scan every %s)", Version, *hub, scanEvery)
	}
	return a.Run(ctx)
}
