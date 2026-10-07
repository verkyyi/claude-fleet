package api

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/json"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"golang.org/x/crypto/ssh"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/authz"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/sshca"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// claude-fleet#2261 (EPIC #2259 C2): an invite lets a newcomer in at their
// GitHub sign-in — on the list, the invite spent, their login opened —
// and an invite that cannot be used, or no invite at all, is refused in
// words that say who to ask.

// inviteHarness is the GitHub harness with the fleet module and a CA on, so
// `fleet login` and /i/<code> answer too.
func inviteHarness(t *testing.T) *ghHarness {
	t.Helper()
	return newGitHubHarnessWith(t, func(s *Server) {
		if err := s.Store.EnsureNodes(); err != nil {
			t.Fatal(err)
		}
		s.Fleet = true
		_, priv, _ := ed25519.GenerateKey(rand.Reader)
		signer, _ := ssh.NewSignerFromKey(priv)
		s.SSHCA = sshca.New(signer)
	}, ghAdmin.Login)
}

// mintInvite is POST /v1/fleet/invites as the operator.
func (h *ghHarness) mintInvite(t *testing.T, githubLogin string) InviteCreated {
	t.Helper()
	body, _ := json.Marshal(map[string]string{"github_login": githubLogin})
	req, _ := http.NewRequest(http.MethodPost, h.http.URL+"/v1/fleet/invites", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+viewerToken)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusCreated {
		b, _ := io.ReadAll(resp.Body)
		t.Fatalf("mint = %d %s", resp.StatusCode, b)
	}
	var out InviteCreated
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		t.Fatal(err)
	}
	return out
}

// operatorDo is one operator request; the status and the body.
func (h *ghHarness) operatorDo(t *testing.T, method, path string) (int, string) {
	t.Helper()
	req, _ := http.NewRequest(method, h.http.URL+path, nil)
	req.Header.Set("Authorization", "Bearer "+viewerToken)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, string(b)
}

// signInWith is signIn with more cookies on the callback (an invite, a
// waiting `fleet login`'s code); the callback's response and its body.
func (h *ghHarness) signInWith(t *testing.T, u fakeGHUser, more ...*http.Cookie) (*http.Response, string) {
	t.Helper()
	resp, err := noFollow.Get(h.http.URL + "/auth/github/start")
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	loc, _ := url.Parse(resp.Header.Get("Location"))
	q := loc.Query()
	flow := cookieNamed(resp, githubFlowCookie)
	h.n++
	code := "c" + strconv.Itoa(h.n)
	h.gh.mu.Lock()
	h.gh.codes[code] = fakeGrant{user: u, challenge: q.Get("code_challenge")}
	h.gh.mu.Unlock()
	req, _ := http.NewRequest(http.MethodGet, h.http.URL+"/auth/github/callback?code="+code+"&state="+url.QueryEscape(q.Get("state")), nil)
	req.Header.Set("Accept", "text/html")
	req.Header.Set("Accept-Language", "en")
	req.AddCookie(flow)
	for _, c := range more {
		req.AddCookie(c)
	}
	cb, err := noFollow.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer cb.Body.Close()
	b, _ := io.ReadAll(cb.Body)
	return cb, string(b)
}

func inviteCookieOf(code string) *http.Cookie { return &http.Cookie{Name: inviteCookie, Value: code} }

func (h *ghHarness) inviteState(t *testing.T, id string) store.Invite {
	t.Helper()
	invs, err := h.srv.Store.Invites()
	if err != nil {
		t.Fatal(err)
	}
	for _, i := range invs {
		if i.ID == id {
			return i
		}
	}
	t.Fatalf("no invite %s", id)
	return store.Invite{}
}

func auditHas(log []store.HubAuditEntry, action, outcome, detailPart string) bool {
	for _, e := range log {
		if e.Action == action && e.Outcome == outcome && strings.Contains(e.Detail, detailPart) {
			return true
		}
	}
	return false
}

