package api

import (
	"encoding/json"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/fleetid"
)

// WACK C5: the 紧急开关 page's five actions, an admin's only.

type emHarness struct {
	*trialHarness
	mu   sync.Mutex
	told []string
}

func newEmHarness(t *testing.T) *emHarness {
	t.Helper()
	h := &emHarness{trialHarness: newTrialHarness(t)}
	h.srv.Notify = func(msg string) {
		h.mu.Lock()
		h.told = append(h.told, msg)
		h.mu.Unlock()
	}
	return h
}

func (h *emHarness) press(t *testing.T, sess *http.Cookie, body map[string]any, want int) emergencyView {
	t.Helper()
	st, b := requestsDo(t, h.ghHarness, sess, http.MethodPost, AdminEmergencyPath, body)
	if st != want {
		t.Fatalf("POST %v = %d %s; want %d", body, st, b, want)
	}
	var v emergencyView
	_ = json.Unmarshal(b, &v)
	return v
}

func (h *emHarness) notices() []string {
	h.mu.Lock()
	defer h.mu.Unlock()
	return append([]string(nil), h.told...)
}

// emAuditRows is every fleet_audit row of action emergency.<action>.
func emAuditRows(t *testing.T, h *ghHarness, action string) []string {
	t.Helper()
	rows, err := h.srv.Store.DB().Query(`SELECT actor || ' ' || fleet_id || ' ' || outcome FROM fleet_audit
		WHERE action = ? ORDER BY id`, "emergency."+action)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var s string
		_ = rows.Scan(&s)
		out = append(out, s)
	}
	return out
}

func TestEmergencyAdminOnly(t *testing.T) {
	h := newEmHarness(t)
	if st, b := requestsDo(t, h.ghHarness, h.user, http.MethodGet, AdminEmergencyPath, nil); st != http.StatusForbidden {
		t.Fatalf("member GET = %d %s; want 403", st, b)
	}
	h.press(t, h.user, map[string]any{"action": "trial_stop"}, http.StatusForbidden)
	if h.srv.trialHalted() || len(h.notices()) != 0 {
		t.Fatal("a member's press did something")
	}
	if st, b := requestsDo(t, h.ghHarness, h.admin, http.MethodGet, AdminEmergencyPath, nil); st != http.StatusOK {
		t.Fatalf("admin GET = %d %s", st, b)
	}
	h.press(t, h.admin, map[string]any{"action": "launch"}, http.StatusBadRequest)
}

