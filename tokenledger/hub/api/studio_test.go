package api

import (
	"encoding/json"
	"net/http"
	"testing"
	"testing/fstest"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/authz"
	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

func TestStudioFounderGate(t *testing.T) {
	h := newFleetHarness(t)
	enablePeople(t, h, pAlice, pBob)
	h.srv.ConsoleFS = fstest.MapFS{"app/index.html": {Data: []byte("APP-ENTRY")}}
	headers := map[string]string{"Content-Type": "application/json", "X-Fleet-Webchat": "1"}
	check := func(cookie *http.Cookie, path, method string, want int) {
		t.Helper()
		r := chatDo(t, h, method, path, cookie, headers, `{}`)
		defer r.Body.Close()
		if r.StatusCode != want {
			t.Fatalf("%s %s = %d, want %d", method, path, r.StatusCode, want)
		}
	}
	owner := personCookie(pAlice, "founder")
	check(owner, "/app/studio", "GET", 404)
	check(owner, "/v1/chat/studio", "GET", 404)
	if err := h.srv.Store.SetFleetSetting(StudioPrincipalsKey, pAlice, time.Now()); err != nil {
		t.Fatal(err)
	}
	check(owner, "/app/studio", "GET", 200)
	// Authorized identity reaches normal home selection, never another machine.
	check(owner, "/v1/chat/studio", "GET", 409)
	for _, p := range []string{"/app/studio", "/v1/chat/studio", "/v1/chat/studio/open", "/v1/chat/studio/action", "/v1/chat/studio/preview"} {
		method := "GET"
		if p == "/v1/chat/studio/open" || p == "/v1/chat/studio/action" || p == "/v1/chat/studio/preview" {
			method = "POST"
		}
		// Matching display name and an operator credential grant nothing.
		check(personCookie(pBob, "founder"), p, method, 404)
	}
	readOnly := &http.Cookie{Name: authz.CookieName, Value: authz.SignReadOnly(store.IdentityGitHub, pAlice, "founder", roleUser,
		(&GitHubAuth{ClientSecret: testGitHubSecret}).sessionKey(), time.Now(), time.Hour)}
	check(readOnly, "/app/studio", "GET", 404)
	for _, who := range []struct {
		cookie *http.Cookie
		want   bool
	}{{owner, true}, {personCookie(pBob, "founder"), false}, {readOnly, false}} {
		r := chatDo(t, h, "GET", "/v1/me", who.cookie, nil, "")
		var me Me
		if err := json.NewDecoder(r.Body).Decode(&me); err != nil {
			t.Fatal(err)
		}
		r.Body.Close()
		if me.Studio != who.want {
			t.Fatalf("menu visibility = %v, want %v", me.Studio, who.want)
		}
	}
	if err := h.srv.Store.SetFleetSetting(StudioPrincipalsKey, "", time.Now()); err != nil {
		t.Fatal(err)
	}
	check(owner, "/app/studio", "GET", 404)
}
