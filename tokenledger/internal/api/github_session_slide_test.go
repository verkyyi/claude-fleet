package api

import (
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/authz"
)

// mintSession is a session cookie for u signed at `at` for the hub's TTL —
// a browser that signed in that long ago.
func (h *ghHarness) mintSession(u fakeGHUser, role string, at time.Time) *http.Cookie {
	return &http.Cookie{Name: authz.CookieName,
		Value: authz.SignRole("github", githubPrincipal(u.ID), u.Login, role, h.srv.sessionKey(), at, h.srv.sessionTTL())}
}

// meResp is /v1/me with a session cookie, the whole response.
func (h *ghHarness) meResp(t *testing.T, sess *http.Cookie) *http.Response {
	t.Helper()
	req, _ := http.NewRequest(http.MethodGet, h.http.URL+"/v1/me", nil)
	req.Header.Set("Accept", "application/json")
	req.AddCookie(sess)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	return resp
}

// A web session lives a day, and slides while it is used (claude-fleet#3701):
// a request with under 20% of it left gets a fresh day; one with more left
// gets nothing; a day-old one is refused.
func TestGitHubSignIn_SessionSlides(t *testing.T) {
	h := newGitHubHarness(t, "verkyyi")
	h.addUser(t, ghAlice)
	_, fresh := h.signIn(t, ghAlice)
	if fresh == nil || fresh.MaxAge != int((24*time.Hour).Seconds()) {
		t.Fatalf("sign-in cookie = %+v; want MaxAge of a day", fresh)
	}
	// Just signed in: nothing to renew.
	if resp := h.meResp(t, fresh); resp.StatusCode != http.StatusOK || cookieNamed(resp, authz.CookieName) != nil {
		t.Fatalf("fresh session: %d, re-signed %v", resp.StatusCode, cookieNamed(resp, authz.CookieName) != nil)
	}

	now := time.Now()
	// 10 hours in: 14 of 24 left, above 20%.
	if resp := h.meResp(t, h.mintSession(ghAlice, "user", now.Add(-10*time.Hour))); resp.StatusCode != http.StatusOK ||
		cookieNamed(resp, authz.CookieName) != nil {
		t.Fatalf("10h-old session: %d, re-signed %v", resp.StatusCode, cookieNamed(resp, authz.CookieName) != nil)
	}

	// 20 hours in: 4 of 24 left, under 20% — a fresh day comes back.
	resp := h.meResp(t, h.mintSession(ghAlice, "user", now.Add(-20*time.Hour)))
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("20h-old session = %d; want 200", resp.StatusCode)
	}
	slid := cookieNamed(resp, authz.CookieName)
	if slid == nil || !slid.HttpOnly || slid.MaxAge != int((24*time.Hour).Seconds()) {
		t.Fatalf("20h-old session not re-signed for a day: %+v", slid)
	}
	sess, err := authz.VerifySession(slid.Value, h.srv.sessionKey(), time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if left := time.Until(time.Unix(sess.Exp, 0)); left < 23*time.Hour {
		t.Errorf("re-signed session has %v left; want a day", left)
	}
	if sess.UID != githubPrincipal(ghAlice.ID) || sess.Sub != "github" || sess.Role != "user" {
		t.Errorf("re-signed session = %+v", sess)
	}
	if code, _ := h.me(t, slid); code != http.StatusOK {
		t.Errorf("re-signed cookie = %d", code)
	}

	// 25 hours in: past its day, refused, nothing re-signed.
	resp = h.meResp(t, h.mintSession(ghAlice, "user", now.Add(-25*time.Hour)))
	if resp.StatusCode == http.StatusOK || cookieNamed(resp, authz.CookieName) != nil {
		t.Errorf("expired session = %d, re-signed %v; want refused", resp.StatusCode, cookieNamed(resp, authz.CookieName) != nil)
	}
}

// «Sign out everywhere» (claude-fleet#3701): an admin cuts a person's
// sessions — every value signed before is refused, a new sign-in works, and
// another person is untouched. Removing a person cuts theirs too.
func TestGitHubSignIn_CutSessions(t *testing.T) {
	h := newGitHubHarness(t, "verkyyi")
	h.addUser(t, ghAlice)
	h.addUser(t, ghMallory)
	_, admin := h.signIn(t, ghAdmin)
	_, alice := h.signIn(t, ghAlice)
	_, mallory := h.signIn(t, ghMallory)
	// An older browser of hers, too.
	aliceOld := h.mintSession(ghAlice, "user", time.Now().Add(-3*time.Hour))

	cut := func(who string, sess *http.Cookie) int {
		req, _ := http.NewRequest(http.MethodPost, h.http.URL+"/v1/fleet/users/sessions", strings.NewReader(`{"login":"`+who+`"}`))
		req.Header.Set("Content-Type", "application/json")
		req.AddCookie(sess)
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		return resp.StatusCode
	}
	if code := cut("verkyyi", alice); code != http.StatusForbidden {
		t.Fatalf("a user cutting = %d; want 403", code)
	}
	if code := cut("nobody", admin); code != http.StatusNotFound {
		t.Fatalf("cutting someone not listed = %d; want 404", code)
	}
	if code := cut("alice", admin); code != http.StatusOK {
		t.Fatalf("admin cutting alice = %d", code)
	}
	for name, c := range map[string]*http.Cookie{"alice": alice, "alice's older browser": aliceOld} {
		if code, _ := h.me(t, c); code == http.StatusOK {
			t.Errorf("%s after the cut = 200; want refused", name)
		}
	}
	if code, _ := h.me(t, mallory); code != http.StatusOK {
		t.Errorf("mallory after alice's cut = %d; want 200", code)
	}
	// A sign-in after the cut (the next second) is good.
	if code, _ := h.me(t, h.mintSession(ghAlice, "user", time.Now().Add(time.Second))); code != http.StatusOK {
		t.Errorf("a session signed after the cut = %d; want 200", code)
	}
	if nb, err := h.srv.Store.SessionCutoff(githubPrincipal(ghMallory.ID)); err != nil || nb != 0 {
		t.Fatalf("mallory's cut-off = %d, %v; want none", nb, err)
	}

	// Removing mallory cuts hers: added back, the old cookie stays dead.
	req, _ := http.NewRequest(http.MethodDelete, h.http.URL+"/v1/fleet/users?login=mallory", nil)
	req.AddCookie(admin)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("remove mallory = %d", resp.StatusCode)
	}
	h.addUser(t, ghMallory)
	if code, _ := h.me(t, mallory); code == http.StatusOK {
		t.Errorf("mallory's old cookie after remove + re-add = 200; want refused")
	}
}
