package e2e

import (
	"sync"

	"context"
	"encoding/json"
	"os"
	"os/user"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/verkyyi/claude-fleet/tokenledger/agent"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/model"
)

// 旧节点兼容: a login's own agent (a plain link) works as before — and while
// its machine link carries it, an old per-login agent left running is refused
// rather than flip the login back and forth.
func TestMachineLinkAndPlainAgents(t *testing.T) {
	h, n := machineRig(t)
	c := dialNode(t, h, h.Tokens["beta"])
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	m, _ := control.New(control.TypeHello, control.Hello{HeartbeatMS: 60000})
	if err := wsjson.Write(ctx, c, m); err != nil {
		t.Fatal(err)
	}
	var r control.Message
	if err := wsjson.Read(ctx, c, &r); err != nil || r.Type != control.TypeError || r.Error.Code != control.CodeRefused {
		t.Fatalf("an old agent for a login the machine link carries: %v %+v; want REFUSED", err, r)
	}
	if cur := h.Srv.NodeForTest("ep_beta"); cur == nil || cur.MachineForTest() != "ep_mach" {
		t.Fatal("the old agent took beta off the machine link")
	}

	// A login not on the machine link dials its own, exactly as before.
	h.Enroll(t, "carol")
	plain := dialNode(t, h, h.Tokens["carol"])
	if w := hello(t, plain, control.Proto, 60000); !w.Accepted {
		t.Fatalf("plain hello: %+v", w)
	}
	beat(t, plain, control.Proto, control.Heartbeat{Hostname: "mac-c", OSUser: "carol"})
	waitFor(t, 3*time.Second, "carol online on her own link", func() bool {
		for _, v := range roster(t, h).Nodes {
			if v.EndpointID == "ep_carol" {
				return v.Connected && v.Via == ""
			}
		}
		return false
	})
	n.beat("alpha", control.Heartbeat{Hostname: "mac-c", OSUser: "alpha", ObservedAt: time.Now()})
	n.beat("beta", control.Heartbeat{Hostname: "mac-c", OSUser: "beta", ObservedAt: time.Now()})
	waitFor(t, 3*time.Second, "mac-c: the machine link + carol's own", func() bool {
		ms := roster(t, h).Machines
		return len(ms) == 1 && ms[0].Links == 2 && ms[0].Logins == 3
	})

	// The machine link going away takes its logins with it.
	n.c.Close(websocket.StatusNormalClosure, "bye")
	waitFor(t, 3*time.Second, "alpha and beta off", func() bool {
		return h.Srv.NodeForTest("ep_alpha") == nil && h.Srv.NodeForTest("ep_beta") == nil
	})
	if h.Srv.NodeForTest("ep_carol") == nil {
		t.Fatal("carol's own link went with the machine link")
	}
}

