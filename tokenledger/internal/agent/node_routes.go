package agent

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
)

// The heartbeat's routes (claude-fleet#1414): how people reach this machine's
// sshd from outside. The hub merges them into what `fleet connect` is handed,
// so a client never hard-codes an address — a machine that moves to a new
// port or tailnet name says so on its next beat.
//
// Two sources: CCQUOTA_FLEET_NODE_ROUTES, written by the operator (a public
// port lives on the gateway, which this machine cannot see), and the local
// tailscaled's own name for the machine, asked for here.

// ParseNodeRoutes reads CCQUOTA_FLEET_NODE_ROUTES:
// "name=host[:port],name=host[:port]", e.g.
// "public=gw.example.com:22023,lan=192.168.1.20". Names and hosts are
// plain tokens (letters, digits, . - _) — the hub writes them into ssh
// configs.
func ParseNodeRoutes(s string) ([]control.NodeRoute, error) {
	var out []control.NodeRoute
	for _, part := range strings.Split(s, ",") {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		name, addr, ok := strings.Cut(part, "=")
		if !ok {
			return nil, fmt.Errorf("CCQUOTA_FLEET_NODE_ROUTES: %q is not name=host[:port]", part)
		}
		r := control.NodeRoute{Name: strings.TrimSpace(name), Host: strings.TrimSpace(addr)}
		if h, p, ok := strings.Cut(r.Host, ":"); ok {
			n, err := strconv.Atoi(p)
			if err != nil || n <= 0 || n > 65535 {
				return nil, fmt.Errorf("CCQUOTA_FLEET_NODE_ROUTES: bad port in %q", part)
			}
			r.Host, r.Port = h, n
		}
		if !routeToken(r.Name) || !routeToken(r.Host) {
			return nil, fmt.Errorf("CCQUOTA_FLEET_NODE_ROUTES: bad route %q", part)
		}
		out = append(out, r)
	}
	return out, nil
}

// routeToken: letters, digits and . - _ only, not leading with "-".
func routeToken(s string) bool {
	if s == "" || len(s) > 253 || s[0] == '-' {
		return false
	}
	for _, c := range s {
		switch {
		case c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z', c >= '0' && c <= '9':
		case c == '.' || c == '-' || c == '_':
		default:
			return false
		}
	}
	return true
}

// tailnetRefresh is how long a tailnet-name reading is reused. The name
// changes only when the operator renames the machine; an hour-old one is fine.
const tailnetRefresh = time.Hour

// tailnetName caches the local tailscaled's DNS name for this machine.
type tailnetName struct {
	mu   sync.Mutex
	name string
	at   time.Time
}

// tailnetSelfName is the injection point for tests: this machine's tailnet
// DNS name ("m4.tail1234.ts.net"), "" when there is no tailscale.
var tailnetSelfName = func(ctx context.Context) string {
	bin, err := exec.LookPath("tailscale")
	if err != nil {
		// The macOS app ships its CLI inside the bundle, off PATH.
		bin = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
		if _, err := os.Stat(bin); err != nil {
			return ""
		}
	}
	ctx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	tcmd := exec.CommandContext(ctx, bin, "status", "--json", "--peers=false")
	if prepCmd(ctx, tcmd) != nil {
		return ""
	}
	out, err := tcmd.Output()
	if err != nil {
		return ""
	}
	var st struct {
		BackendState string
		Self         struct{ DNSName string }
	}
	if json.Unmarshal(out, &st) != nil || st.BackendState != "Running" {
		return ""
	}
	return strings.TrimSuffix(st.Self.DNSName, ".")
}

func (t *tailnetName) get(ctx context.Context, now time.Time) string {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.at.IsZero() || now.Sub(t.at) >= tailnetRefresh {
		t.name, t.at = tailnetSelfName(ctx), now
	}
	return t.name
}

// nodeRoutes is the heartbeat's Routes: the configured ones, plus the
// tailnet name when no configured route is called "tailnet".
func (a *Agent) nodeRoutes(ctx context.Context) []control.NodeRoute {
	out := append([]control.NodeRoute(nil), a.cfg.FleetRoutes...)
	if !a.cfg.FleetTailnetRoute {
		return out
	}
	for _, r := range out {
		if r.Name == "tailnet" {
			return out
		}
	}
	if name := a.tailnet.get(ctx, time.Now()); routeToken(name) {
		out = append(out, control.NodeRoute{Name: "tailnet", Host: name})
	}
	return out
}
