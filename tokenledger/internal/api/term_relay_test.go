package api

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/agent"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// The browser terminal's acceptance (claude-fleet#3838, EPIC #3836 C1; BREAK-IT
// term-other-person · term-relay-orphan): a hub with sign-in, a REAL agent on the
// control channel, and the agent's real `term-pty` on a real pseudo-terminal —
// only the one command is a throwaway shell instead of fleet-term-attach.sh. Every
// run of that command is counted (a marker line per start, its process by a
// unique token), so "never reached" is a count of zero and "released" is no
// process left.

const termFleetUUID = "33333333-3333-4333-8333-333333333333"

// termRig is one hub + agent + the throwaway command's bookkeeping.
type termRig struct {
	h            *harness
	host, login  string
	tok, marker  string
	wid, fid     string
	nc           *nodeConn
	label        string
	chatSock     *fakeChatSock
	starts       func() []string
	procs        func() int
	origin       string
	alice, bobAd *http.Cookie
}

func newTermRig(t *testing.T, term bool) *termRig {
	t.Helper()
	if _, err := exec.LookPath("pgrep"); err != nil {
		t.Skip("no pgrep")
	}
	r := &termRig{label: fmt.Sprintf("term-%d", time.Now().UnixNano()%1e9)}
	r.tok = "termrig-" + r.label
	dir := t.TempDir()
	r.marker = filepath.Join(dir, "starts")
	agent.SetTermHelperForTest(func(view, target string) []string {
		return []string{"/bin/sh", "-c", `printf '%s %s\n' "$1" "$2" >> "$3"; stty size; ` +
			`while read l; do case "$l" in size) stty size ;; *) echo "got:$l" ;; esac; done`, r.tok, view, target, r.marker}
	})
	t.Cleanup(func() { agent.SetTermHelperForTest(nil) })
	r.starts = func() []string {
		b, _ := os.ReadFile(r.marker)
		return strings.Fields(strings.ReplaceAll(string(b), "\n", " | "))
	}
	r.procs = func() int {
		out, _ := exec.Command("pgrep", "-f", r.tok).Output()
		return len(strings.Fields(string(out)))
	}

	r.h = newFleetHarness(t)
	enablePeople(t, r.h, pAlice, pBob, pCarol)
	r.h.srv.Admins = []string{pBob}
	conf := shortTemp(t)
	r.chatSock = listenChatSock(t, conf)
	r.nc, r.host, r.login = runTermAgentIn(t, r.h, r.label, term, conf)
	r.fid = "44444444-4444-4444-8444-444444444444"
	r.wid = termFleetUUID + "/" + r.fid
	w, _ := json.Marshal([]map[string]any{{"key": "issue-1", "state": "working", "worker_id": r.wid}})
	if _, err := r.h.srv.Store.RecordFleetSnapshot("ep_"+r.label, r.host, r.login, "mach-"+r.host, []store.FleetReport{{
		FleetID: termFleetUUID, Name: "fleet", Repo: "o/r", Checkout: "/c", WorkerCount: 1, WorkersJSON: string(w)}}, time.Now()); err != nil {
		t.Fatal(err)
	}
	setChatHome(t, r.h, pAlice, r.host, r.login)
	r.origin = r.h.http.URL
	r.alice, r.bobAd = personCookie(pAlice, "alice"), personCookie(pBob, "bob")
	return r
}

