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

	"github.com/verkyyi/claude-fleet/tokenledger/hub/authz"
	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

// claude-fleet#3590 (EPIC #3569 C20): the 60-second trial. A trial invite lets
// a stranger in; the first in line takes a ready spare, the rest wait and are
// told roughly how long; the page's one timing is kept anonymously; a spent
// trial's login goes back (claude-fleet#4059). fleet.trial off adds nothing.

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

// With the trial off an old trial link is 试用暂未开放 + the way to apply
// (claude-fleet#4269), never an error, and the trial's doors stay shut.
func TestTryOffSaysApply(t *testing.T) {
	h := newFleetHarness(t)
	enablePeople(t, h)
	for _, lang := range []string{"zh", "en"} {
		resp, err := noFollow.Get(h.http.URL + TryPagePath + "?from=site&lang=" + lang)
		if err != nil {
			t.Fatal(err)
		}
		b, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		want := map[string]string{"zh": "试用暂未开放", "en": "The trial isn&#39;t open"}[lang]
		if resp.StatusCode != http.StatusOK || !strings.Contains(string(b), want) ||
			!strings.Contains(string(b), `href="`+ApplyPath+`"`) || strings.Contains(string(b), tryScriptPath) {
			t.Fatalf("GET /app/try?lang=%s with the trial off = %d; want 200, %q and an apply button:\n%s", lang, resp.StatusCode, want, b)
		}
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

// A spent trial goes back (claude-fleet#4059, it replaced the 7-day reclaim):
// fleet.trial.max_secs on a machine, or the last line's reply given
// trialCapGrace; one with budget left stays; a spent trial who comes back has
// tried (fleet.trial.once) or rejoins the line with a whole budget.
func TestTrySweepEndsASpentTrial(t *testing.T) {
	h := newFleetHarness(t)
	enablePeople(t, h)
	nodes := spareFleet(t, h)
	setHubSetting(t, h.srv, TrialKey, "on")
	sparesOn(t, h, "2")
	openSpares(t, nodes["mac-c"], 2, control.CredsepSeparated)
	openSpares(t, nodes["mac-d"], 2, control.CredsepSeparated)
	readySpares(t, h, "mac-d", 2)

	const timed, talked = "gh:7301", "gh:7302"
	now := time.Now()
	for _, p := range []string{timed, talked} {
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
	// talked sends all 20 lines in the first minute; the 21st is refused.
	for i := 1; i <= defaultTrialMaxMsgs; i++ {
		if code, _, _ := h.srv.trialTurn(&nopWriter{h: http.Header{}}, talked, now.Add(time.Minute)); code != "" {
			t.Fatalf("line %d refused: %s", i, code)
		}
	}
	if code, _, _ := h.srv.trialTurn(&nopWriter{h: http.Header{}}, talked, now.Add(time.Minute)); code != "trial_over" {
		t.Fatalf("line 21 = %q; want trial_over", code)
	}
	h.srv.SweepTrials(now.Add(time.Minute + trialCapGrace - time.Second))
	for _, p := range []string{timed, talked} {
		if a := accountState(t, h, p, "mac-d"); a.State != store.AccountActive {
			t.Fatalf("%s swept with budget (or its last reply's grace) left: %+v", p, a)
		}
	}
	h.srv.SweepTrials(now.Add(time.Minute + trialCapGrace + time.Second))
	if a := accountState(t, h, talked, "mac-d"); a.State == store.AccountActive {
		t.Fatalf("a trial past its lines was not given back: %+v", a)
	}
	if tr, _ := h.srv.Store.Trial(talked); tr == nil || tr.State != store.TrialReclaimed || tr.EndedReason != trialEndMsgs || tr.Msgs != 20 {
		t.Fatalf("talked = %+v; want reclaimed for msgs after 20 lines", tr)
	}
	if a := accountState(t, h, timed, "mac-d"); a.State != store.AccountActive {
		t.Fatalf("a trial with time left was swept: %+v", a)
	}
	h.srv.SweepTrials(now.Add(time.Duration(defaultTrialMaxSecs-1) * time.Second))
	if a := accountState(t, h, timed, "mac-d"); a.State != store.AccountActive {
		t.Fatalf("swept before 900 s: %+v", a)
	}
	h.srv.SweepTrials(now.Add(time.Duration(defaultTrialMaxSecs) * time.Second))
	if tr, _ := h.srv.Store.Trial(timed); tr == nil || tr.State != store.TrialReclaimed || tr.EndedReason != trialEndTime || tr.UsedSecs != defaultTrialMaxSecs {
		t.Fatalf("timed = %+v; want reclaimed for time after 900 s", tr)
	}
	if !auditHas(mustAudit(t, h), "trial.release", "ok", "reason=msgs") || !auditHas(mustAudit(t, h), "trial.release", "ok", "reason=time") {
		t.Errorf("no trial.release audit rows with their reasons")
	}
	// What the chat reads now: ended, why, and where to apply.
	st, err := h.srv.trialStateOf(timed, now.Add(time.Hour))
	if err != nil || st.State != "ended" || st.Ended != trialEndTime || st.SecsLeft != 0 || st.Apply != ApplyPath+"?from=trial" {
		t.Fatalf("state after = %+v, %v", st, err)
	}
	// Back after it: one trial per account — 「已试过」, pointed at /apply.
	later := now.Add(time.Hour)
	if a, err := h.srv.tryClaim(timed, "", later); err != nil || a.State != "tried" || a.Next != ApplyPath {
		t.Fatalf("a second trial = %+v, %v; want tried → /apply", a, err)
	}
	// With fleet.trial.once off: to the end of the line with a whole budget.
	setHubSetting(t, h.srv, TrialOnceKey, "off")
	if _, err := h.srv.tryClaim(timed, "", later); err != nil {
		t.Fatal(err)
	}
	if tr, _ := h.srv.Store.Trial(timed); tr == nil || tr.State == store.TrialReclaimed || tr.UsedSecs != 0 || tr.Msgs != 0 || tr.EndedReason != "" {
		t.Fatalf("reclaimed trial after a claim = %+v; want back in line, budget whole", tr)
	}
}

// What is left (claude-fleet#4059): GET /v1/try/state counts the time held
// and the lines sent; every line's answer carries the same two numbers; the
// settings move the budget; fleet.trial off 404s.
func TestTryStateCountsDown(t *testing.T) {
	h := newFleetHarness(t)
	enablePeople(t, h)
	setHubSetting(t, h.srv, TrialKey, "on")
	setHubSetting(t, h.srv, TrialMaxSecsKey, "600")
	setHubSetting(t, h.srv, TrialMaxMsgsKey, "5")
	const pid = "p:00000000-0000-4000-8000-000000004059"
	c := trialSession(t, h, pid)
	get := func() (int, trialState) {
		req, _ := http.NewRequest(http.MethodGet, h.http.URL+TryStatePath, nil)
		req.AddCookie(c)
		resp, err := noFollow.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		var st trialState
		_ = json.NewDecoder(resp.Body).Decode(&st)
		return resp.StatusCode, st
	}
	if code, st := get(); code != http.StatusOK || st.State != "waiting" || st.SecsLeft != 600 || st.MsgsLeft != 5 || st.MaxMsgs != 5 {
		t.Fatalf("waiting state = %d %+v", code, st)
	}
	now := time.Now()
	if err := h.srv.Store.PlaceTrial(pid, "mac-d", now.Add(-100*time.Second)); err != nil {
		t.Fatal(err)
	}
	w := &nopWriter{h: http.Header{}}
	if code, _, _ := h.srv.trialTurn(w, pid, now); code != "" {
		t.Fatalf("a line with budget left refused: %s", code)
	}
	if got := w.h.Get(trialLeftHeader); got != "500,4" {
		t.Fatalf("%s = %q; want 500,4", trialLeftHeader, got)
	}
	code, st := get()
	if code != http.StatusOK || st.State != "running" || st.MsgsLeft != 4 || st.SecsLeft > 500 || st.SecsLeft < 495 {
		t.Fatalf("running state = %d %+v", code, st)
	}
	// Time up: the line is refused before it is counted.
	if code, _, _ := h.srv.trialTurn(&nopWriter{h: http.Header{}}, pid, now.Add(501*time.Second)); code != "trial_over" {
		t.Fatalf("a line past the time = %q; want trial_over", code)
	}
	if tr, _ := h.srv.Store.Trial(pid); tr.Msgs != 1 {
		t.Fatalf("msgs = %d; want the refused line not counted", tr.Msgs)
	}
	// A member is not held by any of it.
	if code, _, _ := h.srv.trialTurn(&nopWriter{h: http.Header{}}, "gh:7399", now); code != "" {
		t.Fatalf("a member's line = %q", code)
	}
	setHubSetting(t, h.srv, TrialKey, "off")
	if code, _ := get(); code != http.StatusNotFound {
		t.Fatalf("state with the trial off = %d; want 404", code)
	}
}

// Approved (claude-fleet#4059): a trial person becomes a member — role user,
// the trial converted, the login they hold stays theirs and the sweep leaves
// it; the chat reads member.
func TestApprovedTrialBecomesAMember(t *testing.T) {
	h := newFleetHarness(t)
	enablePeople(t, h)
	nodes := spareFleet(t, h)
	setHubSetting(t, h.srv, TrialKey, "on")
	sparesOn(t, h, "1")
	openSpares(t, nodes["mac-d"], 1, control.CredsepSeparated)
	readySpares(t, h, "mac-d", 1)
	const pid = "p:00000000-0000-4000-8000-000000004061"
	now := time.Now()
	if err := h.srv.Store.StartTrialAs(pid, store.IdentityEmail, "kept@example.com", now); err != nil {
		t.Fatal(err)
	}
	if err := h.srv.Store.AddHubIdentity(store.HubIdentity{Kind: store.IdentityEmail, Subject: "kept@example.com",
		PrincipalID: pid, VerifiedAt: now, AddedBy: "trial"}); err != nil {
		t.Fatal(err)
	}
	if got := h.srv.claimSpares(pid, pid, pid, []string{"mac-d"}, now); len(got) != 1 {
		t.Fatalf("claim = %v", got)
	}
	if err := h.srv.Store.PlaceTrial(pid, "mac-d", now); err != nil {
		t.Fatal(err)
	}
	if role, _ := h.srv.personRole(pid); role != roleTrial {
		t.Fatalf("role before = %q; want trial", role)
	}
	req := &store.AccessRequest{ID: "rq-trial", Kind: store.IdentityEmail, Subject: "kept@example.com", Display: "Kept"}
	if got, err := h.srv.admitRequest(req, "gh:1", now.Add(time.Minute)); err != nil || got != pid {
		t.Fatalf("admit = %q, %v; want the trial's person", got, err)
	}
	if role, _ := h.srv.personRole(pid); role != roleUser {
		t.Fatalf("role after = %q; want user", role)
	}
	tr, _ := h.srv.Store.Trial(pid)
	if tr == nil || tr.State != store.TrialConverted || tr.EndedReason != "approved" || h.srv.trialPerson(pid) {
		t.Fatalf("trial after approval = %+v", tr)
	}
	if st, _ := h.srv.trialStateOf(pid, now); st.State != "member" {
		t.Fatalf("state after approval = %+v; want member", st)
	}
	h.srv.SweepTrials(now.Add(time.Hour))
	if a := accountState(t, h, pid, "mac-d"); a.State != store.AccountActive {
		t.Fatalf("the approved person's login went back: %+v", a)
	}
	if code, _, _ := h.srv.trialTurn(&nopWriter{h: http.Header{}}, pid, now.Add(time.Hour)); code != "" {
		t.Fatalf("an approved person's line = %q; want through", code)
	}
	if !auditHas(mustAudit(t, h), "trial.convert", "ok", "") {
		t.Errorf("no trial.convert audit row")
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
	// Only mac-d may hand out a spare. Set the cap before replenishing:
	// lowering it afterwards leaves mac-c's ready spare claimable (#4129).
	setHubSetting(t, h.srv, NodeUserCapPrefix+"mac-c", "0")
	sparesOn(t, h, "1")
	openSpares(t, nodes["mac-d"], 1, control.CredsepSeparated)
	readySpares(t, h, "mac-d", 1)
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
	waitFor(t, 3*time.Second, "mac-d's gate to say no", func() bool { return h.srv.trialHold("mac-d", time.Now()) == trialWaitBusyAdmit })
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
	if audit := mustAudit(t, h); !auditHas(audit, "trial.claim", "ok", "mac-d") {
		t.Errorf("no trial.claim audit for mac-d: %+v", audit)
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

// The sign-in pages offer the trial only while it is on (claude-fleet#4269).
func TestSigninLeadTrialOnlyWhenOn(t *testing.T) {
	h := newFleetHarness(t)
	enablePeople(t, h)
	for _, c := range []struct {
		on        string
		want, not string
	}{{"off", "登录后当场申请", "先试用"}, {"on", "登录后可以先试用、当场申请", "登录后当场申请"}} {
		setHubSetting(t, h.srv, TrialKey, c.on)
		rec := httptest.NewRecorder()
		h.srv.renderSigninWays(rec, httptest.NewRequest(http.MethodGet, "/app/signin?lang=zh", nil), "zh-CN", "")
		if b := rec.Body.String(); !strings.Contains(b, c.want) || strings.Contains(b, c.not) {
			t.Errorf("fleet.trial %s: sign-in lead lacks %q or says %q", c.on, c.want, c.not)
		}
	}
}
