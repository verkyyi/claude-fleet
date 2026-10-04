package agent

import (
	"context"
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