// runTermAgentIn is runChatAgentIn with the terminal on (or off) beside chat.
func runTermAgentIn(t *testing.T, h *harness, label string, term bool, conf string) (*nodeConn, string, string) {
	t.Helper()
	t.Setenv("FLEET_CONF_DIR", conf)
	me, err := user.Current()
	if err != nil {
		t.Fatal(err)
	}
	home := t.TempDir()
	a, err := agent.New(agent.Config{
		HubURL: h.http.URL, Token: h.enroll(t, label), Home: home,
		StateDir: filepath.Join(home, "state"), SessionsDir: filepath.Join(home, "sessions"),
		Sources: "claude", LiveInterval: 200 * time.Millisecond, ScanInterval: time.Hour, LimitsInterval: time.Hour,
		Fleet: true, FleetChat: true, FleetTerm: term, Version: "it-" + label,
	})
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { a.Run(ctx); close(done) }()
	t.Cleanup(func() { cancel(); <-done })
	host, _ := os.Hostname()
	var nc *nodeConn
	waitFor(t, 5*time.Second, "agent connected as its login", func() bool {
		nc = h.srv.nodes.get("ep_" + label)
		return nc != nil && nc.hostname() == host && nc.user() == me.Username
	})
	return nc, host, me.Username
}

// dialTerm opens TermConnectPath?query with cookie and origin; it returns the
// browser's end, or the HTTP status of a refused upgrade.
func (r *termRig) dialTerm(t *testing.T, query string, cookie *http.Cookie, origin string, hdr map[string]string) (*websocket.Conn, int, string) {
	t.Helper()
	h := http.Header{}
	if cookie != nil {
		h.Add("Cookie", cookie.String())
	}
	if origin != "" {
		h.Set("Origin", origin)
	}
	for k, v := range hdr {
		h.Set(k, v)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	u := "ws" + strings.TrimPrefix(r.h.http.URL, "http") + TermConnectPath + "?" + query
	c, resp, err := websocket.Dial(ctx, u, &websocket.DialOptions{HTTPHeader: h, HTTPClient: r.h.http.Client()})
	if err != nil {
		code, st := "", 0
		if resp != nil {
			st = resp.StatusCode
			var v struct {
				Code string `json:"code"`
			}
			_ = json.NewDecoder(resp.Body).Decode(&v)
			code = v.Code
		}
		return nil, st, code
	}
	c.SetReadLimit(1 << 20)
	return c, 101, ""
}

// readCtl reads frames until a control frame of type want (output is skipped).
func readCtl(t *testing.T, c *websocket.Conn, want string) control.TermControl {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	for {
		typ, b, err := c.Read(ctx)
		if err != nil {
			t.Fatalf("waiting for %q: %v", want, err)
		}
		if typ != websocket.MessageText {
			continue
		}
		var tc control.TermControl
		_ = json.Unmarshal(b, &tc)
		if tc.T == want {
			return tc
		}
	}
}

// readOut reads output until it says s.
func readOut(t *testing.T, c *websocket.Conn, s string) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	var seen strings.Builder
	for !strings.Contains(seen.String(), s) {
		typ, b, err := c.Read(ctx)
		if err != nil {
			t.Fatalf("output %q never said %q: %v", seen.String(), s, err)
		}
		if typ == websocket.MessageBinary {
			seen.Write(b)
		}
	}
}

func send(t *testing.T, c *websocket.Conn, typ websocket.MessageType, b []byte) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := c.Write(ctx, typ, b); err != nil {
		t.Fatal(err)
	}
}