// The node half, for real: `ccquota agent --machine` (agent.RunMachine) holds
// one link and serves two logins, and a hub read for each runs that login's
// own controller as that login (HOME / USER of the login, never root's).
func TestMachineAgentRunsEachLoginAsItself(t *testing.T) {
	h := newFleetHarness(t)
	h.Enroll(t, "mach")
	me, err := user.Current()
	if err != nil {
		t.Fatal(err)
	}
	uid, _ := strconv.ParseUint(me.Uid, 10, 32)
	gid, _ := strconv.ParseUint(me.Gid, 10, 32)
	host, _ := os.Hostname()
	const every = 150 * time.Millisecond
	var tenants []agent.Config
	homes := map[string]string{}
	for _, l := range []string{"alpha", "beta"} {
		h.Enroll(t, l)
		identify(t, h, l, host, l)
		home := t.TempDir()
		homes[l] = home
		bin := filepath.Join(home, ".claude", "fleet", "bin")
		if err := os.MkdirAll(bin, 0o755); err != nil {
			t.Fatal(err)
		}
		script := "#!/bin/sh\nin=$(cat)\nprintf '%s %s\\n' \"$USER\" \"$in\" >> \"$HOME/calls.log\"\n" +
			"printf '{\"machine_id\":\"mid-%s\",\"result\":{\"user\":\"%s\",\"home\":\"%s\",\"fleets\":[]}}\\n' \"$USER\" \"$USER\" \"$HOME\"\n"
		if err := os.WriteFile(filepath.Join(bin, "fleet-control.py"), []byte(script), 0o755); err != nil {
			t.Fatal(err)
		}
		tenants = append(tenants, agent.Config{
			Token: h.Tokens[l], Home: home, StateDir: filepath.Join(t.TempDir(), "state"),
			SessionsDir: filepath.Join(home, ".ccquota"), Sources: "claude",
			LiveInterval: every, ScanInterval: time.Hour, LimitsInterval: time.Hour,
			RunAs: &agent.RunAs{Login: l, UID: uint32(uid), GID: uint32(gid), Home: home},
		})
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		_ = agent.RunMachine(ctx, agent.MachineConfig{HubURL: h.HTTP.URL, Token: h.Tokens["mach"],
			Version: "it-machine", LiveInterval: every, Tenants: tenants})
		close(done)
	}()
	t.Cleanup(func() { cancel(); <-done })

	waitFor(t, 5*time.Second, "both logins online on the machine link", func() bool {
		a, b := h.Srv.NodeForTest("ep_alpha"), h.Srv.NodeForTest("ep_beta")
		return a != nil && b != nil && a.MachineForTest() == "ep_mach" && b.MachineForTest() == "ep_mach"
	})
	for _, l := range []string{"alpha", "beta"} {
		res, mid, err := h.Srv.NodeRead(context.Background(), "ep_"+l, "fleet_status", map[string]any{"fleet_id": "x"})
		if err != nil {
			t.Fatalf("%s: read: %v", l, err)
		}
		var got struct{ User, Home string }
		_ = json.Unmarshal(res, &got)
		if got.User != l || got.Home != homes[l] || mid != "mid-"+l {
			t.Fatalf("a read for %s ran as %+v (machine %s); want %s in %s", l, got, mid, l, homes[l])
		}
	}
	// The other login's controller never saw the call.
	for l, home := range homes {
		b, _ := os.ReadFile(filepath.Join(home, "calls.log"))
		for _, line := range strings.Split(strings.TrimSpace(string(b)), "\n") {
			if line != "" && !strings.HasPrefix(line, l+" ") {
				t.Fatalf("%s's controller ran as someone else: %q", l, line)
			}
		}
	}
	waitFor(t, 5*time.Second, "one link on the machine", func() bool {
		for _, m := range roster(t, h).Machines {
			if m.Hostname == host {
				return m.Links == 1 && m.Logins == 2
			}
		}
		return false
	})
}

// identify gives an enrolled endpoint the machine and login it reports, as a
// usage push would.
func identify(t *testing.T, h *harness, label, hostname, osUser string) {
	t.Helper()
	ident := model.Identity{AccountUUID: "acct-" + label, Hostname: hostname, OSUser: osUser}
	if err := h.Srv.Store.UpsertAccount(ident, "max", ""); err != nil {
		t.Fatal(err)
	}
	if _, _, err := h.Srv.Store.TouchEndpoint("ep_"+label, ident, "test", true, nil); err != nil {
		t.Fatal(err)
	}
}

