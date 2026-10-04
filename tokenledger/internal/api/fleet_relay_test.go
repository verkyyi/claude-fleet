package api

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket/wsjson"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/agent"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// Node-to-node relays (claude-fleet#1421, EPIC #1419 C2).

// installFakeHubNode lays a stand-in for claude-fleet's bin/fleet-hub-node.sh
// beside the fake fleet-control.py: `paths` names an outbox and a worker map
// under home, `deliver` appends the relay to home/delivered (one line each)
// and exits with home/deliver.rc (0 when absent).
func installFakeHubNode(t *testing.T, home string) {
	t.Helper()
	dir := filepath.Join(home, ".claude", "fleet", "bin")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	script := `#!/bin/bash
H=` + shQuote(home) + `
case "$1" in
  paths) printf 'outbox\t%s\nworkers\t%s\n' "$H/outbox" "$H/hub-workers.tsv" ;;
  deliver) { tr -d '\n'; echo; } >> "$H/delivered"; rc=$(cat "$H/deliver.rc" 2>/dev/null); exit "${rc:-0}" ;;
  *) exit 2 ;;
esac
`
	if err := os.WriteFile(filepath.Join(dir, "fleet-hub-node.sh"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
}

// startRelayAgent runs one real agent against the harness hub until the test
// ends (or the returned stop is called).
func startRelayAgent(t *testing.T, h *harness, label, home, token string, every time.Duration) (stop func()) {
	t.Helper()
	a, err := agent.New(agent.Config{
		HubURL: h.http.URL, Token: token, Home: home,
		StateDir: filepath.Join(home, "state"), SessionsDir: filepath.Join(home, "sessions"),
		Sources: "claude", LiveInterval: every, ScanInterval: time.Hour, LimitsInterval: time.Hour,
		Fleet: true, Version: "it-" + label,
	})
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { a.Run(ctx); close(done) }()
	stopped := false
	stop = func() {
		if !stopped {
			stopped = true
			cancel()
			<-done
		}
	}
	t.Cleanup(stop)
	return stop
}

func lines(path string) []string {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	out := []string{}
	for _, l := range strings.Split(strings.TrimSpace(string(b)), "\n") {
		if l != "" {
			out = append(out, l)
		}
	}
	return out
}

func dropRelay(t *testing.T, outbox, name string, r control.Relay) string {
	t.Helper()
	if err := os.MkdirAll(outbox, 0o700); err != nil {
		t.Fatal(err)
	}
	b, _ := json.Marshal(r)
	f := filepath.Join(outbox, name)
	if err := os.WriteFile(f, b, 0o600); err != nil {
		t.Fatal(err)
	}
	return f
}

func gone(path string) bool { _, err := os.Stat(path); return os.IsNotExist(err) }

// TestRelayIntegrationTwoAgents is the issue's 完成判据, on a local hub with two
// real agents and claude-fleet's real fleet_control.py: a child on one machine
// reports to its parent on the other; the parent's machine applies it exactly
// once however often it is sent; a parent machine that is offline gets it when
// it is back; the hub map tells each machine where the other's workers are and
// whose children they are; and a node cannot speak for a worker it does not
// host.
func TestRelayIntegrationTwoAgents(t *testing.T) {
	py, err := exec.LookPath("python3")
	if err != nil {
		t.Skip("no python3")
	}
	bin, _ := filepath.Abs("../../../bin")
	if _, err := os.Stat(filepath.Join(bin, "fleet_control.py")); err != nil {
		t.Skip("no claude-fleet bin/ beside tokenledger/")
	}
	oldPush := workersPushEvery
	workersPushEvery = 100 * time.Millisecond
	t.Cleanup(func() { workersPushEvery = oldPush })

	h := newFleetHarness(t)
	const every = 150 * time.Millisecond
	parentHome, childHome := t.TempDir(), t.TempDir()
	installFakeFleetControl(t, py, bin, parentHome, "fleet-m5", "verkyyi/claude-fleet")
	installFakeFleetControl(t, py, bin, childHome, "fleet-m4", "verkyyi/claude-fleet")
	// The child's machine: its issue-42 window carries the parent's worker_id
	// as @origin_wid (the inventory's last column, issue #1423) once we know it.
	adapter := filepath.Join(childHome, ".claude", "fleet", "bin", "fleet-control-read.sh")
	b, _ := os.ReadFile(adapter)
	b = []byte(strings.Replace(string(b),
		`workers) printf '@1\t42\t\t/w/x-issue-42\tworking\tclaude\tw1\t\t\n@2\t\t1\t/w/x-scratch-3\tidle\tclaude\tw2\t\t\n' ;;`,
		`workers) printf '@1\t42\t\t/w/x-issue-42\tworking\tclaude\tw1\t\t\tissue-42\t%s\n' "$(cat `+shQuote(filepath.Join(childHome, "origin"))+` 2>/dev/null)" ;;`, 1))
	if err := os.WriteFile(adapter, b, 0o755); err != nil {
		t.Fatal(err)
	}
	installFakeHubNode(t, parentHome)
	installFakeHubNode(t, childHome)

	parentTok, childTok := h.enroll(t, "m5"), h.enroll(t, "m4")
	stopParent := startRelayAgent(t, h, "m5", parentHome, parentTok, every)
	startRelayAgent(t, h, "m4", childHome, childTok, every)

	var parentFleet, childFleet string
	waitFor(t, 10*time.Second, "both fleets registered", func() bool {
		for _, f := range getFleet(t, h, "/v1/fleet/fleet_list", 200)["fleets"].([]any) {
			f := f.(map[string]any)
			switch f["endpoint_id"] {
			case "ep_m5":
				parentFleet = f["fleet_id"].(string)
			case "ep_m4":
				childFleet = f["fleet_id"].(string)
			}
		}
		return parentFleet != "" && childFleet != ""
	})
	parentWID, childWID := parentFleet+"/issue-42", childFleet+"/issue-42"
	if err := os.WriteFile(filepath.Join(childHome, "origin"), []byte(parentWID), 0o644); err != nil {
		t.Fatal(err)
	}

	// The map: the parent's machine learns its child runs elsewhere, and whose.
	parentMap := filepath.Join(parentHome, "hub-workers.tsv")
	waitFor(t, 10*time.Second, "the parent's map to list the remote child with its parent", func() bool {
		for _, l := range lines(parentMap) {
			if f := strings.Split(l, "\t"); len(f) == 3 && f[0] == childWID && f[1] != "" && f[2] == parentWID {
				return true
			}
		}
		return false
	})

	// A report, sent twice (the outbox's resend): applied once.
	childOutbox := filepath.Join(childHome, "outbox")
	report := control.Relay{ID: childWID + "#1700000000.1", Kind: control.RelayChildReport, From: childWID, To: parentWID,
		Payload: json.RawMessage(`{"child":"issue-42","state":"MERGED","pr":"7","tier":"quiet","msg":"[child-report] issue #42"}`)}
	f1 := dropRelay(t, childOutbox, "20260101T000000Z-1-a.json", report)
	delivered := filepath.Join(parentHome, "delivered")
	waitFor(t, 10*time.Second, "the report applied on the parent's machine", func() bool { return len(lines(delivered)) == 1 })
	waitFor(t, 5*time.Second, "the child's outbox file settled", func() bool { return gone(f1) })
	var got control.Relay
	if err := json.Unmarshal([]byte(lines(delivered)[0]), &got); err != nil || got.ID != report.ID || got.From != childWID ||
		got.To != parentWID || got.FromNode == "" || !strings.Contains(string(got.Payload), `"MERGED"`) {
		t.Fatalf("delivered %q (%v); want the report, from %s, with the hub naming the sender's machine", lines(delivered)[0], err, childWID)
	}
	waitFor(t, 5*time.Second, "the relay recorded delivered", func() bool {
		r, err := h.srv.Store.FleetRelay(report.ID)
		return err == nil && r.Status == store.RelayDelivered
	})
	f2 := dropRelay(t, childOutbox, "20260101T000001Z-1-b.json", report)
	waitFor(t, 5*time.Second, "the duplicate acked", func() bool { return gone(f2) })
	time.Sleep(4 * every)
	if n := len(lines(delivered)); n != 1 {
		t.Fatalf("a resent report was applied %d times; want once", n)
	}

	// The parent's machine is offline: the hub keeps it, and delivers on return.
	stopParent()
	report2 := report
	report2.ID = childWID + "#1700000001.2"
	f3 := dropRelay(t, childOutbox, "20260101T000002Z-1-c.json", report2)
	waitFor(t, 5*time.Second, "the hub stores it while the parent is away", func() bool {
		r, err := h.srv.Store.FleetRelay(report2.ID)
		return gone(f3) && err == nil && r.Status == store.RelayPending
	})
	startRelayAgent(t, h, "m5-again", parentHome, parentTok, every)
	waitFor(t, 10*time.Second, "the waiting report delivered on reconnect", func() bool { return len(lines(delivered)) == 2 })

	// A node speaks only for workers it hosts: m4 cannot forge m5's.
	forged := control.Relay{ID: parentWID + "#1", Kind: control.RelayMessage, From: parentWID, To: childWID,
		Payload: json.RawMessage(`{"text":"hi"}`)}
	f4 := dropRelay(t, childOutbox, "20260101T000003Z-1-d.json", forged)
	refused := filepath.Join(childOutbox, "refused", filepath.Base(f4))
	waitFor(t, 5*time.Second, "the forged relay refused and kept aside", func() bool { return gone(f4) && !gone(refused) })
	if why, _ := os.ReadFile(refused + ".why"); !strings.Contains(string(why), "FORBIDDEN") {
		t.Fatalf("refusal reason = %q; want FORBIDDEN", why)
	}
	if _, err := h.srv.Store.FleetRelay(forged.ID); err == nil {
		t.Fatal("a refused relay was stored")
	}
}

// A relay the target cannot apply right now (75) stays pending and is pushed
// again; one it refuses (any other exit) fails for good. Driven by hand on the
// hub side, so the timing is the test's.
func TestRelayRetryAndRefusal(t *testing.T) {
	oldResend := relayResendAfter
	relayResendAfter = 50 * time.Millisecond
	t.Cleanup(func() { relayResendAfter = oldResend })
	h := newFleetHarness(t)
	parent := fakeFleet(t, machineA, "fleet-a", "verkyyi/claude-fleet", "/a", 1)
	child := fakeFleet(t, machineB, "fleet-b", "verkyyi/claude-fleet", "/b", 2)

	// Two hand-driven relay nodes.
	connect := func(label string) *fakeNode {
		c := dialNode(t, h, h.enroll(t, label))
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		m, _ := control.New(control.TypeHello, control.Hello{HeartbeatMS: 60000, AgentVersion: "test",
			Capabilities: []string{control.CapRead, control.CapWrite, control.CapRelay}})
		if err := wsjson.Write(ctx, c, m); err != nil {
			t.Fatal(err)
		}
		var reply control.Message
		if err := wsjson.Read(ctx, c, &reply); err != nil || reply.Type != control.TypeWelcome {
			t.Fatalf("hello: %v %+v", err, reply)
		}
		return &fakeNode{t: t, conn: c}
	}
	pn, cn := connect("a"), connect("b")
	pn.beat("m5", "op", machineA, parent)
	cn.beat("m4", "op", machineB, child)
	var pfid, cfid string
	waitFor(t, 5*time.Second, "fleets registered", func() bool {
		rows, _ := h.srv.Store.Fleets()
		for _, r := range rows {
			if r.EndpointID == "ep_a" {
				pfid = r.FleetID
			}
			if r.EndpointID == "ep_b" {
				cfid = r.FleetID
			}
		}
		return pfid != "" && cfid != ""
	})
	pw, cw := pfid+"/issue-1", cfid+"/issue-2"

	// The parent node answers: first "not now", then refuses outright.
	answers := make(chan control.Message, 16)
	go func() {
		for {
			var m control.Message
			if err := wsjson.Read(context.Background(), pn.conn, &m); err != nil {
				return
			}
			if m.Type == control.TypeRelay {
				answers <- m
			}
		}
	}()
	acks := make(chan control.Message, 16)
	go func() {
		for {
			var m control.Message
			if err := wsjson.Read(context.Background(), cn.conn, &m); err != nil {
				return
			}
			if m.Type == control.TypeAck || m.Type == control.TypeError {
				acks <- m
			}
		}
	}()
	send := func(id string) {
		m, _ := control.New(control.TypeRelay, control.Relay{ID: id, Kind: control.RelayChildReport, From: cw, To: pw,
			Payload: json.RawMessage(`{"child":"issue-2","state":"BLOCKED"}`)})
		m.OpID = id
		if err := wsjson.Write(context.Background(), cn.conn, m); err != nil {
			t.Fatal(err)
		}
	}
	answer := func(m control.Message, res control.RelayResult) {
		out, _ := control.New(control.TypeRelayResult, res)
		out.OpID = m.OpID
		if err := wsjson.Write(context.Background(), pn.conn, out); err != nil {
			t.Fatal(err)
		}
	}
	next := func(ch chan control.Message, what string) control.Message {
		select {
		case m := <-ch:
			return m
		case <-time.After(5 * time.Second):
			t.Fatalf("timed out waiting for %s", what)
		}
		return control.Message{}
	}

	id := cw + "#9"
	send(id)
	if a := next(acks, "the hub's ack"); a.Type != control.TypeAck || a.OpID != id {
		t.Fatalf("sender got %+v; want an ack of %s", a, id)
	}
	m := next(answers, "the first push")
	answer(m, control.RelayResult{ID: id, Retry: true, Detail: "busy"})
	time.Sleep(100 * time.Millisecond)
	pn.beat("m5", "op", machineA, parent) // a beat is what re-pushes a stale one
	m = next(answers, "the push after a retry")
	if m.OpID != id {
		t.Fatalf("re-pushed %s; want %s", m.OpID, id)
	}
	answer(m, control.RelayResult{ID: id, Detail: "no such parent here"})
	waitFor(t, 5*time.Second, "the relay failed for good", func() bool {
		r, err := h.srv.Store.FleetRelay(id)
		return err == nil && r.Status == store.RelayFailed && r.Detail == "no such parent here" && r.Attempts == 2
	})

	// A relay to a fleet nobody has, and one with an id not scoped to its
	// sender, are refused at the door.
	for _, bad := range []control.Relay{
		{ID: cw + "#x", Kind: control.RelayMessage, From: cw, To: "33333333-3333-4333-8333-333333333333/issue-1", Payload: json.RawMessage(`{"text":"x"}`)},
		{ID: "someone-else#1", Kind: control.RelayMessage, From: cw, To: pw, Payload: json.RawMessage(`{"text":"x"}`)},
		{ID: cw + "#y", Kind: "shell", From: cw, To: pw, Payload: json.RawMessage(`{}`)},
	} {
		m, _ := control.New(control.TypeRelay, bad)
		m.OpID = bad.ID
		if err := wsjson.Write(context.Background(), cn.conn, m); err != nil {
			t.Fatal(err)
		}
		if a := next(acks, "a refusal"); a.Type != control.TypeError || a.OpID != bad.ID {
			t.Fatalf("relay %+v answered %+v; want a refusal", bad, a)
		}
	}
}

// Relays stay between one owner's logins: with admins named, an operator
// login cannot relay to a colleague's, and the map it gets lists only the
// operator's own workers.
func TestRelayOwnerBoundary(t *testing.T) {
	h := newFleetHarness(t)
	h.srv.FleetAdmins = []string{"op"}
	op := store.FleetRow{EndpointID: "e1", Hostname: "m5", OSUser: "op"}
	op2 := store.FleetRow{EndpointID: "e2", Hostname: "m4", OSUser: "op"}
	colleague := store.FleetRow{EndpointID: "e3", Hostname: "m4", OSUser: "zhang"}
	o := func(r store.FleetRow) string { return h.srv.relayOwner(r.EndpointID, r.Hostname, r.OSUser, nil) }
	if o(op) != o(op2) {
		t.Fatalf("the operator's two logins are different owners: %s vs %s", o(op), o(op2))
	}
	if o(op) == o(colleague) {
		t.Fatal("a colleague's login shares the operator's owner")
	}
	accts := []store.FleetAccount{{PrincipalID: "p1", Hostname: "m4", Login: "zhang", State: store.AccountActive},
		{PrincipalID: "p1", Hostname: "m5", Login: "zhang2", State: store.AccountActive}}
	if a, b := h.srv.relayOwner("e3", "m4", "zhang", accts), h.srv.relayOwner("e4", "m5", "zhang2", accts); a != b || a != "person:p1" {
		t.Fatalf("one person's two logins = %s / %s; want both person:p1", a, b)
	}
	if h.srv.relayOwner("e5", "m5", "lee", accts) != "endpoint:e5" {
		t.Fatal("an unassigned login must be its own owner")
	}
	// No admins named: a one-operator hub, every login the operator's.
	h.srv.FleetAdmins = nil
	if o(op) != o(colleague) {
		t.Fatal("with no admins named every login is the operator's")
	}
}
