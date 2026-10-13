package api

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// claude-fleet#3590 (EPIC #3569 C20): the 60-second trial. A trial invite lets
// a stranger in; the first in line takes a ready spare, the rest wait and are
// told roughly how long; the page's one timing is kept anonymously; a trial
// login unused for 7 days goes back. fleet.trial off adds nothing.

// tryDo is one request from the trial page: its header, and the person's
// session when pid is set.
func tryDo(t *testing.T, h *harness, method, path, pid string, body any) (int, http.Header, map[string]any) {
	t.Helper()
	var rd io.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		rd = bytes.NewReader(b)
	}
	req, _ := http.NewRequest(method, h.http.URL+path, rd)
	req.Header.Set(tryHeader, "1")
	if pid != "" {
		listPerson(t, h, pid, "")
		req.AddCookie(personCookie(pid, "trier"))
	}
	resp, err := noFollow.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	out := map[string]any{}
	b, _ := io.ReadAll(resp.Body)
	_ = json.Unmarshal(b, &out)
	return resp.StatusCode, resp.Header, out
}

func TestTryOffIsTheOldRedirect(t *testing.T) {
	h := newFleetHarness(t)
	enablePeople(t, h)
	resp, err := noFollow.Get(h.http.URL + TryPagePath + "?from=site")
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusFound || resp.Header.Get("Location") != AppPrefix+"?from=site" {
		t.Fatalf("GET /app/try with the trial off = %d → %q; want the old 302 → /app?from=site", resp.StatusCode, resp.Header.Get("Location"))
	}
	for _, p := range []string{TryStartPath, TryClaimPath, TryTimingPath} {
		pid := "gh:7001"
		if p == TryStartPath {
			pid = ""
		}
		if code, _, _ := tryDo(t, h, http.MethodPost, p, pid, map[string]int{"ms": 1000}); code != http.StatusNotFound {
			t.Errorf("POST %s with the trial off = %d; want 404", p, code)
		}
	}
	if n, err := h.srv.Store.Invites(); err != nil || len(n) != 0 {
		t.Fatalf("invites = %v, %v; want none", n, err)
	}
}

func TestTryPageAndScript(t *testing.T) {
	h := newFleetHarness(t)
	enablePeople(t, h)
	setHubSetting(t, h.srv, TrialKey, "on")
	resp, body := h.get(t, TryPagePath+"?lang=zh")
	if resp.StatusCode != http.StatusOK || !strings.Contains(string(body), "60 秒试用") ||
		!strings.Contains(string(body), `src="`+tryScriptPath+`"`) {
		t.Fatalf("GET /app/try = %d %s", resp.StatusCode, body)
	}
	if csp := resp.Header.Get("Content-Security-Policy"); !strings.Contains(csp, "script-src 'self'") {
		t.Fatalf("CSP = %q; want the page's own script allowed", csp)
	}
	resp, body = h.get(t, tryScriptPath)
	if resp.StatusCode != http.StatusOK || !strings.HasPrefix(resp.Header.Get("Content-Type"), "text/javascript") ||
		!strings.Contains(string(body), "fleet.try.t0") {
		t.Fatalf("GET /app/try.js = %d %q", resp.StatusCode, resp.Header.Get("Content-Type"))
	}
}