// A valid code lets the person in, puts them on the list, spends the code
// and audits 「邀请已使用」; the same code lets nobody else in. The code is
// never written anywhere the hub keeps.
func TestInviteLetsANewcomerIn(t *testing.T) {
	h := inviteHarness(t)
	inv := h.mintInvite(t, "")
	if !strings.HasPrefix(inv.URL, h.http.URL+InvitePath) || inv.Command != "curl -fsSL "+inv.URL+" | sh" ||
		inv.State != "active" || inv.ExpiresAt.Sub(inv.CreatedAt) != store.InviteTTL {
		t.Fatalf("minted = %+v", inv)
	}

	cb, _ := h.signInWith(t, ghMallory, inviteCookieOf(inv.Code))
	if cb.StatusCode != http.StatusFound || cb.Header.Get("Location") != "/" {
		t.Fatalf("callback = %d → %q; want 302 → /", cb.StatusCode, cb.Header.Get("Location"))
	}
	if cookieNamed(cb, authz.CookieName) == nil {
		t.Fatal("no session set")
	}
	if c := cookieNamed(cb, inviteCookie); c == nil || c.MaxAge >= 0 {
		t.Errorf("the invite cookie was not spent: %+v", c)
	}
	u, err := h.srv.Store.HubUserByID(ghMallory.ID)
	if err != nil || u == nil || u.Role != store.RoleUser || !strings.Contains(u.AddedBy, inv.ID) {
		t.Fatalf("list row = %+v, %v", u, err)
	}
	got := h.inviteState(t, inv.ID)
	if got.State(time.Now()) != store.InviteUsed || got.UsedBy != githubPrincipal(ghMallory.ID) {
		t.Fatalf("invite after use = %+v", got)
	}
	log := h.audit(t)
	if !auditHas(log, "invite", "ok", "邀请已使用") || !auditHas(log, "invite", "created", "for anyone") {
		t.Errorf("audit lacks the invite rows: %+v", log)
	}

	// Used once: the next person is refused, with the reason.
	cb, body := h.signInWith(t, ghNewAlice, inviteCookieOf(inv.Code))
	if cb.StatusCode != http.StatusForbidden || !strings.Contains(body, "already used") {
		t.Fatalf("second use = %d %s", cb.StatusCode, body)
	}
	if u, _ := h.srv.Store.HubUserByID(ghNewAlice.ID); u != nil {
		t.Fatalf("a spent code put %+v on the list", u)
	}
	if !auditHas(h.audit(t), "invite", "refused", "invite used") {
		t.Errorf("no refused-invite audit row: %+v", h.audit(t))
	}

	// The code itself is nowhere: not the audit, not the list's answer.
	for _, e := range h.audit(t) {
		if strings.Contains(e.Detail+e.Target, inv.Code) {
			t.Fatalf("audit row carries the code: %+v", e)
		}
	}
	if _, list := h.operatorDo(t, http.MethodGet, "/v1/fleet/invites"); strings.Contains(list, inv.Code) ||
		!strings.Contains(list, `"state":"used"`) {
		t.Fatalf("list = %s", list)
	}
}

// Expired, revoked, unknown and someone else's codes are refused, each with
// a reason a person can act on, and put nobody on the list.
func TestInviteRefusals(t *testing.T) {
	h := inviteHarness(t)
	now := time.Now()

	expired := "expiredexpiredexpired0"
	if err := h.srv.Store.CreateInvite(store.Invite{ID: "inv_old", CodeHash: inviteHash(expired),
		CreatedAt: now.Add(-8 * 24 * time.Hour), ExpiresAt: now.Add(-24 * time.Hour)}); err != nil {
		t.Fatal(err)
	}
	revoked := h.mintInvite(t, "")
	if code, _ := h.operatorDo(t, http.MethodDelete, "/v1/fleet/invites?id="+revoked.ID); code != http.StatusOK {
		t.Fatalf("revoke = %d", code)
	}
	if code, _ := h.operatorDo(t, http.MethodDelete, "/v1/fleet/invites?id="+revoked.ID); code != http.StatusNotFound {
		t.Fatalf("revoke twice = %d; want 404", code)
	}
	forAlice := h.mintInvite(t, "Alice")

	for _, c := range []struct{ name, code, want, audit string }{
		{"expired", expired, "has expired", "invite expired"},
		{"revoked", revoked.Code, "withdrew", "invite revoked"},
		{"unknown", "neverminted-neverminted", "never made", "invite unknown"},
		{"other user", forAlice.Code, "another GitHub account", "invite other-user"},
	} {
		t.Run(c.name, func(t *testing.T) {
			cb, body := h.signInWith(t, ghMallory, inviteCookieOf(c.code))
			if cb.StatusCode != http.StatusForbidden || !strings.Contains(body, c.want) {
				t.Fatalf("callback = %d, body lacks %q:\n%s", cb.StatusCode, c.want, body)
			}
			if u, _ := h.srv.Store.HubUserByID(ghMallory.ID); u != nil {
				t.Fatalf("refused invite put %+v on the list", u)
			}
			if !auditHas(h.audit(t), "invite", "refused", c.audit) {
				t.Errorf("no audit row %q: %+v", c.audit, h.audit(t))
			}
		})
	}
	// The bound invite still works for the person it names.
	cb, _ := h.signInWith(t, fakeGHUser{ID: 400, Login: "alice"}, inviteCookieOf(forAlice.Code))
	if cb.StatusCode != http.StatusFound {
		t.Fatalf("alice with her own invite = %d", cb.StatusCode)
	}
}

