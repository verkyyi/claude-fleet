package api

import (
	"context"
	"encoding/json"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket/wsjson"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

// Node-to-node relays (claude-fleet#1421, EPIC #1419 C2).

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

func gone(path string) bool { _, err := os.Stat(path); return os.IsNotExist(err) }

// A relay the target cannot apply right now (75) stays pending and is pushed
// again; one it refuses (any other exit) fails for good. Driven by hand on the
// hub side, so the timing is the test's.
func TestRelayRetryAndRefusal(t *testing.T) {
	oldResend := relayResendAfter.Get()
	relayResendAfter.Set(50 * time.Millisecond)
	t.Cleanup(func() { relayResendAfter.Set(oldResend) })
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
	pn.beat("mac-d", "op", machineA, parent)
	cn.beat("mac-c", "op", machineB, child)
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
	pn.beat("mac-d", "op", machineA, parent) // a beat is what re-pushes a stale one
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
	op := store.FleetRow{EndpointID: "e1", Hostname: "mac-d", OSUser: "op"}
	op2 := store.FleetRow{EndpointID: "e2", Hostname: "mac-c", OSUser: "op"}
	colleague := store.FleetRow{EndpointID: "e3", Hostname: "mac-c", OSUser: "zhang"}
	o := func(r store.FleetRow) string { return h.srv.relayOwner(r.EndpointID, r.Hostname, r.OSUser, nil) }
	if o(op) != o(op2) {
		t.Fatalf("the operator's two logins are different owners: %s vs %s", o(op), o(op2))
	}
	if o(op) == o(colleague) {
		t.Fatal("a colleague's login shares the operator's owner")
	}
	accts := []store.FleetAccount{{PrincipalID: "p1", Hostname: "mac-c", Login: "zhang", State: store.AccountActive},
		{PrincipalID: "p1", Hostname: "mac-d", Login: "zhang2", State: store.AccountActive}}
	if a, b := h.srv.relayOwner("e3", "mac-c", "zhang", accts), h.srv.relayOwner("e4", "mac-d", "zhang2", accts); a != b || a != "person:p1" {
		t.Fatalf("one person's two logins = %s / %s; want both person:p1", a, b)
	}
	if h.srv.relayOwner("e5", "mac-d", "lee", accts) != "endpoint:e5" {
		t.Fatal("an unassigned login must be its own owner")
	}
	// No admins named: a one-operator hub, every login the operator's.
	h.srv.FleetAdmins = nil
	if o(op) != o(colleague) {
		t.Fatal("with no admins named every login is the operator's")
	}
}

// An admin login that is also a person's account relays to that person's other
// logins (claude-fleet#3520): the orchestrator on the admin login placed a
// worker on the person's managed Linux login — /v1/node/place allows it — and
// the hub then answered NOT_FOUND to every message between the two. A
// colleague's login stays out.
func TestRelayOwnerAdminIsAlsoAPerson(t *testing.T) {
	h := newFleetHarness(t)
	h.srv.FleetAdmins = []string{"heidi"}
	accts := []store.FleetAccount{
		{PrincipalID: "p1", Hostname: "mac-e", Login: "heidi", State: store.AccountActive},
		{PrincipalID: "p1", Hostname: "linux-b", Login: "verky2", State: store.AccountActive},
		{PrincipalID: "p2", Hostname: "linux-b", Login: "zhang", State: store.AccountActive},
	}
	orch := h.srv.relayOwners("e1", "mac-e", "heidi", accts)
	worker := h.srv.relayOwners("e2", "linux-b", "verky2", accts)
	colleague := h.srv.relayOwners("e3", "linux-b", "zhang", accts)
	if !sameRelayOwner(orch, worker) {
		t.Fatalf("the person's admin login %v and their Linux login %v are different owners", orch, worker)
	}
	if sameRelayOwner(orch, colleague) || sameRelayOwner(worker, colleague) {
		t.Fatalf("a colleague's login %v shares an owner with %v / %v", colleague, orch, worker)
	}
	// Another admin login with no account stays the operator's.
	if !sameRelayOwner(orch, h.srv.relayOwners("e4", "mac-f", "heidi", accts)) {
		t.Fatal("the operator's two admin logins are different owners")
	}
}

// A relay waits for its RECIPIENT, by identity, and its sender hears what
// became of it (claude-fleet#1647): pushed once, answered "not now", it is not
// pushed again while the target fleet's inventory lacks that worker — however
// often the target node beats — and goes the beat that lists it live under its
// <fleet>/<fleet_id>. Delivered, the SENDER's node gets a receipt (OpID
// rcpt:<id>), and its answer settles it; a relay nobody takes within the TTL
// expires and the sender gets an "expired" receipt.
func TestRelayQueuedForRecipientAndReceipts(t *testing.T) {
	oldResend, oldTTL := relayResendAfter.Get(), relayTTL.Get()
	relayResendAfter.Set(50 * time.Millisecond)
	t.Cleanup(func() {
		relayResendAfter.Set(oldResend)
		relayTTL.Set(oldTTL)
	})
	h := newFleetHarness(t)
	const identity = "4b3c2d1e-0f9a-4b8c-9d7e-6f5a4b3c2d1e"
	parent := fakeFleet(t, machineA, "fleet-a", "verkyyi/claude-fleet", "/a", 1)
	child := fakeFleet(t, machineB, "fleet-b", "verkyyi/claude-fleet", "/b", 2)
	withIdentity := parent
	withIdentity.Workers = json.RawMessage(`[{"worker_id":"` + parent.FleetID + `/issue-1","key":"issue-1","window_id":"@1","issue":1,"state":"working"},` +
		`{"worker_id":"` + parent.FleetID + `/scratch-4","key":"scratch-4","window_id":"@4","state":"idle","identity":"` + identity + `"}]`)
	withIdentity.Count = 2

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
	pn.beat("mac-d", "op", machineA, parent)
	cn.beat("mac-c", "op", machineB, child)
	waitFor(t, 5*time.Second, "fleets registered", func() bool {
		_, e1 := h.srv.Store.Fleet(parent.FleetID)
		_, e2 := h.srv.Store.Fleet(child.FleetID)
		return e1 == nil && e2 == nil
	})
	to, from := parent.FleetID+"/"+identity, child.FleetID+"/issue-2"

	pushes, receipts, acks := make(chan control.Message, 16), make(chan control.Message, 16), make(chan control.Message, 16)
	go func() {
		for {
			var m control.Message
			if wsjson.Read(context.Background(), pn.conn, &m) != nil {
				return
			}
			if m.Type == control.TypeRelay {
				pushes <- m
			}
		}
	}()
	go func() {
		for {
			var m control.Message
			if wsjson.Read(context.Background(), cn.conn, &m) != nil {
				return
			}
			switch m.Type {
			case control.TypeRelay:
				receipts <- m
			case control.TypeAck, control.TypeError:
				acks <- m
			}
		}
	}()
	next := func(ch chan control.Message, what string) control.Message {
		select {
		case m := <-ch:
			return m
		case <-time.After(5 * time.Second):
			t.Fatalf("timed out waiting for %s", what)
		}
		return control.Message{}
	}
	none := func(ch chan control.Message, what string) {
		select {
		case m := <-ch:
			t.Fatalf("%s: got %+v", what, m)
		case <-time.After(300 * time.Millisecond):
		}
	}
	answer := func(n *fakeNode, m control.Message, res control.RelayResult) {
		out, _ := control.New(control.TypeRelayResult, res)
		out.OpID = m.OpID
		if err := wsjson.Write(context.Background(), n.conn, out); err != nil {
			t.Fatal(err)
		}
	}
	send := func(id string) {
		m, _ := control.New(control.TypeRelay, control.Relay{ID: id, Kind: control.RelayChildReport, From: from, To: to,
			Payload: json.RawMessage(`{"child":"issue-2","state":"MERGED"}`)})
		m.OpID = id
		if err := wsjson.Write(context.Background(), cn.conn, m); err != nil {
			t.Fatal(err)
		}
		if a := next(acks, "the hub's ack"); a.Type != control.TypeAck {
			t.Fatalf("relay %s answered %+v; want stored", id, a)
		}
	}

	id := from + "#1"
	send(id)
	answer(pn, next(pushes, "the first push"), control.RelayResult{ID: id, Retry: true, Detail: "parent not live here"})
	time.Sleep(100 * time.Millisecond)
	for i := 0; i < 3; i++ {
		pn.beat("mac-d", "op", machineA, parent) // no worker with that identity yet
	}
	none(pushes, "re-pushed while the recipient is not in the inventory")
	if r, _ := h.srv.Store.FleetRelay(id); r.Status != store.RelayPending || r.Attempts != 1 {
		t.Fatalf("relay = %s/%d attempts; want pending after one push", r.Status, r.Attempts)
	}
	none(receipts, "a receipt for a relay still pending")

	pn.beat("mac-d", "op", machineA, withIdentity) // the recipient is live, by identity
	m := next(pushes, "the push once the recipient is live")
	if m.OpID != id {
		t.Fatalf("pushed %s; want %s", m.OpID, id)
	}
	answer(pn, m, control.RelayResult{ID: id, OK: true, Detail: "reported"})
	waitFor(t, 5*time.Second, "delivered", func() bool {
		r, err := h.srv.Store.FleetRelay(id)
		return err == nil && r.Status == store.RelayDelivered && r.Receipt == store.ReceiptDue
	})
	cn.beat("mac-c", "op", machineB, child)
	rc := next(receipts, "the sender's receipt")
	var rel control.Relay
	var body control.RelayReceiptBody
	if json.Unmarshal(rc.Payload, &rel) != nil || json.Unmarshal(rel.Payload, &body) != nil ||
		rel.Kind != control.RelayReceipt || rc.OpID != control.ReceiptOpPrefix+id || rel.ID != id || rel.To != from ||
		body.RID != id || body.Status != store.RelayDelivered || body.To != to {
		t.Fatalf("receipt %+v / %+v; want delivered for %s back to %s", rel, body, id, from)
	}
	answer(cn, rc, control.RelayResult{ID: id, OK: true})
	waitFor(t, 5*time.Second, "the receipt settled", func() bool {
		r, _ := h.srv.Store.FleetRelay(id)
		return r.Receipt == store.ReceiptDone
	})
	cn.beat("mac-c", "op", machineB, child)
	none(receipts, "a settled receipt pushed again")

	// Nobody ever takes it: expired after the TTL, and the sender is told.
	id2 := from + "#2"
	send(id2)
	answer(pn, next(pushes, "the push of the second"), control.RelayResult{ID: id2, Retry: true})
	time.Sleep(50 * time.Millisecond)
	relayTTL.Set(10 * time.Millisecond)
	h.srv.relayExpiredAt.Store(0)
	cn.beat("mac-c", "op", machineB, child)
	rc = next(receipts, "the expiry receipt")
	if json.Unmarshal(rc.Payload, &rel) != nil || json.Unmarshal(rel.Payload, &body) != nil ||
		body.RID != id2 || body.Status != store.RelayExpired {
		t.Fatalf("receipt %+v; want expired for %s", body, id2)
	}
}

// A message from the person at a login (claude-fleet#1649): a shell or daemon
// with no pane sends as `<fleet UUID>/operator@<login>`. The hub takes it from
// the node that reports that fleet, under the login that fleet runs under —
// and refuses another login's name, a fleet the node does not report, and an
// operator "child report".
func TestRelayOperatorSender(t *testing.T) {
	h := newFleetHarness(t)
	fa := fakeFleet(t, machineA, "fleet-a", "verkyyi/claude-fleet", "/a", 1)
	fb := fakeFleet(t, machineB, "fleet-b", "verkyyi/claude-fleet", "/b", 2)
	connectFakeNode(t, h, "a", false).beat("mac-d", "op", machineA, fa)
	connectFakeNode(t, h, "b", false).beat("mac-c", "op", machineB, fb)
	var afid, bfid string
	waitFor(t, 5*time.Second, "fleets registered", func() bool {
		rows, _ := h.srv.Store.Fleets()
		for _, r := range rows {
			if r.EndpointID == "ep_a" {
				afid = r.FleetID
			}
			if r.EndpointID == "ep_b" {
				bfid = r.FleetID
			}
		}
		return afid != "" && bfid != ""
	})
	rel := func(kind, from string) control.Message {
		m, _ := control.New(control.TypeRelay, control.Relay{ID: from + "#1", Kind: kind, From: from,
			To: bfid + "/issue-2", Payload: json.RawMessage(`{"text":"hi"}`)})
		return m
	}
	ep := store.Endpoint{ID: "ep_a"}
	r, err := h.srv.checkRelay(ep, rel(control.RelayMessage, afid+"/operator@op"))
	if err != nil || r.FromWID != afid+"/operator@op" || r.TargetEndpoint != "ep_b" {
		t.Fatalf("operator message refused: %+v %v", r, err)
	}
	if fleetOf(r.FromWID) != afid {
		t.Fatalf("fleetOf(operator) = %q", fleetOf(r.FromWID))
	}
	bad := [][3]string{
		{"another login's name", control.RelayMessage, afid + "/operator@zhang"},
		{"an operator child report", control.RelayChildReport, afid + "/operator@op"},
	}
	for _, c := range bad {
		if _, err := h.srv.checkRelay(ep, rel(c[1], c[2])); err == nil {
			t.Errorf("%s: accepted", c[0])
		}
	}
	if _, err := h.srv.checkRelay(store.Endpoint{ID: "ep_b"}, rel(control.RelayMessage, afid+"/operator@op")); err == nil {
		t.Error("a node spoke for another node's fleet's operator")
	}
}
