package api

import (
	"context"
	"testing"
	"time"

	"github.com/coder/websocket/wsjson"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// A Linux managed machine opens its own logins (claude-fleet#3210, EPIC #3208
// C2): no admin login there, so the machine link that lists CapLoginJoin is
// its account-op node — for its own host only, and nothing more than that.

// dialMachineCaps is dialMachine with the hello's capabilities given.
func dialMachineCaps(t *testing.T, h *harness, token string, caps ...string) *machNode {
	t.Helper()
	c := dialNode(t, h, token)
	off := false
	m, _ := control.New(control.TypeHello, control.Hello{HeartbeatMS: 60000, AgentVersion: "test",
		Capabilities: append([]string{control.CapMachine}, caps...), Compute: &off})
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := wsjson.Write(ctx, c, m); err != nil {
		t.Fatal(err)
	}
	var reply control.Message
	if err := wsjson.Read(ctx, c, &reply); err != nil || reply.Type != control.TypeWelcome {
		t.Fatalf("machine hello: %v %+v", err, reply)
	}
	n := &machNode{t: t, c: c, in: map[string]chan control.Message{}, writes: map[string][]map[string]any{}}
	go n.serve()
	return n
}

// linuxRig is fleet-linux-0's machine link (it opens its own logins) and m9's
// (a Mac: it does not). The hub's admin logins are elsewhere.
func linuxRig(t *testing.T) (*harness, *machNode, *machNode) {
	t.Helper()
	h := newFleetHarness(t)
	h.srv.FleetAdmins = []string{"verky"}
	h.enroll(t, "linux")
	h.enroll(t, "mac")
	lin := dialMachineCaps(t, h, h.tokens["linux"], control.CapLoginJoin)
	lin.beat("", control.Heartbeat{OS: "linux", Hostname: "fleet-linux-0", OSUser: "root", NCPU: 4, ObservedAt: time.Now()})
	mac := dialMachineCaps(t, h, h.tokens["mac"])
	mac.beat("", control.Heartbeat{OS: "darwin", Hostname: "m9", OSUser: "root", NCPU: 10, ObservedAt: time.Now()})
	waitFor(t, 3*time.Second, "both machine links named", func() bool {
		_, ok := h.srv.nodes.openerFor("fleet-linux-0")
		named := false
		h.srv.nodes.each(func(_ string, c *nodeConn) { named = named || c.hostname() == "m9" })
		return ok && named
	})
	return h, lin, mac
}

// 怎么算成功: assigned to fleet-linux-0, the create goes down the machine's own
// lane; its answer makes the row active; a remove goes the same way.
func TestLinuxMachineOpensItsOwnLogins(t *testing.T) {
	h, lin, mac := linuxRig(t)
	if id, ok := h.srv.nodes.openerFor("m9"); ok {
		t.Fatalf("m9 (no CapLoginJoin) is an opener: %s", id)
	}
	if code := operatorPost(t, h, FleetAccountRequest{Action: "assign", PrincipalID: "arvin", Hostname: "fleet-linux-0"}); code != 200 {
		t.Fatalf("assign: HTTP %d", code)
	}
	m, op := expectAccountOp(t, &tnode{in: lin.inbox("")})
	if op.Op != control.AccountCreate || m.Login != "" || op.JoinCode == "" {
		t.Fatalf("op = %+v on lane %q; want a create with its join code on the machine's own lane", op, m.Login)
	}
	if got, ok := readMsg(&tnode{in: mac.inbox("")}, 300*time.Millisecond); ok && got.Type == control.TypeAccountOp {
		t.Fatalf("m9 received fleet-linux-0's op %+v", got)
	}
	res, _ := control.New(control.TypeAccountResult, control.AccountResult{Op: control.AccountCreate, Login: op.Login,
		OK: true, Credsep: control.CredsepSeparated})
	res.OpID = m.OpID
	lin.send("", res)
	a := waitState(t, h, "arvin", "fleet-linux-0", store.AccountActive)
	if ack, ok := readMsg(&tnode{in: lin.inbox("")}, 3*time.Second); !ok || ack.Type != control.TypeAck || ack.OpID != m.OpID {
		t.Fatalf("the result was not acked: %+v", ack)
	}

	// The roster says it can open logins, and that it is no admin.
	snap, err := h.srv.Nodes(time.Now())
	if err != nil {
		t.Fatal(err)
	}
	for _, n := range snap.Nodes {
		if n.Hostname == "fleet-linux-0" && n.MachineLink {
			if !n.LoginJoin || n.Admin {
				t.Fatalf("fleet-linux-0's row: LoginJoin=%v Admin=%v; want true/false", n.LoginJoin, n.Admin)
			}
		}
	}
	if !adminNodesOnline(snap)["fleet-linux-0"] {
		t.Fatal("fleet-linux-0 is not counted as a machine that can open a login")
	}

	if code := operatorPost(t, h, FleetAccountRequest{Action: "remove", PrincipalID: "arvin", Hostname: "fleet-linux-0"}); code != 200 {
		t.Fatalf("remove: HTTP %d", code)
	}
	m, op = expectAccountOp(t, &tnode{in: lin.inbox("")})
	if op.Op != control.AccountRemove || op.Login != a.Login {
		t.Fatalf("op = %+v; want a remove of %s", op, a.Login)
	}
	res, _ = control.New(control.TypeAccountResult, control.AccountResult{Op: control.AccountRemove, Login: op.Login, OK: true})
	res.OpID = m.OpID
	lin.send("", res)
	waitState(t, h, "arvin", "fleet-linux-0", store.AccountRemoved)
}

// A machine link that opens logins is not an admin: no SSH CA is sent to it,
// and a Mac's machine link (no CapLoginJoin) is never sent a create
// (TestMachineAccountOpsOffAddsNothing's hub half).
func TestMachineOpenerIsNoAdmin(t *testing.T) {
	h, lin, mac := linuxRig(t)
	if got, ok := readMsg(&tnode{in: lin.inbox("")}, 300*time.Millisecond); ok && got.Type == control.TypeSSHCA {
		t.Fatalf("the machine opener was sent the SSH CA: %+v", got)
	}
	if code := operatorPost(t, h, FleetAccountRequest{Action: "assign", PrincipalID: "carol", Hostname: "m9"}); code != 200 {
		t.Fatalf("assign: HTTP %d", code)
	}
	if got, ok := readMsg(&tnode{in: mac.inbox("")}, 500*time.Millisecond); ok && got.Type == control.TypeAccountOp {
		t.Fatalf("m9's machine link (no CapLoginJoin) was sent %+v", got)
	}
	if a := accountState(t, h, "carol", "m9"); a.State != store.AccountPending {
		t.Fatalf("carol@m9 is %q; want it still pending", a.State)
	}
}
