package api

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/authz"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

// claude-fleet#4215: a drill trier walks the real trial — an admin's one-time
// code into the same trialSignIn, the same claim / give-back / conversation —
// and is deleted with everything of it when its life runs out.

func drillTrialHarness(t *testing.T) *harness {
	t.Helper()
	h := newFleetHarness(t)
	enablePeople(t, h)
	setHubSetting(t, h.srv, TrialKey, "on")
	return h
}

// mintTrier is the operator's POST /v1/admin/drill/trial.
func mintTrier(t *testing.T, h *harness, body map[string]any) DrillTrialResponse {
	t.Helper()
	code, raw := drillReq(t, h, http.MethodPost, DrillTrialPath, viewerToken, body)
	if code != http.StatusOK {
		t.Fatalf("mint %v = %d %s", body, code, raw)
	}
	var out DrillTrialResponse
	if err := json.Unmarshal(raw, &out); err != nil {
		t.Fatal(err)
	}
	return out
}

// redeem opens the code's URL with no cookie; the answer is not followed.
func redeem(t *testing.T, h *harness, code string) *http.Response {
	t.Helper()
	resp, err := noFollow.Get(h.http.URL + DrillTrialRedeemPath + "?code=" + url.QueryEscape(code))
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	return resp
}

// trierSession is the session the redeem set, verified as the hub reads it.
func trierSession(t *testing.T, h *harness, resp *http.Response) (*http.Cookie, *authz.Session) {
	t.Helper()
	c := cookieNamed(resp, authz.CookieName)
	if c == nil {
		t.Fatalf("redeem set no session (status %d)", resp.StatusCode)
	}
	sess, _, ok := h.srv.personSessionValue(c.Value)
	if !ok {
		t.Fatalf("the redeem's session does not verify")
	}
	return c, sess
}

func TestDrillTrialMintIsAdminOnly(t *testing.T) {
	h := drillTrialHarness(t)
	if code, _ := asPerson(t, h, http.MethodPost, DrillTrialPath, pAlice, []byte(`{}`)); code != http.StatusForbidden {
		t.Fatalf("a colleague minted a drill trier: %d, want 403", code)
	}
	if code, _ := drillReq(t, h, http.MethodPost, DrillTrialPath, "", map[string]any{}); code != http.StatusUnauthorized && code != http.StatusForbidden {
		t.Fatalf("no credential: %d", code)
	}
	for _, bad := range []map[string]any{{"ttl_seconds": 60}, {"ttl_seconds": 3 * 86400}} {
		if code, body := drillReq(t, h, http.MethodPost, DrillTrialPath, viewerToken, bad); code != http.StatusBadRequest {
			t.Fatalf("mint %v: %d %s, want 400", bad, code, body)
		}
	}
	if code, _ := drillReq(t, h, http.MethodPost, DrillTrialPath, viewerToken, map[string]any{"subject": "trial-nobody"}); code != http.StatusNotFound {
		t.Fatalf("another code for nobody: %d, want 404", code)
	}
	out := mintTrier(t, h, map[string]any{})
	if out.Kind != store.DrillKind || !strings.HasPrefix(out.Subject, "trial-") || !drillTrialCodeRe.MatchString(out.Code) ||
		!strings.HasSuffix(out.URL, DrillTrialRedeemPath+"?code="+out.Code) || out.PersonID != "" {
		t.Fatalf("mint = %+v", out)
	}
	if d := time.Until(out.ExpiresAt); d < DrillDefaultTTL-time.Minute || d > DrillDefaultTTL {
		t.Fatalf("life %v; want 2h", d)
	}
	if d := time.Until(out.CodeExpiresAt); d < drillTrialCodeTTL-time.Minute || d > drillTrialCodeTTL {
		t.Fatalf("code life %v; want 600 s", d)
	}
	if !auditHas(mustAudit(t, h), "drill.trial.mint", "ok", "") {
		t.Errorf("no drill.trial.mint audit")
	}
}