func TestTermRelayReachesOwnWorker(t *testing.T) {
	r := newTermRig(t, true)
	before := r.procs()
	c, st, code := r.dialTerm(t, "worker="+r.wid, r.alice, r.origin, nil)
	if c == nil {
		t.Fatalf("upgrade refused: %d %s", st, code)
	}
	hello := readCtl(t, c, "hello")
	if hello.V != 1 || hello.Term != r.wid || hello.Mode != "relay" || hello.Conn == "" || hello.Gen == "" {
		t.Fatalf("hello = %+v", hello)
	}
	readCtl(t, c, "ready")
	send(t, c, websocket.MessageText, []byte(`{"t":"resize","cols":100,"rows":30}`))
	send(t, c, websocket.MessageBinary, []byte("size\n"))
	readOut(t, c, "30 100")
	send(t, c, websocket.MessageBinary, []byte("中文输入\n"))
	readOut(t, c, "got:中文输入")
	during := r.procs()
	if s := strings.Join(r.starts(), " "); !strings.Contains(s, "web-"+hello.Conn[:8]+" worker:"+r.fid) {
		t.Fatalf("the command ran as %q, want view web-%s on worker:%s", s, hello.Conn[:8], r.fid)
	}
	c.Close(websocket.StatusNormalClosure, "")
	waitFor(t, 30*time.Second, "the terminal's processes and relay released", func() bool {
		return r.procs() == before && r.h.srv.termRelays.open() == 0
	})
	t.Logf("processes: before %d · attached %d · after %d", before, during, r.procs())
	if during != before+1 {
		t.Fatalf("attached: %d processes of the command, want %d", during, before+1)
	}
	var rows []store.FleetTermSession
	waitFor(t, 5*time.Second, "the audit row finished", func() bool {
		rows, _ = r.h.srv.Store.FleetTermSessions(pAlice, 5)
		return len(rows) == 1 && rows[0].Outcome != ""
	})
	if rw := rows[0]; rw.ID != hello.Conn || rw.Target != r.wid || rw.Mode != "relay" || rw.BytesUp == 0 || rw.BytesDown == 0 ||
		rw.Machine != r.host || rw.Login != r.login {
		t.Fatalf("audit row = %+v", rw)
	}
	b, _ := json.Marshal(rows[0])
	if strings.Contains(string(b), "中文") || strings.Contains(string(b), "got:") {
		t.Fatalf("the audit row holds terminal content: %s", b)
	}
}

// term-other-person: nobody but the home's own person reaches a terminal there —
// not another person, not an admin as themselves, not an admin looking through
// the person's eyes, not the operator's door, not a page of another origin.
func TestTermRelayOtherPersonNeverReachesIt(t *testing.T) {
	r := newTermRig(t, true)
	setChatHome(t, r.h, pCarol, "elsewhere", "carol")
	bobHome := func() { setChatHome(t, r.h, pBob, "elsewhere", "bob") }
	cases := []struct {
		name   string
		query  string
		cookie *http.Cookie
		origin string
		hdr    map[string]string
		status int
		code   string
	}{
		{"no credential", "worker=" + r.wid, nil, r.origin, nil, http.StatusUnauthorized, ""},
		{"another person's worker", "worker=" + r.wid, personCookie(pCarol, "carol"), r.origin, nil, http.StatusNotFound, "not_yours"},
		{"an admin with no home", "worker=" + r.wid, r.bobAd, r.origin, nil, http.StatusConflict, "no_home"},
		{"an admin viewing as the person", "worker=" + r.wid + "&" + ViewAsParam + "=" + pAlice, r.bobAd, r.origin, nil, http.StatusForbidden, ""},
		{"the operator's door", "worker=" + r.wid, nil, r.origin, map[string]string{"Authorization": "Bearer " + r.h.srv.ViewerToken}, http.StatusForbidden, "operator"},
		{"another origin", "worker=" + r.wid, r.alice, "https://evil.example", nil, http.StatusForbidden, "origin"},
		{"no origin", "worker=" + r.wid, r.alice, "", nil, http.StatusForbidden, "origin"},
		{"both selectors", "worker=" + r.wid + "&target=personal", r.alice, r.origin, nil, http.StatusBadRequest, "bad_target"},
		{"no selector", "", r.alice, r.origin, nil, http.StatusBadRequest, "bad_target"},
		{"a path for a target", "target=/bin/sh", r.alice, r.origin, nil, http.StatusBadRequest, "bad_target"},
		{"a worker that does not exist", "worker=" + termFleetUUID + "/55555555-5555-4555-8555-555555555555", r.alice, r.origin, nil, http.StatusNotFound, "not_yours"},
		{"a worker id that is a path", "worker=" + termFleetUUID + "/..%2F..", r.alice, r.origin, nil, http.StatusNotFound, "not_yours"},
		{"a login in the query", "worker=" + r.wid + "&person=" + pCarol, r.alice, r.origin, nil, http.StatusForbidden, "not_yours"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			c, st, code := r.dialTerm(t, tc.query, tc.cookie, tc.origin, tc.hdr)
			if c != nil {
				c.CloseNow()
				t.Fatalf("upgraded, want %d %s", tc.status, tc.code)
			}
			if st != tc.status && !(tc.status == http.StatusUnauthorized && st == http.StatusFound) {
				t.Fatalf("status %d (%s), want %d %s", st, code, tc.status, tc.code)
			}
			if tc.code != "" && code != tc.code {
				t.Fatalf("code %q, want %q", code, tc.code)
			}
		})
	}
	// An admin AS THEMSELVES, with a home of their own elsewhere: still not hers.
	bobHome()
	if c, st, code := r.dialTerm(t, "worker="+r.wid, r.bobAd, r.origin, nil); c != nil || st != http.StatusNotFound || code != "not_yours" {
		if c != nil {
			c.CloseNow()
		}
		t.Fatalf("an admin as themselves: %d %s, want 404 not_yours", st, code)
	}
	if s := r.starts(); len(s) != 0 || r.procs() != 0 || r.h.srv.termRelays.open() != 0 {
		t.Fatalf("a refused terminal reached the node: starts %v, procs %d", s, r.procs())
	}
	// every refusal the route made (the sign-in gate and the view-as guard
	// answer before it), plus the admin as themselves
	if n := chatAudits(t, r.h, "term_refused"); n < len(cases)-2+1 {
		t.Fatalf("%d refusals audited, want ≥ %d", n, len(cases)-1)
	}
	// The control: the person herself does reach it.
	c, st, code := r.dialTerm(t, "worker="+r.wid, r.alice, r.origin, nil)
	if c == nil {
		t.Fatalf("the person refused: %d %s", st, code)
	}
	readCtl(t, c, "ready")
	c.Close(websocket.StatusNormalClosure, "")
}

