package api

import (
	"context"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

// claude-fleet WACK C8: an ended trial's data goes on a schedule.

// retentionFleet is recycleFleet's m8 with spares on, and pid's own login
// there running one session (wid), its trial ending at until.
func retentionFleet(t *testing.T, until time.Time) (*harness, *fleetNode, *[]string) {
	t.Helper()
	h := newFleetHarness(t)
	enablePeople(t, h)
	admin := recycleFleet(t, h)
	sparesOn(t, h, "2")
	var mu sync.Mutex
	stopped := &[]string{}
	h.srv.trialStopHook = func(_ context.Context, wid string) error {
		mu.Lock()
		defer mu.Unlock()
		*stopped = append(*stopped, wid)
		return nil
	}
	return h, admin, stopped
}

// trialMember opens pid's login on m8, writes their limits ending at until
// and one session on that login.
func trialMember(t *testing.T, h *harness, admin *fleetNode, pid, login string, until time.Time, wid string) {
	t.Helper()
	openLogin(t, h, admin, pid, login)
	l := MemberLimits{Until: until, Since: until.Add(-7 * 24 * time.Hour), Sessions: 1}
	if err := h.srv.Store.SetFleetSetting(MemberLimitsPrefix+pid, l.String(), time.Now()); err != nil {
		t.Fatal(err)
	}
	if wid == "" {
		return
	}
	if _, err := h.srv.Store.RecordFleetSnapshot("ep_m8-"+login, "m8", login, "mid-"+login, []store.FleetReport{{
		FleetID: "f-" + login, Name: "fleet", State: "running", WorkerCount: 1,
		WorkersJSON: `[{"worker_id":"` + wid + `","key":"scratch-1"}]`}}, time.Now()); err != nil {
		t.Fatal(err)
	}
}

func retainAudit(t *testing.T, h *harness, action, pid string) bool {
	t.Helper()
	ok, err := h.srv.Store.HubAuditTargetHas(action, pid)
	if err != nil {
		t.Fatal(err)
	}
	return ok
}

func noticeIDs(t *testing.T, h *harness, pid string) []string {
	t.Helper()
	ns, err := h.srv.Store.NoticesOf(pid, store.NotifyKindTrialPurge)
	if err != nil {
		t.Fatal(err)
	}
	var out []string
	for _, n := range ns {
		out = append(out, n.ID)
	}
	return out
}

// The completion criterion: as time moves on, the end stops the sessions,
// +23 and +27 days tell the person, +30 deletes their copies and washes the
// login back into the spare pool through a clean check; a converted member and
// one still in their trial are left alone.
func TestTrialRetentionStopRemindPurge(t *testing.T) {
	until := time.Now().Truncate(time.Second).Add(-time.Hour)
	h, admin, stopped := retentionFleet(t, until)
	const p, conv, live = "gh:9101", "gh:9102", "gh:9103"
	const login, wid = "trialret", "11111111-1111-4111-8111-111111111111/scratch-1"
	trialMember(t, h, admin, p, login, until, wid)
	// conv was a trial member and 转正: the key cleared
	trialMember(t, h, admin, conv, "trialconv", until, "22222222-2222-4222-8222-222222222222/scratch-1")
	if err := h.srv.Store.SetFleetSetting(MemberLimitsPrefix+conv, "", time.Now()); err != nil {
		t.Fatal(err)
	}
	// live is still in their trial
	trialMember(t, h, admin, live, "triallive", until.Add(90*24*time.Hour), "33333333-3333-4333-8333-333333333333/scratch-1")

	// the hub's copies of p's data
	if err := h.srv.Store.PutChatMirror(p, []byte("sealed"), until.Add(90*24*time.Hour), until); err != nil {
		t.Fatal(err)
	}
	if err := h.srv.Store.PutFleetAttachment(store.FleetAttachment{ID: "att-1", Actor: p, Name: "a.txt", SHA256: "x", Size: 1,
		Created: time.Now()}, []byte("a")); err != nil {
		t.Fatal(err)
	}

	at := func(d time.Duration) time.Time { return until.Add(d) }
	day := 24 * time.Hour

	// before the end: nothing
	h.srv.SweepTrialRetention(at(-time.Minute))
	if len(*stopped) != 0 || retainAudit(t, h, auditTrialStop, p) {
		t.Fatalf("stopped before the end: %v", *stopped)
	}

	// the end: p's session stops, once; nobody else's
	h.srv.SweepTrialRetention(at(time.Hour))
	h.srv.SweepTrialRetention(at(2 * time.Hour))
	if got := strings.Join(*stopped, ","); got != wid {
		t.Fatalf("stopped = %q; want only %s, once", got, wid)
	}
	if !retainAudit(t, h, auditTrialStop, p) || retainAudit(t, h, auditTrialStop, conv) || retainAudit(t, h, auditTrialStop, live) {
		t.Fatal("trial.expire_stop rows wrong")
	}
	if ids := noticeIDs(t, h, p); len(ids) != 0 {
		t.Fatalf("told too early: %v", ids)
	}

	// +22 days: still nothing to say; +23: the first notice; +27: the second
	h.srv.SweepTrialRetention(at(22 * day))
	if ids := noticeIDs(t, h, p); len(ids) != 0 {
		t.Fatalf("told at +22: %v", ids)
	}
	h.srv.SweepTrialRetention(at(23*day + time.Hour))
	h.srv.SweepTrialRetention(at(23*day + 2*time.Hour))
	if ids := noticeIDs(t, h, p); len(ids) != 1 || !strings.HasSuffix(ids[0], "-7") {
		t.Fatalf("at +23 notices = %v; want the 7-day one", ids)
	}
	h.srv.SweepTrialRetention(at(27*day + time.Hour))
	if ids := noticeIDs(t, h, p); len(ids) != 2 {
		t.Fatalf("at +27 notices = %v; want two", ids)
	}
	if ids := noticeIDs(t, h, conv); len(ids) != 0 {
		t.Fatalf("the converted member was told: %v", ids)
	}
	ns, _ := h.srv.Store.NoticesOf(p, store.NotifyKindTrialPurge)
	msg, ok, err := h.srv.noticeMsg(ns[0])
	if err != nil || !ok || !strings.Contains(msg.Text, noticeTime(until.Add(30*day), false)) || !strings.Contains(msg.Text, "转正") {
		t.Fatalf("notice words = %+v %v %v", msg, ok, err)
	}
	if en, _, _ := h.srv.trialPurgeNoticeMsg(ns[0], true, ""); !strings.Contains(en.Text, "deleted on") {
		t.Fatalf("English notice = %q", en.Text)
	}

	// +30 days: the purge — the login goes through the wash
	h.srv.SweepTrialRetention(at(30*day + time.Hour))
	m, op := expectAccountOp(t, admin.tnode)
	if op.Op != control.AccountReset || op.Login != login {
		t.Fatalf("op = %+v; want the reset (wash) of %s", op, login)
	}
	sendResult(t, admin.c, m.OpID, control.AccountResult{Op: control.AccountReset, Login: login, OK: true,
		Reset: control.ResetClean, Credsep: control.CredsepSeparated})
	waitFor(t, 3*time.Second, login+" washed back into the spare pool", func() bool {
		for _, sp := range mustSpares(t, h) {
			if sp.Login == login && sp.State == store.AccountActive {
				return true
			}
		}
		return false
	})
	if as := mustAccounts(t, h, p); len(as) != 0 {
		t.Fatalf("the purged person still holds %+v", as)
	}
	if c, err := h.srv.Store.ChatMirror(p, at(30*day)); err != nil || c != nil {
		t.Fatalf("mirror after the purge = %+v %v", c, err)
	}
	if _, _, err := h.srv.Store.FleetAttachmentData("att-1"); err == nil {
		t.Fatal("an upload survived the purge")
	}
	if !retainAudit(t, h, auditTrialPurge, p) || retainAudit(t, h, auditTrialPurge, conv) || retainAudit(t, h, auditTrialPurge, live) {
		t.Fatal("trial.purge rows wrong")
	}
	fa, err := h.srv.Store.FleetAuditLog(50)
	if err != nil {
		t.Fatal(err)
	}
	var row *store.FleetAuditEntry
	for i := range fa {
		if fa[i].Action == auditTrialPurge {
			row = &fa[i]
		}
	}
	if row == nil || row.FleetID != p || row.Outcome != "ok" {
		t.Fatalf("fleet_audit trial.purge = %+v", row)
	}
	// purged once: a later pass sends nothing more, and a notice still queued
	// has nothing left to say
	h.srv.SweepTrialRetention(at(31 * day))
	if n := countTrialPurgeAudits(t, h, p); n != 1 {
		t.Fatalf("trial.purge rows for %s = %d", p, n)
	}
	if _, ok, _ := h.srv.noticeMsg(ns[0]); ok {
		t.Fatal("a notice after the purge still has words")
	}
	// the converted member's and the live trial's logins are untouched
	for _, q := range []string{conv, live} {
		if as := mustAccounts(t, h, q); len(as) != 1 || as[0].State != store.AccountActive {
			t.Fatalf("%s's login = %+v", q, as)
		}
	}
}

func countTrialPurgeAudits(t *testing.T, h *harness, pid string) int {
	t.Helper()
	log, err := h.srv.Store.HubAuditLog(500)
	if err != nil {
		t.Fatal(err)
	}
	n := 0
	for _, e := range log {
		if e.Action == auditTrialPurge && e.Target == pid {
			n++
		}
	}
	return n
}

// fleet.trial.retain_days 0 purges on the first pass after the end, with no
// notice.
func TestTrialRetentionZeroDays(t *testing.T) {
	until := time.Now().Truncate(time.Second).Add(-time.Minute)
	h, admin, stopped := retentionFleet(t, until)
	setHubSetting(t, h.srv, TrialRetainDaysKey, "0")
	const p, login = "gh:9201", "trialzero"
	trialMember(t, h, admin, p, login, until, "")
	h.srv.SweepTrialRetention(until.Add(time.Minute))
	m, op := expectAccountOp(t, admin.tnode)
	if op.Op != control.AccountReset || op.Login != login {
		t.Fatalf("op = %+v; want the reset of %s", op, login)
	}
	sendResult(t, admin.c, m.OpID, control.AccountResult{Op: control.AccountReset, Login: login, OK: true,
		Reset: control.ResetClean, Credsep: control.CredsepSeparated})
	if !retainAudit(t, h, auditTrialPurge, p) || !retainAudit(t, h, auditTrialStop, p) {
		t.Fatal("retain 0: no purge / stop row")
	}
	if ids := noticeIDs(t, h, p); len(ids) != 0 || len(*stopped) != 0 {
		t.Fatalf("retain 0: notices %v, stops %v", ids, *stopped)
	}
}

func TestTrialRetainDaysSetting(t *testing.T) {
	h := newFleetHarness(t)
	if got := h.srv.trialRetainDays(); got != defaultTrialRetainDays {
		t.Fatalf("default = %d", got)
	}
	if _, why := hubSettings[TrialRetainDaysKey].check(h.srv, "400"); why == "" {
		t.Fatal("400 days accepted")
	}
}
