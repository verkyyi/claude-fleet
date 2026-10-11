package api

import (
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/model"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// claude-fleet#3032: an admin agent built before #2652 (restored from the
// attic, its ccquota off the release) opens a login without handing it its
// join code, so the login's own node never connects and the newcomer waits
// ten minutes for 「failed」. Such an admin lists no CapLoginJoin: it is never
// sent a create, placement never picks its machine, and the words name it.

// connectStaleAdmin is connectNode for an admin agent that predates
// CapLoginJoin, reporting version.
func connectStaleAdmin(t *testing.T, h *harness, label, hostname, osUser, version string) *fleetNode {
	t.Helper()
	tok := h.enroll(t, label)
	id := "ep_" + label
	ident := model.Identity{AccountUUID: "acct-" + label, Hostname: hostname, OSUser: osUser}
	if err := h.srv.Store.UpsertAccount(ident, "max", ""); err != nil {
		t.Fatal(err)
	}
	if _, _, err := h.srv.Store.TouchEndpoint(id, ident, "test", true, nil); err != nil {
		t.Fatal(err)
	}
	n := &fleetNode{token: tok, id: id}
	n.tnode = dialStaleAdmin(t, h, tok, version)
	beat(t, n.c, control.Proto, control.Heartbeat{Hostname: hostname, OSUser: osUser, NCPU: 8})
	return n
}

func TestStaleAdminIsNeverSentACreate(t *testing.T) {
	h := newFleetHarness(t)
	h.srv.FleetAdmins = []string{"verkyyi", "ops"}
	stale := connectStaleAdmin(t, h, "m4-op", "m4", "verkyyi", "prod-e715029")

	if code := operatorPost(t, h, FleetAccountRequest{Action: "assign", PrincipalID: "WangXiaoMing", Hostname: "m4"}); code != 200 {
		t.Fatalf("assign: HTTP %d", code)
	}
	if got, ok := readMsg(stale.tnode, 500*time.Millisecond); ok && got.Type == control.TypeAccountOp {
		t.Fatalf("the stale admin was sent %+v", got)
	}
	a := accountState(t, h, "WangXiaoMing", "m4")
	if a.State != store.AccountPending {
		t.Fatalf("account = %+v; want it still queued", a)
	}

	// The roster says it is an admin that cannot open a login.
	for _, n := range roster(t, h).Nodes {
		if n.OSUser == "verkyyi" && (!n.Admin || n.LoginJoin) {
			t.Fatalf("stale admin in the roster: admin=%v login_join=%v", n.Admin, n.LoginJoin)
		}
	}

	// Past openingNoAdmin the opening says which admin is too old.
	why := h.srv.openingStuck(a, a.RequestedAt.Add(openingNoAdmin+time.Second))
	if !strings.Contains(why, "too old") || !strings.Contains(why, "verkyyi (ccquota prod-e715029)") {
		t.Fatalf("stuck why = %q; want it to name the stale admin", why)
	}

	// A current admin on the machine takes the queued create.
	current := connectNode(t, h, "m4-ops", "m4", "ops", true)
	_, op := expectAccountOp(t, current.tnode)
	if op.Op != control.AccountCreate || op.Login != "wangxiaoming" || op.JoinCode == "" {
		t.Fatalf("op = %+v; want a create with its join code", op)
	}
	if got, ok := readMsg(stale.tnode, 300*time.Millisecond); ok && got.Type == control.TypeAccountOp {
		t.Fatalf("the stale admin was sent %+v", got)
	}
}

func TestLeastBusySkipsAMachineWithOnlyAStaleAdmin(t *testing.T) {
	h := newFleetHarness(t)
	enablePeople(t, h)
	h.srv.FleetAdmins = []string{"verkyyi"}
	stale := connectStaleAdmin(t, h, "mini2-op", "mini2", "verkyyi", "prod-e715029")
	beatCount(t, stale, "mini2", "verkyyi", 0)
	busy := connectNode(t, h, "m4-op", "m4", "verkyyi", true)
	beatCount(t, busy, "m4", "verkyyi", 5)
	waitFor(t, 3*time.Second, "least-busy to pick m4 over the idle stale-admin machine", func() bool {
		return h.srv.leastBusyMachine(time.Now()) == "m4"
	})

	// With the current admin gone, nothing can open a login — and the word
	// names the stale one.
	busy.c.CloseNow()
	waitFor(t, 3*time.Second, "no machine to open a login on", func() bool {
		return h.srv.leastBusyMachine(time.Now()) == ""
	})
	snap, err := h.srv.Nodes(time.Now())
	if err != nil {
		t.Fatal(err)
	}
	why := noLoginOpenerWhy(snap)
	if !strings.HasPrefix(why, noLoginOpener) || !strings.Contains(why, "verkyyi@mini2 (ccquota prod-e715029)") {
		t.Fatalf("why = %q; want it to name the stale admin", why)
	}
}
