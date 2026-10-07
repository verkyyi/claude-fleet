package api

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"crypto/sha512"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"
	"golang.org/x/crypto/ssh"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/agent"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/sshca"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// The relay's completion criterion (claude-fleet#1413), end to end on one
// machine: a hub, a REAL agent on the control channel, and an SSH server on a
// throwaway port standing in for sshd. A client reaches the SSH server only
// through the hub, logs in, pushes 10MB and gets back the same digest.

// testSSHD is an in-process SSH server: password "pw" for anyone; an exec of
// "sha256" answers the hex digest of stdin, "hostname" answers "relay-test".
func testSSHD(t *testing.T) string {
	t.Helper()
	_, hostKey, _ := ed25519.GenerateKey(rand.Reader)
	signer, err := ssh.NewSignerFromKey(hostKey)
	if err != nil {
		t.Fatal(err)
	}
	cfg := &ssh.ServerConfig{PasswordCallback: func(c ssh.ConnMetadata, pw []byte) (*ssh.Permissions, error) {
		if string(pw) == "pw" {
			return nil, nil
		}
		return nil, fmt.Errorf("bad password")
	}}
	cfg.AddHostKey(signer)
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go serveSSH(c, cfg)
		}
	}()
	return ln.Addr().String()
}

func serveSSH(c net.Conn, cfg *ssh.ServerConfig) {
	defer c.Close()
	_, chans, reqs, err := ssh.NewServerConn(c, cfg)
	if err != nil {
		return
	}
	go ssh.DiscardRequests(reqs)
	for nc := range chans {
		if nc.ChannelType() != "session" {
			nc.Reject(ssh.UnknownChannelType, "session only")
			continue
		}
		ch, in, err := nc.Accept()
		if err != nil {
			return
		}
		go func() {
			defer ch.Close()
			for req := range in {
				if req.Type != "exec" {
					req.Reply(false, nil)
					continue
				}
				var p struct{ Cmd string }
				ssh.Unmarshal(req.Payload, &p)
				req.Reply(true, nil)
				switch p.Cmd {
				case "sha256":
					h := sha256.New()
					io.Copy(h, ch)
					fmt.Fprint(ch, hex.EncodeToString(h.Sum(nil)))
				case "hostname":
					fmt.Fprint(ch, "relay-test")
				}
				ch.SendRequest("exit-status", false, ssh.Marshal(struct{ S uint32 }{0}))
				return
			}
		}()
	}
}

// startSSHRelayAgent runs a real agent with the fleet module on, enrolled as
// label, relaying to sshd. It returns the hostname the hub knows it by and a
// stop function.
func startSSHRelayAgent(t *testing.T, h *harness, label, sshd string) (string, context.CancelFunc) {
	t.Helper()
	agent.SetSSHRelayTargetForTest(sshd)
	t.Cleanup(func() { agent.SetSSHRelayTargetForTest("") })
	home := t.TempDir()
	a, err := agent.New(agent.Config{
		HubURL: h.http.URL, Token: h.enroll(t, label), Home: home,
		StateDir: filepath.Join(home, "state"), SessionsDir: filepath.Join(home, "sessions"),
		Sources: "claude", LiveInterval: 200 * time.Millisecond, ScanInterval: time.Hour, LimitsInterval: time.Hour,
		Fleet: true, FleetSSHRelay: true, Version: "it-" + label,
	})
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { a.Run(ctx); close(done) }()
	t.Cleanup(func() { cancel(); <-done })
	host, _ := os.Hostname()
	waitFor(t, 5*time.Second, "agent connected", func() bool {
		return h.srv.nodes.get("ep_"+label) != nil && h.srv.nodes.get("ep_"+label).hostname() == host
	})
	return host, cancel
}