// The start mints a one-use trial invite into the cookie and sends the
// browser to sign in; the sign-in that spends it records a waiting trial and
// opens no login.
func TestTryStartLetsAStrangerInAsATrial(t *testing.T) {
	h := newFleetHarness(t)
	enablePeople(t, h)
	setHubSetting(t, h.srv, TrialKey, "on")
	setHubSetting(t, h.srv, AutoAssignKey, "least-busy")

	req, _ := http.NewRequest(http.MethodPost, h.http.URL+TryStartPath, nil)
	if resp, err := noFollow.Do(req); err != nil || resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("a start without the page's header = %v, %v; want 400", resp, err)
	}
	code, hdr, out := tryDo(t, h, http.MethodPost, TryStartPath, "", nil)
	if code != http.StatusOK || out["next"] != AppPrefix+"/signin" {
		t.Fatalf("start = %d %v", code, out)
	}
	resp := &http.Response{Header: hdr}
	ic, rc := cookieNamed(resp, inviteCookie), cookieNamed(resp, entryReturnCookie)
	if ic == nil || !validInviteCode(ic.Value) || rc == nil || rc.Value != TryPagePath {
		t.Fatalf("cookies = %+v / %+v; want an invite and a way back to /app/try", ic, rc)
	}
	inv, err := h.srv.Store.InviteByHash(inviteHash(ic.Value))
	if err != nil || inv == nil || inv.CreatedBy != trialInviter {
		t.Fatalf("invite = %+v, %v; want one made by %q", inv, err, trialInviter)
	}

	const pid = "p:00000000-0000-4000-8000-000000003590"
	if refusal, err := h.srv.admitInviteAs(pid, store.IdentityEmail, "trier@example.com", "trier", ic.Value, time.Now()); err != nil || refusal != "" {
		t.Fatalf("admit = %q, %v", refusal, err)
	}
	tr, err := h.srv.Store.Trial(pid)
	if err != nil || tr == nil || tr.State != store.TrialWaiting {
		t.Fatalf("trial = %+v, %v; want waiting", tr, err)
	}
	if h.srv.placePrincipal(pid, "trier", pid); len(mustAccounts(t, h, pid)) != 0 {
		t.Fatalf("the sign-in opened a login for a trial: %+v", mustAccounts(t, h, pid))
	}

	// An admin's invite is not a trial.
	other := &store.Invite{CreatedBy: "gh:1"}
	h.srv.trialAdmitted("gh:7777", other, time.Now())
	if tr, _ := h.srv.Store.Trial("gh:7777"); tr != nil {
		t.Fatalf("an admin's invite made a trial: %+v", tr)
	}
	// The way back after the sign-in is the try page.
	r := httptestRequestWithCookie(entryReturnCookie, TryPagePath)
	if to := entryReturnTo(&nopWriter{h: http.Header{}}, r); to != TryPagePath {
		t.Fatalf("entryReturnTo = %q; want %s", to, TryPagePath)
	}
}

func mustAccounts(t *testing.T, h *harness, pid string) []store.FleetAccount {
	t.Helper()
	as, err := h.srv.Store.FleetAccounts(pid)
	if err != nil {
		t.Fatal(err)
	}
	return as
}

func httptestRequestWithCookie(name, value string) *http.Request {
	r, _ := http.NewRequest(http.MethodGet, "http://hub.example.com/", nil)
	r.AddCookie(&http.Cookie{Name: name, Value: value})
	return r
}

type nopWriter struct{ h http.Header }

func (w *nopWriter) Header() http.Header         { return w.h }
func (w *nopWriter) Write(b []byte) (int, error) { return len(b), nil }
func (w *nopWriter) WriteHeader(int)             {}

