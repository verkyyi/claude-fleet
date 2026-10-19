package api

import (
	"bytes"
	"encoding/json"
	"net/http"
	"testing"
	"testing/fstest"
	"time"
)

func TestTerminalBrowserLease(t *testing.T) {
	h := newFleetHarness(t)
	enablePeople(t, h, pAlice, pBob, pCarol)
	h.srv.Admins = []string{pBob}
	call := func(path, origin string, cookie *http.Cookie, body any) (int, []byte) {
		t.Helper()
		b, _ := json.Marshal(body)
		req, _ := http.NewRequest("POST", h.http.URL+path, bytes.NewReader(b))
		req.Header.Set("Origin", origin)
		req.Header.Set("Content-Type", "application/json")
		if cookie != nil {
			req.AddCookie(cookie)
		}
		r, err := h.http.Client().Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer r.Body.Close()
		var out bytes.Buffer
		out.ReadFrom(r.Body)
		return r.StatusCode, out.Bytes()
	}
	acquire := func(person string) ClientLeaseResponse {
		t.Helper()
		code, b := call(TermClientPath, h.http.URL, personCookie(person, "test"), ClientLeaseRequest{Action: "acquire", Terminal: "iTerm2", Caps: []string{"iterm2", "show_file"}})
		var out ClientLeaseResponse
		json.Unmarshal(b, &out)
		if code != 200 || out.Lease == nil || out.ActionKey == "" {
			t.Fatalf("lease: %d %s", code, b)
		}
		if out.Lease.Terminal != "browser" || len(out.Lease.Caps) != 1 || out.Lease.Caps[0] != "link" {
			t.Fatalf("lying browser: %+v", out.Lease)
		}
		return out
	}
	alice, admin := acquire(pAlice), acquire(pBob)
	if h.srv.clientLeases.get("operator", time.Now()).Lease != nil {
		t.Fatal("admin took operator lease")
	}
	// Browser action routing selects this browser, not the previous iTerm.
	old := h.srv.clientLeases.acquire("p:"+pAlice, ClientLeaseRequest{Action: "acquire", Terminal: "iTerm2"}, time.Now().Add(-time.Second))
	c, _, _ := h.srv.clientLeases.send("p:"+pAlice, ClientAction{Kind: "open_url", URL: "https://example.com/"}, false, time.Now())
	if c == nil || c.ID != alice.Lease.ID || c.ID == old.Lease.ID {
		t.Fatal("action went to previous device")
	}
	code, b := call(TermClientPath+"/actions", h.http.URL, personCookie(pAlice, "alice"), ClientActionPoll{Action: "poll", Lease: alice.Lease.ID})
	var actions ClientActionPollResponse
	json.Unmarshal(b, &actions)
	if code != 200 || len(actions.Actions) != 1 || actions.Actions[0].Sig != signClientAction(alice.ActionKey, []byte(actions.Actions[0].Payload)) {
		t.Fatalf("signed action: %d %s", code, b)
	}
	code, b = call(TermClientPath+"/actions", h.http.URL, personCookie(pBob, "bob"), ClientActionPoll{Action: "poll", Lease: alice.Lease.ID})
	json.Unmarshal(b, &actions)
	if code != 200 || len(actions.Actions) != 0 || actions.State == "active" {
		t.Fatalf("admin read another person: %d %s", code, b)
	}
	for _, origin := range []string{"", "https://elsewhere.invalid"} {
		code, _ := call(TermClientPath, origin, personCookie(pAlice, "alice"), ClientLeaseRequest{Action: "input", Lease: alice.Lease.ID})
		if code != 403 {
			t.Fatalf("origin %q: %d", origin, code)
		}
	}
	code, _ = call(TermClientPath, h.http.URL, nil, ClientLeaseRequest{Action: "acquire"})
	if code != 401 && code != 403 {
		t.Fatalf("anonymous: %d", code)
	}
	code, b = call(TermClientPath, h.http.URL, personCookie(pBob, "bob"), ClientLeaseRequest{Action: "release", Lease: admin.Lease.ID})
	if code != 200 {
		t.Fatalf("release: %d %s", code, b)
	}
}

func TestTerminalConsoleRoutes(t *testing.T) {
	h, _, user := rolesHarness(t)
	h.srv.ConsoleFS = fstest.MapFS{"app/index.html": {Data: []byte("TERMINAL-CONSOLE")}}
	for _, path := range []string{"/term", "/term?worker=fleet%2Fworker"} {
		r := consoleDo(h.srv.Handler(), "GET", path, user)
		want := "/app/terminal"
		if path != "/term" {
			want += "?worker=fleet%2Fworker"
		}
		if r.Code != 301 || r.Header().Get("Location") != want {
			t.Fatalf("%s: %d %s", path, r.Code, r.Header().Get("Location"))
		}
	}
	r := consoleDo(h.srv.Handler(), "GET", "/app/terminal", user)
	if r.Code != 200 || !bytes.Contains(r.Body.Bytes(), []byte("TERMINAL-CONSOLE")) {
		t.Fatalf("terminal: %d %s", r.Code, r.Body.String())
	}
}