// rawTermRelay hands the agent an open and a first frame of the test's own,
// under relay id id when given; it returns how the agent ended the stream (-1:
// it never dialled).
func rawTermRelay(t *testing.T, r *termRig, id string, login string, hello func(id string) []byte) websocket.StatusCode {
	t.Helper()
	rctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	if id == "" {
		id = control.NewOpID()
	}
	p := &pendingSSHRelay{id: id, secret: control.NewOpID(), endpointID: "ep_" + r.label, node: r.nc,
		attach: make(chan *websocket.Conn, 1), done: make(chan struct{}), cancel: cancel}
	r.h.srv.termRelays.put(p)
	defer func() { close(p.done); r.h.srv.termRelays.drop(p.id) }()
	msg, _ := control.New(control.TypeTermOpen, control.TermOpen{RelayID: p.id, Secret: p.secret, Login: login})
	if err := r.h.srv.SendNodeWrite(rctx, "ep_"+r.label, msg); err != nil {
		t.Fatal(err)
	}
	var ac *websocket.Conn
	select {
	case ac = <-p.attach:
	case <-time.After(3 * time.Second):
		return -1
	}
	wctx, wcancel := context.WithTimeout(rctx, 5*time.Second)
	defer wcancel()
	if err := ac.Write(wctx, websocket.MessageText, hello(p.id)); err != nil {
		t.Fatal(err)
	}
	_ = ac.Write(wctx, websocket.MessageBinary, []byte("hello\n"))
	var out strings.Builder
	for {
		typ, b, err := ac.Read(wctx)
		if err != nil {
			return websocket.CloseStatus(err)
		}
		if typ == websocket.MessageBinary {
			out.Write(b)
		}
		if strings.Contains(out.String(), "got:hello") { // the command itself answered
			ac.Close(websocket.StatusNormalClosure, "")
			return websocket.StatusNormalClosure
		}
	}
}

