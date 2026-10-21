package cli

import (
	"bufio"
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"os"
	"os/signal"
	"strings"
	"syscall"

	"github.com/verkyyi/claude-fleet/tokenledger/agent/door"
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
	d, err := door.New(door.Config{Hub: hub, Token: tok, HostKey: hk, Audit: audit, Namespace: *ns})
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
	return d.Serve(ctx, ln)
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
