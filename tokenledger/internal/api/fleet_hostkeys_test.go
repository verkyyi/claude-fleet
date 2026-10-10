package api

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"golang.org/x/crypto/ssh"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
)

// A machine's sshd host keys travel with its routes (claude-fleet#2983), so
// `fleet connect` can trust a new person's first connection without ssh's
// yes/no question.

func hostKeyLine(t *testing.T) string {
	t.Helper()
	pub, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	sp, err := ssh.NewPublicKey(pub)
	if err != nil {
		t.Fatal(err)
	}
	return strings.TrimSpace(string(ssh.MarshalAuthorizedKey(sp)))
}

func beatHostKeys(t *testing.T, h *harness, label, host string, at time.Time, keys []string, routes []control.NodeRoute) {
	t.Helper()
	h.enroll(t, label)
	if err := h.srv.Store.NodeConnected("ep_"+label, host, label, "test", control.Proto, 1000, at); err != nil {
		t.Fatal(err)
	}
	b, _ := json.Marshal(control.Heartbeat{Hostname: host, Routes: routes, HostKeys: keys})
	if err := h.srv.Store.NodeHeartbeat("ep_"+label, host, label, "", control.Proto, string(b), at); err != nil {
		t.Fatal(err)
	}
}

// The newest heartbeat of a machine names its keys — an older login's stale
// report does not keep a replaced key trusted; a bad line (a comment, a
// certificate, an injected newline) never reaches the list; the operator's
// static keys stay beside them; a machine nobody reported keys for has none.
func TestFleetMachinesHostKeys(t *testing.T) {
	h := newFleetHarness(t)
	static, old, cur := hostKeyLine(t), hostKeyLine(t), hostKeyLine(t)
	h.srv.FleetRoutes = []FleetMachine{{Hostname: "mini", Alias: "m4", HostKeys: []string{static + " operator@desk"},
		Routes: []FleetRoute{{Name: "public", Host: "gw.static", Port: 22022}}}}
	now := time.Now()
	tail := []control.NodeRoute{{Name: "tailnet", Host: "mini.tail.ts.net"}}
	beatHostKeys(t, h, "a", "mini", now.Add(-time.Hour), []string{old}, tail)
	beatHostKeys(t, h, "b", "mini", now, []string{cur + " root@mini", "garbage", cur + "\nmini2 " + old, "ssh-ed25519-cert-v01@openssh.com AAAA"}, nil)
	beatHostKeys(t, h, "c", "m9", now, nil, []control.NodeRoute{{Name: "tailnet", Host: "m9.tail.ts.net"}})

	ms := h.srv.fleetMachines()
	if len(ms) != 2 {
		t.Fatalf("machines = %+v", ms)
	}
	if got := ms[0].HostKeys; len(got) != 2 || got[0] != static || got[1] != cur {
		t.Fatalf("mini host keys = %q, want [static cur]", got)
	}
	if ms[1].HostKeys != nil {
		t.Fatalf("m9 host keys = %q, want none", ms[1].HostKeys)
	}
	if len(h.srv.FleetRoutes[0].HostKeys) != 1 {
		t.Fatalf("static host keys mutated: %+v", h.srv.FleetRoutes[0].HostKeys)
	}
	// The route list `fleet connect` reads carries them.
	b, _ := json.Marshal(RouteMachine{FleetMachine: ms[0]})
	if !strings.Contains(string(b), `"host_keys":["`+static) {
		t.Fatalf("route machine JSON lacks host_keys: %s", b)
	}
	b, _ = json.Marshal(RouteMachine{FleetMachine: ms[1]})
	if strings.Contains(string(b), "host_keys") {
		t.Fatalf("a machine without keys says host_keys: %s", b)
	}
}