func grantFrame(g control.TermGrant, key string) []byte {
	b, _ := json.Marshal(control.TermRelayHello{Grant: control.SignTermGrant(g, key)})
	return b
}

// The node's half of term-other-person: a grant signed wrong, expired, for
// another relay / login / service, replayed, or no grant at all — no terminal.
func TestTermRelayBadGrantNeverOpensATerminal(t *testing.T) {
	r := newTermRig(t, true)
	key := r.nc.tokHash
	now := time.Now()
	good := func(id string) control.TermGrant {
		return control.TermGrant{V: 1, Aud: control.TermAudience, Person: pAlice, Login: r.login, Relay: id,
			Target: control.TermWorkerTarget(r.fid), Iat: now.Unix(), Exp: now.Add(time.Minute).Unix()}
	}
	cases := []struct {
		name  string
		hello func(id string) []byte
	}{
		{"signed with another key", func(id string) []byte { return grantFrame(good(id), HashToken("someone-else")) }},
		{"expired", func(id string) []byte {
			g := good(id)
			g.Iat, g.Exp = now.Add(-3*time.Minute).Unix(), now.Add(-time.Minute).Unix()
			return grantFrame(g, key)
		}},
		{"for another relay", func(id string) []byte { g := good(id); g.Relay = "other"; return grantFrame(g, key) }},
		{"for another login", func(id string) []byte { g := good(id); g.Login = "mallory"; return grantFrame(g, key) }},
		{"for the chat", func(id string) []byte { g := good(id); g.Aud = "chat"; return grantFrame(g, key) }},
		{"a chat statement", func(id string) []byte {
			return personFrame(control.ChatPerson{V: 1, Person: pAlice, Login: r.login, Relay: id, Iat: now.Unix(), Exp: now.Add(time.Minute).Unix()}, key)
		}},
		{"a command for a target", func(id string) []byte { g := good(id); g.Target = "/bin/sh -c id"; return grantFrame(g, key) }},
		{"no grant", func(string) []byte { return []byte(`{}`) }},
		{"bytes first", func(string) []byte { return []byte("id\n") }},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if st := rawTermRelay(t, r, "", r.login, tc.hello); st != websocket.StatusPolicyViolation {
				t.Fatalf("stream ended %d, want policy violation", st)
			}
		})
	}
	if st := rawTermRelay(t, r, "", "mallory", func(id string) []byte { return grantFrame(good(id), key) }); st != -1 {
		t.Fatalf("an open for another login was dialled (%d)", st)
	}
	if s := r.starts(); len(s) != 0 {
		t.Fatalf("a terminal started: %v", s)
	}
	// A good grant opens one — and the same relay id is never good twice.
	id := control.NewOpID()
	if st := rawTermRelay(t, r, id, r.login, func(id string) []byte { return grantFrame(good(id), key) }); st != websocket.StatusNormalClosure {
		t.Fatalf("a good grant: stream ended %d", st)
	}
	waitFor(t, 5*time.Second, "the control started a terminal", func() bool { return len(r.starts()) > 0 })
	n := len(r.starts())
	if st := rawTermRelay(t, r, id, r.login, func(id string) []byte { return grantFrame(good(id), key) }); st != websocket.StatusPolicyViolation {
		t.Fatalf("a replayed grant: stream ended %d, want policy violation", st)
	}
	if len(r.starts()) != n {
		t.Fatal("a replayed grant started a terminal")
	}
	waitFor(t, 30*time.Second, "no terminal left", func() bool { return r.procs() == 0 })
}