// No code: the list alone decides, as before — and the refusal says the one
// line to send an admin. A listed person never spends an invite.
func TestInviteNoCodeIsTheListAsBefore(t *testing.T) {
	h := inviteHarness(t)
	cb, body := h.signInWith(t, ghMallory)
	if cb.StatusCode != http.StatusForbidden || !strings.Contains(body, "Nobody has invited") ||
		!strings.Contains(body, "Please invite GitHub user mallory") {
		t.Fatalf("no invite = %d:\n%s", cb.StatusCode, body)
	}
	if !hasAudit(h.audit(t), "refused", "not on the list") {
		t.Errorf("audit = %+v", h.audit(t))
	}
	inv := h.mintInvite(t, "")
	if cb, _ := h.signInWith(t, ghAdmin, inviteCookieOf(inv.Code)); cb.StatusCode != http.StatusFound {
		t.Fatalf("admin = %d", cb.StatusCode)
	}
	if st := h.inviteState(t, inv.ID).State(time.Now()); st != "active" {
		t.Fatalf("the admin's sign-in spent the invite: %s", st)
	}
}

// /i/<code>: a browser is sent to sign in carrying the code; `curl | sh` of a
// dead code prints why and exits 1; a live one gets the installer with
// FLEET_INVITE under its shebang.
func TestInviteInstallCommand(t *testing.T) {
	h := inviteHarness(t)
	var logged []string
	var mu sync.Mutex
	h.srv.LogWriter = func(line string) { mu.Lock(); logged = append(logged, line); mu.Unlock() }
	inv := h.mintInvite(t, "")
	defer func() {
		mu.Lock()
		defer mu.Unlock()
		for _, l := range logged {
			if strings.Contains(l, inv.Code) {
				t.Errorf("the request log carries the code: %q", l)
			}
		}
		if len(logged) == 0 {
			t.Error("nothing was logged — did LogWriter stop being read?")
		}
	}()

	req, _ := http.NewRequest(http.MethodGet, inv.URL, nil)
	req.Header.Set("Accept", "text/html")
	resp, err := noFollow.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if c := cookieNamed(resp, inviteCookie); resp.StatusCode != http.StatusFound || resp.Header.Get("Location") != "/signin" ||
		c == nil || c.Value != inv.Code || c.Path != githubFlowPath || !c.HttpOnly {
		t.Fatalf("browser = %d → %q, cookie %+v", resp.StatusCode, resp.Header.Get("Location"), c)
	}

	req, _ = http.NewRequest(http.MethodGet, h.http.URL+InvitePath+"neverminted-neverminted", nil)
	req.Header.Set("Accept-Language", "zh-CN")
	resp, err = http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	b, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK || !strings.HasPrefix(string(b), "#!/bin/sh\n") ||
		!strings.Contains(string(b), "本入口没发过这条邀请") || !strings.HasSuffix(string(b), "exit 1\n") {
		t.Fatalf("dead code = %d %q", resp.StatusCode, b)
	}

	if got := withInvite("#!/bin/sh\nset -eu\n", "abcdefghijklmnop"); got !=
		"#!/bin/sh\nFLEET_INVITE='abcdefghijklmnop'; export FLEET_INVITE  # invite (claude-fleet#2261): sent once by fleet login\nset -eu\n" {
		t.Fatalf("withInvite = %q", got)
	}
}

// `fleet login` carries the invite: the confirmation page, opened signed
// out, hands it to the GitHub callback, which lets the person in and sends
// them back to the confirmation.
func TestInviteRidesFleetLogin(t *testing.T) {
	h := inviteHarness(t)
	inv := h.mintInvite(t, "")
	st := h.deviceStart(t, inv.Code)

	req, _ := http.NewRequest(http.MethodGet, h.http.URL+"/fleet/login?code="+st.UserCode, nil)
	req.Header.Set("Accept", "text/html")
	resp, err := noFollow.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	ic, lc := cookieNamed(resp, inviteCookie), cookieNamed(resp, loginCookie)
	if ic == nil || ic.Value != inv.Code || lc == nil {
		t.Fatalf("signed-out confirmation page: invite %+v, login %+v", ic, lc)
	}
	cb, _ := h.signInWith(t, ghMallory, ic, lc)
	if cb.StatusCode != http.StatusFound || cb.Header.Get("Location") != "/fleet/login?code="+st.UserCode {
		t.Fatalf("callback = %d → %q", cb.StatusCode, cb.Header.Get("Location"))
	}
	if u, _ := h.srv.Store.HubUserByID(ghMallory.ID); u == nil {
		t.Fatal("the invite fleet login carried did not let mallory in")
	}
}

