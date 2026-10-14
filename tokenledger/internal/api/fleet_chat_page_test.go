package api

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// The web chat's page (claude-fleet#3646) moved to /app, the console's front
// page (claude-fleet#3926), and its /chat/assets build went with the old
// console (claude-fleet#3939): /chat and /chat/ move on, the files are gone;
// GET /v1/chat/home says where the conversation runs without relaying
// anything.

func TestChatPage(t *testing.T) {
	h, _, _, _ := chatHarness(t)
	alice := personCookie(pAlice, "alice")
	page := func(path string, cookie *http.Cookie) *http.Response {
		t.Helper()
		resp := chatDo(t, h, "GET", path, cookie, map[string]string{"Accept": "text/html"}, "")
		resp.Body.Close()
		return resp
	}
	// One 301, signed in or not — the gate is /app's.
	for _, c := range []*http.Cookie{alice, nil} {
		for _, p := range []string{"/chat/", "/chat"} {
			if resp := page(p, c); resp.StatusCode != http.StatusMovedPermanently || resp.Header.Get("Location") != AppPrefix {
				t.Fatalf("%s (cookie %v): %d → %q; want 301 %s", p, c != nil, resp.StatusCode, resp.Header.Get("Location"), AppPrefix)
			}
		}
	}
	if resp := page("/chat/?x=1", alice); resp.Header.Get("Location") != AppPrefix+"?x=1" {
		t.Errorf("/chat/?x=1 → %q; want the query kept", resp.Header.Get("Location"))
	}
	for _, p := range []string{"/chat/assets/index-x.js", "/chat/nope.js"} {
		if resp := page(p, alice); resp.StatusCode != http.StatusNotFound {
			t.Errorf("%s: %d; want 404 — the old build is gone", p, resp.StatusCode)
		}
	}
	if resp := chatDo(t, h, "POST", "/chat/", alice, nil, ""); resp.StatusCode != http.StatusNotFound {
		t.Errorf("POST /chat/: %d; want 404", resp.StatusCode)
	}

	// A return cookie a sign-in left before the move still lands (and moves on).
	r := httptest.NewRequest(http.MethodGet, "/auth/github/callback", nil)
	r.AddCookie(&http.Cookie{Name: entryReturnCookie, Value: ChatPagePath})
	if got := loginReturn(httptest.NewRecorder(), r); got != ChatPagePath {
		t.Errorf("after sign-in: %q; want %s", got, ChatPagePath)
	}
}

func TestChatInEveryMenu(t *testing.T) {
	for _, role := range []string{roleUser, roleAdmin} {
		found := false
		for _, p := range pagesFor(role) {
			found = found || p == "chat"
		}
		if !found {
			t.Errorf("%s's pages %v have no chat", role, pagesFor(role))
		}
	}
}

func TestChatHome(t *testing.T) {
	h, svc, host, login := chatHarness(t)
	alice := personCookie(pAlice, "alice")
	home := func() (int, ChatHome, string) {
		t.Helper()
		resp := chatDo(t, h, "GET", "/v1/chat/home", alice, nil, "")
		b, _ := io.ReadAll(resp.Body)
		var v ChatHome
		_ = json.Unmarshal(b, &v)
		return resp.StatusCode, v, string(b)
	}
	if code, _, body := home(); code != http.StatusConflict || !strings.Contains(body, "no_home") {
		t.Fatalf("no home: %d %s", code, body)
	}
	setChatHome(t, h, pAlice, host, login)
	if code, v, body := home(); code != http.StatusOK || v.Machine != host || v.Login != login || v.State != "ok" {
		t.Fatalf("home: %d %s", code, body)
	}
	setChatHome(t, h, pAlice, "elsewhere", login)
	if _, v, body := home(); v.State != "offline" {
		t.Fatalf("not connected: %s; want offline", body)
	}
	setChatHome(t, h, pAlice, host, login)
	if err := h.srv.Store.SetFleetSetting(maintenanceKey(host), "drill", time.Now()); err != nil {
		t.Fatal(err)
	}
	if _, v, body := home(); v.State != "maintenance" {
		t.Fatalf("in maintenance: %s; want maintenance", body)
	}
	if resp := chatDo(t, h, "GET", "/v1/chat/home", nil, map[string]string{"Authorization": "Bearer " + viewerToken}, ""); resp.StatusCode != http.StatusForbidden {
		t.Errorf("the operator's door: %d; want 403", resp.StatusCode)
	}
	if hits := svc.seen(); len(hits) != 0 {
		t.Errorf("home relayed to the service: %v", hits)
	}
	if n := chatAudits(t, h, "chat_relay"); n != 0 {
		t.Errorf("%d relays opened for home; want none", n)
	}
}
