package e2e

import (
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

// 只读 (task F481): GET /v1/chat/view?worker=<id> reaches the login the person's
// session runs on, as /api/view?fid=<its window>; another person's worker is
// 404 not_yours, the operator's door and a view-as never read one.
func TestChatViewReadsOwnSession(t *testing.T) {
	h, svc, host, login := chatHarness(t)
	enablePeople(t, h, pCarol)
	const fuid, fid = "66666666-6666-4666-8666-666666666666", "77777777-7777-4777-8777-777777777777"
	wid := fuid + "/" + fid
	ws, _ := json.Marshal([]map[string]any{{"key": "issue-1", "state": "working", "worker_id": wid}})
	if _, err := h.Srv.Store.RecordFleetSnapshot("ep_chat-entry", host, login, "mach-"+host, []store.FleetReport{{
		FleetID: fuid, Name: "fleet", Repo: "o/r", Checkout: "/c", WorkerCount: 1, WorkersJSON: string(ws)}}, time.Now()); err != nil {
		t.Fatal(err)
	}
	setChatHome(t, h, pAlice, host, login)
	setChatHome(t, h, pCarol, "elsewhere", "carol")
	alice := personCookie(pAlice, "alice")

	resp := chatDo(t, h, "GET", "/v1/chat/view?worker="+wid+"&from=5", alice, nil, "")
	if resp.StatusCode != http.StatusOK || !strings.HasPrefix(resp.Header.Get("Content-Type"), "text/event-stream") {
		b, _ := io.ReadAll(resp.Body)
		t.Fatalf("view: %d %s %s", resp.StatusCode, resp.Header.Get("Content-Type"), b)
	}
	b, _ := io.ReadAll(resp.Body)
	if !strings.Contains(string(b), `"t":"state"`) || !strings.Contains(string(b), "id: 1\n") ||
		!strings.Contains(string(b), `fid=`+fid) || !strings.Contains(string(b), `from=5`) {
		t.Fatalf("stream = %s", b)
	}
	var hit string
	for _, s := range svc.seen() {
		if strings.Contains(s, "/api/view") {
			hit = s
		}
	}
	if !strings.Contains(hit, "person="+pAlice) || strings.Contains(hit, "cookie=ccq") {
		t.Fatalf("the service saw %q", hit)
	}

	cases := []struct {
		name   string
		query  string
		cookie *http.Cookie
		hdr    map[string]string
		status int
		code   string
	}{
		{"signed out", "worker=" + wid, nil, nil, http.StatusUnauthorized, ""},
		{"another person's session", "worker=" + wid, personCookie(pCarol, "carol"), nil, http.StatusNotFound, "not_yours"},
		{"no such session", "worker=" + fuid + "/88888888-8888-4888-8888-888888888888", alice, nil, http.StatusNotFound, "not_yours"},
		{"no worker", "", alice, nil, http.StatusBadRequest, "bad_target"},
		{"a bad from", "worker=" + wid + "&from=-1", alice, nil, http.StatusBadRequest, "bad_from"},
		{"the operator's door", "worker=" + wid, nil, map[string]string{"Authorization": "Bearer " + viewerToken}, http.StatusForbidden, "operator"},
	}
	for _, c := range cases {
		resp := chatDo(t, h, "GET", "/v1/chat/view?"+c.query, c.cookie, c.hdr, "")
		if resp.StatusCode != c.status {
			t.Errorf("%s: %d; want %d", c.name, resp.StatusCode, c.status)
			continue
		}
		if c.code != "" {
			if got := chatCode(t, resp); got != c.code {
				t.Errorf("%s: code %q; want %q", c.name, got, c.code)
			}
		}
	}
	n := 0
	for _, s := range svc.seen() {
		if strings.Contains(s, "/api/view") {
			n++
		}
	}
	if n != 1 {
		t.Fatalf("a refused view reached the service: %d views there", n)
	}
}

// An agent without the chat relay: one sentence, no relay (「这台机器还旧」).
func TestChatViewOldAgent(t *testing.T) {
	h := newFleetHarness(t)
	enablePeople(t, h, pAlice)
	_, host, login := runChatAgentIn(t, h, "chat-old", false, shortTemp(t))
	const fuid, fid = "66666666-6666-4666-8666-666666666666", "77777777-7777-4777-8777-777777777777"
	ws, _ := json.Marshal([]map[string]any{{"key": "issue-1", "state": "working", "worker_id": fuid + "/" + fid}})
	if _, err := h.Srv.Store.RecordFleetSnapshot("ep_chat-old", host, login, "mach-"+host, []store.FleetReport{{
		FleetID: fuid, Name: "fleet", Repo: "o/r", Checkout: "/c", WorkerCount: 1, WorkersJSON: string(ws)}}, time.Now()); err != nil {
		t.Fatal(err)
	}
	setChatHome(t, h, pAlice, host, login)
	resp := chatDo(t, h, "GET", "/v1/chat/view?worker="+fuid+"/"+fid, personCookie(pAlice, "alice"), nil, "")
	if resp.StatusCode != http.StatusConflict {
		t.Fatalf("old agent: %d, want 409", resp.StatusCode)
	}
	if c := chatCode(t, resp); c != "old_agent" {
		t.Fatalf("code %q, want old_agent", c)
	}
}

// 接管 / 交回 (task VV8F): POST /v1/chat/takeover|giveback?worker=<id> reaches the
// person's home as /api/takeover|giveback with the hub's own body {"fid"}; a GET,
// a call without X-Fleet-Webchat, another person's worker and the operator's
// door never reach it.
func TestChatHandover(t *testing.T) {
	h, svc, host, login := chatHarness(t)
	enablePeople(t, h, pCarol)
	const fuid, fid = "66666666-6666-4666-8666-666666666666", "77777777-7777-4777-8777-777777777777"
	wid := fuid + "/" + fid
	ws, _ := json.Marshal([]map[string]any{{"key": "issue-1", "state": "done", "worker_id": wid}})
	if _, err := h.Srv.Store.RecordFleetSnapshot("ep_chat-entry", host, login, "mach-"+host, []store.FleetReport{{
		FleetID: fuid, Name: "fleet", Repo: "o/r", Checkout: "/c", WorkerCount: 1, WorkersJSON: string(ws)}}, time.Now()); err != nil {
		t.Fatal(err)
	}
	setChatHome(t, h, pAlice, host, login)
	setChatHome(t, h, pCarol, "elsewhere", "carol")
	alice := personCookie(pAlice, "alice")
	page := map[string]string{"X-Fleet-Webchat": "1"}

	for _, route := range []string{"takeover", "giveback"} {
		resp := chatDo(t, h, "POST", "/v1/chat/"+route+"?worker="+wid, alice, page, "")
		b, _ := io.ReadAll(resp.Body)
		if resp.StatusCode != http.StatusOK || !strings.Contains(string(b), `\"fid\":\"`+fid+`\"`) {
			t.Fatalf("%s: %d %s", route, resp.StatusCode, b)
		}
	}
	cases := []struct {
		name, method, query string
		cookie              *http.Cookie
		hdr                 map[string]string
		status              int
		code                string
	}{
		{"a GET", "GET", "worker=" + wid, alice, page, http.StatusMethodNotAllowed, ""},
		{"not from the page", "POST", "worker=" + wid, alice, nil, http.StatusForbidden, "forbidden"},
		{"signed out", "POST", "worker=" + wid, nil, page, http.StatusUnauthorized, ""},
		{"another person's session", "POST", "worker=" + wid, personCookie(pCarol, "carol"), page, http.StatusNotFound, "not_yours"},
		{"the personal terminal", "POST", "target=personal", alice, page, http.StatusBadRequest, "bad_target"},
		{"the operator's door", "POST", "worker=" + wid, nil, map[string]string{"Authorization": "Bearer " + viewerToken, "X-Fleet-Webchat": "1"}, http.StatusForbidden, "operator"},
	}
	for _, c := range cases {
		resp := chatDo(t, h, c.method, "/v1/chat/takeover?"+c.query, c.cookie, c.hdr, "")
		if resp.StatusCode != c.status {
			t.Errorf("%s: %d; want %d", c.name, resp.StatusCode, c.status)
			continue
		}
		if c.code != "" {
			if got := chatCode(t, resp); got != c.code {
				t.Errorf("%s: code %q; want %q", c.name, got, c.code)
			}
		}
	}
	n := 0
	for _, s := range svc.seen() {
		if strings.Contains(s, "/api/takeover") || strings.Contains(s, "/api/giveback") {
			if !strings.Contains(s, "person="+pAlice) {
				t.Errorf("the service saw %q", s)
			}
			n++
		}
	}
	if n != 2 {
		t.Fatalf("handovers at the service: %d, want 2", n)
	}
}
