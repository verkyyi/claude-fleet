package api

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha512"
	"encoding/base64"
	"encoding/binary"
	"fmt"
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

	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

// The relay's completion criterion (claude-fleet#1413), end to end on one
// machine: a hub, a REAL agent on the control channel, and an SSH server on a
// throwaway port standing in for sshd. A client reaches the SSH server only
// through the hub, logs in, pushes 10MB and gets back the same digest.

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

// With no agent able to relay on a machine, the refusal says so instead of
// timing out.
func TestRelayNodeOffline(t *testing.T) {
	h := newFleetHarness(t)
	if _, code := sshRelayDial(t, h, "mac-c", asOperator, nil); code != "NODE_OFFLINE" {
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
