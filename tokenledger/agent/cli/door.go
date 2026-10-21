package cli

import (
	"bufio"
	"context"
	"crypto/tls"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/agent/door"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

// runDoor is `ccquota door` (A5SQ): the cluster door's own SSH server — one
// address for everyone, each person taken to their own home by their username
// and key (agent/door). The hub and the door's token come from machine.env
// (CCQUOTA_HUB_URL, CCQUOTA_TOKEN), never an argv.
func runDoor(args []string) error {
	fs := flag.NewFlagSet("door", flag.ContinueOnError)
	listen := fs.String("listen", ":22022", "address to listen on")
	hostKey := fs.String("host-key", "/run/fleet-door/host", "the door's host key (OpenSSH private key)")
	envFile := fs.String("env", "/var/db/fleet-node/machine.env", "machine.env: CCQUOTA_HUB_URL and CCQUOTA_TOKEN")
	auditFile := fs.String("audit", "", "append one JSON line per login here (default: the log)")
	ns := fs.String("namespace", envOr("FLEET_DOOR_NAMESPACE", "fleet-workers"), "the pods' namespace (the jump's tunnels)")
	relayListen := fs.String("relay-listen", os.Getenv("FLEET_DOOR_RELAY_LISTEN"), "where homes' agents dial back (e.g. :22443); \"\" = every stream home goes through the hub")
	relayURL := fs.String("relay-url", os.Getenv("FLEET_DOOR_RELAY_URL"), "the relay listener as a home dials it (ws://<this door's address>:22443/relay)")
	// XX79: browser terminals through this door (TLS: a page on https)
	browserListen := fs.String("browser-listen", os.Getenv("FLEET_DOOR_BROWSER_LISTEN"), "where browsers and homes join a terminal's pipe (e.g. :443); \"\" = off")
	browserCert := fs.String("browser-cert", os.Getenv("FLEET_DOOR_BROWSER_CERT"), "the browser listener's certificate chain (PEM; re-read when it changes)")
	browserKey := secretEnvFlag(fs, "browser-key", "FLEET_DOOR_BROWSER_KEY", "the browser listener's private key `file` (PEM)")
	browserOrigin := fs.String("browser-origin", os.Getenv("FLEET_DOOR_BROWSER_ORIGIN"), "the pages a browser half may come from (comma-separated https://host)")
	doorID := fs.String("door-id", os.Getenv("FLEET_DOOR_ID"), "this door's name in the hub's fleet.term_doors (us)")
	if err := fs.Parse(args); err != nil {
		return err
	}
	env, err := readEnvFile(*envFile)
	if err != nil {
		return err
	}
	hub, tok := env["CCQUOTA_HUB_URL"], env["CCQUOTA_TOKEN"]
	if hub == "" || tok == "" {
		return fmt.Errorf("%s names no CCQUOTA_HUB_URL or no CCQUOTA_TOKEN", *envFile)
	}
	pem, err := os.ReadFile(*hostKey)
	if err != nil {
		return err
	}
	hk, err := door.ParseHostKey(pem)
	if err != nil {
		return fmt.Errorf("%s: %w", *hostKey, err)
	}
	var audit io.Writer
	if *auditFile != "" {
		f, err := os.OpenFile(*auditFile, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o640)
		if err != nil {
			return err
		}
		defer f.Close()
		audit = f
	}
	if (*relayListen == "") != (*relayURL == "") {
		return errors.New("--relay-listen and --relay-url go together")
	}
	d, err := door.New(door.Config{Hub: hub, Token: tok, HostKey: hk, Audit: audit, Namespace: *ns, RelayURL: *relayURL})
	if err != nil {
		return err
	}
	ln, err := net.Listen("tcp", *listen)
	if err != nil {
		return err
	}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()
	fmt.Fprintf(os.Stderr, "ccquota door: %s on %s (host key %s)\n", hub, ln.Addr(), door.PublicKeyLine(hk))
	// the browser listener may share the relay's port (a door whose firewall
	// opens only that one): one socket, split by the first byte (XX79)
	var rl, bl net.Listener
	if *browserListen != "" && *browserListen == *relayListen {
		shared, err := net.Listen("tcp", *relayListen)
		if err != nil {
			return err
		}
		bl, rl = door.SplitTLS(shared, 10*time.Second)
	}
	if *relayListen != "" {
		// homes' dial-back (CapRelayVia): the bytes of a session reach the
		// home from here, not through the hub's region
		if rl == nil {
			if rl, err = net.Listen("tcp", *relayListen); err != nil {
				return err
			}
		}
		hs := &http.Server{Handler: d.RelayHandler(), ReadHeaderTimeout: 10 * time.Second}
		go func() { <-ctx.Done(); hs.Close() }()
		go func() {
			if err := hs.Serve(rl); err != nil && !errors.Is(err, http.ErrServerClosed) {
				fmt.Fprintf(os.Stderr, "ccquota door: relay listener: %v\n", err)
			}
		}()
		fmt.Fprintf(os.Stderr, "ccquota door: homes dial back at %s (%s)\n", *relayURL, rl.Addr())
	}
	if *browserListen != "" {
		if *browserCert == "" || *browserKey == "" || *doorID == "" {
			return errors.New("--browser-listen needs --browser-cert, --browser-key and --door-id")
		}
		var origins []string
		for _, o := range strings.Split(*browserOrigin, ",") {
			if o = strings.TrimSpace(o); o != "" {
				origins = append(origins, o)
			}
		}
		pipes, err := door.NewPipes(door.PipeConfig{ID: *doorID, Key: control.ChatTokenHash(tok), Origins: origins}, d.PipeAudit)
		if err != nil {
			return err
		}
		certs := &reloadingCert{cert: *browserCert, key: *browserKey}
		if _, err := certs.get(nil); err != nil {
			return fmt.Errorf("the browser listener's certificate: %w", err)
		}
		if bl == nil {
			if bl, err = net.Listen("tcp", *browserListen); err != nil {
				return err
			}
		}
		hs := &http.Server{Handler: pipes.Handler(), ReadHeaderTimeout: 10 * time.Second,
			TLSConfig: &tls.Config{MinVersion: tls.VersionTLS12, GetCertificate: certs.get}}
		go func() { <-ctx.Done(); hs.Close() }()
		go func() {
			if err := hs.ServeTLS(bl, "", ""); err != nil && !errors.Is(err, http.ErrServerClosed) {
				fmt.Fprintf(os.Stderr, "ccquota door: browser listener: %v\n", err)
			}
		}()
		fmt.Fprintf(os.Stderr, "ccquota door: browser terminals join at %s as door %q\n", bl.Addr(), *doorID)
	}
	return d.Serve(ctx, ln)
}

// reloadingCert reads the certificate again when its file changes: a renewal
// (certbot / lego writing the same paths) is taken without a restart.
type reloadingCert struct {
	cert, key string
	mu        sync.Mutex
	mod       time.Time
	cur       *tls.Certificate
}

func (c *reloadingCert) get(*tls.ClientHelloInfo) (*tls.Certificate, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	st, err := os.Stat(c.cert)
	if err != nil {
		if c.cur != nil {
			return c.cur, nil
		}
		return nil, err
	}
	if c.cur == nil || !st.ModTime().Equal(c.mod) {
		kp, err := tls.LoadX509KeyPair(c.cert, c.key)
		if err != nil {
			if c.cur != nil {
				return c.cur, nil // half-written renewal: keep the last good one
			}
			return nil, err
		}
		c.cur, c.mod = &kp, st.ModTime()
	}
	return c.cur, nil
}

// readEnvFile reads KEY=VALUE lines (quotes trimmed, comments skipped).
func readEnvFile(path string) (map[string]string, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	out := map[string]string{}
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		l := strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(sc.Text()), "export "))
		if l == "" || strings.HasPrefix(l, "#") {
			continue
		}
		k, v, ok := strings.Cut(l, "=")
		if !ok {
			continue
		}
		out[strings.TrimSpace(k)] = strings.Trim(strings.TrimSpace(v), `"'`)
	}
	if err := sc.Err(); err != nil {
		return nil, err
	}
	if len(out) == 0 {
		return nil, errors.New(path + ": no KEY=VALUE lines")
	}
	return out, nil
}
