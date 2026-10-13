package api

import (
	"context"
	"encoding/json"
	"io"
	"net"
	"os"
	"os/user"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"

	"github.com/coder/websocket"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/agent"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
)

// The chat relay's acceptance (claude-fleet#3644, EPIC #3642 C2; BREAK-IT
// chat-relay-wrong-person): a hub, a REAL agent on the control channel, and a
// unix socket standing in for the login's conversation service at
// $FLEET_CONF_DIR/webchat/chat.sock. A statement signed wrong, expired, minted
// for another relay or for another login closes the stream, and the socket never
// receives a byte; the target cannot be changed by anything the hub sends; an
// agent that did not offer CapChat is never sent an open.

// fakeChatSock listens at <conf>/webchat/chat.sock, counts connections and bytes,
// and echoes each read back prefixed "pong:".
type fakeChatSock struct {
	conns, bytes atomic.Int64
}

func listenChatSock(t *testing.T, conf string) *fakeChatSock {
	t.Helper()
	if err := os.MkdirAll(filepath.Join(conf, "webchat"), 0o700); err != nil {
		t.Fatal(err)
	}
	ln, err := net.Listen("unix", filepath.Join(conf, "webchat", "chat.sock"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	f := &fakeChatSock{}
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			f.conns.Add(1)
			go func() {
				defer c.Close()
				buf := make([]byte, 4096)
				for {
					n, err := c.Read(buf)
					if n > 0 {
						f.bytes.Add(int64(n))
						c.Write(append([]byte("pong:"), buf[:n]...))
					}
					if err != nil {
						return
					}
				}
			}()
		}
	}()
	return f
}

// shortTemp is a directory short enough for a unix socket path (104 bytes on macOS).
func shortTemp(t *testing.T) string {
	t.Helper()
	d, err := os.MkdirTemp("/tmp", "cr")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(d) })
	return d
}

// startChatAgent runs a real agent (chat on or off) whose conf dir holds the
// fake socket; it returns the hub's link, the machine and the login.
func startChatAgent(t *testing.T, h *harness, label string, chat bool) (*fakeChatSock, *nodeConn, string, string) {
	t.Helper()
	conf := shortTemp(t)
	sock := listenChatSock(t, conf)
	nc, host, login := runChatAgentIn(t, h, label, chat, conf)
	return sock, nc, host, login
}