// term-relay-orphan: whatever end goes — the browser half-open, the agent's link,
// a malformed frame, a revoked sign-in — both streams, the PTY and its command go
// within 30 s, and the relay's slot is free again.
func TestTermRelayOrphanReleasesEverything(t *testing.T) {
	oldPing, oldTimeout, oldRecheck := termPingEvery, termPingTimeout, termRecheckEvery
	termPingEvery, termPingTimeout, termRecheckEvery = 300*time.Millisecond, 300*time.Millisecond, 300*time.Millisecond
	defer func() { termPingEvery, termPingTimeout, termRecheckEvery = oldPing, oldTimeout, oldRecheck }()
	r := newTermRig(t, true)
	open := func(t *testing.T) *websocket.Conn {
		t.Helper()
		c, st, code := r.dialTerm(t, "worker="+r.wid, r.alice, r.origin, nil)
		if c == nil {
			t.Fatalf("refused: %d %s", st, code)
		}
		readCtl(t, c, "ready")
		return c
	}
	released := func(t *testing.T, what string) {
		t.Helper()
		t0 := time.Now()
		waitFor(t, 30*time.Second, what+": everything released", func() bool {
			return r.procs() == 0 && r.h.srv.termRelays.open() == 0 && r.nc != nil
		})
		t.Logf("%s: released in %s", what, time.Since(t0).Round(100*time.Millisecond))
	}
	lastOutcome := func() string {
		rows, _ := r.h.srv.Store.FleetTermSessions(pAlice, 1)
		if len(rows) == 0 {
			return ""
		}
		return rows[0].Outcome
	}

	t.Run("half-open browser", func(t *testing.T) {
		c := open(t)
		defer c.CloseNow()
		// It stops reading: no pong ever comes back.
		released(t, "half-open")
		if o := lastOutcome(); !strings.Contains(o, "stopped answering") {
			t.Fatalf("outcome %q", o)
		}
	})
	t.Run("malformed control", func(t *testing.T) {
		c := open(t)
		defer c.CloseNow()
		go func() {
			for {
				if _, _, err := c.Read(context.Background()); err != nil {
					return
				}
			}
		}()
		send(t, c, websocket.MessageText, []byte(`{"t":"exec","cmd":"id"}`))
		released(t, "malformed")
		if o := lastOutcome(); !strings.Contains(o, "malformed") {
			t.Fatalf("outcome %q", o)
		}
	})
	t.Run("oversized frame", func(t *testing.T) {
		c := open(t)
		defer c.CloseNow()
		go func() {
			for {
				if _, _, err := c.Read(context.Background()); err != nil {
					return
				}
			}
		}()
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		_ = c.Write(ctx, websocket.MessageBinary, make([]byte, control.TermFrameMax+1))
		cancel()
		released(t, "oversized")
	})
	t.Run("revoked sign-in", func(t *testing.T) {
		c := open(t)
		defer c.CloseNow()
		if _, err := r.h.srv.Store.DeleteHubUser(1001); err != nil { // pAlice
			t.Fatal(err)
		}
		defer listPerson(t, r.h, pAlice, "")
		e := readCtl(t, c, "error")
		if e.Err != "revoked" {
			t.Fatalf("error frame %+v", e)
		}
		released(t, "revoked")
	})
	t.Run("cancelled while attaching", func(t *testing.T) {
		c, st, code := r.dialTerm(t, "worker="+r.wid, r.alice, r.origin, nil)
		if c == nil {
			t.Fatalf("refused: %d %s", st, code)
		}
		c.CloseNow() // gone before the hello, maybe before the agent attached
		released(t, "cancelled")
	})
}

// The agent's link going ends its terminals too (closeNode), and the browser is
// told by the stream closing.
func TestTermRelayAgentLinkDrop(t *testing.T) {
	r := newTermRig(t, true)
	c, st, code := r.dialTerm(t, "worker="+r.wid, r.alice, r.origin, nil)
	if c == nil {
		t.Fatalf("refused: %d %s", st, code)
	}
	defer c.CloseNow()
	readCtl(t, c, "ready")
	r.h.srv.termRelays.closeNode(r.nc)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	for {
		if _, _, err := c.Read(ctx); err != nil {
			break
		}
	}
	waitFor(t, 30*time.Second, "the agent's terminal released", func() bool { return r.procs() == 0 && r.h.srv.termRelays.open() == 0 })
}

