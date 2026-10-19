package api

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"

	"golang.org/x/crypto/ssh"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/sshca"
)

// claude-fleet#3509 (EPIC #3500 R3): a machine or cluster whose spares have
// been 0 for 30 minutes, or that holds a spare made or washed badly, is one
// alert (fleet_alerts + one hub_audit spare.alert line) — once a day per
// place and reason, cleared when it is over. And (#2947) a drill identity
// takes a Mac's spare and gives it back washed when it deletes itself.

// spareAlertRows is every (kind, subject) row, open or cleared.
func spareAlertRows(t *testing.T, h *harness, kind, subject string) (open, all int) {
	t.Helper()
	rows, err := h.srv.Store.FleetAlerts(500)
	if err != nil {
		t.Fatal(err)
	}
	for _, a := range rows {
		if a.Kind == kind && a.Subject == subject {
			all++
			if a.ClearedAt == nil {
				open++
			}
		}
	}
	return open, all
}

// spareTick is one alert pass at now, past the pace.
func spareTick(h *harness, since, now time.Time) {
	h.srv.spareAlertMu.Lock()
	h.srv.spareAlertAt = time.Time{}
	h.srv.spareAlertMu.Unlock()
	h.srv.SpareAlertTick(since, now)
}

// backdateEmpty moves every place's 「empty since」 back by d.
func backdateEmpty(h *harness, d time.Duration) {
	h.srv.spareAlertMu.Lock()
	defer h.srv.spareAlertMu.Unlock()
	for k, v := range h.srv.spareEmptySince {
		h.srv.spareEmptySince[k] = v.Add(-d)
	}
}

func spareAlertAudits(t *testing.T, h *harness, host string) []store.HubAuditEntry {
	t.Helper()
	var out []store.HubAuditEntry
	for _, e := range audits(t, h, "spare.alert") {
		if e.Target == host {
			out = append(out, e)
		}
	}
	return out
}

// 0 ready for 30 minutes on a machine that keeps spares: one alert and one
// audit line, never a second while it stays empty; a ready spare clears it.
// A machine 维护中 or one that cannot keep spares is never alerted.
func TestSpareEmptyAlertsOnceAfterThirtyMinutes(t *testing.T) {
	h := newFleetHarness(t)
	enablePeople(t, h)
	nodes := spareFleet(t, h)
	sparesOn(t, h, "1") // mac-c and mac-d are sent a create nobody answers yet
	start := time.Now()
	spareTick(h, start, time.Now())
	backdateEmpty(h, spareEmptyAfter-time.Minute)
	spareTick(h, start, time.Now())
	if _, all := spareAlertRows(t, h, store.AlertSpareEmpty, "mac-d"); all != 0 {
		t.Fatalf("spare_empty raised before 30 minutes")
	}
	backdateEmpty(h, 2*time.Minute)
	spareTick(h, start, time.Now())
	for _, host := range []string{"mac-c", "mac-d"} {
		if open, _ := spareAlertRows(t, h, store.AlertSpareEmpty, host); open != 1 {
			t.Fatalf("%s: open spare_empty = %d; want 1", host, open)
		}
		au := spareAlertAudits(t, h, host)
		if len(au) != 1 || au[0].Outcome != "empty" || !strings.Contains(au[0].Detail, "0 ready of 1") {
			t.Fatalf("%s: audit = %+v; want one spare.alert empty line «0 ready of 1»", host, au)
		}
	}
	for _, host := range []string{"m6", "m7"} {
		if _, all := spareAlertRows(t, h, store.AlertSpareEmpty, host); all != 0 {
			t.Fatalf("%s (维护中 / no credsep) was alerted", host)
		}
	}
	spareTick(h, start, time.Now())
	if _, all := spareAlertRows(t, h, store.AlertSpareEmpty, "mac-d"); all != 1 || len(spareAlertAudits(t, h, "mac-d")) != 1 {
		t.Fatal("a second spare_empty while it stayed empty")
	}
	openSpares(t, nodes["mac-d"], 1, control.CredsepSeparated)
	waitFor(t, 3*time.Second, "mac-d's spare to be ready", func() bool { return h.srv.spareReadyHosts()["mac-d"] == 1 })
	spareTick(h, start, time.Now())
	if open, _ := spareAlertRows(t, h, store.AlertSpareEmpty, "mac-d"); open != 0 {
		t.Fatal("a ready spare did not clear spare_empty")
	}
	if open, _ := spareAlertRows(t, h, store.AlertSpareEmpty, "mac-c"); open != 1 {
		t.Fatal("mac-c's spare_empty went with mac-d's")
	}
}

