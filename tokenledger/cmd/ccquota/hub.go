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
	addr := fs.String("addr", "127.0.0.1:8787", "listen address")
	dbPath := fs.String("db", "ccquota.db", "path to the SQLite database")
	token := fs.String("token", os.Getenv("CCQUOTA_VIEWER_TOKEN"), "viewer token for the dashboard, API and MCP")
	noAuth := fs.Bool("no-auth", false, "serve without a viewer token (loopback binds only)")
	insecurePublic := fs.Bool("insecure-public", false, "acknowledge binding to a public address without TLS in front")
	pricingFile := fs.String("pricing", "", "path to a pricing override file")
	pollInterval := fs.Int("limits-poll-interval", 120, "seconds between agents' limit polls")
	retentionDays := fs.Int("retention-days", 90, "days of raw events to keep (0 disables pruning)")
	if err := fs.Parse(args); err != nil {
		return err
	}

	if err := checkExposure(*addr, *token, *noAuth, *insecurePublic); err != nil {
		return err
	}

	st, err := store.Open(*dbPath)
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

	httpSrv := &http.Server{
		Addr:              *addr,
		Handler:           srv.Handler(),
		ReadHeaderTimeout: 10 * time.Second,
	}

	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		_ = httpSrv.Shutdown(shutdownCtx)
	}()

	log.Printf("ccquota hub listening on %s (db %s)", *addr, *dbPath)
	if *token != "" {
		log.Printf("dashboard: http://%s/?token=%s", *addr, *token)
	}
	if err := httpSrv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		return err
	}
	return nil
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
	dbPath := fs.String("db", "ccquota.db", "path to the SQLite database")
	label := fs.String("name", "", "a human name for this endpoint, e.g. web-01")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *label == "" {
		return errors.New("--name is required")
	}

	st, err := store.Open(*dbPath)
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

	fmt.Printf(`Enrolled %q as %s.

Run this on that endpoint (the token is shown once and is not recoverable):

  export CCQUOTA_HUB_URL=https://your-hub.example.com
  export CCQUOTA_TOKEN=%s
  ccquota agent

`, *label, id, tok)
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