// A refused sign-in while `fleet login` waits: the terminal's next poll is
// the refusal, in the page's words, not ten minutes of waiting.
func TestInviteRefusalReachesTheTerminal(t *testing.T) {
	h := inviteHarness(t)
	st := h.deviceStart(t, "")
	cb, _ := h.signInWith(t, ghMallory, &http.Cookie{Name: loginCookie, Value: st.UserCode})
	to := cb.Header.Get("Location")
	if cb.StatusCode != http.StatusFound || !strings.HasPrefix(to, LoginRefusedPath+"?r=") {
		t.Fatalf("callback = %d → %q; want the refusal hop", cb.StatusCode, to)
	}
	req, _ := http.NewRequest(http.MethodGet, h.http.URL+to, nil)
	req.Header.Set("Accept", "text/html")
	req.Header.Set("Accept-Language", "en")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	b, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if resp.StatusCode != http.StatusForbidden || !strings.Contains(string(b), "Please invite GitHub user mallory") {
		t.Fatalf("hop page = %d:\n%s", resp.StatusCode, b)
	}
	code, poll := postJSON(t, &harness{srv: h.srv, http: h.http}, "/v1/fleet/login/poll", map[string]string{"device_code": st.DeviceCode})
	var res map[string]string
	_ = json.Unmarshal(poll, &res)
	if code != http.StatusForbidden || res["code"] != codeInviteRefused ||
		!strings.Contains(res["reason"], "Nobody has invited mallory") || !strings.Contains(res["reason"], "Please invite GitHub user mallory") {
		t.Fatalf("poll = %d %s", code, poll)
	}

	// A forged note does nothing.
	if resp, err := noFollow.Get(h.http.URL + LoginRefusedPath + "?r=forged.note"); err != nil || resp.StatusCode != http.StatusFound {
		t.Fatalf("forged hop = %v %v", resp, err)
	}
}

func (h *ghHarness) deviceStart(t *testing.T, invite string) DeviceStart {
	t.Helper()
	code, b := postJSON(t, &harness{srv: h.srv, http: h.http}, "/v1/fleet/login/start",
		map[string]string{"public_key": newUserKey(t), "invite": invite})
	if code != http.StatusOK {
		t.Fatalf("start = %d %s", code, b)
	}
	var st DeviceStart
	if err := json.Unmarshal(b, &st); err != nil {
		t.Fatal(err)
	}
	return st
}

// An invited person's login is opened whatever fleet.auto_assign says — on
// the least-busy machine when it names none; a person with no invite gets
// nothing, as before.
func TestInviteOpensTheLoginWithAutoAssignOff(t *testing.T) {
	h := newFleetHarness(t)
	enablePeople(t, h)
	nodes := leastBusyFleet(t, h)
	setHubSetting(t, h.srv, AutoAssignKey, "none")
	now := time.Now()

	const plain, invited = "gh:6001", "gh:6002"
	listPerson(t, h, plain, "plainy")
	h.srv.onPrincipalSignIn(plain, "plainy")
	if got, ok := readMsg(nodes["m5"].tnode, 300*time.Millisecond); ok && got.Type == control.TypeAccountOp {
		t.Fatalf("auto_assign none, no invite, yet m5 was sent %+v", got)
	}

	if err := h.srv.Store.CreateInvite(store.Invite{ID: "inv_x", CodeHash: inviteHash("codecodecodecodecode"),
		CreatedAt: now, ExpiresAt: now.Add(store.InviteTTL)}); err != nil {
		t.Fatal(err)
	}
	if _, err := h.srv.Store.UseInvite(inviteHash("codecodecodecodecode"), "invy", invited, now); err != nil {
		t.Fatal(err)
	}
	listPerson(t, h, invited, "invy")
	h.srv.onPrincipalSignIn(invited, "invy")
	_, op := expectAccountOp(t, nodes["m5"].tnode)
	if op.Op != control.AccountCreate || op.Login != "invy" {
		t.Fatalf("op = %+v; want a create of invy on m5", op)
	}
}