// The first in line takes the ready spare; with none free the next waits —
// told their place and an ETA, no error — and one who left the page holds no
// one up.
func TestTryClaimSpareOrWaitlist(t *testing.T) {
	h := newFleetHarness(t)
	enablePeople(t, h)
	nodes := spareFleet(t, h)
	setHubSetting(t, h.srv, TrialKey, "on")
	sparesOn(t, h, "1")
	openSpares(t, nodes["mac-c"], 1, control.CredsepSeparated)
	macD := openSpares(t, nodes["mac-d"], 1, control.CredsepSeparated)
	readySpares(t, h, "mac-d", 1)
	// mac-c's spare is taken out of play: only mac-d hands one out here.
	setHubSetting(t, h.srv, NodeUserCapPrefix+"mac-c", "0")

	const a, b, c = "gh:7101", "gh:7102", "gh:7103"
	now := time.Now()
	for i, p := range []string{a, b, c} {
		if err := h.srv.Store.StartTrial(p, now.Add(time.Duration(i)*time.Second)); err != nil {
			t.Fatal(err)
		}
	}
	// b and c are already on the page, so a's claim is the only seat.
	for _, p := range []string{b, c} {
		if err := h.srv.Store.TouchTrial(p, now); err != nil {
			t.Fatal(err)
		}
	}

	// b may not jump the line while a, first, is still on the page.
	code, _, out := tryDo(t, h, http.MethodPost, TryClaimPath, b, nil)
	if code != http.StatusOK || out["state"] != "waiting" || out["position"] != float64(1) {
		t.Fatalf("b's claim before a = %d %v; want waiting, 1 ahead", code, out)
	}
	code, _, out = tryDo(t, h, http.MethodPost, TryClaimPath, a, nil)
	if code != http.StatusOK || (out["state"] != "ready" && out["state"] != "opening") {
		t.Fatalf("a's claim = %d %v; want a seat", code, out)
	}
	if acct := accountState(t, h, a, "mac-d"); acct.State != store.AccountActive || acct.Login != macD[0] {
		t.Fatalf("a's account = %+v; want the spare %s", acct, macD[0])
	}
	if tr, _ := h.srv.Store.Trial(a); tr == nil || tr.State != store.TrialPlaced || tr.Host != "mac-d" {
		t.Fatalf("a's trial = %+v; want placed on mac-d", tr)
	}

	// No spare left: b is first in line now, c behind; neither is an error.
	code, _, out = tryDo(t, h, http.MethodPost, TryClaimPath, b, nil)
	if code != http.StatusOK || out["state"] != "waiting" || out["position"] != nil || !(out["eta_secs"].(float64) > 0) {
		t.Fatalf("b's claim with no spare = %d %v; want waiting first, with an ETA", code, out)
	}
	if len(mustAccounts(t, h, b)) != 0 {
		t.Fatalf("a waiting trial was given a login: %+v", mustAccounts(t, h, b))
	}
	code, _, out = tryDo(t, h, http.MethodPost, TryClaimPath, c, nil)
	if out["state"] != "waiting" || out["position"] != float64(1) {
		t.Fatalf("c's claim = %d %v; want waiting, 1 ahead", code, out)
	}
	if eb, ec := h.srv.trialETA("mac-d", 0), h.srv.trialETA("mac-d", 1); ec < eb {
		t.Fatalf("ETA behind someone %d < ETA first %d", ec, eb)
	}
	// b walks away (not seen since): c is first.
	tc, _ := h.srv.Store.Trial(c)
	if n, err := h.srv.Store.TrialsAhead(tc, time.Now().Add(time.Minute)); err != nil || n != 0 {
		t.Fatalf("ahead of c once b is not seen = %d, %v; want 0", n, err)
	}

	// A member who never came through the trial is sent to the console.
	if _, _, out := tryDo(t, h, http.MethodPost, TryClaimPath, "gh:7199", nil); out["state"] != "member" || out["next"] != AppPrefix {
		t.Fatalf("member's claim = %v", out)
	}
}