// The heart of #4215: the code once, into a trial session — not the list,
// not the console — and the same person back on a second code.
func TestDrillTrialCodeOnceIntoTheTrial(t *testing.T) {
	h := drillTrialHarness(t)
	out := mintTrier(t, h, map[string]any{"ttl_seconds": 900})
	resp := redeem(t, h, out.Code)
	if resp.StatusCode != http.StatusFound || resp.Header.Get("Location") != TryPagePath {
		t.Fatalf("redeem = %d → %q; want 302 → %s", resp.StatusCode, resp.Header.Get("Location"), TryPagePath)
	}
	c, sess := trierSession(t, h, resp)
	if sess.Sub != store.DrillKind || sess.Role != roleTrial {
		t.Fatalf("session = %+v; want kind drill, role trial", sess)
	}
	pid := sess.UID
	if role, err := h.srv.personRole(pid); err != nil || role != roleTrial {
		t.Fatalf("role = %q, %v; want trial", role, err)
	}
	if u, _ := h.srv.Store.HubUserByPrincipal(pid); u != nil {
		t.Fatalf("a drill trier was put on the list: %+v", u)
	}
	if d, _ := h.srv.Store.DrillTrialOf(pid); d == nil || d.Subject != out.Subject {
		t.Fatalf("drill trier of %s = %+v", pid, d)
	}
	if tr, _ := h.srv.Store.TrialByWay(store.DrillKind, out.Subject); tr == nil || tr.Principal != pid || tr.State != store.TrialWaiting {
		t.Fatalf("trial = %+v; want %s waiting", tr, pid)
	}
	// The chat and the trial answer it; the console does not.
	do := func(method, path string) int {
		req, _ := http.NewRequest(method, h.http.URL+path, nil)
		req.AddCookie(c)
		req.Header.Set(tryHeader, "1")
		resp, err := noFollow.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		return resp.StatusCode
	}
	if code := do(http.MethodPost, TryClaimPath); code != http.StatusOK {
		t.Fatalf("drill trier's claim = %d; want 200", code)
	}
	for _, p := range []string{control.SessionsPath, "/v1/fleet/settings", AdminPrefix, TryStatsPath, DrillTrialPath} {
		if code := do(http.MethodGet, p); code != http.StatusNotFound {
			t.Errorf("drill trier GET %s = %d; want 404", p, code)
		}
	}
	// Replayed: refused, nothing set.
	if again := redeem(t, h, out.Code); again.StatusCode != http.StatusUnauthorized || cookieNamed(again, authz.CookieName) != nil {
		t.Fatalf("a replayed code = %d; want 401, no session", again.StatusCode)
	}
	if code := redeem(t, h, "ft_aaaaaaaaaaaaaaaaaaaaaaaaaa").StatusCode; code != http.StatusUnauthorized {
		t.Fatalf("an unknown code = %d; want 401", code)
	}
	// Coming back: another code for the same subject is the same person.
	back := mintTrier(t, h, map[string]any{"subject": out.Subject})
	if back.Subject != out.Subject || back.PersonID != pid || back.Code == out.Code {
		t.Fatalf("again = %+v; want the same %s / %s, a new code", back, out.Subject, pid)
	}
	if byPid := mintTrier(t, h, map[string]any{"subject": pid}); byPid.Subject != out.Subject {
		t.Fatalf("again by person = %+v", byPid)
	}
	if _, sess2 := trierSession(t, h, redeem(t, h, back.Code)); sess2.UID != pid {
		t.Fatalf("came back as %s; want %s", sess2.UID, pid)
	}
	// A code past its own life is worth nothing.
	stale := "ft_bbbbbbbbbbbbbbbbbbbbbbbbbb"
	if err := h.srv.Store.AddDrillTrialCode(out.Subject, HashToken(stale), time.Now().Add(-time.Second), time.Now()); err != nil {
		t.Fatal(err)
	}
	if code := redeem(t, h, stale).StatusCode; code != http.StatusUnauthorized {
		t.Fatalf("an expired code = %d; want 401", code)
	}
	if !auditHas(mustAudit(t, h), "drill.trial.redeem", "refused", "") || !auditHas(mustAudit(t, h), "trial.start", "ok", "") {
		t.Errorf("redeem audits missing")
	}
}

