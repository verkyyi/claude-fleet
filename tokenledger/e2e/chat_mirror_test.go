package e2e

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"testing"

	. "github.com/verkyyi/claude-fleet/tokenledger/hub/api"
	"github.com/verkyyi/claude-fleet/tokenledger/hub/credvault"
)

// The copy beside the entry (task V9DJ D): a read that reached the home
// leaves a sealed copy of the person's own words, the reply's text and the
// tool steps' one line (never a tool's output); the page reads it back while
// the home is away; nobody else reads it; the person's switch deletes it.
func TestChatMirror(t *testing.T) {
	h, svc, host, login := chatHarness(t)
	sealer, err := credvault.NewSealer(bytes.Repeat([]byte{7}, 32))
	if err != nil {
		t.Fatal(err)
	}
	h.Srv.Vault = &credvault.Vault{Store: h.Srv.Store, Sealer: sealer}
	setChatHome(t, h, pAlice, host, login)
	alice, bob := personCookie(pAlice, "alice"), personCookie(pBob, "bob")
	svc.mu.Lock()
	svc.conversation = func(w http.ResponseWriter) {
		w.Header().Set("Content-Type", "application/json")
		io.WriteString(w, `{"session":"s1","cwd":"/h","busy":true,"items":[{"t":"user","text":"把部署日志贴一下"},`+
			`{"t":"tool","id":"tu1","name":"Bash","summary":"Bash · kubectl logs"},`+
			`{"t":"tool_result","id":"tu1","text":"SECRET-TOKEN=abc"},{"t":"text","d":"好的，最近 20 行"}]}`)
	}
	svc.mu.Unlock()
	read := func(c *http.Cookie, q string, hdr map[string]string) (int, map[string]any, string) {
		req, _ := http.NewRequest("GET", h.HTTP.URL+"/v1/chat/conversation"+q, nil)
		req.AddCookie(c)
		for k, v := range hdr {
			req.Header.Set(k, v)
		}
		resp, err := h.HTTP.Client().Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		b, _ := io.ReadAll(resp.Body)
		var m map[string]any
		json.Unmarshal(b, &m)
		return resp.StatusCode, m, string(b)
	}
	// No copy yet is no error (task J091): 200, no items, mirror null.
	noCopy := func(c *http.Cookie) (bool, string) {
		st, m, b := read(c, "?cached=1", nil)
		items, _ := m["items"].([]any)
		mirror, has := m["mirror"]
		return st == http.StatusOK && m["items"] != nil && len(items) == 0 && has && mirror == nil, fmt.Sprintf("%d %s", st, b)
	}
	copied := func(c *http.Cookie) bool {
		st, m, _ := read(c, "?cached=1", nil)
		return st == http.StatusOK && m["mirror"] != nil
	}
	if ok, got := noCopy(alice); !ok {
		t.Fatalf("before any read: %s; want 200 {items:[], mirror:null}", got)
	}
	if st, _, b := read(alice, "", nil); st != http.StatusOK || !strings.Contains(b, "SECRET-TOKEN") {
		t.Fatalf("the home's answer: %d %s", st, b)
	}
	waitFor(t, 5e9, "copy kept", func() bool { return copied(alice) })
	n := len(svc.seen())
	st, m, b := read(alice, "?cached=1", nil)
	if st != http.StatusOK || m["session"] != "s1" || m["busy"] != false || m["mirror"] == nil {
		t.Fatalf("the copy: %d %s", st, b)
	}
	if strings.Contains(b, "SECRET-TOKEN") || !strings.Contains(b, "kubectl logs") || !strings.Contains(b, "最近 20 行") || !strings.Contains(b, "部署日志") {
		t.Errorf("the copy holds %s; want words, text and the step's line — never the tool's output", b)
	}
	if len(svc.seen()) != n {
		t.Error("a cached read reached the home")
	}
	// At rest it is sealed: no word of it in the table.
	var sealed []byte
	if err := h.Srv.Store.DB().QueryRow(`SELECT sealed FROM hub_chat_mirrors WHERE principal = ?`, pAlice).Scan(&sealed); err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(sealed, []byte("部署日志")) || bytes.Contains(sealed, []byte("kubectl")) {
		t.Error("the copy is stored in the clear")
	}
	// The home away: the copy still reads.
	setChatHome(t, h, pAlice, "elsewhere", login)
	if st, _, _ := read(alice, "", nil); st != http.StatusServiceUnavailable {
		t.Errorf("home away: live read %d; want 503", st)
	}
	if !copied(alice) {
		t.Error("home away: the cached read gave no copy")
	}
	// Nobody else reads it: Bob has none of his own; a view-as read is refused.
	if ok, got := noCopy(bob); !ok {
		t.Errorf("bob's cached read: %s; want none (his own, none)", got)
	}
	if st, _, _ := read(alice, "?cached=1", map[string]string{ViewAsHeader: pBob}); st != http.StatusForbidden {
		t.Errorf("a view-as cached read: %d; want 403", st)
	}
	// The switch: off deletes the copy and keeps none; on again keeps the next.
	put := func(on bool) int {
		req, _ := http.NewRequest("PUT", h.HTTP.URL+"/v1/chat/mirror", strings.NewReader(map[bool]string{true: `{"on":true}`, false: `{"on":false}`}[on]))
		req.AddCookie(alice)
		req.Header.Set("X-Fleet-Webchat", "1")
		resp, err := h.HTTP.Client().Do(req)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		return resp.StatusCode
	}
	if put(false) != http.StatusOK {
		t.Fatal("switch off refused")
	}
	var rows int
	h.Srv.Store.DB().QueryRow(`SELECT COUNT(*) FROM hub_chat_mirrors WHERE principal = ?`, pAlice).Scan(&rows)
	if rows != 0 {
		t.Errorf("%d copies left after the switch went off", rows)
	}
	setChatHome(t, h, pAlice, host, login)
	read(alice, "", nil)
	if ok, got := noCopy(alice); !ok {
		t.Errorf("switch off: a read kept a copy (%s)", got)
	}
	if put(true) != http.StatusOK {
		t.Fatal("switch on refused")
	}
	read(alice, "", nil)
	waitFor(t, 5e9, "copy kept again", func() bool { return copied(alice) })
}