// One timing per trial person, nobody's name on it; the admin reads p50 / p90.
func TestTryTimingAnonymousAndStats(t *testing.T) {
	h := newFleetHarness(t)
	enablePeople(t, h)
	setHubSetting(t, h.srv, TrialKey, "on")
	now := time.Now()
	for _, p := range []string{"gh:7201", "gh:7202", "gh:7203"} {
		if err := h.srv.Store.StartTrial(p, now); err != nil {
			t.Fatal(err)
		}
	}
	for p, ms := range map[string]int{"gh:7201": 47000, "gh:7202": 52000, "gh:7203": 90000} {
		if code, _, out := tryDo(t, h, http.MethodPost, TryTimingPath, p, map[string]int{"ms": ms}); code != http.StatusOK || out["kept"] != true {
			t.Fatalf("timing of %s = %d %v", p, code, out)
		}
	}
	if _, _, out := tryDo(t, h, http.MethodPost, TryTimingPath, "gh:7201", map[string]int{"ms": 1000}); out["kept"] != false {
		t.Fatalf("a second timing = %v; want not kept", out)
	}
	if _, _, out := tryDo(t, h, http.MethodPost, TryTimingPath, "gh:7299", map[string]int{"ms": 1000}); out["kept"] != false {
		t.Fatalf("a member's timing = %v; want not kept", out)
	}
	for _, bad := range []int{0, -5, 3600*1000 + 1} {
		if code, _, _ := tryDo(t, h, http.MethodPost, TryTimingPath, "gh:7202", map[string]int{"ms": bad}); code != http.StatusBadRequest {
			t.Fatalf("ms=%d = %d; want 400", bad, code)
		}
	}
	st, err := h.srv.trialStatsAt(time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if st.Last7d.N != 3 || st.Last7d.MedianSecs == nil || *st.Last7d.MedianSecs != 52 || *st.Last7d.P90Secs != 90 {
		t.Fatalf("stats = %+v", st)
	}
	// The admin's route; a member gets nothing from it.
	if code, _ := asUID(t, h, http.MethodGet, TryStatsPath, "gh:7202", "", nil); code == http.StatusOK {
		t.Fatalf("a member read the trial stats")
	}
	code, body := h.post(t, TryStatsPath, nil)
	_ = body
	if code == http.StatusOK {
		t.Fatalf("POST stats = 200; want GET only")
	}
}

// Seven days unused, a trial login goes back through the operator's remove;
// one used yesterday stays; a reclaimed trial who comes back rejoins the line.
func TestTrySweepReclaimsAfterSevenDays(t *testing.T) {
	h := newFleetHarness(t)
	enablePeople(t, h)
	nodes := spareFleet(t, h)
	setHubSetting(t, h.srv, TrialKey, "on")
	sparesOn(t, h, "2")
	openSpares(t, nodes["mac-c"], 2, control.CredsepSeparated)
	openSpares(t, nodes["mac-d"], 2, control.CredsepSeparated)
	readySpares(t, h, "mac-d", 2)

	const old, fresh = "gh:7301", "gh:7302"
	now := time.Now()
	for _, p := range []string{old, fresh} {
		if err := h.srv.Store.StartTrial(p, now); err != nil {
			t.Fatal(err)
		}
		if got := h.srv.claimSpares(p, p, p, []string{"mac-d"}, now); len(got) != 1 {
			t.Fatalf("claim for %s = %v", p, got)
		}
		if err := h.srv.Store.PlaceTrial(p, "mac-d", now); err != nil {
			t.Fatal(err)
		}
	}
	h.srv.SweepTrials(now.Add(trialIdle - time.Hour))
	if a := accountState(t, h, old, "mac-d"); a.State != store.AccountActive {
		t.Fatalf("swept before 7 days: %+v", a)
	}
	if err := h.srv.Store.TouchTrial(fresh, now.Add(6*24*time.Hour)); err != nil {
		t.Fatal(err)
	}
	h.srv.SweepTrials(now.Add(trialIdle + time.Hour))
	if a := accountState(t, h, old, "mac-d"); a.State == store.AccountActive {
		t.Fatalf("an idle trial login was not given back: %+v", a)
	}
	if tr, _ := h.srv.Store.Trial(old); tr == nil || tr.State != store.TrialReclaimed {
		t.Fatalf("old trial = %+v; want reclaimed", tr)
	}
	if a := accountState(t, h, fresh, "mac-d"); a.State != store.AccountActive {
		t.Fatalf("a trial used yesterday was swept: %+v", a)
	}
	if !auditHas(mustAudit(t, h), "trial", "ok", "7 天没用") {
		t.Errorf("no reclaim audit row")
	}
	// Back after the reclaim: to the end of the line, never an error.
	if _, err := h.srv.tryClaim(old, "", now.Add(trialIdle+2*time.Hour)); err != nil {
		t.Fatal(err)
	}
	if tr, _ := h.srv.Store.Trial(old); tr == nil || tr.State == store.TrialReclaimed {
		t.Fatalf("reclaimed trial after a claim = %+v; want back in line or placed", tr)
	}
}

func mustAudit(t *testing.T, h *harness) []store.HubAuditEntry {
	t.Helper()
	log, err := h.srv.Store.HubAuditLog(200)
	if err != nil {
		t.Fatal(err)
	}
	return log
}
