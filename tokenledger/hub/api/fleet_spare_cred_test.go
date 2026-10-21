package api

import (
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

// claude-fleet NKTP: a spare is a principal the hub mints, so strict mode's
// «no list» denied its readiness check every subscription. Inside its own
// create / reset it has fleet.spare.cred_allow ("*" by default); nowhere else.

// setNow writes a setting without setHubSetting's EnsureNodes, which (like a
// hub restart) turns an op in flight unknown.
func setNow(t *testing.T, h *harness, key, value string) {
	t.Helper()
	if err := h.srv.Store.SetFleetSetting(key, value, time.Now()); err != nil {
		t.Fatal(err)
	}
}

// sentSpare queues a spare on mac-c and sends its create at sent.
func sentSpare(t *testing.T, h *harness, sent time.Time) *store.FleetAccount {
	t.Helper()
	spare, err := h.srv.Store.CreateSpare("mac-c", func(string) bool { return true }, sent.Add(-time.Second))
	if err != nil {
		t.Fatal(err)
	}
	if ok, err := h.srv.Store.MarkAccountSent(spare.PrincipalID, "mac-c", store.AccountPending, store.AccountCreating, "op-sp", "ep_admin-mac-c", sent); err != nil || !ok {
		t.Fatalf("send create: %v %v", ok, err)
	}
	return spare
}

func TestSpareLeasesInsideItsOwnOpInStrictMode(t *testing.T) {
	h, _, _ := policyRig(t)
	setHubSetting(t, h.srv, CredPolicyModeKey, "strict")
	setHubSetting(t, h.srv, credNodeKey("mac-c"), `"*"`) // the machine half is not this test's
	enrollAs(t, h, "admin-mac-c", "mac-c", "admin")
	spare := sentSpare(t, h, time.Now().Add(-5*time.Second))
	tok := enrollAs(t, h, "spare-mac-c", "mac-c", spare.Login)

	got, withdrawn, resp := leased(t, h, tok)
	if resp.PrincipalID != spare.PrincipalID {
		t.Fatalf("principal %q, want %q", resp.PrincipalID, spare.PrincipalID)
	}
	if !strings.Contains(strings.Join(got, ","), "claude/gmail") {
		t.Fatalf("a spare inside its create: got %v withdrawn %v (%+v), want the pool", got, withdrawn, resp.Withdrawn)
	}
	for _, w := range resp.Withdrawn {
		if strings.Contains(w.Error, "has no allowlist") {
			t.Fatalf("still the strict-mode refusal: %+v", w)
		}
	}

	// []: none — the check fails, as before.
	setNow(t, h, SpareCredAllowKey, "[]")
	if got, _, _ := leased(t, h, tok); strings.Contains(strings.Join(got, ","), "claude/") {
		t.Fatalf("[]: got %v, want no claude subscription", got)
	}
	// A list: only its entries.
	setNow(t, h, SpareCredAllowKey, `["`+uuidGmail+`"]`)
	if got, _, _ := leased(t, h, tok); !strings.Contains(strings.Join(got, ","), "claude/gmail") || strings.Contains(strings.Join(got, ","), "claude/icloud") {
		t.Fatalf("a list: got %v, want gmail only", got)
	}
	// A list written for the spare itself wins.
	setNow(t, h, SpareCredAllowKey, `"*"`)
	setNow(t, h, credUserKey(spare.PrincipalID), `["`+uuidICloud+`"]`)
	if got, _, _ := leased(t, h, tok); strings.Contains(strings.Join(got, ","), "claude/gmail") {
		t.Fatalf("the spare's own list: got %v, want icloud only", got)
	}
}

func TestSpareAllowanceOnlyWhileItsOpIsInFlight(t *testing.T) {
	user := func(h *harness, pid string) credAllow {
		t.Helper()
		pol, err := h.srv.credPolicyFor("", pid)
		if err != nil {
			t.Fatal(err)
		}
		return pol.User
	}
	denied := func(a credAllow) bool { return a.Set && !a.All }

	// In flight: "*".
	h, _, _ := policyRig(t)
	setHubSetting(t, h.srv, CredPolicyModeKey, "strict")
	spare := sentSpare(t, h, time.Now().Add(-5*time.Second))
	if a := user(h, spare.PrincipalID); !a.All {
		t.Fatalf("in flight: %+v, want \"*\"", a)
	}
	// Ready (the op answered): nothing — an idle spare holds no subscription.
	if ok, err := h.srv.Store.FinishAccountOp("op-sp", "ep_admin-mac-c", store.AccountActive, "", time.Now()); err != nil || !ok {
		t.Fatalf("finish: %v %v", ok, err)
	}
	if a := user(h, spare.PrincipalID); !denied(a) {
		t.Fatalf("a ready spare: %+v, want denied", a)
	}
	// Claimed: the person's principal and the person's rules (strict: none).
	acct, err := h.srv.Store.ClaimSpare("mac-c", "gh:9001", "Newcomer", "test", time.Now(), false)
	if err != nil {
		t.Fatal(err)
	}
	if a := user(h, acct.PrincipalID); !denied(a) {
		t.Fatalf("the claimed spare's person: %+v, want their own (no) list", a)
	}

	// Past the op's window: nothing.
	h2, _, _ := policyRig(t)
	setHubSetting(t, h2.srv, CredPolicyModeKey, "strict")
	late := sentSpare(t, h2, time.Now().Add(-accountOpLeaseWindow-time.Minute))
	if a := user(h2, late.PrincipalID); !denied(a) {
		t.Fatalf("past the window: %+v, want denied", a)
	}

	// The link dropped (unknown) or the op failed: nothing.
	h3, _, _ := policyRig(t)
	setHubSetting(t, h3.srv, CredPolicyModeKey, "strict")
	lost := sentSpare(t, h3, time.Now().Add(-5*time.Second))
	if err := h3.srv.Store.LoseAccountOps("ep_admin-mac-c", time.Now()); err != nil {
		t.Fatal(err)
	}
	if a := user(h3, lost.PrincipalID); !denied(a) {
		t.Fatalf("an unknown op: %+v, want denied", a)
	}

	// Never a person: a person with no list in strict mode stays denied.
	if a := user(h3, pBob); !denied(a) {
		t.Fatalf("a person: %+v, want denied", a)
	}
}

// A spare whose op an agent restart cut off is retried by the hub, at most
// spareCutOffTries, instead of holding its machine's refill.
func TestSpareCutOffIsRetriedNotHeld(t *testing.T) {
	h := newFleetHarness(t)
	st := h.srv.Store
	now := time.Now()
	spare, err := st.CreateSpare("mac-c", func(string) bool { return true }, now.Add(-time.Minute))
	if err != nil {
		t.Fatal(err)
	}
	if ok, err := st.MarkAccountSent(spare.PrincipalID, "mac-c", store.AccountPending, store.AccountCreating, "op-c", "ep_admin-mac-c", now.Add(-50*time.Second)); err != nil || !ok {
		t.Fatalf("send: %v %v", ok, err)
	}
	if ok, err := st.FinishAccountOp("op-c", "ep_admin-mac-c", store.AccountActive, "", now.Add(-40*time.Second)); err != nil || !ok {
		t.Fatalf("finish: %v %v", ok, err)
	}
	state := func() string {
		t.Helper()
		a, err := st.FleetAccounts(spare.PrincipalID)
		if err != nil || len(a) == 0 {
			t.Fatalf("account: %v", err)
		}
		return a[0].State
	}
	cut := func(op string) {
		t.Helper()
		if err := st.RequestAccountReset(spare.PrincipalID, "mac-c", time.Now()); err != nil && state() != store.AccountResetPending {
			t.Fatal(err)
		}
		if ok, err := st.MarkAccountSent(spare.PrincipalID, "mac-c", store.AccountResetPending, store.AccountResetting, op, "ep_admin-mac-c", time.Now()); err != nil || !ok {
			t.Fatalf("send reset: %v %v", ok, err)
		}
		detail := "the node agent (pid 2576) " + control.AccountCutOffMark + " (started 11:28); the login exists on this machine but may be half made"
		if ok, err := st.FinishAccountOp(op, "ep_admin-mac-c", store.AccountFailed, detail, time.Now()); err != nil || !ok {
			t.Fatalf("fail reset: %v %v", ok, err)
		}
	}
	pic := func() *spareMachine {
		t.Helper()
		p, err := h.srv.sparePicture("mac-c")
		if err != nil {
			t.Fatal(err)
		}
		return p["mac-c"]
	}
	for try := 1; try <= spareCutOffTries; try++ {
		cut("op-r" + string(rune('0'+try)))
		m := pic()
		if m.Failed || m.CutOff != 1 {
			t.Fatalf("try %d: failed=%v cutoff=%d, want a retry, not a hold", try, m.Failed, m.CutOff)
		}
		if !h.srv.healCutOffSpares(m, time.Now()) || state() != store.AccountResetPending {
			t.Fatalf("try %d: state %s, want washed again (%s)", try, state(), store.AccountResetPending)
		}
	}
	// Past the tries: an ordinary failed spare, held for the operator.
	cut("op-rx")
	if m := pic(); !m.Failed || m.CutOff != 0 {
		t.Fatalf("past the tries: failed=%v cutoff=%d, want held", m.Failed, m.CutOff)
	}

	// A refusal is never retried.
	if spareCutOff(store.FleetAccount{PrincipalID: spare.PrincipalID, State: store.AccountFailed, Op: control.AccountCreate, Detail: "ready: FAIL reply"}) {
		t.Fatal("a refused create read as cut off")
	}
	// A person's row is never a spare's retry.
	if spareCutOff(store.FleetAccount{PrincipalID: pBob, State: store.AccountFailed, Op: control.AccountReset, Detail: control.AccountCutOffMark}) {
		t.Fatal("a person's wash read as a spare's cut-off")
	}
}
