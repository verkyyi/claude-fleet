package credproxy

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"
)

// Main is `ccquota credproxy` — the cluster credential proxy
// (claude-fleet#1973, EPIC #1967 C6). Same image as the hub, its own
// Deployment (deploy/k8s/credproxy): stateless, so any number of replicas.
// Both builds run it — the hub image's (the Deployment's command) and the
// node's (agent/cli) — so it lives here, beside the proxy (claude-fleet#4814).
//
// Settings come from flags or the environment (flags win):
//
//	--listen     CCQUOTA_CREDPROXY_LISTEN     default 127.0.0.1:8788
//	--hub        CCQUOTA_CREDPROXY_HUB_URL    the hub (in the cluster: its Service)
//	(token)      CCQUOTA_FLEET_CREDPROXY_TOKEN[_FILE] — never a flag (argv is public)
//	--relay      CCQUOTA_CREDPROXY_RELAY_URL  the Singapore relay (C7)
//	--direct     CCQUOTA_CREDPROXY_DIRECT=1   no relay: straight to the providers
//	--anthropic  CCQUOTA_CREDPROXY_ANTHROPIC_URL (with --direct)
//	--codex      CCQUOTA_CREDPROXY_CODEX_URL     (with --direct)
//	--cache      CCQUOTA_CREDPROXY_CACHE      one hub answer's life (≤ 30s)
//	--stale      CCQUOTA_CREDPROXY_STALE      how long to ride out a hub that cannot answer
//	--session-pub CCQUOTA_CREDPROXY_SESSION_PUB fcp-h2's key (base64; default: the hub's answer)
//	--bedrock    CCQUOTA_CREDPROXY_BEDROCK_URL the Bedrock fallback's endpoint (default: the key's
//	             region, bedrock-runtime.<region>.amazonaws.com; whether it is used is the hub's
//	             fleet.fallback.bedrock, off by default — task PNWW)
func Main(version string, args []string) error {
	fs := flag.NewFlagSet("credproxy", flag.ExitOnError)
	env := func(k, d string) string {
		if v := strings.TrimSpace(os.Getenv(k)); v != "" {
			return v
		}
		return d
	}
	envDur := func(k string, d time.Duration) time.Duration {
		if v := os.Getenv(k); v != "" {
			if x, err := time.ParseDuration(v); err == nil {
				return x
			}
		}
		return d
	}
	listen := fs.String("listen", env("CCQUOTA_CREDPROXY_LISTEN", "127.0.0.1:8788"), "address to serve on")
	hub := fs.String("hub", env("CCQUOTA_CREDPROXY_HUB_URL", ""), "the hub's URL")
	relay := fs.String("relay", env("CCQUOTA_CREDPROXY_RELAY_URL", ""), "the Singapore relay's URL")
	direct := fs.Bool("direct", env("CCQUOTA_CREDPROXY_DIRECT", "") == "1", "send straight to the providers, not through the relay")
	anth := fs.String("anthropic", env("CCQUOTA_CREDPROXY_ANTHROPIC_URL", ""), "Anthropic's API (with --direct)")
	codex := fs.String("codex", env("CCQUOTA_CREDPROXY_CODEX_URL", ""), "Codex's API (with --direct)")
	cache := fs.Duration("cache", envDur("CCQUOTA_CREDPROXY_CACHE", MaxCacheTTL), "how long one hub answer is used (≤ 30s)")
	stale := fs.Duration("stale", envDur("CCQUOTA_CREDPROXY_STALE", 15*time.Minute), "how long an answer outlives --cache while the hub cannot answer")
	spub := fs.String("session-pub", env("CCQUOTA_CREDPROXY_SESSION_PUB", ""), "the key fcp-h2 passes are verified with (base64; default: learned from the hub)")
	bedrock := fs.String("bedrock", env("CCQUOTA_CREDPROXY_BEDROCK_URL", ""), "the Bedrock fallback's endpoint (default: by the key's region)")
	_ = fs.Parse(args)
	pub, err := ParseSessionPub(*spub)
	if err != nil {
		return fmt.Errorf("credproxy: --session-pub: %w", err)
	}

	tok, err := envOrFile("CCQUOTA_FLEET_CREDPROXY_TOKEN")
	if err != nil {
		return err
	}
	if *hub == "" || tok == "" {
		return errors.New("credproxy: needs the hub (--hub / CCQUOTA_CREDPROXY_HUB_URL) and CCQUOTA_FLEET_CREDPROXY_TOKEN[_FILE]")
	}
	if *cache > MaxCacheTTL {
		return fmt.Errorf("credproxy: --cache %s is longer than %s", *cache, MaxCacheTTL)
	}
	p, err := New(Config{
		Resolver:     &HubResolver{URL: *hub, Token: tok},
		RelayURL:     *relay,
		Direct:       *direct,
		AnthropicURL: *anth,
		CodexURL:     *codex,
		CacheTTL:     *cache,
		StaleFor:     *stale,
		Audit:        func(l string) { fmt.Fprintln(os.Stdout, l) },
		SessionPub:   pub,
		BedrockURL:   *bedrock,
	})
	if err != nil {
		return err
	}
	road := "relay " + *relay
	if *direct {
		road = "DIRECT (no relay)"
	}
	srv := &http.Server{Addr: *listen, Handler: p.Handler(), ReadHeaderTimeout: 30 * time.Second}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	errc := make(chan error, 1)
	go func() { errc <- srv.ListenAndServe() }()
	log.Printf("credproxy %s: serving %s · hub %s · %s · cache %s · stale %s", version, *listen, *hub, road, *cache, *stale)
	select {
	case err := <-errc:
		return err
	case <-ctx.Done():
	}
	// A rollout: stop taking new requests, let the streams in flight finish
	// (the Deployment's grace period is longer than this).
	sctx, cancel := context.WithTimeout(context.Background(), 110*time.Second)
	defer cancel()
	return srv.Shutdown(sctx)
}

// envOrFile reads a secret from $name, or the file $name_FILE names (which wins).
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
