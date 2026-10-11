package agent

import (
	"context"
	"net/netip"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
)

func TestParseNodeRoutes(t *testing.T) {
	got, err := ParseNodeRoutes(" public=gw.example.com:22023, lan=192.168.1.20 ,")
	if err != nil {
		t.Fatal(err)
	}
	want := []control.NodeRoute{{Name: "public", Host: "gw.example.com", Port: 22023}, {Name: "lan", Host: "192.168.1.20"}}
	if len(got) != len(want) || got[0] != want[0] || got[1] != want[1] {
		t.Fatalf("got %+v, want %+v", got, want)
	}
	if got, err := ParseNodeRoutes(""); err != nil || len(got) != 0 {
		t.Fatalf("empty: %+v %v", got, err)
	}
	for _, bad := range []string{"gw:22", "p=gw:0", "p=gw:x", "p=gw:70000", "p q=gw", "p=-oProxyCommand", "p=a b"} {
		if _, err := ParseNodeRoutes(bad); err == nil {
			t.Errorf("%q accepted", bad)
		}
	}
}

// The tailnet name is added as "tailnet" unless a configured route already
// has that name, and the reading is reused, not re-forked every beat.
func TestNodeRoutesTailnet(t *testing.T) {
	calls := 0
	old := tailnetSelfName
	tailnetSelfName = func(context.Context) string { calls++; return "mini.tail1.ts.net" }
	t.Cleanup(func() { tailnetSelfName = old })

	a := &Agent{cfg: Config{FleetTailnetRoute: true,
		FleetRoutes: []control.NodeRoute{{Name: "public", Host: "gw", Port: 22023}}}}
	got := a.nodeRoutes(context.Background())
	if len(got) != 2 || got[1] != (control.NodeRoute{Name: "tailnet", Host: "mini.tail1.ts.net"}) {
		t.Fatalf("routes = %+v", got)
	}
	a.nodeRoutes(context.Background())
	if calls != 1 {
		t.Fatalf("tailscale asked %d times, want 1 (cached)", calls)
	}
	a.tailnet.at = time.Now().Add(-2 * tailnetRefresh)
	a.nodeRoutes(context.Background())
	if calls != 2 {
		t.Fatalf("stale reading not refreshed (calls=%d)", calls)
	}

	own := &Agent{cfg: Config{FleetTailnetRoute: true, FleetRoutes: []control.NodeRoute{{Name: "tailnet", Host: "custom"}}}}
	if got := own.nodeRoutes(context.Background()); len(got) != 1 || got[0].Host != "custom" {
		t.Fatalf("a configured tailnet route was overridden: %+v", got)
	}
	off := &Agent{cfg: Config{}}
	if got := off.nodeRoutes(context.Background()); len(got) != 0 {
		t.Fatalf("tailnet off still advertised %+v", got)
	}
	tailnetSelfName = func(context.Context) string { return "" }
	none := &Agent{cfg: Config{FleetTailnetRoute: true}}
	if got := none.nodeRoutes(context.Background()); len(got) != 0 {
		t.Fatalf("no tailscale still advertised %+v", got)
	}
}

// claude-fleet#3074: every private address this machine has is a "lan" route
// with its prefix length — RFC 1918 and ULA only, the tailnet's 100.64/10,
// public and link-local addresses never; IPv4 first, names unique, capped.
func TestLANRoutes(t *testing.T) {
	pp := func(ss ...string) []netip.Prefix {
		var out []netip.Prefix
		for _, s := range ss {
			out = append(out, netip.MustParsePrefix(s))
		}
		return out
	}
	got := lanRoutes(pp("fd12:3456::7/64", "192.168.1.249/24", "100.101.2.3/32", "8.8.8.8/24",
		"fe80::1/64", "10.0.0.5/8", "192.168.1.249/24"))
	want := []control.NodeRoute{
		{Name: "lan", Host: "192.168.1.249", Prefix: 24},
		{Name: "lan-2", Host: "10.0.0.5", Prefix: 8},
		{Name: "lan-3", Host: "fd12:3456::7", Prefix: 64},
	}
	if len(got) != len(want) {
		t.Fatalf("lan routes = %+v", got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("lan route %d = %+v, want %+v", i, got[i], want[i])
		}
	}
	if n := len(lanRoutes(pp("10.0.0.1/24", "10.0.1.1/24", "10.0.2.1/24", "10.0.3.1/24", "10.0.4.1/24"))); n != lanRoutesMax {
		t.Fatalf("%d lan routes, want the cap %d", n, lanRoutesMax)
	}
	if got := lanRoutes(nil); len(got) != 0 {
		t.Fatalf("no addresses still gave %+v", got)
	}
}

func TestNodeRoutesLAN(t *testing.T) {
	old := localPrefixes
	localPrefixes = func() []netip.Prefix { return []netip.Prefix{netip.MustParsePrefix("192.168.1.249/24")} }
	t.Cleanup(func() { localPrefixes = old })

	a := &Agent{cfg: Config{FleetLANRoute: true, FleetRoutes: []control.NodeRoute{{Name: "public", Host: "gw", Port: 22023}}}}
	got := a.nodeRoutes(context.Background())
	if len(got) != 2 || got[1] != (control.NodeRoute{Name: "lan", Host: "192.168.1.249", Prefix: 24}) {
		t.Fatalf("routes = %+v", got)
	}
	own := &Agent{cfg: Config{FleetLANRoute: true, FleetRoutes: []control.NodeRoute{{Name: "lan", Host: "10.9.9.9"}}}}
	if got := own.nodeRoutes(context.Background()); len(got) != 1 || got[0].Host != "10.9.9.9" {
		t.Fatalf("a configured lan route was overridden: %+v", got)
	}
	if got := (&Agent{cfg: Config{}}).nodeRoutes(context.Background()); len(got) != 0 {
		t.Fatalf("lan off still advertised %+v", got)
	}
}

func TestVirtualIf(t *testing.T) {
	for _, n := range []string{"utun3", "tailscale0", "docker0", "bridge100", "vmnet8", "awdl0", "llw0"} {
		if !virtualIf(n) {
			t.Errorf("%s not taken for virtual", n)
		}
	}
	for _, n := range []string{"en0", "en1", "eth0", "wlan0", "enp3s0", "br0"} {
		if virtualIf(n) {
			t.Errorf("%s taken for virtual", n)
		}
	}
}