// trial_stop closes every road into a new trial — a 试用二维码, /app/try's
// claim — and trial_resume opens them again; each is one fleet_audit row
// and one line to the admins, a repeat neither.
func TestEmergencyTrialStopResume(t *testing.T) {
	h := newEmHarness(t)
	c := h.newCode(t, map[string]any{"channel": "沙龙"})

	v := h.press(t, h.admin, map[string]any{"action": "trial_stop", "reason": "刷号"}, http.StatusOK)
	if !v.Trial.Stopped || v.Trial.At == nil || v.Done == nil || v.Done.Outcome != "ok" {
		t.Fatalf("after stop = %+v", v)
	}
	h.press(t, h.admin, map[string]any{"action": "trial_stop"}, http.StatusOK) // already

	// a new WeChat scanning meets the pause, and no trial starts
	st, a := h.follow(t, c.Scene, "openid-halted-000001", "union-halted-1", "subscribe")
	if st != http.StatusOK || a.Reply != trialHaltWords(false) || len(h.grants(t, c.ID)) != 0 {
		t.Fatalf("scan while stopped = %d %+v grants %v", st, a, h.grants(t, c.ID))
	}
	// /app/try's claim waits on it too
	if err := h.srv.Store.StartTrial("p:00000000-0000-4000-8000-0000000000aa", time.Now()); err != nil {
		t.Fatal(err)
	}
	if ans, err := h.srv.tryClaim("p:00000000-0000-4000-8000-0000000000aa", "", time.Now()); err != nil || ans.State != "halted" {
		t.Fatalf("claim while stopped = %+v %v", ans, err)
	}
	st2, b := requestsDo(t, h.ghHarness, h.admin, http.MethodGet, AdminEmergencyPath, nil)
	var got emergencyView
	if st2 != http.StatusOK || json.Unmarshal(b, &got) != nil || got.Trial.Saw != 2 {
		t.Fatalf("state = %d %s; want 2 people who saw the pause", st2, b)
	}

	v = h.press(t, h.admin, map[string]any{"action": "trial_resume"}, http.StatusOK)
	if v.Trial.Stopped || h.srv.trialHalted() {
		t.Fatalf("after resume = %+v", v.Trial)
	}
	h.ageScans(t)
	if _, a := h.follow(t, c.Scene, "openid-halted-000001", "union-halted-1", "subscribe"); a.News == nil {
		t.Fatalf("scan after resume = %+v; want the trial", a)
	}

	stops, resumes := emAuditRows(t, h.ghHarness, "trial_stop"), emAuditRows(t, h.ghHarness, "trial_resume")
	if len(stops) != 2 || !strings.HasSuffix(stops[0], " ok") || !strings.Contains(stops[1], "already") ||
		len(resumes) != 1 || !strings.HasSuffix(resumes[0], " ok") {
		t.Fatalf("audit stop %q resume %q", stops, resumes)
	}
	if n := h.notices(); len(n) != 2 || !strings.Contains(n[0], "停止了所有新试用") || !strings.Contains(n[0], "刷号") ||
		!strings.Contains(n[1], "恢复了新试用") {
		t.Fatalf("told = %q; want one stop and one resume", n)
	}
}

func TestEmergencyCodeDisable(t *testing.T) {
	h := newEmHarness(t)
	c := h.newCode(t, map[string]any{"channel": "线下"})
	h.press(t, h.admin, map[string]any{"action": "code_disable", "target": "tc-nope"}, http.StatusNotFound)
	v := h.press(t, h.admin, map[string]any{"action": "code_disable", "target": c.ID}, http.StatusOK)
	if len(v.Codes) != 1 || v.Codes[0].State != store.TrialCodeStopped {
		t.Fatalf("codes = %+v", v.Codes)
	}
	if _, a := h.follow(t, c.Scene, "openid-stopped-00001", "", "subscribe"); a.Reply == "" || a.News != nil {
		t.Fatalf("scan of a stopped code = %+v", a)
	}
	if rows := emAuditRows(t, h.ghHarness, "code_disable"); len(rows) != 2 || !strings.HasSuffix(rows[1], " ok") {
		t.Fatalf("audit = %q", rows)
	}
}

// emNode is a write node on h's hub: mac-e, login alice-mac, with sessions.
func emNode(t *testing.T, h *emHarness) (*writeNode, string) {
	t.Helper()
	hh := &harness{srv: h.srv, http: h.http, tokens: map[string]string{}}
	n := connectWriteNode(t, hh, "mac-e")
	f := fakeFleet(t, machineA, "fleet-mac-e", writeRepo, "/u/alice/claude-fleet", 7, 8)
	n.beatLoad("mac-e", aliceLogin, machineA, 1, 2, f)
	waitFor(t, 3*time.Second, "mac-e registered", func() bool {
		r, err := h.srv.Store.Fleet(f.FleetID)
		return err == nil && r.Present
	})
	return n, f.FleetID
}

func TestEmergencyMachinePause(t *testing.T) {
	h := newEmHarness(t)
	emNode(t, h)
	h.press(t, h.admin, map[string]any{"action": "machine_pause", "target": "nowhere"}, http.StatusNotFound)
	v := h.press(t, h.admin, map[string]any{"action": "machine_pause", "target": "mac-e"}, http.StatusOK)
	set, _ := h.srv.Store.FleetSettings()
	if _, ok := maintenanceOf("mac-e", set); !ok {
		t.Fatal("mac-e is not flagged")
	}
	if len(v.Machines) != 1 || !v.Machines[0].Paused {
		t.Fatalf("machines = %+v", v.Machines)
	}
	if rows := emAuditRows(t, h.ghHarness, "machine_pause"); len(rows) != 2 || !strings.Contains(rows[1], "mac-e ok") {
		t.Fatalf("audit = %q", rows)
	}
}

