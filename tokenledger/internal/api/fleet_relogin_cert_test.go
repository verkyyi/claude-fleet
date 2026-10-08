package api

import (
	"net/http"
	"strings"
	"testing"
	"time"

	"golang.org/x/crypto/ssh"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/sshca"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// A fleet that moved to a NEW OS login on a machine (a relogin, #2210) keeps
// its person record's old login, so the two diverge: fleet_principals says
// `alice`, the machine's account row says `alice2`. issueCert mints the
// certificate for the ACCOUNT logins, so checking it against the person
// record alone made the hub refuse its own certificates — the route list, the
// machine pick and fleet_sessions all 401 together, and with them the quota
// readings account rotation needs (claude-fleet#2437).
func TestFleetCertAcceptsAReloginLogin(t *testing.T) {
	h := newFleetHarness(t)
	k := newCertKit(t)
	h.srv.SSHCA = sshca.New(k.ca)
	h.srv.FleetRoutes = []FleetMachine{
		{Hostname: "mini", Alias: "m4", Routes: []FleetRoute{{Name: "public", Host: "gw", Port: 22023}}},
	}
	beatRoutes(t, h, "a", "mini", []control.NodeRoute{{Name: "tailnet", Host: "mini.ts.net"}})

	now := time.Now()
	p, err := h.srv.Store.AdoptPrincipal("wx-alice", "alice", "Alice", now)
	if err != nil {
		t.Fatal(err)
	}
	if err := h.srv.Store.AdoptAccount(p, "mini", now); err != nil {
		t.Fatal(err)
	}
	// The move (claude-fleet#2210): her row on mini goes to a new login and
	// the machine reports the create done — active under alice2, while the
	// person record still says alice.
	if _, err := h.srv.Store.RequestRelogin(p.ID, "mini", "alice2", now); err != nil {
		t.Fatal(err)
	}
	if ok, err := h.srv.Store.MarkAccountSent(p.ID, "mini", store.AccountPending, store.AccountCreating,
		"op-1", "ep_a", now); err != nil || !ok {
		t.Fatalf("MarkAccountSent = %v, %v", ok, err)
	}
	if ok, err := h.srv.Store.FinishAccountOp("op-1", "ep_a", store.AccountActive, "created", now); err != nil || !ok {
		t.Fatalf("FinishAccountOp = %v, %v", ok, err)
	}
	if got, err := h.srv.Store.Principal("wx-alice"); err != nil || got.Login != "alice" {
		t.Fatalf("person record = %+v, %v; want login alice (the divergence this test is about)", got, err)
	}

	// What the hub itself would mint now: the account logins, not p.Login.
	logins, _, byHost, err := h.srv.managedLoginsOf(p.ID)
	if err != nil {
		t.Fatal(err)
	}
	if len(logins) != 1 || logins[0] != "alice2" || byHost["mini"] != "alice2" {
		t.Fatalf("managedLoginsOf = %v / %v, want [alice2] and mini→alice2", logins, byHost)
	}

	signed := func(c *ssh.Certificate, ts int64) RoutesRequest {
		return RoutesRequest{Cert: string(ssh.MarshalAuthorizedKey(c)), TS: ts,
			Sig: sshsig(t, k.user, control.RoutesSigNamespace, []byte(control.RoutesSigMessage(ts)))}
	}
	cert := k.cert(t, "person:wx-alice", []string{"alice2"}, now.Add(-time.Minute), now.Add(12*time.Hour))
	code, out, raw := postRoutes(t, h, nil, signed(cert, now.Unix()))
	if code != 200 {
		t.Fatalf("a certificate for the relogin'd login: HTTP %d %s, want 200", code, raw)
	}
	if len(out.Machines) != 1 || out.Machines[0].Alias != "m4" {
		t.Fatalf("machines = %+v, want m4", out.Machines)
	}

	// The snippet names THIS machine's login, not the person record's.
	if cfg := h.srv.sshConfigFor(p.Login, map[string]bool{"mini": true}, byHost); !strings.Contains(cfg, "User alice2") || strings.Contains(cfg, "User alice\n") {
		t.Fatalf("ssh config = %q, want User alice2", cfg)
	}

	// A login that is nobody's is still refused.
	bad := k.cert(t, "person:wx-alice", []string{"root"}, now.Add(-time.Minute), now.Add(12*time.Hour))
	if code, _, raw := postRoutes(t, h, nil, signed(bad, now.Unix())); code != http.StatusUnauthorized {
		t.Errorf("a login that is nobody's: HTTP %d %s, want 401", code, raw)
	}
}
