package api

import (
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// claude-fleet#3504 (EPIC #3500 C12): where spares are on and the machine's
// admin can recycle, removing a person's login sends a reset; a clean,
// separated wash makes the same login a new ready spare the next person is
// handed, and the hub's own pieces of the person (node token, relay
// credential, leases, 家, unused join codes) are gone. Dirty, not separated,
// a failed run or no answer for 30 minutes ⇒ failed and never handed out.
// delete: true, spares off or an admin that cannot recycle ⇒ the old remove.

const recycleJoin = "fj_aaaaaaaaaaaaaaaaaaaaaaaaaa"

// recycleFleet is m8, one admin that separates credentials and recycles. It
// is 维护中, so the refill opens no spare of its own there (a recycle needs no
// fitness) and every op its admin is sent is one the test made.
func recycleFleet(t *testing.T, h *harness, caps ...string) *fleetNode {
	t.Helper()
	h.srv.FleetAdmins = []string{"bob"}
	if caps == nil {
		caps = []string{control.CapCredsep, control.CapRecycle}
	}
	n := connectCaps(t, h, "m8-op", "m8", "bob", true, caps...)
	if _, _, err := h.srv.enterMaintenance("m8", "test", "test", time.Now()); err != nil {
		t.Fatal(err)
	}
	return n
}

// openLogin opens person's own login on m8 through a create and answers it.
func openLogin(t *testing.T, h *harness, admin *fleetNode, person, login string) {
	t.Helper()
	if _, err := h.srv.Store.AdoptPrincipal(person, login, login, time.Now()); err != nil {
		t.Fatal(err)
	}
	code, out := h.post(t, "/v1/fleet/accounts", FleetAccountRequest{Action: "assign", PrincipalID: person, Hostname: "m8", OwnName: true})
	if code != http.StatusOK {
		t.Fatalf("assign: HTTP %d %v", code, out)
	}
	m, op := expectAccountOp(t, admin.tnode)
	if op.Op != control.AccountCreate || op.Login != login {
		t.Fatalf("op = %+v; want the create of %s", op, login)
	}
	sendResult(t, admin.c, m.OpID, control.AccountResult{Op: control.AccountCreate, Login: login, OK: true, Credsep: control.CredsepSeparated})
	waitState(t, h, person, "m8", store.AccountActive)
}

// plantPerson leaves on the hub what a person's login there holds: its own
// node (token, roster row, a work lease), a relay credential, the person's
// 家 on it, and a join code minted for it and never redeemed.
func plantPerson(t *testing.T, h *harness, person, login string) *fleetNode {
	t.Helper()
	now := time.Now()
	n := connectCaps(t, h, "m8-"+login, "m8", login, false)
	if err := h.srv.Store.SetFleetSetting(relayKey("m8"), login+":"+HashToken("relay-"+login)+" bob:"+HashToken("relay-admin"), now); err != nil {
		t.Fatal(err)
	}
	if _, err := h.srv.Store.SetEntryHome(store.EntryHome{Person: person, Machine: "m8", Login: login, SetBy: "test", SetAt: now}); err != nil {
		t.Fatal(err)
	}
	if err := h.srv.Store.CreateJoinCodeFor(HashToken("planted-"+login), "m8-"+login, store.NodeKindFixed, "", "", "m8", now, time.Hour); err != nil {
		t.Fatal(err)
	}
	if ok, _, _, err := h.srv.Store.AcquireLease(store.LeaseClaim{Repo: "o/r", Issue: 7, WorkerID: "w-" + login, FleetID: "f-" + login,
		EndpointID: n.id, Hostname: "m8", OSUser: login}, time.Minute, now); err != nil || !ok {
		t.Fatalf("lease: %v %v", ok, err)
	}
	time.Sleep(5 * time.Millisecond) // the remove is requested after all of it
	return n
}

// removeLogin is the operator's remove of person's login on m8.
func removeLogin(t *testing.T, h *harness, person string, del bool) {
	t.Helper()
	code, out := h.post(t, "/v1/fleet/accounts", FleetAccountRequest{Action: "remove", PrincipalID: person, Hostname: "m8", Delete: del})
	if code != http.StatusOK {
		t.Fatalf("remove: HTTP %d %v", code, out)
	}
}

func hubAuditHas(t *testing.T, h *harness, action, target string) *store.HubAuditEntry {
	t.Helper()
	log, err := h.srv.Store.HubAuditLog(100)
	if err != nil {
		t.Fatal(err)
	}
	for i := range log {
		if log[i].Action == action && log[i].Target == target {
			return &log[i]
		}
	}
	return nil
}

func TestRemoveRecyclesLoginIntoSpare(t *testing.T) {
	h := newFleetHarness(t)
	enablePeople(t, h)
	admin := recycleFleet(t, h)
	sparesOn(t, h, "2")
	const p, login = "gh:7001", "zhangsan"
	openLogin(t, h, admin, p, login)
	person := plantPerson(t, h, p, login)
	cutoff := time.Now()

	removeLogin(t, h, p, false)
	m, op := expectAccountOp(t, admin.tnode)
	if op.Op != control.AccountReset || op.Login != login || op.JoinCode == "" {
		t.Fatalf("op = %+v; want a reset of %s with a fresh join code", op, login)
	}
	if a := accountState(t, h, p, "m8"); a.State != store.AccountResetting || a.Op != control.AccountReset {
		t.Fatalf("row = %+v; want resetting", a)
	}

	// The hub's half went before the wash started.
	if ep, err := h.srv.Store.EndpointByID(person.id); err != nil || ep.RetiredAt == nil {
		t.Fatalf("the person's node %s = %+v, %v; want retired", person.id, ep, err)
	}
	settings, _ := h.srv.Store.FleetSettings()
	if e := relayEntries(settings[relayKey("m8")]); e[login] != "" || e["bob"] == "" {
		t.Fatalf("relay entries = %v; want %s's gone, the admin's kept", e, login)
	}
	if _, ok, _ := h.srv.Store.EntryHomeOf(p); ok {
		t.Fatalf("the person's 家 is still %s@m8", login)
	}
	if n, err := h.srv.Store.LiveJoinCodes("m8-"+login, "m8", cutoff, time.Now()); err != nil || n != 0 {
		t.Fatalf("live join codes from before = %d, %v; want 0", n, err)
	}
	if ls, _ := h.srv.Store.Leases(time.Now()); len(ls) != 0 {
		t.Fatalf("leases = %+v; want the person's released", ls)
	}

	sendResult(t, admin.c, m.OpID, control.AccountResult{Op: control.AccountReset, Login: login, OK: true,
		Reset: control.ResetClean, Credsep: control.CredsepSeparated})
	waitFor(t, 3*time.Second, "the recycled spare to be ready", func() bool {
		return h.srv.spareReadyHosts()["m8"] == 1
	})
	if a := accountState(t, h, p, "m8"); a.State != "" {
		t.Fatalf("the person still has %+v on m8", a)
	}
	var sp store.FleetAccount
	for _, a := range mustSpares(t, h) {
		if a.Hostname == "m8" {
			sp = a
		}
	}
	if sp.Login != login || sp.State != store.AccountActive || !strings.HasPrefix(sp.PrincipalID, "spare:m8:") {
		t.Fatalf("spare = %+v; want %s active under a new spare:m8:<nonce>", sp, login)
	}
	if e := hubAuditHas(t, h, "spare.recycle", login); e == nil || !strings.Contains(e.Detail, p) || !strings.Contains(e.Detail, store.AccountActive) {
		t.Fatalf("audit spare.recycle = %+v; want one line from %s to an active spare", e, p)
	}
	if pr, err := h.srv.Store.Principal(p); err != nil || pr.Login != login {
		t.Fatalf("the person's record = %+v, %v; want kept", pr, err)
	}

	// The next person is handed it — their record is made under a name of
	// their own, since the last person's record still holds it.
	const q = "gh:7002"
	a := assignAccount(t, h, FleetAccountRequest{PrincipalID: q, Hostname: "m8", DisplayName: "LiSi"})
	if a.State != store.AccountActive || a.Login != login {
		t.Fatalf("next person's row = %+v; want %s active at once", a, login)
	}
	if pr, err := h.srv.Store.Principal(q); err != nil || pr.Login == login {
		t.Fatalf("next person's record = %+v, %v; want a name of their own", pr, err)
	}
}

func TestRecycleNeverHandsOutAnUncleanWash(t *testing.T) {
	h := newFleetHarness(t)
	enablePeople(t, h)
	admin := recycleFleet(t, h)
	sparesOn(t, h, "2")
	for i, c := range []struct {
		name string
		res  control.AccountResult
		want string
	}{
		{"dirty", control.AccountResult{OK: true, Reset: "dirty home,crontab", Credsep: control.CredsepSeparated}, "reset: dirty home,crontab"},
		{"not separated", control.AccountResult{OK: true, Reset: control.ResetClean, Credsep: "pending"}, "without credential separation"},
		{"no verdict", control.AccountResult{OK: true, Credsep: control.CredsepSeparated}, "reset: no verdict"},
		{"failed run", control.AccountResult{OK: false, Exit: 1, Reset: control.ResetClean, Credsep: control.CredsepSeparated}, "reset failed (exit 1)"},
	} {
		t.Run(c.name, func(t *testing.T) {
			p, login := "gh:72"+string(rune('0'+i)), "wash"+string(rune('a'+i))
			openLogin(t, h, admin, p, login)
			removeLogin(t, h, p, false)
			m, op := expectAccountOp(t, admin.tnode)
			if op.Op != control.AccountReset {
				t.Fatalf("op = %+v; want a reset", op)
			}
			c.res.Op, c.res.Login = control.AccountReset, login
			sendResult(t, admin.c, m.OpID, c.res)
			a := waitState(t, h, p, "m8", store.AccountFailed)
			if !strings.Contains(a.Detail, c.want) || !strings.Contains(a.Detail, "not handed out") {
				t.Fatalf("detail = %q; want %q and «not handed out»", a.Detail, c.want)
			}
			for _, sp := range mustSpares(t, h) {
				if sp.Login == login {
					t.Fatalf("an unclean wash became a spare: %+v", sp)
				}
			}
			if hubAuditHas(t, h, "spare.recycle", login) != nil {
				t.Fatal("an unclean wash was audited as recycled")
			}
		})
	}
}

// The hub's own check (BREAK-IT spare-recycle-dirty): each of the person's
// hub-side pieces is named while it is there, none once recycleClear ran — and
// the node the wash's own join code enrolls is never one of them.
func TestRecycleLeftoversNamesEachHubPiece(t *testing.T) {
	h := newFleetHarness(t)
	enablePeople(t, h)
	recycleFleet(t, h)
	const p, login = "gh:7301", "leftover"
	plantPerson(t, h, p, login)
	a := store.FleetAccount{PrincipalID: p, Hostname: "m8", Login: login, Op: control.AccountReset, RequestedAt: time.Now()}
	time.Sleep(5 * time.Millisecond)
	connectCaps(t, h, "m8-"+login+"-new", "m8", login, false) // the spare's own node, after the request
	if got := strings.Join(h.srv.recycleLeftovers(a, time.Now()), ","); got != "node-token,lease,home,join-code" {
		t.Fatalf("leftovers = %q; want node-token,lease,home,join-code", got)
	}
	h.srv.recycleClear(a, time.Now())
	if got := h.srv.recycleLeftovers(a, time.Now()); len(got) != 0 {
		t.Fatalf("leftovers after the clear = %v; want none", got)
	}
	if ep, err := h.srv.Store.EndpointByID("ep_m8-" + login + "-new"); err != nil || ep.RetiredAt != nil {
		t.Fatalf("the spare's own node = %+v, %v; want it left live", ep, err)
	}
}

// What comes back while the wash runs (a 家 written again, a code minted
// earlier) is cleared once more before the spare is recorded.
func TestRecycleClearsWhatCameBackDuringTheWash(t *testing.T) {
	h := newFleetHarness(t)
	enablePeople(t, h)
	admin := recycleFleet(t, h)
	sparesOn(t, h, "2")
	const p, login = "gh:7311", "cameback"
	openLogin(t, h, admin, p, login)
	removeLogin(t, h, p, false)
	m, _ := expectAccountOp(t, admin.tnode)
	if _, err := h.srv.Store.SetEntryHome(store.EntryHome{Person: p, Machine: "m8", Login: login, SetBy: "test", SetAt: time.Now()}); err != nil {
		t.Fatal(err)
	}
	if err := h.srv.Store.CreateJoinCodeFor(HashToken("late"), "m8-"+login, store.NodeKindFixed, "", "", "m8",
		time.Now().Add(-time.Hour), 2*time.Hour); err != nil {
		t.Fatal(err)
	}
	sendResult(t, admin.c, m.OpID, control.AccountResult{Op: control.AccountReset, Login: login, OK: true,
		Reset: control.ResetClean, Credsep: control.CredsepSeparated})
	waitFor(t, 3*time.Second, "the recycled spare to be ready", func() bool {
		return h.srv.spareReadyHosts()["m8"] == 1
	})
	if _, ok, _ := h.srv.Store.EntryHomeOf(p); ok {
		t.Fatal("the late 家 is still there")
	}
}

func TestRecycleNoAnswerFailsAfterThirtyMinutes(t *testing.T) {
	h := newFleetHarness(t)
	enablePeople(t, h)
	admin := recycleFleet(t, h)
	sparesOn(t, h, "2")
	const p, login = "gh:7401", "silent"
	openLogin(t, h, admin, p, login)
	removeLogin(t, h, p, false)
	if _, op := expectAccountOp(t, admin.tnode); op.Op != control.AccountReset {
		t.Fatalf("op = %+v; want a reset", op)
	}
	admin.c.CloseNow()
	waitState(t, h, p, "m8", store.AccountUnknown)
	h.srv.accountsMu.Lock()
	h.srv.reaskAccounts(time.Now().Add(accountUnknownGiveUp + time.Minute))
	h.srv.accountsMu.Unlock()
	a := waitState(t, h, p, "m8", store.AccountFailed)
	if !strings.Contains(a.Detail, "no answer") {
		t.Fatalf("detail = %q; want «no answer»", a.Detail)
	}
	for _, sp := range mustSpares(t, h) {
		if sp.Login == login {
			t.Fatalf("an unanswered wash became a spare: %+v", sp)
		}
	}
}

// The old road stays byte for byte: delete: true, spares off, and an admin
// that cannot recycle all send the remove they sent before.
func TestRemoveOldRoadWhenNotRecycling(t *testing.T) {
	for _, c := range []struct {
		name   string
		spares bool
		del    bool
		caps   []string
	}{
		{"delete", true, true, nil},
		{"spares off", false, false, nil},
		{"admin cannot recycle", true, false, []string{control.CapCredsep}},
	} {
		t.Run(c.name, func(t *testing.T) {
			h := newFleetHarness(t)
			enablePeople(t, h)
			admin := recycleFleet(t, h, c.caps...)
			if c.spares {
				sparesOn(t, h, "2")
			}
			const p, login = "gh:7501", "oldroad"
			openLogin(t, h, admin, p, login)
			removeLogin(t, h, p, c.del)
			m, op := expectAccountOp(t, admin.tnode)
			if op != (control.AccountOp{Op: control.AccountRemove, Login: login}) {
				t.Fatalf("op = %+v; want the plain remove of %s", op, login)
			}
			if a := accountState(t, h, p, "m8"); a.State != store.AccountRemoving || a.Op != control.AccountRemove {
				t.Fatalf("row = %+v; want removing", a)
			}
			sendResult(t, admin.c, m.OpID, control.AccountResult{Op: control.AccountRemove, Login: login, OK: true})
			waitState(t, h, p, "m8", store.AccountRemoved)
			if hubAuditHas(t, h, "spare.recycle", login) != nil {
				t.Fatal("the old road recycled")
			}
		})
	}
}
