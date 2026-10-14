package api

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/authz"
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
	if resp.StatusCode != http.StatusOK || !strings.Contains(string(body), "立即体验") ||
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

// The start leaves only the ccq_try note and sends the browser to sign in —
// no invite. A verified sign-in the list refuses, carrying the note, becomes a
// trial person (role trial, one row per way); without the note it is the old
// refusal; a trial invite from before admits no one (claude-fleet#4058).
func TestTryStartNeedsAVerifiedSignIn(t *testing.T) {
	h := newFleetHarness(t)
	enablePeople(t, h)
	setHubSetting(t, h.srv, TrialKey, "on")

	req, _ := http.NewRequest(http.MethodPost, h.http.URL+TryStartPath, nil)
	if resp, err := noFollow.Do(req); err != nil || resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("a start without the page's header = %v, %v; want 400", resp, err)
	}
	code, hdr, out := tryDo(t, h, http.MethodPost, TryStartPath, "", nil)
	if code != http.StatusOK || out["next"] != AppPrefix+"/signin" {
		t.Fatalf("start = %d %v", code, out)
	}
	resp := &http.Response{Header: hdr}
	tc, rc := cookieNamed(resp, tryCookie), cookieNamed(resp, entryReturnCookie)
	if tc == nil || tc.Value != "1" || rc == nil || rc.Value != TryPagePath || cookieNamed(resp, inviteCookie) != nil {
		t.Fatalf("cookies = %+v / %+v; want the try note, a way back to /app/try and no invite", tc, rc)
	}
	if n, err := h.srv.Store.Invites(); err != nil || len(n) != 0 {
		t.Fatalf("invites = %v, %v; want none minted", n, err)
	}

	now := time.Now()
	// No note: the refusal stands, nothing recorded.
	w := httptest.NewRecorder()
	r := httptest.NewRequest(http.MethodGet, "https://hub.example.com/auth/email/link", nil)
	if h.srv.trialSignIn(w, r, h.srv.trialAsked(r), store.IdentityEmail, "a@example.com", "a", "", now) {
		t.Fatalf("a sign-in with no try note became a trial")
	}
	// With the note: a trial person, signed in as one, sent to /app/try.
	r.AddCookie(&http.Cookie{Name: tryCookie, Value: "1"})
	w = httptest.NewRecorder()
	if !h.srv.trialSignIn(w, r, h.srv.trialAsked(r), store.IdentityEmail, "A@example.com", "a", "", now) {
		t.Fatalf("a verified sign-in with the try note was not made a trial")
	}
	if loc := w.Result().Header.Get("Location"); loc != TryPagePath {
		t.Fatalf("after the trial sign-in → %q; want %s", loc, TryPagePath)
	}
	tr, err := h.srv.Store.TrialByWay(store.IdentityEmail, "a@example.com")
	if err != nil || tr == nil || tr.State != store.TrialWaiting {
		t.Fatalf("trial by the address = %+v, %v; want waiting", tr, err)
	}
	if role, err := h.srv.personRole(tr.Principal); err != nil || role != roleTrial {
		t.Fatalf("role = %q, %v; want trial", role, err)
	}
	if u, _ := h.srv.Store.HubUserByPrincipal(tr.Principal); u != nil {
		t.Fatalf("a trial person was put on the list: %+v", u)
	}
	if h.srv.placePrincipal(tr.Principal, "a", tr.Principal); len(mustAccounts(t, h, tr.Principal)) != 0 {
		t.Fatalf("the sign-in opened a login for a trial")
	}
	// The same address signs in again: the same person, the same one trial.
	pid, role, _, err := h.srv.admitPerson(store.IdentityEmail, "a@example.com", "", "", now)
	if err != nil || pid != tr.Principal || role != roleTrial {
		t.Fatalf("second sign-in = %q %q %v; want the trial person back", pid, role, err)
	}
	// Another person cannot take this way's trial.
	if err := h.srv.Store.StartTrialAs("p:00000000-0000-4000-8000-000000004058", store.IdentityEmail, "a@example.com", now); err == nil {
		t.Fatalf("a second trial on one way was recorded")
	}

	// A trial invite from before #4058 lets no one in.
	code2 := "trialcode-0000000000000000000000000000"
	if err := h.srv.Store.CreateInvite(store.Invite{ID: "try-old", CodeHash: inviteHash(code2), CreatedBy: trialInviter,
		CreatedAt: now, ExpiresAt: now.Add(time.Hour)}); err != nil {
		t.Fatal(err)
	}
	if refusal, err := h.srv.admitInviteAs("p:00000000-0000-4000-8000-000000004059", store.IdentityEmail, "b@example.com", "b", code2, now); err != nil || refusal == "" {
		t.Fatalf("an old trial invite = %q, %v; want refused", refusal, err)
	}
	// The way back after the sign-in is the try page.
	r = httptestRequestWithCookie(entryReturnCookie, TryPagePath)
	if to := entryReturnTo(&nopWriter{h: http.Header{}}, r); to != TryPagePath {
		t.Fatalf("entryReturnTo = %q; want %s", to, TryPagePath)
	}
}

