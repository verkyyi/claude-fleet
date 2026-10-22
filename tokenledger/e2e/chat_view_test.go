package e2e

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/credvault"
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
	// a keyed session (scratch-N / issue-N) is listed as <fleet>/<key>, its
	// window as "identity" (task YP39: these were all 404 not_yours)
	const kfid = "99999999-9999-4999-8999-999999999999"
	kwid := fuid + "/o-r:scratch-3"
	ws, _ := json.Marshal([]map[string]any{{"key": "issue-1", "state": "working", "worker_id": wid},
		{"key": "o-r:scratch-3", "state": "done", "worker_id": kwid, "identity": kfid}})
	if _, err := h.Srv.Store.RecordFleetSnapshot("ep_chat-entry", host, login, "mach-"+host, []store.FleetReport{{
		FleetID: fuid, Name: "fleet", Repo: "o/r", Checkout: "/c", WorkerCount: 2, WorkersJSON: string(ws)}}, time.Now()); err != nil {
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
	if !resp.Uncompressed {
		t.Errorf("the view went out uncompressed (task YP39: gzip, flushed per event)")
	}
	b, _ := io.ReadAll(resp.Body)
	if !strings.Contains(string(b), `"t":"state"`) || !strings.Contains(string(b), "id: 1\n") ||
		!strings.Contains(string(b), `fid=`+fid) || !strings.Contains(string(b), `from=5`) {
		t.Fatalf("stream = %s", b)
	}
	kresp := chatDo(t, h, "GET", "/v1/chat/view?worker="+kwid, personCookie(pAlice, "alice"), nil, "")
	kb, _ := io.ReadAll(kresp.Body)
	if kresp.StatusCode != http.StatusOK || !strings.Contains(string(kb), `fid=`+kfid) {
		t.Fatalf("a keyed session: %d %s", kresp.StatusCode, kb)
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
	if n != 2 {
		t.Fatalf("a refused view reached the service: %d views there", n)
	}
}

// Capability frames are live service data, never replaced by the board or the
// cached transcript. The gzip relay must preserve split frames on reconnect too.
func TestChatViewCapabilityFramesSurviveRelay(t *testing.T) {
	h, svc, host, login := chatHarness(t)
	const fleet, fid = "66666666-6666-4666-8666-666666666666", "77777777-7777-4777-8777-777777777777"
	wid := fleet + "/" + fid
	workers, _ := json.Marshal([]map[string]any{{"worker_id": wid, "identity": fid, "state": "done", "can_talk": false}})
	if _, err := h.Srv.Store.RecordFleetSnapshot("ep_chat-entry", host, login, "mach-"+host, []store.FleetReport{{
		FleetID: fleet, Name: "fleet", Repo: "o/r", Checkout: "/c", WorkerCount: 1, WorkersJSON: string(workers)}}, time.Now()); err != nil {
		t.Fatal(err)
	}
	setChatHome(t, h, pAlice, host, login)
	frames := []string{
		`data: {"t":"state","session":"same-thread","can_talk":null,"talk_reason":"checking"}` + "\n\n",
		`data: {"t":"state","session":"same-thread","can_talk":null,"talk_reason":"unreachable"}` + "\n\n",
		`data: {"t":"state","session":"same-thread","can_talk":true,"talk_reason":""}` + "\n\n",
		`data: {"t":"state","session":"same-thread","can_talk":false,"talk_reason":"old_version"}` + "\n\n",
	}
	svc.mu.Lock()
	svc.view = func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("fid") != fid || r.Header.Get("X-Fleet-Person") != pAlice {
			t.Error("view reached the wrong session or person")
		}
		w.Header().Set("Content-Type", "text/event-stream")
		for _, frame := range frames {
			// Deliberately split the JSON token across flushed network chunks.
			cut := strings.Index(frame, "can_talk") + 4
			io.WriteString(w, frame[:cut])
			w.(http.Flusher).Flush()
			io.WriteString(w, frame[cut:])
			w.(http.Flusher).Flush()
		}
	}
	svc.mu.Unlock()
	for _, cursor := range []string{"", "&at=17&s=same-thread"} {
		resp := chatDo(t, h, "GET", "/v1/chat/view?worker="+wid+cursor, personCookie(pAlice, "alice"), nil, "")
		got, err := io.ReadAll(resp.Body)
		resp.Body.Close()
		if err != nil || resp.StatusCode != http.StatusOK || !resp.Uncompressed || string(got) != strings.Join(frames, "") {
			t.Fatalf("capability stream %q: %d gzip=%v err=%v body=%s", cursor, resp.StatusCode, resp.Uncompressed, err, got)
		}
		if !strings.Contains(resp.Header.Get("Cache-Control"), "no-store") {
			t.Fatal("live capability stream may be cached")
		}
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

// The copy beside the entry (task YP39): a view's first fresh frame is kept,
// sealed to its person, the conversation copy's rules (no step's output);
// ?cached=1 answers it from here, only to that person; the switch deletes it.
func TestChatViewCopy(t *testing.T) {
	h, _, host, login := chatHarness(t)
	enablePeople(t, h, pCarol)
	sealer, err := credvault.NewSealer(bytes.Repeat([]byte{7}, 32))
	if err != nil {
		t.Fatal(err)
	}
	h.Srv.Vault = &credvault.Vault{Store: h.Srv.Store, Sealer: sealer}
	const fuid, kfid = "66666666-6666-4666-8666-666666666666", "99999999-9999-4999-8999-999999999999"
	kwid := fuid + "/o-r:scratch-3"
	ws, _ := json.Marshal([]map[string]any{{"key": "o-r:scratch-3", "state": "done", "worker_id": kwid, "identity": kfid}})
	if _, err := h.Srv.Store.RecordFleetSnapshot("ep_chat-entry", host, login, "mach-"+host, []store.FleetReport{{
		FleetID: fuid, Name: "fleet", Repo: "o/r", Checkout: "/c", WorkerCount: 1, WorkersJSON: string(ws)}}, time.Now()); err != nil {
		t.Fatal(err)
	}
	setChatHome(t, h, pAlice, host, login)
	setChatHome(t, h, pCarol, "elsewhere", "carol")
	alice := personCookie(pAlice, "alice")
	read := func(c *http.Cookie, q string) (int, string) {
		resp := chatDo(t, h, "GET", "/v1/chat/view?worker="+kwid+q, c, nil, "")
		b, _ := io.ReadAll(resp.Body)
		return resp.StatusCode, string(b)
	}
	if st, b := read(alice, "&cached=1"); st != http.StatusOK || !strings.Contains(b, `"mirror":null`) {
		t.Fatalf("no copy yet: %d %s", st, b)
	}
	if st, b := read(alice, "&at=12&s=s1"); st != http.StatusOK || !strings.Contains(b, "at=12") || !strings.Contains(b, "s=s1") {
		t.Fatalf("the cursor did not reach the service: %d %s", st, b)
	}
	var b string
	waitFor(t, 5e9, "copy kept", func() bool { _, b = read(alice, "&cached=1"); return strings.Contains(b, `"d":"hi"`) })
	if strings.Contains(b, "SECRET-OUTPUT") || !strings.Contains(b, `"session":"s1"`) {
		t.Errorf("the copy: %s; want the reply and the conversation, never a step's output", b)
	}
	if st, _ := read(personCookie(pCarol, "carol"), "&cached=1"); st != http.StatusNotFound {
		t.Errorf("carol reading alice's copy: %d; want 404", st)
	}
	if st, b := read(alice, "&tool=toolu_01"); st != http.StatusOK || !strings.Contains(b, "tool=toolu_01") {
		t.Errorf("a step's output: %d %s", st, b)
	}
	for _, bad := range []string{"&at=-1", "&before=x", "&s=../x", "&tool=a%20b"} {
		if st, _ := read(alice, bad); st != http.StatusBadRequest {
			t.Errorf("%s: %d; want 400", bad, st)
		}
	}
	if err := h.Srv.Store.SetChatMirrorOff(pAlice, true, time.Now()); err != nil {
		t.Fatal(err)
	}
	if c, err := h.Srv.Store.ChatMirrorOf(pAlice, store.ChatMirrorViewPrefix+kwid, time.Now()); err != nil || c != nil {
		t.Errorf("the switch off left the view copy: %v %v", c, err)
	}
}

// 会话合一 (task PQ41): POST /v1/chat/say|answer|stop?worker=<id> reaches the
// login the session runs on as /api/say|answer|stop, the page's body with the
// hub's own fid; the browser's fid is never passed on. A say carries at most 4
// pictures and something to say; another person's worker, the personal
// terminal, a call not from the page and the operator's door never reach it.
func TestChatSayToSession(t *testing.T) {
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
	page := map[string]string{"X-Fleet-Webchat": "1", "Content-Type": "application/json"}

	resp := chatDo(t, h, "POST", "/v1/chat/say?worker="+wid, alice, page, `{"text":"hi","fid":"forged","images":[{"media_type":"image/png","data":"x"}]}`)
	b, _ := io.ReadAll(resp.Body)
	var got struct{ Delivery, State, Got string }
	_ = json.Unmarshal(b, &got)
	var sent map[string]any
	_ = json.Unmarshal([]byte(got.Got), &sent)
	if resp.StatusCode != http.StatusOK || got.State != "sent" || got.Delivery != "d1" || sent["fid"] != fid || sent["text"] != "hi" {
		t.Fatalf("say: %d %s", resp.StatusCode, b)
	}
	if pics, _ := sent["images"].([]any); len(pics) != 1 {
		t.Fatalf("say: the picture was not passed on: %s", got.Got)
	}
	resp = chatDo(t, h, "POST", "/v1/chat/say?worker="+wid, alice, page, `{"text":"refuse"}`)
	if b, _ := io.ReadAll(resp.Body); resp.StatusCode != http.StatusOK || !strings.Contains(string(b), `"state":"refused"`) {
		t.Fatalf("a refused say: %d %s", resp.StatusCode, b)
	}
	for _, route := range []string{"answer", "stop", "ack"} {
		resp := chatDo(t, h, "POST", "/v1/chat/"+route+"?worker="+wid, alice, page, `{"fp":"q1","pick":"是"}`)
		b, _ := io.ReadAll(resp.Body)
		if resp.StatusCode != http.StatusOK || !strings.Contains(string(b), `\"fid\":\"`+fid+`\"`) {
			t.Fatalf("%s: %d %s", route, resp.StatusCode, b)
		}
	}
	five := `{"text":"x","images":[{},{},{},{},{}]}`
	cases := []struct {
		name, method, query, body string
		cookie                    *http.Cookie
		hdr                       map[string]string
		status                    int
		code                      string
	}{
		{"a GET", "GET", "worker=" + wid, "", alice, page, http.StatusMethodNotAllowed, ""},
		{"not from the page", "POST", "worker=" + wid, `{"text":"x"}`, alice, nil, http.StatusForbidden, "forbidden"},
		{"signed out", "POST", "worker=" + wid, `{"text":"x"}`, nil, page, http.StatusUnauthorized, ""},
		{"another person's session", "POST", "worker=" + wid, `{"text":"x"}`, personCookie(pCarol, "carol"), page, http.StatusNotFound, "not_yours"},
		{"no session", "POST", "", `{"text":"x"}`, alice, page, http.StatusBadRequest, "bad_target"},
		{"the personal terminal", "POST", "target=personal", `{"text":"x"}`, alice, page, http.StatusBadRequest, "bad_target"},
		{"nothing to say", "POST", "worker=" + wid, `{"text":"  "}`, alice, page, http.StatusBadRequest, "empty"},
		{"five pictures", "POST", "worker=" + wid, five, alice, page, http.StatusBadRequest, "too_many_images"},
		{"not JSON", "POST", "worker=" + wid, `hi`, alice, page, http.StatusBadRequest, "bad_body"},
		{"the operator's door", "POST", "worker=" + wid, `{"text":"x"}`, nil, map[string]string{"Authorization": "Bearer " + viewerToken, "X-Fleet-Webchat": "1"}, http.StatusForbidden, "operator"},
	}
	for _, c := range cases {
		resp := chatDo(t, h, c.method, "/v1/chat/say?"+c.query, c.cookie, c.hdr, c.body)
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
		if strings.Contains(s, "/api/say") {
			if !strings.Contains(s, "person="+pAlice) || strings.Contains(s, "cookie=ccq") {
				t.Errorf("the service saw %q", s)
			}
			n++
		}
	}
	if n != 2 {
		t.Fatalf("says at the service: %d, want 2", n)
	}

	// a new session from the web: on the home, its first line with it
	resp = chatDo(t, h, "POST", "/v1/chat/open", alice, page, `{"agent":"claude","text":"hello"}`)
	if b, _ := io.ReadAll(resp.Body); resp.StatusCode != http.StatusOK || !strings.Contains(string(b), `"fid":"f-new"`) ||
		!strings.Contains(string(b), `"worker":"`+fuid+`/f-new"`) {
		t.Fatalf("open: %d %s", resp.StatusCode, b)
	}
	// an answer / a stop with no worker is still the home conversation's own
	resp = chatDo(t, h, "POST", "/v1/chat/stop", alice, page, "")
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("the home's own stop: %d", resp.StatusCode)
	}
	// fleet.chat.unified on: the old routes answer 410 moved, nothing reaches the home
	if err := h.Srv.Store.SetFleetSetting("fleet.chat.unified", "on", time.Now()); err != nil {
		t.Fatal(err)
	}
	before := len(svc.seen())
	for _, route := range []string{"turn", "new", "take", "takeover?worker=" + wid, "giveback?worker=" + wid} {
		resp := chatDo(t, h, "POST", "/v1/chat/"+route, alice, page, `{"text":"hi"}`)
		if resp.StatusCode != http.StatusGone {
			t.Errorf("%s with fleet.chat.unified on: %d; want 410", route, resp.StatusCode)
			continue
		}
		if got := chatCode(t, resp); got != "moved" {
			t.Errorf("%s: code %q; want moved", route, got)
		}
	}
	if n := len(svc.seen()); n != before {
		t.Fatalf("a moved route reached the service: %v", svc.seen()[before:])
	}
	resp = chatDo(t, h, "POST", "/v1/chat/say?worker="+wid, alice, page, `{"text":"hi"}`)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("say with fleet.chat.unified on: %d", resp.StatusCode)
	}
	// the page reads the switch off its top bar's read
	resp = chatDo(t, h, "GET", "/v1/chat/home", alice, nil, "")
	if b, _ := io.ReadAll(resp.Body); !strings.Contains(string(b), `"unified":true`) {
		t.Fatalf("home with fleet.chat.unified on: %s", b)
	}
}