// Its life over, a drill trier with a machine gives it back on the real
// road and goes with its conversation, identity and trial; a code minted
// before is worth nothing.
func TestDrillTrialExpiresGivesBackAndDeletes(t *testing.T) {
	h := drillTrialHarness(t)
	nodes := spareFleet(t, h)
	sparesOn(t, h, "2")
	openSpares(t, nodes["mac-c"], 2, control.CredsepSeparated)
	openSpares(t, nodes["mac-d"], 2, control.CredsepSeparated)
	readySpares(t, h, "mac-d", 2)

	out := mintTrier(t, h, map[string]any{"ttl_seconds": 300})
	_, sess := trierSession(t, h, redeem(t, h, out.Code))
	pid := sess.UID
	later := mintTrier(t, h, map[string]any{"subject": out.Subject})
	now := time.Now()
	if got := h.srv.claimSpares(pid, pid, pid, []string{"mac-d"}, now); len(got) != 1 {
		t.Fatalf("claim = %v", got)
	}
	if err := h.srv.Store.PlaceTrial(pid, "mac-d", now); err != nil {
		t.Fatal(err)
	}
	if err := h.srv.Store.PutTrialConvo(pid, []byte("sealed"), now.Add(24*time.Hour), now); err != nil {
		t.Fatal(err)
	}
	h.srv.SweepDrillTrials(now.Add(4 * time.Minute))
	if a := accountState(t, h, pid, "mac-d"); a.State != store.AccountActive {
		t.Fatalf("swept with life left: %+v", a)
	}
	end := now.Add(6 * time.Minute)
	h.srv.SweepDrillTrials(end)
	if tr, _ := h.srv.Store.TrialByWay(store.DrillKind, out.Subject); tr != nil && tr.State == store.TrialPlaced {
		t.Fatalf("an expired drill trier keeps its machine: %+v", tr)
	}
	for i := 0; i < 3; i++ {
		if d, _ := h.srv.Store.DrillTrialBySubject(out.Subject); d == nil {
			break
		}
		// A remove on its way back: answered, then the next sweep deletes.
		if m, op, ok := tryAccountOp(nodes["mac-d"]); ok {
			sendResult(t, nodes["mac-d"].c, m.OpID, control.AccountResult{Op: op.Op, Login: op.Login, OK: true, Credsep: control.CredsepSeparated})
			time.Sleep(200 * time.Millisecond)
		}
		h.srv.SweepDrillTrials(end)
	}
	if d, _ := h.srv.Store.DrillTrialBySubject(out.Subject); d != nil {
		t.Fatalf("drill trier still there: %+v (accounts %+v)", d, mustAccounts(t, h, pid))
	}
	for _, a := range mustAccounts(t, h, pid) {
		t.Errorf("a login row is still its: %+v", a)
	}
	if c, _ := h.srv.Store.TrialConvo(pid, end); c != nil {
		t.Fatalf("its conversation's ciphertext is still kept")
	}
	if tr, _ := h.srv.Store.Trial(pid); tr != nil {
		t.Fatalf("its trial is still there: %+v", tr)
	}
	if owner, _ := h.srv.Store.IdentityPrincipal(store.DrillKind, out.Subject); owner != "" {
		t.Fatalf("its identity still lets %s in", owner)
	}
	if role, _ := h.srv.personRole(pid); role != "" {
		t.Fatalf("role after = %q; want none", role)
	}
	if code := redeem(t, h, later.Code).StatusCode; code != http.StatusUnauthorized {
		t.Fatalf("a code minted before its end = %d; want 401", code)
	}
	if !auditHas(mustAudit(t, h), "drill.trial.delete", "ok", "") || !auditHas(mustAudit(t, h), "trial.release", "ok", "reason=drill") {
		t.Errorf("no drill.trial.delete / trial.release reason=drill audit")
	}
}

// tryAccountOp is the next account op sent to n, if one comes.
func tryAccountOp(n *fleetNode) (control.Message, control.AccountOp, bool) {
	for i := 0; i < 4; i++ {
		m, ok := readMsg(n.tnode, 250*time.Millisecond)
		if !ok {
			return control.Message{}, control.AccountOp{}, false
		}
		if m.Type != control.TypeAccountOp {
			continue
		}
		var op control.AccountOp
		if json.Unmarshal(m.Payload, &op) != nil {
			return control.Message{}, control.AccountOp{}, false
		}
		return m, op, true
	}
	return control.Message{}, control.AccountOp{}, false
}