// No CapTerm ⇒ the page reads unsupported (「这台机器还不支持」), the connect is
// refused before anything is asked of the node.
func TestTermRelayUnsupportedNode(t *testing.T) {
	r := newTermRig(t, false)
	if r.nc.canTerm {
		t.Fatal("an agent with FleetTerm off offered CapTerm")
	}
	resp := chatDo(t, r.h, http.MethodGet, TermHomePath, r.alice, nil, "")
	var home TermHome
	_ = json.NewDecoder(resp.Body).Decode(&home)
	if resp.StatusCode != http.StatusOK || home.State != "unsupported" || home.Machine != r.host {
		t.Fatalf("home = %d %+v", resp.StatusCode, home)
	}
	if c, st, code := r.dialTerm(t, "worker="+r.wid, r.alice, r.origin, nil); c != nil || st != http.StatusConflict || code != "unsupported" {
		t.Fatalf("connect = %d %s, want 409 unsupported", st, code)
	}
	if len(r.starts()) != 0 {
		t.Fatal("a terminal started on a node without CapTerm")
	}
}

// The terminal and the chat share the relay road, never a stream: a terminal
// that is saturated, closes or sends garbage leaves a chat relay on the same
// login working, and the reverse.
func TestTermRelayDoesNotInterruptChat(t *testing.T) {
	r := newTermRig(t, true)
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	chat, err := r.h.srv.dialChatRelay(ctx, pAlice, r.host, r.login)
	if err != nil {
		t.Fatal(err)
	}
	defer chat.Close()
	ping := func(word string) {
		t.Helper()
		if _, err := chat.Write([]byte(word)); err != nil {
			t.Fatal(err)
		}
		got := make([]byte, len("pong:"+word))
		chat.SetReadDeadline(time.Now().Add(5 * time.Second))
		if _, err := io.ReadFull(chat, got); err != nil || string(got) != "pong:"+word {
			t.Fatalf("chat read %q, %v", got, err)
		}
	}
	ping("one")
	c, st, code := r.dialTerm(t, "worker="+r.wid, r.alice, r.origin, nil)
	if c == nil {
		t.Fatalf("refused: %d %s", st, code)
	}
	readCtl(t, c, "ready")
	// Saturate: a burst the terminal echoes back, nobody reading it yet.
	for i := 0; i < 64; i++ {
		send(t, c, websocket.MessageBinary, []byte(strings.Repeat("x", 1000)+"\n"))
	}
	ping("two")
	send(t, c, websocket.MessageText, []byte(`{"t":"bogus"}`))
	c.CloseNow()
	waitFor(t, 30*time.Second, "terminal gone", func() bool { return r.procs() == 0 && r.h.srv.termRelays.open() == 0 })
	ping("three")
	// …and the reverse: the chat closing leaves a terminal working.
	c, _, _ = r.dialTerm(t, "worker="+r.wid, r.alice, r.origin, nil)
	if c == nil {
		t.Fatal("second terminal refused")
	}
	defer c.CloseNow()
	readCtl(t, c, "ready")
	chat.Close()
	send(t, c, websocket.MessageBinary, []byte("after\n"))
	readOut(t, c, "got:after")
}

// The per-person bound: a third terminal at once is refused before the node.
func TestTermRelayPerPersonCap(t *testing.T) {
	r := newTermRig(t, true)
	r.h.srv.TermMaxPerPerson = 1
	c, _, _ := r.dialTerm(t, "worker="+r.wid, r.alice, r.origin, nil)
	if c == nil {
		t.Fatal("first refused")
	}
	defer c.CloseNow()
	readCtl(t, c, "ready")
	if c2, st, code := r.dialTerm(t, "worker="+r.wid, r.alice, r.origin, nil); c2 != nil || st != http.StatusTooManyRequests {
		t.Fatalf("second = %d %s, want 429", st, code)
	}
}