// trialSession is a trial person's session cookie: their own role, not on
// the list.
func trialSession(t *testing.T, h *harness, pid string) *http.Cookie {
	t.Helper()
	if err := h.srv.Store.StartTrialAs(pid, store.IdentityEmail, pid+"@example.com", time.Now()); err != nil {
		t.Fatal(err)
	}
	return &http.Cookie{Name: authz.CookieName, Value: authz.SignRole(store.IdentityEmail, pid, "trier", roleTrial,
		(&GitHubAuth{ClientSecret: testGitHubSecret}).sessionKey(), time.Now(), time.Hour)}
}

// A trial person reaches the chat, their trial and /apply; /app/sessions,
// /v1/fleet/*, the admin side answer 404 (claude-fleet#4058).
func TestTrialRoleReachesOnlyTheChat(t *testing.T) {
	h := newFleetHarness(t)
	enablePeople(t, h)
	setHubSetting(t, h.srv, TrialKey, "on")
	const pid = "p:00000000-0000-4000-8000-000000004060"
	c := trialSession(t, h, pid)
	do := func(method, path string) (int, string) {
		req, _ := http.NewRequest(method, h.http.URL+path, nil)
		req.AddCookie(c)
		req.Header.Set(tryHeader, "1")
		resp, err := noFollow.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		b, _ := io.ReadAll(resp.Body)
		return resp.StatusCode, string(b)
	}
	for _, p := range []string{AppPrefix + "/sessions", control.SessionsPath, control.SummaryPath, "/v1/fleet/settings",
		AdminPrefix, AdminPrefix + "/people", TryStatsPath, "/v1/me/identities"} {
		if code, _ := do(http.MethodGet, p); code != http.StatusNotFound {
			t.Errorf("trial GET %s = %d; want 404", p, code)
		}
	}
	code, body := do(http.MethodGet, "/v1/me")
	if code != http.StatusOK || !strings.Contains(body, `"role":"trial"`) {
		t.Fatalf("trial GET /v1/me = %d %s; want role trial", code, body)
	}
	var me Me
	_ = json.Unmarshal([]byte(body), &me)
	if len(me.Pages) != 1 || me.Pages[0] != "chat" {
		t.Fatalf("trial pages = %v; want the chat only", me.Pages)
	}
	if code, _ := do(http.MethodPost, TryClaimPath); code != http.StatusOK {
		t.Fatalf("trial claim = %d; want 200", code)
	}
	if !trialRoute(AppPrefix) || !trialRoute(ChatPathPrefix+"home") || trialRoute(AppPrefix+"/usage") {
		t.Fatalf("trialRoute is not the chat and the trial")
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
	if !auditHas(mustAudit(t, h), "trial.release", "ok", "7 天没用") {
		t.Errorf("no reclaim audit row")
	}
	// Back after the reclaim: one trial per account (fleet.trial.once) —
	// 「已试过」, pointed at /apply.
	if a, err := h.srv.tryClaim(old, "", now.Add(trialIdle+2*time.Hour)); err != nil || a.State != "tried" || a.Next != ApplyPath {
		t.Fatalf("a second trial = %+v, %v; want tried → /apply", a, err)
	}
	// With fleet.trial.once off: to the end of the line, never an error.
	setHubSetting(t, h.srv, TrialOnceKey, "off")
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

// Admission (共同约定「准入」, claude-fleet#4058): seats full, the machine's own
// gate saying no, load over the line, the pool under its floor — each a wait
// with its reason and an ETA, never an error; the day's total spent (halved
// under half a pool) is 「今天满了」.
func TestTrialAdmissionQueues(t *testing.T) {
	h := newFleetHarness(t)
	enablePeople(t, h)
	nodes := spareFleet(t, h)
	setHubSetting(t, h.srv, TrialKey, "on")
	sparesOn(t, h, "1")
	openSpares(t, nodes["mac-c"], 1, control.CredsepSeparated)
	openSpares(t, nodes["mac-d"], 1, control.CredsepSeparated)
	readySpares(t, h, "mac-d", 1)
	setHubSetting(t, h.srv, NodeUserCapPrefix+"mac-c", "0")
	old := trialPoolLeft
	t.Cleanup(func() { trialPoolLeft = old })
	pool := func(left float64, ok bool) { trialPoolLeft = func(*Server) (float64, bool) { return left, ok } }
	pool(0, false)

	now := time.Now()
	const p = "gh:7401"
	if err := h.srv.Store.StartTrialAs(p, store.IdentityGitHub, "7401", now); err != nil {
		t.Fatal(err)
	}
	claim := func(want, reason string) tryAnswer {
		t.Helper()
		a, err := h.srv.tryClaim(p, "", time.Now())
		if err != nil || a.State != want || a.Reason != reason {
			t.Fatalf("claim = %+v, %v; want %s/%s", a, err, want, reason)
		}
		return a
	}
	setHubSetting(t, h.srv, TrialSlotsKey, "0")
	if a := claim("waiting", trialWaitFull); a.ETASecs <= 0 {
		t.Fatalf("a full wait has no ETA: %+v", a)
	}
	setHubSetting(t, h.srv, TrialSlotsKey, "8")
	pool(10, true)
	claim("waiting", trialWaitQuota)
	pool(40, true) // under half: the day's 2 halve to 1
	setHubSetting(t, h.srv, TrialDailyKey, "2")
	if err := h.srv.Store.StartTrialAs("gh:7402", store.IdentityGitHub, "7402", now); err != nil {
		t.Fatal(err)
	}
	if err := h.srv.Store.PlaceTrial("gh:7402", "mac-d", now); err != nil {
		t.Fatal(err)
	}
	claim("day_full", "")
	pool(90, true)
	// The machine's own gate holds new sessions: busy.
	no := false
	beat(t, nodes["mac-d"].c, control.Proto, control.Heartbeat{Hostname: "mac-d", OSUser: "ivan", Sessions: 1, NCPU: 8, Admit: &no, AdmitWhy: "内存紧张"})
	waitFor(t, 3*time.Second, "mac-d's gate to say no", func() bool { return h.srv.trialHold("mac-d", time.Now()) == trialWaitBusy })
	// Load over 0.8 × cores.
	beat(t, nodes["mac-d"].c, control.Proto, control.Heartbeat{Hostname: "mac-d", OSUser: "ivan", Sessions: 1, NCPU: 8, Load1: 7})
	waitFor(t, 3*time.Second, "mac-d's load to read", func() bool { return h.srv.trialHold("mac-d", time.Now()) == trialWaitLoad })
	setHubSetting(t, h.srv, TrialLoadRatioKey, "1")
	beatCount(t, nodes["mac-d"], "mac-d", "ivan", 1)
	waitFor(t, 3*time.Second, "mac-d to admit again", func() bool { return h.srv.trialHold("mac-d", time.Now()) == "" })
	if !auditHas(mustAudit(t, h), "trial.queued", "waiting", "reason=quota") {
		t.Errorf("no trial.queued audit for the pool")
	}
	// Every gate open: the seat.
	if a, err := h.srv.tryClaim(p, "", time.Now()); err != nil || (a.State != "ready" && a.State != "opening") {
		t.Fatalf("claim with every gate open = %+v, %v; want a seat", a, err)
	}
	if !auditHas(mustAudit(t, h), "trial.claim", "ok", "mac-d") {
		t.Errorf("no trial.claim audit")
	}
	// The ETA follows the last releases' spacing once two are known.
	for i, q := range []string{"gh:7403", "gh:7404"} {
		_ = h.srv.Store.StartTrialAs(q, store.IdentityGitHub, q[3:], now)
		_ = h.srv.Store.PlaceTrial(q, "mac-d", now)
		if err := h.srv.Store.ReclaimTrial(q, now.Add(time.Duration(i)*90*time.Second)); err != nil {
			t.Fatal(err)
		}
	}
	if eta := h.srv.trialETA("mac-d", 1); eta != 180 {
		t.Fatalf("ETA one behind = %d; want 2 × the 90 s spacing", eta)
	}
}