// person_stop takes alice off the list and stops every session on her login
// through the node — at once, and again on the sweep for one that shows up
// after; an admin is never stopped from here.
func TestEmergencyPersonStop(t *testing.T) {
	h := newEmHarness(t)
	n, fid := emNode(t, h)
	alice := githubPrincipal(ghAlice.ID)
	if _, err := h.srv.Store.SetEntryHome(store.EntryHome{Person: alice, Machine: "mac-e", Login: aliceLogin,
		SetBy: "test", SetAt: time.Now()}); err != nil {
		t.Fatal(err)
	}
	h.press(t, h.admin, map[string]any{"action": "person_stop", "target": "ivan"}, http.StatusForbidden)

	start := time.Now()
	v := h.press(t, h.admin, map[string]any{"action": "person_stop", "target": "alice"}, http.StatusOK)
	if v.Done == nil || v.Done.Sessions != 2 || v.Done.Stopped != 2 {
		t.Fatalf("done = %+v; want both sessions stopped", v.Done)
	}
	stopped := func() map[string]bool {
		n.mu.Lock()
		defer n.mu.Unlock()
		out := map[string]bool{}
		for _, w := range n.writes {
			if w["action"] == "worker_stop" {
				out[asString(w["params"].(map[string]any)["worker_id"])] = true
			}
		}
		return out
	}
	want := []string{fleetid.WorkerID(fid, fleetid.WorkerKey(7, false, "", "")), fleetid.WorkerID(fid, fleetid.WorkerKey(8, false, "", ""))}
	got := stopped()
	for _, w := range want {
		if !got[w] {
			t.Fatalf("worker_stop sent for %v; want %v", got, want)
		}
	}
	if d := time.Since(start); d > 60*time.Second {
		t.Fatalf("sessions stopped after %s", d)
	}
	if role, _ := h.srv.personRole(alice); role != "" {
		t.Fatalf("alice's role = %q; want off the list", role)
	}
	if r, err := h.srv.Store.RevokedFor("", alice); err != nil || r == nil {
		t.Fatalf("subscriptions not revoked: %+v %v", r, err)
	}
	if len(v.Stopped) != 1 || v.Stopped[0].Principal != alice || v.Stopped[0].Login != "alice" {
		t.Fatalf("stopped = %+v", v.Stopped)
	}

	// a third session on her login after the press is stopped by the sweep
	f := fakeFleet(t, machineA, "fleet-mac-e", writeRepo, "/u/alice/claude-fleet", 7, 8, 9)
	n.beatLoad("mac-e", aliceLogin, machineA, 1, 3, f)
	waitFor(t, 3*time.Second, "the third session registered", func() bool {
		r, _ := h.srv.Store.Fleet(fid)
		return strings.Contains(r.WorkersJSON, `"issue":9`)
	})
	h.srv.EmergencySweep(time.Now().Add(time.Minute))
	if w9 := fleetid.WorkerID(fid, fleetid.WorkerKey(9, false, "", "")); !stopped()[w9] {
		t.Fatalf("the sweep did not stop %s: %v", w9, stopped())
	}
	// an hour on, the sweep lets her be
	before := n.count()
	h.srv.EmergencySweep(time.Now().Add(2 * time.Hour))
	if n.count() != before {
		t.Fatal("the sweep kept stopping after its hour")
	}
	if rows := emAuditRows(t, h.ghHarness, "person_stop"); len(rows) != 2 || !strings.Contains(rows[0], "refused") ||
		!strings.Contains(rows[1], "alice ("+alice+") ok") {
		t.Fatalf("audit = %q", rows)
	}
}