// DELETE /v1/self by its own session deletes a drill trier at once.
func TestDrillTrialSelfDelete(t *testing.T) {
	h := drillTrialHarness(t)
	out := mintTrier(t, h, map[string]any{})
	c, sess := trierSession(t, h, redeem(t, h, out.Code))
	req, _ := http.NewRequest(http.MethodDelete, h.http.URL+DrillSelfPath, nil)
	req.AddCookie(c)
	resp, err := noFollow.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("self-delete = %d; want 200", resp.StatusCode)
	}
	if d, _ := h.srv.Store.DrillTrialOf(sess.UID); d != nil {
		t.Fatalf("still there: %+v", d)
	}
	if _, _, ok := h.srv.personSessionValue(c.Value); ok {
		if role, _ := h.srv.personRole(sess.UID); role != "" {
			t.Fatalf("its session still has a role: %q", role)
		}
	}
	// A real trial person cannot delete itself this way.
	const realP = "p:00000000-0000-4000-8000-000000004215"
	rc := trialSession(t, h, realP)
	req, _ = http.NewRequest(http.MethodDelete, h.http.URL+DrillSelfPath, nil)
	req.AddCookie(rc)
	resp, err = noFollow.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusNotFound {
		t.Fatalf("a real trial person's DELETE /v1/self = %d; want 404 as before", resp.StatusCode)
	}
	if tr, _ := h.srv.Store.Trial(realP); tr == nil {
		t.Fatalf("a real trial person was deleted")
	}
}

// No code, no change: fleet.trial off 404s the mint and answers a redeem
// link 试用暂未开放 (claude-fleet#4269); a real sign-in's
// trial is the one it always was.
func TestDrillTrialOffAddsNothing(t *testing.T) {
	h := newFleetHarness(t)
	enablePeople(t, h)
	if code, _ := drillReq(t, h, http.MethodPost, DrillTrialPath, viewerToken, map[string]any{}); code != http.StatusNotFound {
		t.Fatalf("mint with fleet.trial off = %d; want 404", code)
	}
	if resp := redeem(t, h, "ft_aaaaaaaaaaaaaaaaaaaaaaaaaa"); resp.StatusCode != http.StatusOK || cookieNamed(resp, authz.CookieName) != nil {
		t.Fatalf("redeem with fleet.trial off = %d; want 200, the 试用暂未开放 page and no session (claude-fleet#4269)", resp.StatusCode)
	}
	setHubSetting(t, h.srv, TrialKey, "on")
	w := httptest.NewRecorder()
	r := httptestRequestWithCookie(tryCookie, "1")
	if !h.srv.trialSignIn(w, r, h.srv.trialAsked(r), store.IdentityEmail, "real@example.com", "real", "", time.Now()) {
		t.Fatalf("a real sign-in was not made a trial")
	}
	c := cookieNamed(w.Result(), authz.CookieName)
	sess, pid, ok := h.srv.personSessionValue(c.Value)
	if !ok || sess.Sub != store.IdentityEmail || sess.Role != roleTrial {
		t.Fatalf("real session = %+v", sess)
	}
	if d, _ := h.srv.Store.DrillTrialOf(pid); d != nil {
		t.Fatalf("a real trial person reads as a drill trier")
	}
	if ex, _ := h.srv.Store.ExpiredDrillTrials(time.Now().Add(48 * time.Hour)); len(ex) != 0 {
		t.Fatalf("drill rows with no code: %+v", ex)
	}
	for _, e := range mustAudit(t, h) {
		if strings.HasPrefix(e.Action, "drill.") {
			t.Errorf("a drill audit with no code: %+v", e)
		}
	}
	// A drill kind is never one a person adds as a way in.
	if store.KnownIdentityKind(store.DrillKind) {
		t.Fatalf("drill is listed as a way to sign in")
	}
}