// sshRelayDial opens a relay to node and runs the handshake. auth sets the HTTP
// credential; answer, when set, answers a certificate challenge. It returns
// the stream as a net.Conn on "ready", or the hub's refusal code.
func sshRelayDial(t *testing.T, h *harness, node string, auth func(http.Header), answer func(nonce string) control.SSHRelayHello) (net.Conn, string) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	hdr := http.Header{}
	if auth != nil {
		auth(hdr)
	}
	url := "ws" + strings.TrimPrefix(h.http.URL, "http") + control.SSHRelayPath + "?node=" + node
	c, resp, err := websocket.Dial(ctx, url, &websocket.DialOptions{HTTPHeader: hdr})
	if err != nil {
		if resp != nil {
			return nil, fmt.Sprintf("HTTP %d", resp.StatusCode)
		}
		t.Fatalf("dial relay: %v", err)
	}
	t.Cleanup(func() { c.CloseNow() })
	for {
		var m control.SSHRelayHello
		if err := wsjson.Read(ctx, c, &m); err != nil {
			t.Fatalf("relay handshake: %v", err)
		}
		switch m.Type {
		case "challenge":
			if answer == nil {
				t.Fatal("hub sent a challenge to a client that sent a credential")
			}
			if err := wsjson.Write(ctx, c, answer(m.Nonce)); err != nil {
				t.Fatal(err)
			}
		case "ready":
			return websocket.NetConn(context.Background(), c, websocket.MessageBinary), ""
		case "error":
			return nil, m.Code
		default:
			t.Fatalf("unexpected handshake frame %+v", m)
		}
	}
}

func asOperator(hdr http.Header) { hdr.Set("Authorization", "Bearer "+viewerToken) }

// asSession presents principal's GitHub session as a bearer, the way a CLI
// holds it.
func asSession(principal string) func(http.Header) {
	return func(hdr http.Header) {
		hdr.Set("Authorization", "Bearer "+personSession(principal, ""))
	}
}

func sshOver(t *testing.T, conn net.Conn) *ssh.Client {
	t.Helper()
	cc, chans, reqs, err := ssh.NewClientConn(conn, "relay", &ssh.ClientConfig{
		User: "someone", Auth: []ssh.AuthMethod{ssh.Password("pw")},
		HostKeyCallback: ssh.InsecureIgnoreHostKey(), Timeout: 10 * time.Second,
	})
	if err != nil {
		t.Fatalf("ssh login through the relay: %v", err)
	}
	return ssh.NewClient(cc, chans, reqs)
}

func TestRelaySSHTenMegabytes(t *testing.T) {
	h := newFleetHarness(t)
	h.srv.SSHRelayRateBPS = -1
	host, _ := startSSHRelayAgent(t, h, "m4", testSSHD(t))

	conn, code := sshRelayDial(t, h, host, asOperator, nil)
	if conn == nil {
		t.Fatalf("relay refused: %s", code)
	}
	cl := sshOver(t, conn)
	defer cl.Close()

	sess, err := cl.NewSession()
	if err != nil {
		t.Fatal(err)
	}
	data := make([]byte, 10<<20)
	rand.Read(data)
	sum := sha256.Sum256(data)
	sess.Stdin = bytes.NewReader(data)
	out, err := sess.Output("sha256")
	if err != nil {
		t.Fatalf("exec through the relay: %v", err)
	}
	if got, want := string(out), hex.EncodeToString(sum[:]); got != want {
		t.Fatalf("digest through the relay = %s, want %s", got, want)
	}
	cl.Close()

	// The audit row: who, which machine, which agent, and the bytes.
	var r store.SSHRelay
	waitFor(t, 5*time.Second, "relay audited as closed", func() bool {
		rows, _ := h.srv.Store.SSHRelays(10)
		if len(rows) == 1 && rows[0].EndedAt != nil {
			r = rows[0]
			return true
		}
		return false
	})
	if r.Actor != "operator" || r.Hostname != host || r.EndpointID != "ep_m4" || r.OSUser == "" || r.Outcome != "closed" {
		t.Fatalf("audit row = %+v", r)
	}
	if r.BytesUp < 10<<20 || r.BytesDown == 0 {
		t.Fatalf("audit bytes up=%d down=%d; want up >= 10MB", r.BytesUp, r.BytesDown)
	}
	// The audit row is written as the handler unwinds, just before the
	// relay leaves the table.
	waitFor(t, 5*time.Second, "no relay left in flight", func() bool { return h.srv.sshRelays.open() == 0 })
}