// machineRig is mac-c as one machine link carrying alpha and beta, every
// endpoint identified as mac-c's. admins are the hub's admin logins (default
// alpha); an admin's hello says so.
func machineRig(t *testing.T, admins ...string) (*harness, *machNode) {
	t.Helper()
	h := newFleetHarness(t)
	if len(admins) == 0 {
		admins = []string{"alpha"}
	}
	h.Srv.FleetAdmins = admins
	h.Enroll(t, "mach")
	for _, l := range []string{"alpha", "beta"} {
		h.Enroll(t, l)
		identify(t, h, l, "mac-c", l)
	}
	n := dialMachine(t, h, h.Tokens["mach"])
	n.beat("", control.Heartbeat{Hostname: "mac-c", OSUser: "root", NCPU: 10, ObservedAt: time.Now()})
	// The beat is recorded off the link's reader: a login hello read before it
	// found the machine's host unknown and skipped the other-machine check
	// (claude-fleet#4679 — "dave with belongs to mac-d: answered welcome").
	waitFor(t, 3*time.Second, "the machine's host recorded", func() bool {
		ep, err := h.Srv.Store.EndpointByID("ep_mach")
		return err == nil && h.Srv.EndpointHostForTest(*ep) == "mac-c"
	})
	for _, l := range []string{"alpha", "beta"} {
		if r := n.login(l, h.Tokens[l], hasString(admins, l), control.CapRead, control.CapWrite, control.CapMove); r.Type != control.TypeWelcome || r.Login != l {
			t.Fatalf("%s's hello answered %+v", l, r)
		}
	}
	return h, n
}

// machNode is a test machine link: one websocket, the messages it receives
// split by login. Writes are answered "accepted" and recorded per login, as
// writeNode does for a plain link.
type machNode struct {
	t  *testing.T
	c  *websocket.Conn
	mu sync.Mutex
	in map[string]chan control.Message
	// writes is every TypeWrite envelope received, by login.
	writes map[string][]map[string]any
}

func dialMachine(t *testing.T, h *harness, token string, caps ...string) *machNode {
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

func (n *machNode) inbox(login string) chan control.Message {
	n.mu.Lock()
	defer n.mu.Unlock()
	ch := n.in[login]
	if ch == nil {
		ch = make(chan control.Message, 64)
		n.in[login] = ch
	}
	return ch
}

func (n *machNode) serve() {
	for {
		var m control.Message
		if err := wsjson.Read(context.Background(), n.c, &m); err != nil {
			return
		}
		if m.Type == control.TypeWrite {
			var req control.Request
			_ = json.Unmarshal(m.Payload, &req)
			var env map[string]any
			_ = json.Unmarshal(req.Params, &env)
			n.mu.Lock()
			n.writes[m.Login] = append(n.writes[m.Login], env)
			n.mu.Unlock()
			raw, _ := json.Marshal(map[string]any{"operation_id": env["operation_id"], "fleet_id": env["fleet_id"],
				"action": env["action"], "status": "accepted", "result": nil})
			out, _ := control.New(control.TypeResult, control.Result{Result: raw})
			out.OpID, out.Login = m.OpID, m.Login
			_ = wsjson.Write(context.Background(), n.c, out)
			continue
		}
		n.inbox(m.Login) <- m
	}
}

func (n *machNode) count(login string) int {
	n.mu.Lock()
	defer n.mu.Unlock()
	return len(n.writes[login])
}

func (n *machNode) send(login string, m control.Message) {
	n.t.Helper()
	m.Login = login
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := wsjson.Write(ctx, n.c, m); err != nil {
		n.t.Fatal(err)
	}
}

// login says one login's hello on the link and returns the hub's answer.
func (n *machNode) login(login, token string, admin bool, caps ...string) control.Message {
	n.t.Helper()
	if admin {
		caps = append(caps, control.CapLoginJoin) // a current admin (claude-fleet#3032)
	}
	m, _ := control.New(control.TypeHello, control.Hello{HeartbeatMS: 60000, AgentVersion: "test",
		Admin: admin, Capabilities: caps, LoginToken: token})
	n.send(login, m)
	r, ok := readMsg(&tnode{in: n.inbox(login)}, 5*time.Second)
	if !ok {
		n.t.Fatalf("no answer to %s's hello", login)
	}
	return r
}

func (n *machNode) beat(login string, hb control.Heartbeat) {
	n.t.Helper()
	m, _ := control.New(control.TypeHeartbeat, hb)
	n.send(login, m)
}
