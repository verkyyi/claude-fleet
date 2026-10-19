package api

import (
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/model"
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
	h.srv.FleetAdmins = []string{"ivan", "ops"}
	stale := connectStaleAdmin(t, h, "mac-c-op", "mac-c", "ivan", "prod-e715029")

	if code := operatorPost(t, h, FleetAccountRequest{Action: "assign", PrincipalID: "WangXiaoMing", Hostname: "mac-c"}); code != 200 {
		t.Fatalf("assign: HTTP %d", code)
	}
	if got, ok := readMsg(stale.tnode, 500*time.Millisecond); ok && got.Type == control.TypeAccountOp {
		t.Fatalf("the stale admin was sent %+v", got)
	}
	a := accountState(t, h, "WangXiaoMing", "mac-c")
	if a.State != store.AccountPending {
		t.Fatalf("account = %+v; want it still queued", a)
	}

	// The roster says it is an admin that cannot open a login.
	for _, n := range roster(t, h).Nodes {
		if n.OSUser == "ivan" && (!n.Admin || n.LoginJoin) {
			t.Fatalf("stale admin in the roster: admin=%v login_join=%v", n.Admin, n.LoginJoin)
		}
	}

	// Past openingNoAdmin the opening says which admin is too old.
	why := h.srv.openingStuck(a, a.RequestedAt.Add(openingNoAdmin+time.Second))
	if !strings.Contains(why, "too old") || !strings.Contains(why, "ivan (ccquota prod-e715029)") {
		t.Fatalf("stuck why = %q; want it to name the stale admin", why)
	}

	// A current admin on the machine takes the queued create.
	current := connectNode(t, h, "mac-c-ops", "mac-c", "ops", true)
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
	h.srv.FleetAdmins = []string{"ivan"}
	stale := connectStaleAdmin(t, h, "mac-f-op", "mac-f", "ivan", "prod-e715029")
	beatCount(t, stale, "mac-f", "ivan", 0)
	busy := connectNode(t, h, "mac-c-op", "mac-c", "ivan", true)
	beatCount(t, busy, "mac-c", "ivan", 5)
	waitFor(t, 3*time.Second, "least-busy to pick mac-c over the idle stale-admin machine", func() bool {
		return h.srv.leastBusyMachine(time.Now()) == "mac-c"
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
	if !strings.HasPrefix(why, noLoginOpener) || !strings.Contains(why, "ivan@mac-f (ccquota prod-e715029)") {
		t.Fatalf("why = %q; want it to name the stale admin", why)
	}
}