// Who may ask: nothing at all is refused before the upgrade; a person reaches
// only a machine where they hold an active login.
func TestRelayOnlyYourOwnMachines(t *testing.T) {
	h := newFleetHarness(t)
	enablePeople(t, h, pAlice, pBob)
	host, _ := startSSHRelayAgent(t, h, "m4", testSSHD(t))

	if _, code := sshRelayDial(t, h, host, nil, nil); code != "HTTP 401" {
		t.Fatalf("no credential: %s, want HTTP 401", code)
	}
	if _, code := sshRelayDial(t, h, host, asSession(pBob), nil); code != "NOT_FOUND" {
		t.Fatalf("a person with no login there: %s, want NOT_FOUND", code)
	}
	p, err := h.srv.Store.AdoptPrincipal(pAlice, "alice", "Alice", time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if err := h.srv.Store.AdoptAccount(p, host, time.Now()); err != nil {
		t.Fatal(err)
	}
	if _, code := sshRelayDial(t, h, "m9", asSession(pAlice), nil); code != "NOT_FOUND" {
		t.Fatalf("someone else's machine: %s, want NOT_FOUND", code)
	}
	conn, code := sshRelayDial(t, h, host, asSession(pAlice), nil)
	if conn == nil {
		t.Fatalf("Alice to her own machine refused: %s", code)
	}
	cl := sshOver(t, conn)
	out, err := mustSession(t, cl).Output("hostname")
	if err != nil || string(out) != "relay-test" {
		t.Fatalf("hostname through the relay = %q, %v", out, err)
	}
	cl.Close()

	// A person's relays are capped. The slot of the relay just closed is
	// released as its handler unwinds, a moment after the client is gone.
	waitFor(t, 5*time.Second, "Alice's last relay released", func() bool {
		h.srv.sshRelays.mu.Lock()
		defer h.srv.sshRelays.mu.Unlock()
		return h.srv.sshRelays.perUser[pAlice] == 0
	})
	h.srv.SSHRelayMaxPerUser = 1
	c1, _ := sshRelayDial(t, h, host, asSession(pAlice), nil)
	if c1 == nil {
		t.Fatal("first relay refused")
	}
	if _, code := sshRelayDial(t, h, host, asSession(pAlice), nil); code != "TOO_MANY" {
		t.Fatalf("second concurrent relay: %s, want TOO_MANY", code)
	}
	c1.Close()
}

func mustSession(t *testing.T, cl *ssh.Client) *ssh.Session {
	t.Helper()
	s, err := cl.NewSession()
	if err != nil {
		t.Fatal(err)
	}
	return s
}

// An agent that drops takes its relays with it: the client sees the stream
// end promptly, instead of a session that hangs on a link nobody carries.
func TestRelayClosesWhenAgentDrops(t *testing.T) {
	h := newFleetHarness(t)
	host, stop := startSSHRelayAgent(t, h, "m4", testSSHD(t))
	conn, code := sshRelayDial(t, h, host, asOperator, nil)
	if conn == nil {
		t.Fatalf("relay refused: %s", code)
	}
	cl := sshOver(t, conn)
	done := make(chan error, 1)
	go func() { done <- cl.Wait() }()

	stop()
	select {
	case <-done:
	case <-time.After(10 * time.Second):
		t.Fatal("the SSH connection is still open 10s after its agent went away")
	}
	waitFor(t, 5*time.Second, "relay audited as ended", func() bool {
		rows, _ := h.srv.Store.SSHRelays(10)
		return len(rows) == 1 && rows[0].EndedAt != nil
	})
}

// With no agent able to relay on a machine, the refusal says so instead of
// timing out.
func TestRelayNodeOffline(t *testing.T) {
	h := newFleetHarness(t)
	if _, code := sshRelayDial(t, h, "m4", asOperator, nil); code != "NODE_OFFLINE" {
		t.Fatalf("relay to a machine with no agent: %s, want NODE_OFFLINE", code)
	}
}

// sshsig signs msg the way `ssh-keygen -Y sign -n ns` does.
func sshsig(t *testing.T, signer ssh.Signer, ns string, msg []byte) string {
	t.Helper()
	str := func(b []byte) []byte {
		return append(binary.BigEndian.AppendUint32(nil, uint32(len(b))), b...)
	}
	h := sha512.Sum512(msg)
	signed := []byte("SSHSIG")
	for _, f := range [][]byte{[]byte(ns), nil, []byte("sha512"), h[:]} {
		signed = append(signed, str(f)...)
	}
	sig, err := signer.Sign(rand.Reader, signed)
	if err != nil {
		t.Fatal(err)
	}
	blob := []byte("SSHSIG")
	blob = binary.BigEndian.AppendUint32(blob, 1)
	for _, f := range [][]byte{signer.PublicKey().Marshal(), []byte(ns), nil, []byte("sha512"), ssh.Marshal(sig)} {
		blob = append(blob, str(f)...)
	}
	return "-----BEGIN SSH SIGNATURE-----\n" + base64.StdEncoding.EncodeToString(blob) + "\n-----END SSH SIGNATURE-----\n"
}

type certKit struct {
	ca     ssh.Signer
	user   ssh.Signer
	userPK ed25519.PrivateKey
}

func newCertKit(t *testing.T) certKit {
	t.Helper()
	_, caKey, _ := ed25519.GenerateKey(rand.Reader)
	ca, _ := ssh.NewSignerFromKey(caKey)
	_, uKey, _ := ed25519.GenerateKey(rand.Reader)
	u, _ := ssh.NewSignerFromKey(uKey)
	return certKit{ca: ca, user: u, userPK: uKey}
}

func (k certKit) cert(t *testing.T, keyID string, principals []string, from, to time.Time) *ssh.Certificate {
	t.Helper()
	c := &ssh.Certificate{Key: k.user.PublicKey(), CertType: ssh.UserCert, KeyId: keyID,
		ValidPrincipals: principals, ValidAfter: uint64(from.Unix()), ValidBefore: uint64(to.Unix())}
	if err := c.SignCert(rand.Reader, k.ca); err != nil {
		t.Fatal(err)
	}
	return c
}

// A connection certificate from the hub's CA admits its holder — proven by a
// signature over the hub's nonce — to their own machines and no others; an
// expired one, a foreign CA's, or a signature by another key does not.
func TestRelayCertificate(t *testing.T) {
	h := newFleetHarness(t)
	h.srv.ViewerToken = viewerToken
	k := newCertKit(t)
	h.srv.SSHRelayCA = []ssh.PublicKey{k.ca.PublicKey()}
	host, _ := startSSHRelayAgent(t, h, "m4", testSSHD(t))
	p, _ := h.srv.Store.AdoptPrincipal(pAlice, "alice", "Alice", time.Now())
	h.srv.Store.AdoptAccount(p, host, time.Now())

	now := time.Now()
	// The key id as #1412's signer writes it: "person:gh:<id>" — the
	// principal keeps its own ':'.
	good := k.cert(t, sshca.KeyIDPrefix+pAlice, []string{"alice"}, now.Add(-time.Minute), now.Add(12*time.Hour))
	answer := func(c *ssh.Certificate, signer ssh.Signer, ns string) func(string) control.SSHRelayHello {
		return func(nonce string) control.SSHRelayHello {
			return control.SSHRelayHello{Type: "auth", Cert: string(ssh.MarshalAuthorizedKey(c)), Sig: sshsig(t, signer, ns, []byte(nonce))}
		}
	}

	conn, code := sshRelayDial(t, h, host, nil, answer(good, k.user, control.SSHRelaySigNamespace))
	if conn == nil {
		t.Fatalf("a valid certificate was refused: %s", code)
	}
	cl := sshOver(t, conn)
	if out, err := mustSession(t, cl).Output("hostname"); err != nil || string(out) != "relay-test" {
		t.Fatalf("hostname = %q, %v", out, err)
	}
	cl.Close()
	rows, _ := h.srv.Store.SSHRelays(10)
	if len(rows) == 0 || rows[0].Actor != pAlice {
		t.Fatalf("audit names %+v, want %s", rows, pAlice)
	}

	_, other, _ := ed25519.GenerateKey(rand.Reader)
	otherSigner, _ := ssh.NewSignerFromKey(other)
	foreign := newCertKit(t)
	for name, tc := range map[string]struct {
		node   string
		answer func(string) control.SSHRelayHello
	}{
		"expired":        {host, answer(k.cert(t, sshca.KeyIDPrefix+pAlice, []string{"alice"}, now.Add(-13*time.Hour), now.Add(-time.Hour)), k.user, control.SSHRelaySigNamespace)},
		"foreign CA":     {host, answer(foreign.cert(t, sshca.KeyIDPrefix+pAlice, []string{"alice"}, now.Add(-time.Minute), now.Add(time.Hour)), foreign.user, control.SSHRelaySigNamespace)},
		"other key":      {host, answer(good, otherSigner, control.SSHRelaySigNamespace)},
		"wrong ns":       {host, answer(good, k.user, "git")},
		"not her login":  {host, answer(k.cert(t, sshca.KeyIDPrefix+pAlice, []string{"bob"}, now.Add(-time.Minute), now.Add(time.Hour)), k.user, control.SSHRelaySigNamespace)},
		"unknown person": {host, answer(k.cert(t, sshca.KeyIDPrefix+pCarol, []string{"carol"}, now.Add(-time.Minute), now.Add(time.Hour)), k.user, control.SSHRelaySigNamespace)},
	} {
		if _, code := sshRelayDial(t, h, tc.node, nil, tc.answer); code != "UNAUTHORIZED" {
			t.Errorf("%s: %s, want UNAUTHORIZED", name, code)
		}
	}
	if _, code := sshRelayDial(t, h, "m9", nil, answer(good, k.user, control.SSHRelaySigNamespace)); code != "NOT_FOUND" {
		t.Errorf("valid certificate to someone else's machine: %s, want NOT_FOUND", code)
	}

	// The hub's own signing CA (#1412) is trusted with no extra setting.
	h.srv.SSHRelayCA = nil
	h.srv.SSHCA = sshca.New(k.ca)
	conn, code = sshRelayDial(t, h, host, nil, answer(good, k.user, control.SSHRelaySigNamespace))
	if conn == nil {
		t.Fatalf("a certificate from the hub's own CA was refused: %s", code)
	}
	conn.Close()
}

// The hub reads what the real ssh-keygen writes, not only what this test's
// own signer writes.
func TestVerifySSHSigAgainstSSHKeygen(t *testing.T) {
	bin, err := exec.LookPath("ssh-keygen")
	if err != nil {
		t.Skip("no ssh-keygen on PATH")
	}
	dir := t.TempDir()
	key := filepath.Join(dir, "id")
	if out, err := exec.Command(bin, "-q", "-t", "ed25519", "-N", "", "-f", key).CombinedOutput(); err != nil {
		t.Fatalf("ssh-keygen: %v %s", err, out)
	}
	cmd := exec.Command(bin, "-Y", "sign", "-f", key, "-n", control.SSHRelaySigNamespace)
	cmd.Stdin = strings.NewReader("nonce-123")
	sig, err := cmd.Output()
	if err != nil {
		t.Skipf("ssh-keygen -Y sign unsupported here: %v", err)
	}
	pubB, _ := os.ReadFile(key + ".pub")
	pub, _, _, _, err := ssh.ParseAuthorizedKey(pubB)
	if err != nil {
		t.Fatal(err)
	}
	if err := verifySSHSig(pub, sig, []byte("nonce-123"), control.SSHRelaySigNamespace); err != nil {
		t.Fatalf("a real ssh-keygen signature: %v", err)
	}
	if err := verifySSHSig(pub, sig, []byte("nonce-124"), control.SSHRelaySigNamespace); err == nil {
		t.Fatal("a signature over another nonce verified")
	}
}

func TestByteLimiterPaces(t *testing.T) {
	l := newByteLimiter(64 << 10)
	start := time.Now()
	for i := 0; i < 4; i++ {
		if err := l.wait(context.Background(), 32<<10); err != nil {
			t.Fatal(err)
		}
	}
	// 128KB at 64KB/s with a 64KB burst: about a second.
	if d := time.Since(start); d < 800*time.Millisecond || d > 3*time.Second {
		t.Fatalf("128KB at 64KB/s took %s", d)
	}
}