// runChatAgentIn runs a real agent whose $FLEET_CONF_DIR is conf (the test put
// whatever answers at conf/webchat/chat.sock); it returns the hub's link, the
// machine and the login.
func runChatAgentIn(t *testing.T, h *harness, label string, chat bool, conf string) (*nodeConn, string, string) {
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
		Fleet: true, FleetChat: chat, Version: "it-" + label,
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

func TestChatRelayReachesTheLoginsSocket(t *testing.T) {
	h := newFleetHarness(t)
	sock, _, host, login := startChatAgent(t, h, "chat-ok", true)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	c, err := h.srv.dialChatRelay(ctx, "alice", host, login)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer c.Close()
	if _, err := c.Write([]byte("ping")); err != nil {
		t.Fatal(err)
	}
	got := make([]byte, len("pong:ping"))
	c.SetReadDeadline(time.Now().Add(5 * time.Second))
	if _, err := io.ReadFull(c, got); err != nil || string(got) != "pong:ping" {
		t.Fatalf("read %q, %v; want pong:ping", got, err)
	}
	if sock.conns.Load() != 1 {
		t.Fatalf("socket saw %d connections, want 1", sock.conns.Load())
	}
	c.Close()
	waitFor(t, 5*time.Second, "relay released", func() bool { return h.srv.chatRelays.open() == 0 })
}

// rawChatRelay is dialChatRelay with the open payload and the first frame in the
// test's hands: it returns how the agent ended the stream.
func rawChatRelay(t *testing.T, h *harness, nc *nodeConn, epID string, payload func(id, secret string) any,
	hello func(id string) []byte) websocket.StatusCode {
	t.Helper()
	rctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	p := &pendingSSHRelay{id: control.NewOpID(), secret: control.NewOpID(), endpointID: epID, node: nc,
		attach: make(chan *websocket.Conn, 1), done: make(chan struct{}), cancel: cancel}
	h.srv.chatRelays.put(p)
	defer func() { close(p.done); h.srv.chatRelays.drop(p.id) }()
	raw, _ := json.Marshal(payload(p.id, p.secret))
	msg := control.Message{Type: control.TypeChatRelayOpen, Payload: raw}
	if err := h.srv.SendNodeWrite(rctx, epID, msg); err != nil {
		t.Fatal(err)
	}
	var ac *websocket.Conn
	select {
	case ac = <-p.attach:
	case <-time.After(3 * time.Second):
		return -1 // the agent never dialled
	}
	wctx, wcancel := context.WithTimeout(rctx, 5*time.Second)
	defer wcancel()
	if err := ac.Write(wctx, websocket.MessageText, hello(p.id)); err != nil {
		t.Fatal(err)
	}
	// Whatever the agent does next, a refused stream is closed by it.
	_ = ac.Write(wctx, websocket.MessageBinary, []byte("GET /api/conversation HTTP/1.1\r\nHost: webchat\r\n\r\n"))
	_, _, err := ac.Read(wctx)
	return websocket.CloseStatus(err)
}

func personFrame(c control.ChatPerson, key string) []byte {
	b, _ := json.Marshal(control.ChatRelayHello{Person: control.SignChatPerson(c, key)})
	return b
}

func TestChatRelayWrongPersonNeverReachesTheSocket(t *testing.T) {
	h := newFleetHarness(t)
	sock, nc, _, login := startChatAgent(t, h, "chat-wp", true)
	key := nc.tokHash
	if key == "" || key != HashToken(h.tokens["chat-wp"]) {
		t.Fatalf("the link's token hash is %q, want the enrolment token's", key)
	}
	now := time.Now()
	good := func(id string) control.ChatPerson {
		return control.ChatPerson{V: 1, Person: "alice", Login: login, Relay: id, Iat: now.Unix(), Exp: now.Add(time.Minute).Unix()}
	}
	open := func(id, secret string) any {
		return control.ChatRelayOpen{RelayID: id, Secret: secret, Login: login}
	}
	cases := []struct {
		name  string
		hello func(id string) []byte
	}{
		{"signed with another key", func(id string) []byte { return personFrame(good(id), HashToken("someone-else")) }},
		{"expired", func(id string) []byte {
			c := good(id)
			c.Iat, c.Exp = now.Add(-3*time.Minute).Unix(), now.Add(-time.Minute).Unix()
			return personFrame(c, key)
		}},
		{"for another relay", func(id string) []byte {
			c := good(id)
			c.Relay = "someone-elses-relay"
			return personFrame(c, key)
		}},
		{"for another login", func(id string) []byte {
			c := good(id)
			c.Login = "mallory"
			return personFrame(c, key)
		}},
		{"too long a life", func(id string) []byte {
			c := good(id)
			c.Exp = now.Add(time.Hour).Unix()
			return personFrame(c, key)
		}},
		{"no statement", func(string) []byte { return []byte(`{}`) }},
		{"bytes first", func(string) []byte { return []byte("GET / HTTP/1.1\r\n\r\n") }},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if st := rawChatRelay(t, h, nc, "ep_chat-wp", open, tc.hello); st != websocket.StatusPolicyViolation {
				t.Fatalf("stream ended with %d, want %d (policy violation)", st, websocket.StatusPolicyViolation)
			}
		})
	}
	// An open for another login is not even dialled.
	other := func(id, secret string) any {
		return control.ChatRelayOpen{RelayID: id, Secret: secret, Login: "mallory"}
	}
	if st := rawChatRelay(t, h, nc, "ep_chat-wp", other, func(id string) []byte { return personFrame(good(id), key) }); st != -1 {
		t.Fatalf("an open for another login was dialled (stream ended %d)", st)
	}
	if n, b := sock.conns.Load(), sock.bytes.Load(); n != 0 || b != 0 {
		t.Fatalf("the socket saw %d connections, %d bytes; want none", n, b)
	}
	// … and the same rig with a good statement does reach it (the control).
	if st := rawChatRelay(t, h, nc, "ep_chat-wp", open, func(id string) []byte { return personFrame(good(id), key) }); st == websocket.StatusPolicyViolation {
		t.Fatal("a good statement was refused")
	}
	waitFor(t, 5*time.Second, "the control reached the socket", func() bool { return sock.bytes.Load() > 0 })
}

