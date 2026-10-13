package api

import (
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// 删除下发前源机被缩掉 (claude-fleet#3957, BREAK-IT remove-pending-machine-gone):
// a remove queued for a machine that never connects again stays remove_pending,
// and a plain forget refuses it. forget --machine-gone closes it — refused while
// any link of that machine is open, never for a row whose op already landed or
// is still running — as removed, saying in the row and the audit that the home
// was NOT archived there; a plain forget then drops it.
func TestForgetMachineGoneClosesRemovePending(t *testing.T) {
	h := newFleetHarness(t)
	enablePeople(t, h, pAlice)
	if code := operatorPost(t, h, FleetAccountRequest{Action: "adopt", PrincipalID: pAlice, Hostname: "mac-g", Login: "alice"}); code != 200 {
		t.Fatalf("adopt: HTTP %d", code)
	}
	// machine_gone is not a way to drop an active login.
	if code := operatorPost(t, h, FleetAccountRequest{Action: "forget", PrincipalID: pAlice, Hostname: "mac-g", MachineGone: true}); code != http.StatusConflict {
		t.Fatalf("machine_gone on an active login: HTTP %d, want 409", code)
	}
	if code := operatorPost(t, h, FleetAccountRequest{Action: "remove", PrincipalID: pAlice, Hostname: "mac-g", Delete: true}); code != 200 {
		t.Fatalf("remove: HTTP %d", code)
	}
	// No admin of mac-g is connected: the remove stays queued.
	if a := accountState(t, h, pAlice, "mac-g"); a.State != store.AccountRemovePending {
		t.Fatalf("queued remove = %+v", a)
	}
	// The old dead end: forget refuses a remove that has not landed.
	if code := operatorPost(t, h, FleetAccountRequest{Action: "forget", PrincipalID: pAlice, Hostname: "mac-g"}); code != http.StatusConflict {
		t.Fatalf("plain forget of remove_pending: HTTP %d, want 409", code)
	}
	// A machine-wide flag needs the machine.
	if code := operatorPost(t, h, FleetAccountRequest{Action: "forget", PrincipalID: pAlice, MachineGone: true}); code != http.StatusBadRequest {
		t.Fatalf("machine_gone without a hostname: HTTP %d, want 400", code)
	}

	// A link of mac-g is open (a login's own node, not an admin): the machine
	// is not gone, so the row is not closed by hand.
	n := connectNode(t, h, "mac-g-bob", "mac-g", "bob", false)
	deadline := time.Now().Add(5 * time.Second)
	for len(h.srv.liveLinksOn("mac-g")) == 0 {
		if time.Now().After(deadline) {
			t.Fatal("mac-g's link never registered")
		}
		time.Sleep(20 * time.Millisecond)
	}
	if code := operatorPost(t, h, FleetAccountRequest{Action: "forget", PrincipalID: pAlice, Hostname: "mac-g", MachineGone: true}); code != http.StatusConflict {
		t.Fatalf("machine_gone while mac-g is connected: HTTP %d, want 409", code)
	}
	if a := accountState(t, h, pAlice, "mac-g"); a.State != store.AccountRemovePending {
		t.Fatalf("refused machine_gone changed the row: %+v", a)
	}
	n.c.Close(websocket.StatusGoingAway, "scaled to zero")
	deadline = time.Now().Add(5 * time.Second)
	for len(h.srv.liveLinksOn("mac-g")) > 0 {
		if time.Now().After(deadline) {
			t.Fatal("mac-g's link never dropped")
		}
		time.Sleep(20 * time.Millisecond)
	}

	if code := operatorPost(t, h, FleetAccountRequest{Action: "forget", PrincipalID: pAlice, Hostname: "mac-g", MachineGone: true}); code != 200 {
		t.Fatalf("machine_gone: HTTP %d", code)
	}
	a := accountState(t, h, pAlice, "mac-g")
	if a.State != store.AccountRemoved || !strings.Contains(a.Detail, "家目录未在源机归档") {
		t.Fatalf("closed row = %+v", a)
	}
	// Never silent: the audit says so, under the operator.
	log, err := h.srv.Store.HubAuditLog(20)
	if err != nil {
		t.Fatal(err)
	}
	var ok, refused int
	for _, e := range log {
		if e.Action != "account.machine_gone" || e.Target != pAlice+"@mac-g" {
			continue
		}
		switch e.Outcome {
		case "ok":
			ok++
			if !strings.Contains(e.Detail, "remove_pending → removed") || !strings.Contains(e.Detail, "家目录未在源机归档") {
				t.Fatalf("audit detail = %q", e.Detail)
			}
		case "refused":
			refused++
		}
	}
	if ok != 1 || refused != 2 {
		t.Fatalf("audit: %d ok, %d refused; want 1, 2 (%+v)", ok, refused, log)
	}
	// Once removed, the ordinary forget drops the record.
	if code := operatorPost(t, h, FleetAccountRequest{Action: "forget", PrincipalID: pAlice, Hostname: "mac-g"}); code != 200 {
		t.Fatalf("forget after machine_gone: HTTP %d", code)
	}
	if as, _ := h.srv.Store.FleetAccounts(pAlice); len(as) != 0 {
		t.Fatalf("forget left %+v", as)
	}
}

// An unknown row whose op was a remove (the link dropped with it in flight,
// then the machine went) closes the same way, saying the archive is unknown.
func TestForgetMachineGoneUnknownRemove(t *testing.T) {
	h := newFleetHarness(t)
	enablePeople(t, h, pAlice)
	if code := operatorPost(t, h, FleetAccountRequest{Action: "adopt", PrincipalID: pAlice, Hostname: "mac-g", Login: "alice"}); code != 200 {
		t.Fatalf("adopt: HTTP %d", code)
	}
	now := time.Now()
	if err := h.srv.Store.RequestAccountRemoval(pAlice, "mac-g", now); err != nil {
		t.Fatal(err)
	}
	if ok, err := h.srv.Store.MarkAccountSent(pAlice, "mac-g", store.AccountRemovePending, store.AccountUnknown, "op-x", "ep_x", now); err != nil || !ok {
		t.Fatalf("mark unknown: %v %v", ok, err)
	}
	if code := operatorPost(t, h, FleetAccountRequest{Action: "forget", PrincipalID: pAlice, Hostname: "mac-g", MachineGone: true}); code != 200 {
		t.Fatalf("machine_gone on an unknown remove: HTTP %d", code)
	}
	if a := accountState(t, h, pAlice, "mac-g"); a.State != store.AccountRemoved || !strings.Contains(a.Detail, "是否在源机归档不明") {
		t.Fatalf("closed row = %+v", a)
	}
}