// A spare that failed is alerted at once — the machine refills no more —
// and cleared once the operator forgets it; failing again within the day
// raises nothing new, after the day it does.
func TestSpareFailedAlertsAtOnceAndOncePerDay(t *testing.T) {
	h := newFleetHarness(t)
	enablePeople(t, h)
	nodes := spareFleet(t, h)
	sparesOn(t, h, "1")
	openSpares(t, nodes["mac-d"], 1, "") // not separated: failed
	waitFor(t, 3*time.Second, "mac-d's spare to fail", func() bool {
		pic, _ := h.srv.sparePicture()
		return pic["mac-d"] != nil && pic["mac-d"].Failed
	})
	start := time.Now()
	spareTick(h, start, time.Now())
	if open, _ := spareAlertRows(t, h, store.AlertSpareFailed, "mac-d"); open != 1 {
		t.Fatal("a failed spare raised no spare_failed")
	}
	au := spareAlertAudits(t, h, "mac-d")
	if len(au) != 1 || au[0].Outcome != "failed" || !strings.Contains(au[0].Detail, "fleetu") {
		t.Fatalf("audit = %+v; want one spare.alert failed line naming the login", au)
	}
	forgetFailedSpare := func() {
		t.Helper()
		for _, a := range mustSpares(t, h) {
			if a.Hostname == "mac-d" && a.State == store.AccountFailed {
				if err := h.srv.Store.ForgetPrincipal(a.PrincipalID, ""); err != nil {
					t.Fatal(err)
				}
			}
		}
	}
	forgetFailedSpare()
	spareTick(h, start, time.Now())
	if open, _ := spareAlertRows(t, h, store.AlertSpareFailed, "mac-d"); open != 0 {
		t.Fatal("forgetting the failed spare did not clear spare_failed")
	}
	h.srv.replenishSpares(time.Now(), true)
	h.srv.dispatchAccounts()
	openSpares(t, nodes["mac-d"], 1, "")
	waitFor(t, 3*time.Second, "the next spare to fail", func() bool {
		pic, _ := h.srv.sparePicture()
		return pic["mac-d"] != nil && pic["mac-d"].Failed
	})
	spareTick(h, start, time.Now())
	if _, all := spareAlertRows(t, h, store.AlertSpareFailed, "mac-d"); all != 1 {
		t.Fatalf("spare_failed rows = %d within the day; want still 1", all)
	}
	spareTick(h, start, time.Now().Add(spareAlertQuiet+time.Hour))
	if open, all := spareAlertRows(t, h, store.AlertSpareFailed, "mac-d"); open != 1 || all != 2 {
		t.Fatalf("spare_failed after the day: open %d, all %d; want a new one", open, all)
	}
}

// A person's login whose wash came back dirty is never handed out — and is
// alerted like a failed spare, naming the reset.
func TestSpareFailedWashIsAlerted(t *testing.T) {
	h := newFleetHarness(t)
	enablePeople(t, h)
	admin := recycleFleet(t, h)
	sparesOn(t, h, "2")
	const p, login = "gh:7301", "dirtywash"
	openLogin(t, h, admin, p, login)
	removeLogin(t, h, p, false)
	m, _ := expectAccountOp(t, admin.tnode)
	sendResult(t, admin.c, m.OpID, control.AccountResult{Op: control.AccountReset, Login: login, OK: true,
		Reset: "dirty crontab", Credsep: control.CredsepSeparated})
	waitState(t, h, p, "m8", store.AccountFailed)
	spareTick(h, time.Now(), time.Now())
	if open, _ := spareAlertRows(t, h, store.AlertSpareFailed, "m8"); open != 1 {
		t.Fatal("a failed wash raised no spare_failed")
	}
	if au := spareAlertAudits(t, h, "m8"); len(au) != 1 || !strings.Contains(au[0].Detail, login+" (reset:") {
		t.Fatalf("audit = %+v; want the dirty wash named", au)
	}
}

// A cluster is a place like a machine: a spare pod that failed is alerted.
func TestSpareFailedPodAlertsTheCluster(t *testing.T) {
	h, ops := podRig(t)
	setHubSetting(t, h.srv, SpareMaxPrefix+testCluster, "1")
	h.srv.replenishSpares(time.Now(), true)
	tk := ops.expect(control.ClusterCreateUserPod)
	waitPodState(t, h, tk.Pod, store.PodLive)
	bootPod(t, h, tk, "unseparated")
	waitAccount(t, h, tk.Pod, store.AccountFailed)
	spareTick(h, time.Now(), time.Now())
	if open, _ := spareAlertRows(t, h, store.AlertSpareFailed, testCluster); open != 1 {
		t.Fatal("a failed spare pod raised no spare_failed on its cluster")
	}
	if au := spareAlertAudits(t, h, testCluster); len(au) != 1 || !strings.Contains(au[0].Detail, tk.Pod) {
		t.Fatalf("audit = %+v; want the failed pod named", au)
	}
	if _, all := spareAlertRows(t, h, store.AlertSpareFailed, tk.Pod); all != 0 {
		t.Fatal("the pod itself was alerted as a place")
	}
}