func TestChatRelayTargetIsFixed(t *testing.T) {
	h := newFleetHarness(t)
	sock, nc, _, login := startChatAgent(t, h, "chat-tg", true)
	evilDir := shortTemp(t)
	evil := listenChatSock(t, evilDir)
	evilSock := filepath.Join(evilDir, "webchat", "chat.sock")
	tcp, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer tcp.Close()
	var tcpHits atomic.Int64
	go func() {
		for {
			c, err := tcp.Accept()
			if err != nil {
				return
			}
			tcpHits.Add(1)
			c.Close()
		}
	}()
	now := time.Now()
	open := func(id, secret string) any {
		return map[string]any{"relay_id": id, "secret": secret, "login": login,
			"target": evilSock, "path": evilSock, "sock": evilSock, "socket": evilSock,
			"addr": tcp.Addr().String(), "address": tcp.Addr().String(), "host": "127.0.0.1",
			"port": tcp.Addr().(*net.TCPAddr).Port, "conf_dir": evilDir, "home": evilDir}
	}
	hello := func(id string) []byte {
		return personFrame(control.ChatPerson{V: 1, Person: "alice", Login: login, Relay: id,
			Iat: now.Unix(), Exp: now.Add(time.Minute).Unix()}, nc.tokHash)
	}
	rawChatRelay(t, h, nc, "ep_chat-tg", open, hello)
	waitFor(t, 5*time.Second, "the login's own socket was reached", func() bool { return sock.bytes.Load() > 0 })
	if evil.conns.Load() != 0 || tcpHits.Load() != 0 {
		t.Fatalf("a target from the request was reached: socket %d, tcp %d", evil.conns.Load(), tcpHits.Load())
	}
}

func TestChatRelayNotSentWithoutCapChat(t *testing.T) {
	h := newFleetHarness(t)
	sock, nc, host, login := startChatAgent(t, h, "chat-off", false)
	if nc.canChat {
		t.Fatal("an agent with FleetChat off offered CapChat")
	}
	_, err := h.srv.dialChatRelay(context.Background(), "alice", host, login)
	re, ok := err.(*sshRelayError)
	if !ok || re.code != "NO_CHAT" {
		t.Fatalf("dial = %v, want a NO_CHAT refusal", err)
	}
	if h.srv.chatRelays.open() != 0 {
		t.Fatal("a refused relay was left in the table")
	}
	// Even a hand-sent open is ignored by that agent: it never dials.
	open := func(id, secret string) any { return control.ChatRelayOpen{RelayID: id, Secret: secret, Login: login} }
	if st := rawChatRelay(t, h, nc, "ep_chat-off", open, func(string) []byte { return nil }); st != -1 {
		t.Fatalf("an agent without CapChat dialled (stream ended %d)", st)
	}
	if sock.conns.Load() != 0 {
		t.Fatal("the socket was reached")
	}
}

func TestChatRelayPerLoginCap(t *testing.T) {
	h := newFleetHarness(t)
	h.srv.ChatRelayMaxPerLogin = 2
	_, _, host, login := startChatAgent(t, h, "chat-cap", true)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	var open []net.Conn
	for i := 0; i < 2; i++ {
		c, err := h.srv.dialChatRelay(ctx, "alice", host, login)
		if err != nil {
			t.Fatalf("relay %d: %v", i, err)
		}
		open = append(open, c)
	}
	_, err := h.srv.dialChatRelay(ctx, "alice", host, login)
	if re, ok := err.(*sshRelayError); !ok || re.code != "TOO_MANY" {
		t.Fatalf("third relay = %v, want TOO_MANY", err)
	}
	open[0].Close()
	c, err := h.srv.dialChatRelay(ctx, "alice", host, login)
	if err != nil {
		t.Fatalf("after one closed: %v", err)
	}
	c.Close()
	open[1].Close()
}

func TestChatRelayNodeOffline(t *testing.T) {
	h := newFleetHarness(t)
	_, err := h.srv.dialChatRelay(context.Background(), "alice", "nowhere", "nobody")
	if re, ok := err.(*sshRelayError); !ok || re.code != "NODE_OFFLINE" {
		t.Fatalf("dial = %v, want NODE_OFFLINE", err)
	}
}
