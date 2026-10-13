package api

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"testing/fstest"
	"time"
)

// The web chat's page on the website (claude-fleet#3646, EPIC #3642 C4): /chat/
// is a signed-in person's, every byte the hub's own; the menu lists it for
// every role; GET /v1/chat/home says where the conversation runs without
// relaying anything.

func chatPageUI() fstest.MapFS {
	return fstest.MapFS{
		"index.html":             &fstest.MapFile{Data: []byte("console")},
		"chat/index.html":        &fstest.MapFile{Data: []byte(`<!doctype html><script type="module" src="/chat/assets/index-x.js"></script>CHAT-PAGE`)},
		"chat/assets/index-x.js": &fstest.MapFile{Data: []byte("console.log(1)")},
	}
}

func TestChatPage(t *testing.T) {
	h, _, _, _ := chatHarness(t)
	alice := personCookie(pAlice, "alice")
	page := func(path string, cookie *http.Cookie) (*http.Response, string) {
		t.Helper()
		resp := chatDo(t, h, "GET", path, cookie, map[string]string{"Accept": "text/html"}, "")
		b, _ := io.ReadAll(resp.Body)
		return resp, string(b)
	}

	// The page itself moved to /app, the new console's front page
	// (claude-fleet#3926): one 301, signed in or not — the gate is /app's.
	h.srv.UI = chatPageUI()
	for _, c := range []*http.Cookie{alice, nil} {
		if resp, _ := page("/chat/", c); resp.StatusCode != http.StatusMovedPermanently || resp.Header.Get("Location") != AppPrefix {
			t.Fatalf("/chat/ (cookie %v): %d → %q; want 301 %s", c != nil, resp.StatusCode, resp.Header.Get("Location"), AppPrefix)
		}
	}
	if resp, _ := page("/chat/?x=1", alice); resp.Header.Get("Location") != AppPrefix+"?x=1" {
		t.Errorf("/chat/?x=1 → %q; want the query kept", resp.Header.Get("Location"))
	}
	// Its files stay where they were until the old build goes (C16).
	var resp *http.Response
	var body string
	resp, body = page("/chat/assets/index-x.js", alice)
	if resp.StatusCode != http.StatusOK || body != "console.log(1)" || !strings.Contains(resp.Header.Get("Cache-Control"), "immutable") {
		t.Errorf("an asset: %d %q %q", resp.StatusCode, body, resp.Header.Get("Cache-Control"))
	}
	if resp, _ := page("/chat", alice); resp.StatusCode != http.StatusMovedPermanently || resp.Header.Get("Location") != "/chat/" {
		t.Errorf("/chat: %d → %q; want 301 /chat/", resp.StatusCode, resp.Header.Get("Location"))
	}
	for _, p := range []string{"/chat/nope.js", "/chat/assets/", "/chat/../index.html", "/chat/%2e%2e/index.html"} {
		if resp, body := page(p, alice); resp.StatusCode == http.StatusOK {
			t.Errorf("%s: 200 %q; want refused", p, body)
		}
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