// Spares off: nothing is read, nothing raised.
func TestSpareAlertsOffAddsNothing(t *testing.T) {
	h := newFleetHarness(t)
	enablePeople(t, h)
	nodes := spareFleet(t, h)
	sparesOn(t, h, "1")
	openSpares(t, nodes["mac-d"], 1, "")
	setHubSetting(t, h.srv, SparesKey, "off")
	spareTick(h, time.Now(), time.Now())
	backdateEmpty(h, 2*spareEmptyAfter)
	spareTick(h, time.Now(), time.Now())
	if rows, _ := h.srv.Store.FleetAlerts(100); len(rows) != 0 {
		t.Fatalf("alerts with spares off: %+v", rows)
	}
	if au := audits(t, h, "spare.alert"); len(au) != 0 {
		t.Fatalf("audit with spares off: %+v", au)
	}
}

// #2947: a drill identity's first sign-in is handed the machine's ready
// spare (no create, nothing made), and deleting itself washes that login
// back into a ready spare (a reset, never a remove) — the machine keeps its
// OS user and its spare.
func TestDrillTakesASpareAndGivesItBackWashed(t *testing.T) {
	h := newFleetHarness(t)
	enablePeople(t, h)
	h.srv.FleetAdmins = []string{"bob"}
	admin := connectCaps(t, h, "m8-op", "m8", "bob", true, control.CapCredsep, control.CapRecycle)
	beatCount(t, admin, "m8", "bob", 1)
	connectCaps(t, h, "m9-op", "m9", "carol", false)
	setHubSetting(t, h.srv, AutoAssignKey, "least-busy")
	_, priv, _ := ed25519.GenerateKey(rand.Reader)
	signer, _ := ssh.NewSignerFromKey(priv)
	h.srv.SSHCA = sshca.New(signer)
	sparesOn(t, h, "1")
	spare := openSpares(t, admin, 1, control.CredsepSeparated)[0]
	waitFor(t, 3*time.Second, "m8's spare to be ready", func() bool { return h.srv.spareReadyHosts()["m8"] == 1 })

	code, body := drillReq(t, h, http.MethodPost, DrillPath, "viewer-secret", map[string]any{"host": "m9", "home": "m8"})
	if code != 200 {
		t.Fatalf("invite: %d %s", code, body)
	}
	var inv DrillInviteResponse
	json.Unmarshal(body, &inv)
	key, _ := drillKey(t)
	st := startLogin(t, h, key, nil)
	if code, body := drillReq(t, h, http.MethodPost, LoginApprovePath, "", approveRequest{Code: st.UserCode, ApproveCode: inv.ApproveCode}); code != 200 {
		t.Fatalf("approve: %d %s", code, body)
	}
	a := waitState(t, h, inv.PersonID, "m8", store.AccountActive)
	if a.Login != spare {
		t.Fatalf("drill's login on m8 = %+v; want the spare %s handed over", a, spare)
	}
	// The pool refills behind the claim.
	openSpares(t, admin, 1, control.CredsepSeparated)
	waitFor(t, 3*time.Second, "the refill to be ready", func() bool { return h.srv.spareReadyHosts()["m8"] == 1 })

	code, body = drillReq(t, h, http.MethodDelete, DrillSelfPath, "", selfDeleteRequest{ApproveCode: inv.ApproveCode})
	if code != http.StatusAccepted {
		t.Fatalf("self-delete with the spare held: %d %s; want 202", code, body)
	}
	m, op := expectAccountOp(t, admin.tnode)
	if op.Op != control.AccountReset || op.Login != spare || op.JoinCode == "" {
		t.Fatalf("op = %+v; want a reset (wash) of %s, never a remove", op, spare)
	}
	if code, _ := drillReq(t, h, http.MethodDelete, DrillSelfPath, "", selfDeleteRequest{ApproveCode: inv.ApproveCode}); code != http.StatusAccepted {
		t.Fatalf("self-delete mid-wash: %d; want 202 (the wash in flight is waited on)", code)
	}
	sendResult(t, admin.c, m.OpID, control.AccountResult{Op: control.AccountReset, Login: spare, OK: true,
		Reset: control.ResetClean, Credsep: control.CredsepSeparated})
	waitFor(t, 3*time.Second, "the washed login to be recycled", func() bool {
		return hubAuditHas(t, h, "spare.recycle", spare) != nil
	})
	if code, body := drillReq(t, h, http.MethodDelete, DrillSelfPath, "", selfDeleteRequest{ApproveCode: inv.ApproveCode}); code != 200 {
		t.Fatalf("self-delete after the wash: %d %s", code, body)
	}
	if _, err := h.srv.Store.Principal(inv.PersonID); err == nil {
		t.Fatal("the drill is still there")
	}
	// The count is where the drill found it: one over is closed by the
	// refill's own shrink, never left above the machine's target.
	waitFor(t, 3*time.Second, "m8 back to 1 ready spare, as before the drill", func() bool {
		return h.srv.spareReadyHosts()["m8"] == 1
	})
	if e := hubAuditHas(t, h, "spare.recycle", spare); e == nil {
		t.Fatal("no spare.recycle line for the drill's login")
	}
}
