package api

import (
	"crypto/ed25519"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/model"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/release"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// The admin seat (claude-fleet#3557, EPIC #3500 C15): with an account key the
// hub prefers a machine's admin seat over the admin login's old agent and
// signs every op it sends there; without one nothing changes.

// connectSeat is connectNode for an admin agent listing CapAdminSeat.
func connectSeat(t *testing.T, h *harness, label, hostname, osUser string) *fleetNode {
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
	n.tnode = dialAdminCaps(t, h, tok, true, control.CapAdminSeat)
	beat(t, n.c, control.Proto, control.Heartbeat{Hostname: hostname, OSUser: osUser})
	return n
}

// seatRig: mac-a's admin login (the old agent) and its admin seat, both up.
func seatRig(t *testing.T, key ed25519.PrivateKey) (*harness, *fleetNode, *fleetNode) {
	t.Helper()
	h := newFleetHarness(t)
	h.srv.FleetAdmins = []string{"bob", "_fleetadmin"}
	h.srv.SetAccountKey(key)
	old := connectNode(t, h, "maca-op", "mac-a", "bob", true)
	seat := connectSeat(t, h, "maca-seat", "mac-a", "_fleetadmin")
	waitFor(t, 3*time.Second, "both admin links named mac-a", func() bool {
		named := 0
		h.srv.nodes.each(func(_ string, c *nodeConn) {
			if c.hostname() == "mac-a" {
				named++
			}
		})
		return named == 2
	})
	return h, old, seat
}

func testAccountKey() ed25519.PrivateKey {
	seed := make([]byte, ed25519.SeedSize)
	for i := range seed {
		seed[i] = byte(7 * i)
	}
	return ed25519.NewKeyFromSeed(seed)
}

// 怎么算成功: the seat gets the create and the remove, each with a ticket the
// key signed for exactly that op, login, machine and op_id; the old agent of
// the admin login is sent nothing new.
func TestAccountTicketSeatGetsSignedOps(t *testing.T) {
	key := testAccountKey()
	pub := key.Public().(ed25519.PublicKey)
	h, old, seat := seatRig(t, key)
	if id, _ := h.srv.nodes.openerFor("mac-a"); id != seat.id {
		t.Fatalf("mac-a's opener is %q; want the seat %q", id, seat.id)
	}
	check := func(m control.Message, op control.AccountOp, kind string) {
		t.Helper()
		tk, err := control.VerifyAccountTicket(pub, op.Ticket, time.Now())
		if err != nil {
			t.Fatalf("%s: ticket %q: %v", kind, op.Ticket, err)
		}
		if tk.Op != kind || tk.Login != op.Login || tk.Machine != "mac-a" || tk.Nonce != m.OpID {
			t.Fatalf("%s: ticket %+v for op %+v (op_id %s)", kind, tk, op, m.OpID)
		}
		if exp := time.Unix(tk.Exp, 0); exp.After(time.Now().Add(control.AccountTicketTTL + time.Minute)) {
			t.Fatalf("%s: ticket good until %v", kind, exp)
		}
	}
	if code := operatorPost(t, h, FleetAccountRequest{Action: "assign", PrincipalID: "WangXiaoMing", Hostname: "mac-a"}); code != 200 {
		t.Fatalf("assign: HTTP %d", code)
	}
	m, op := expectAccountOp(t, seat.tnode)
	check(m, op, control.AccountCreate)
	if got, ok := readMsg(old.tnode, 300*time.Millisecond); ok && got.Type == control.TypeAccountOp {
		t.Fatalf("the admin login's old agent was sent %+v", got)
	}
	sendResult(t, seat.c, m.OpID, control.AccountResult{Op: control.AccountCreate, Login: op.Login, OK: true})
	waitState(t, h, "WangXiaoMing", "mac-a", store.AccountActive)

	if code := operatorPost(t, h, FleetAccountRequest{Action: "remove", PrincipalID: "WangXiaoMing", Hostname: "mac-a"}); code != 200 {
		t.Fatalf("remove: HTTP %d", code)
	}
	m, op = expectAccountOp(t, seat.tnode)
	check(m, op, control.AccountRemove)
}

// The seat gone, the old agent takes the next op again — unsigned, as before.
func TestAccountTicketFallsBackToTheAdminLogin(t *testing.T) {
	h, old, seat := seatRig(t, testAccountKey())
	_ = seat.c.CloseNow()
	waitFor(t, 3*time.Second, "the seat's link gone", func() bool {
		id, _ := h.srv.nodes.openerFor("mac-a")
		return id == old.id
	})
	if code := operatorPost(t, h, FleetAccountRequest{Action: "assign", PrincipalID: "WangXiaoMing", Hostname: "mac-a"}); code != 200 {
		t.Fatalf("assign: HTTP %d", code)
	}
	if _, op := expectAccountOp(t, old.tnode); op.Ticket != "" {
		t.Fatalf("the admin login's agent was sent a ticket: %+v", op)
	}
}

// 共同约定 10/11: a hub with no account key signs nothing, never picks a seat
// (it would refuse every op) and serves no key — the admin login's agent gets
// the op exactly as before.
func TestAccountTicketOffAddsNothing(t *testing.T) {
	h, old, seat := seatRig(t, nil)
	if id, _ := h.srv.nodes.openerFor("mac-a"); id != old.id {
		t.Fatalf("mac-a's opener is %q with no key; want the admin login %q", id, old.id)
	}
	if code := operatorPost(t, h, FleetAccountRequest{Action: "assign", PrincipalID: "WangXiaoMing", Hostname: "mac-a"}); code != 200 {
		t.Fatalf("assign: HTTP %d", code)
	}
	if _, op := expectAccountOp(t, old.tnode); op.Ticket != "" {
		t.Fatalf("an op carries a ticket with no key: %+v", op)
	}
	if got, ok := readMsg(seat.tnode, 300*time.Millisecond); ok && got.Type == control.TypeAccountOp {
		t.Fatalf("the seat was sent %+v with no key", got)
	}
	resp, err := http.Get(h.http.URL + control.AccountKeyPath)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusNotFound {
		t.Fatalf("GET %s with no key = %d; want 404", control.AccountKeyPath, resp.StatusCode)
	}
}

// The key a machine's root installer pins is served publicly, in the release
// key's one-line form.
func TestAccountKeyServed(t *testing.T) {
	key := testAccountKey()
	h := newFleetHarness(t)
	h.srv.SetAccountKey(key)
	resp, err := http.Get(h.http.URL + control.AccountKeyPath)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	want := release.FormatPublicKey(key.Public().(ed25519.PublicKey))
	if resp.StatusCode != http.StatusOK || strings.TrimSpace(string(b)) != want {
		t.Fatalf("GET %s = %d %q; want 200 %q", control.AccountKeyPath, resp.StatusCode, b, want)
	}
}
