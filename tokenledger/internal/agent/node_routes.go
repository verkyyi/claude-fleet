package agent

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/netip"
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

// lanRoutesMax caps how many "lan" routes one machine reports: a client
// tests only the ones on its own network, but each still rides every beat.
const lanRoutesMax = 4

// localPrefixes is the injection point for tests: this machine's interface
// addresses with their prefix lengths, interfaces down / loopback / virtual
// left out.
var localPrefixes = func() []netip.Prefix {
	ifs, err := net.Interfaces()
	if err != nil {
		return nil
	}
	var out []netip.Prefix
	for _, ifc := range ifs {
		if ifc.Flags&net.FlagUp == 0 || ifc.Flags&net.FlagLoopback != 0 || ifc.Flags&net.FlagPointToPoint != 0 ||
			virtualIf(ifc.Name) {
			continue
		}
		addrs, err := ifc.Addrs()
		if err != nil {
			continue
		}
		for _, a := range addrs {
			if n, ok := a.(*net.IPNet); ok {
				ip, ok := netip.AddrFromSlice(n.IP)
				ones, _ := n.Mask.Size()
				if ok {
					out = append(out, netip.PrefixFrom(ip.Unmap(), ones))
				}
			}
		}
	}
	return out
}

// virtualIf: an interface that is no way in from the room this machine
// sits in — the tunnel interfaces (Tailscale's utun / tailscale0), container
// and VM bridges.
func virtualIf(name string) bool {
	for _, p := range []string{"utun", "tailscale", "tun", "wg", "docker", "veth", "br-", "bridge", "vmnet", "virbr",
		"awdl", "llw", "anpi", "ap", "gif", "stf"} {
		if strings.HasPrefix(name, p) {
			return true
		}
	}
	return false
}

// cgnat is 100.64.0.0/10 — the tailnet's own addresses (and carrier NAT's),
// never a LAN a person shares with this machine.
var cgnat = netip.MustParsePrefix("100.64.0.0/10")

// lanRoutes (claude-fleet#3074, EPIC #3067 共同约定 8): one route per private
// address this machine has — RFC 1918 IPv4 and IPv6 ULA — with its prefix
// length, so a client on the same network connects straight to it instead of
// around through the tailnet or the hub. Named "lan", "lan-2", … (a route's
// name is an ssh-config host alias on the hub, so they must differ); IPv4
// first, at most lanRoutesMax.
func lanRoutes(ps []netip.Prefix) []control.NodeRoute {
	var v4, v6 []netip.Prefix
	seen := map[netip.Addr]bool{}
	for _, p := range ps {
		a := p.Addr()
		if !p.IsValid() || seen[a] || !a.IsPrivate() || cgnat.Contains(a) || a.IsLinkLocalUnicast() {
			continue
		}
		seen[a] = true
		if a.Is4() {
			v4 = append(v4, p)
		} else {
			v6 = append(v6, p)
		}
	}
	var out []control.NodeRoute
	for _, p := range append(v4, v6...) {
		if len(out) == lanRoutesMax {
			break
		}
		name := "lan"
		if len(out) > 0 {
			name = fmt.Sprintf("lan-%d", len(out)+1)
		}
		out = append(out, control.NodeRoute{Name: name, Host: p.Addr().String(), Prefix: p.Bits()})
	}
	return out
}

// nodeRoutes is the heartbeat's Routes: the configured ones, plus this
// machine's private addresses when no configured route is called "lan"
// (claude-fleet#3074), plus the tailnet name when none is called "tailnet".
// The machine-wide node program and each login's agent both beat through
// here, so they report the same routes.
func (a *Agent) nodeRoutes(ctx context.Context) []control.NodeRoute {
	out := append([]control.NodeRoute(nil), a.cfg.FleetRoutes...)
	named := func(n string) bool {
		for _, r := range out {
			if r.Name == n {
				return true
			}
		}
		return false
	}
	if a.cfg.FleetLANRoute && !named("lan") {
		out = append(out, lanRoutes(localPrefixes())...)
	}
	if !a.cfg.FleetTailnetRoute || named("tailnet") {
		return out
	}
	if name := a.tailnet.get(ctx, time.Now()); routeToken(name) {
		out = append(out, control.NodeRoute{Name: "tailnet", Host: name})
	}
	return out
}
