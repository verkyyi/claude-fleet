package api

import (
	"net/http"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

// claude-fleet D0JC: a login's readiness check (fleet-login-ready.sh, #4673)
// leases INSIDE the create / reset that opens it, while the hub's row is still
// creating / resetting. The lease answers that op's own login — fresh, on its
// machine, inside the op's window — and nothing else.

// inflightCreate queues and sends a create of login bob on mac-c through the
// admin node ep_admin-mac-c, sent at sent.
func inflightCreate(t *testing.T, h *harness, sent time.Time) *store.Principal {
	t.Helper()
	p, err := h.srv.Store.AdoptPrincipal("bob", "bob", "Bob", time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if _, err := h.srv.Store.RequestAccount(p, "mac-c", false, sent); err != nil {
		t.Fatal(err)
	}
	if ok, err := h.srv.Store.MarkAccountSent(p.ID, "mac-c", store.AccountPending, store.AccountCreating, "op-create", "ep_admin-mac-c", sent); err != nil || !ok {
		t.Fatalf("mark sent: %v %v", ok, err)
	}
	return p
}

func TestLeaseInsideCreateOp(t *testing.T) {
	h, _, _ := newVaultHarness(t)
	admin := enrollAs(t, h, "admin-mac-c", "mac-c", "admin")
	p := inflightCreate(t, h, time.Now().Add(-5*time.Second))
	bob := enrollAs(t, h, "bob-mac-c", "mac-c", "bob") // the op's join: after the send
	if code, got, refusal := lease(t, h, bob); code != http.StatusOK || got.PrincipalID != p.ID {
		t.Fatalf("bob inside his create: %d %+v %v, want 200 as %s", code, got, refusal, p.ID)
	}
	// The op's own node never leases as the login it opens.
	if code, _, refusal := lease(t, h, admin); code != http.StatusForbidden || refusal["error"] != LeaseNoPrincipal {
		t.Fatalf("the admin node: %d %v, want 403 %s", code, refusal, LeaseNoPrincipal)
	}
	// The same login name on another machine: not this op's.
	elsewhere := enrollAs(t, h, "bob-mac-d", "mac-d", "bob")
	if code, _, refusal := lease(t, h, elsewhere); code != http.StatusForbidden || refusal["error"] != LeaseNoPrincipal {
		t.Fatalf("bob on mac-d: %d %v, want 403", code, refusal)
	}
	// Another login on the op's machine: not this op's.
	carol := enrollAs(t, h, "carol-mac-c", "mac-c", "carol")
	if code, _, refusal := lease(t, h, carol); code != http.StatusForbidden || refusal["error"] != LeaseNoPrincipal {
		t.Fatalf("carol on mac-c: %d %v, want 403", code, refusal)
	}
	// The op answered failed: the in-flight answer is gone.
	if ok, err := h.srv.Store.FinishAccountOp("op-create", "ep_admin-mac-c", store.AccountFailed, "ready: FAIL", time.Now()); err != nil || !ok {
		t.Fatalf("finish: %v %v", ok, err)
	}
	if code, _, refusal := lease(t, h, bob); code != http.StatusForbidden || refusal["error"] != LeaseNoPrincipal {
		t.Fatalf("bob after a failed create: %d %v, want 403", code, refusal)
	}
}

func TestLeaseInsideCreateOpRefusesStaleOrOld(t *testing.T) {
	// A node enrolled before the send holds no token from this op's join.
	h, _, _ := newVaultHarness(t)
	early := enrollAs(t, h, "bob-mac-c", "mac-c", "bob")
	inflightCreate(t, h, time.Now().Add(3*time.Second))
	if code, _, refusal := lease(t, h, early); code != http.StatusForbidden || refusal["error"] != LeaseNoPrincipal {
		t.Fatalf("a token from before the op: %d %v, want 403", code, refusal)
	}

	// An op sent longer ago than the window: over.
	h2, _, _ := newVaultHarness(t)
	inflightCreate(t, h2, time.Now().Add(-accountOpLeaseWindow-time.Minute))
	late := enrollAs(t, h2, "bob-mac-c", "mac-c", "bob")
	if code, _, refusal := lease(t, h2, late); code != http.StatusForbidden || refusal["error"] != LeaseNoPrincipal {
		t.Fatalf("past the op's window: %d %v, want 403", code, refusal)
	}

	// A link that dropped (unknown) is no op in flight.
	h3, _, _ := newVaultHarness(t)
	inflightCreate(t, h3, time.Now().Add(-5*time.Second))
	if err := h3.srv.Store.LoseAccountOps("ep_admin-mac-c", time.Now()); err != nil {
		t.Fatal(err)
	}
	lost := enrollAs(t, h3, "bob-mac-c", "mac-c", "bob")
	if code, _, refusal := lease(t, h3, lost); code != http.StatusForbidden || refusal["error"] != LeaseNoPrincipal {
		t.Fatalf("an op whose link dropped: %d %v, want 403", code, refusal)
	}
}

func TestLeaseInsideResetOnlyForSpare(t *testing.T) {
	h, _, _ := newVaultHarness(t)
	now := time.Now()
	spare, err := h.srv.Store.CreateSpare("mac-c", func(string) bool { return true }, now.Add(-time.Minute))
	if err != nil {
		t.Fatal(err)
	}
	st := h.srv.Store
	if ok, err := st.MarkAccountSent(spare.PrincipalID, "mac-c", store.AccountPending, store.AccountCreating, "op-c", "ep_admin-mac-c", now.Add(-50*time.Second)); err != nil || !ok {
		t.Fatalf("send create: %v %v", ok, err)
	}
	if ok, err := st.FinishAccountOp("op-c", "ep_admin-mac-c", store.AccountActive, "", now.Add(-40*time.Second)); err != nil || !ok {
		t.Fatalf("finish create: %v %v", ok, err)
	}
	if err := st.RequestAccountReset(spare.PrincipalID, "mac-c", now.Add(-30*time.Second)); err != nil {
		t.Fatal(err)
	}
	// A wash that keeps the login's node token: enrolled before the send.
	tok := enrollAs(t, h, "spare-mac-c", "mac-c", spare.Login)
	if ok, err := st.MarkAccountSent(spare.PrincipalID, "mac-c", store.AccountResetPending, store.AccountResetting, "op-r", "ep_admin-mac-c", time.Now().Add(-5*time.Second)); err != nil || !ok {
		t.Fatalf("send reset: %v %v", ok, err)
	}
	if code, got, refusal := lease(t, h, tok); code != http.StatusOK || got.PrincipalID != spare.PrincipalID {
		t.Fatalf("a spare's wash: %d %+v %v, want 200 as %s", code, got, refusal, spare.PrincipalID)
	}

	// A person's login being washed: never their credentials for the check.
	h2, _, _ := newVaultHarness(t)
	alice, err := h2.srv.Store.Principal(pAlice)
	if err != nil {
		t.Fatal(err)
	}
	if err := h2.srv.Store.RequestAccountReset(alice.ID, "mac-c", time.Now().Add(-10*time.Second)); err != nil {
		t.Fatal(err)
	}
	if ok, err := h2.srv.Store.MarkAccountSent(alice.ID, "mac-c", store.AccountResetPending, store.AccountResetting, "op-r2", "ep_admin-mac-c", time.Now().Add(-5*time.Second)); err != nil || !ok {
		t.Fatalf("send reset: %v %v", ok, err)
	}
	fresh := enrollAs(t, h2, "alice2-mac-c", "mac-c", "alice")
	if code, _, refusal := lease(t, h2, fresh); code != http.StatusForbidden || refusal["error"] != LeaseNoPrincipal {
		t.Fatalf("a person's login mid-wash: %d %v, want 403", code, refusal)
	}
}