// Closed FIDs remain readable without a home, node or live inventory. The
// cache door must not launch an operation or grant an admin someone else's chat.
func TestChatViewClosedIdentityIsolation(t *testing.T) {
	h := newFleetHarness(t)
	enablePeople(t, h, pAlice, pBob, pCarol)
	h.Srv.Admins = []string{pBob}
	sealer, err := credvault.NewSealer(bytes.Repeat([]byte{7}, 32))
	if err != nil {
		t.Fatal(err)
	}
	h.Srv.Vault = &credvault.Vault{Store: h.Srv.Store, Sealer: sealer}
	const fid = "77777777-7777-4777-8777-777777777777"
	now := time.Now()
	_, err = h.Srv.Store.ApplyFleetIDEvents(store.FleetIDPush{Owner: pAlice, EndpointID: "old", Machine: "offline", Login: "alice", ID: fid,
		Events: []map[string]any{{"ev": "opened", "seq": float64(1), "ts": float64(now.Unix()), "key": "scratch-1"},
			{"ev": "native", "seq": float64(2), "ts": float64(now.Unix()), "native": "native-id", "agent": "claude"},
			{"ev": "closed", "seq": float64(3), "ts": float64(now.Unix())}}})
	if err != nil {
		t.Fatal(err)
	}
	sealed, err := h.Srv.Vault.SealPerson(map[string]any{"session": "native-id", "items": []map[string]string{{"t": "text", "d": "kept words"}}}, pAlice, "chat-mirror")
	if err != nil {
		t.Fatal(err)
	}
	if err = h.Srv.Store.PutChatMirrorOf(pAlice, "view:66666666-6666-4666-8666-666666666666/"+fid, sealed, now.Add(time.Hour), now); err != nil {
		t.Fatal(err)
	}
	for _, c := range []struct {
		name, person, query string
		status              int
	}{
		{"owner", pAlice, "worker=fid:" + fid + "&cached=1", 200},
		{"other tenant", pCarol, "worker=fid:" + fid + "&cached=1", 404},
		{"admin as self", pBob, "worker=fid:" + fid + "&cached=1", 404},
		{"admin view-as", pBob, "worker=fid:" + fid + "&cached=1&as=" + pAlice, 403},
		{"recycled key", pAlice, "worker=66666666-6666-4666-8666-666666666666/scratch-1&cached=1", 404},
	} {
		req := httptest.NewRequest("GET", "/v1/chat/view?"+c.query, nil)
		req.AddCookie(personCookie(c.person, "reader"))
		rr := httptest.NewRecorder()
		h.Srv.Handler().ServeHTTP(rr, req)
		b := rr.Body.Bytes()
		if rr.Code != c.status {
			t.Errorf("%s: %d %s", c.name, rr.Code, b)
		}
		if (c.status == 200) != strings.Contains(string(b), "kept words") {
			t.Errorf("%s leaked/lost content: %s", c.name, b)
		}
	}
	var operations int
	if err = h.Srv.Store.DB().QueryRow(`SELECT COUNT(*) FROM fleet_operations`).Scan(&operations); err != nil || operations != 0 {
		t.Fatalf("history launched operations=%d err=%v", operations, err)
	}
}
