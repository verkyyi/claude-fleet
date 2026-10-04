package sshca

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/pem"
	"fmt"
	"net"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"golang.org/x/crypto/ssh"
)

// The completion criterion, against a REAL sshd: one trusting the hub's CA
// the way a node is configured (TrustedUserCAKeys) admits a fresh certificate
// as its login, refuses an expired one, one for another login and one from
// another CA — and a plain key in authorized_keys (the operator's own) still
// gets in beside it. The sshd is unprivileged, on loopback, in a temp dir; it
// can only admit the user running the test, which is all this needs. Skipped
// where there is no sshd binary.
func TestRealSshdTrustsTheCA(t *testing.T) {
	sshd, err := exec.LookPath("/usr/sbin/sshd")
	if err != nil {
		t.Skip("no /usr/sbin/sshd")
	}
	sshBin, err := exec.LookPath("ssh")
	if err != nil {
		t.Skip("no ssh client")
	}
	if testing.Short() {
		t.Skip("starts an sshd")
	}
	me, err := user.Current()
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	write := func(name string, b []byte, mode os.FileMode) string {
		p := filepath.Join(dir, name)
		if err := os.WriteFile(p, b, mode); err != nil {
			t.Fatal(err)
		}
		return p
	}
	privPEM := func(k ed25519.PrivateKey) []byte {
		blk, err := ssh.MarshalPrivateKey(k, "")
		if err != nil {
			t.Fatal(err)
		}
		return pem.EncodeToMemory(blk)
	}
	newKey := func(name string) (string, ssh.PublicKey) {
		pub, priv, _ := ed25519.GenerateKey(rand.Reader)
		pk, _ := ssh.NewPublicKey(pub)
		return write(name, privPEM(priv), 0o600), pk
	}

	ca := newCA(t)
	write("ca.pub", []byte(ca.PublicKey()+"\n"), 0o644)
	hostKey, _ := newKey("host")
	opKey, opPub := newKey("operator")
	write("authorized_keys", ssh.MarshalAuthorizedKey(opPub), 0o600)

	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := l.Addr().(*net.TCPAddr).Port
	l.Close()
	cfg := write("sshd_config", []byte(fmt.Sprintf(`Port %d
ListenAddress 127.0.0.1
HostKey %s
PidFile %s
StrictModes no
UsePAM no
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
AuthorizedKeysFile %s
TrustedUserCAKeys %s
`, port, hostKey, filepath.Join(dir, "pid"), filepath.Join(dir, "authorized_keys"), filepath.Join(dir, "ca.pub"))), 0o644)

	// OpenSSH 9.8+ penalises a source that fails auth by refusing its next
	// connections; the refusals below are deliberate, so turn that off where
	// the option exists.
	if exec.Command(sshd, "-t", "-f", cfg, "-o", "PerSourcePenalties=no").Run() == nil {
		f, _ := os.OpenFile(cfg, os.O_APPEND|os.O_WRONLY, 0)
		f.WriteString("PerSourcePenalties no\n")
		f.Close()
	}
	if out, err := exec.Command(sshd, "-t", "-f", cfg).CombinedOutput(); err != nil {
		t.Skipf("this sshd will not run unprivileged here: %v %s", err, out)
	}
	srv := exec.Command(sshd, "-D", "-e", "-f", cfg)
	log := &lockedLog{}
	srv.Stderr = log
	if err := srv.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { srv.Process.Kill(); srv.Wait() })
	for i := 0; ; i++ {
		if c, err := net.Dial("tcp", fmt.Sprintf("127.0.0.1:%d", port)); err == nil {
			c.Close()
			break
		}
		if i > 50 {
			t.Fatalf("sshd never listened: %s", log.String())
		}
		time.Sleep(100 * time.Millisecond)
	}

	try := func(key, cert string) error {
		args := []string{"-F", "/dev/null", "-p", fmt.Sprint(port), "-i", key,
			"-o", "IdentitiesOnly=yes", "-o", "IdentityAgent=none", "-o", "BatchMode=yes",
			"-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null", "-o", "ConnectTimeout=10"}
		if cert != "" {
			args = append(args, "-o", "CertificateFile="+cert)
		}
		out, err := exec.Command(sshBin, append(args, me.Username+"@127.0.0.1", "true")...).CombinedOutput()
		if err != nil {
			return fmt.Errorf("%v: %s", err, out)
		}
		return nil
	}
	certFor := func(name string, signer *CA, login string, at time.Time) (string, string) {
		key, pk := newKey(name)
		iss, err := signer.Sign(Request{Key: pk, PrincipalID: "Tester", Logins: []string{login}}, at)
		if err != nil {
			t.Fatal(err)
		}
		return key, write(name+"-cert.pub", []byte(iss.Line+"\n"), 0o644)
	}

	now := time.Now()
	if k, c := certFor("fresh", ca, me.Username, now); try(k, c) != nil {
		t.Fatalf("a fresh certificate was refused: %v\nsshd: %s", try(k, c), log.String())
	}
	if k, c := certFor("expired", ca, me.Username, now.Add(-13*time.Hour)); try(k, c) == nil {
		t.Fatal("an expired certificate got in")
	}
	if k, c := certFor("other-login", ca, "someoneelse", now); try(k, c) == nil {
		t.Fatal("a certificate for another login got in")
	}
	if k, c := certFor("other-ca", newCA(t), me.Username, now); try(k, c) == nil {
		t.Fatal("a certificate from another CA got in")
	}
	if err := try(opKey, ""); err != nil {
		t.Fatalf("the operator's plain key no longer gets in: %v", err)
	}
	if !strings.Contains(log.String(), "wecom:Tester") {
		t.Errorf("sshd's log does not name the key id: %s", log.String())
	}
}

// lockedLog is sshd's stderr: exec copies into it from its own goroutine
// while the test reads it.
type lockedLog struct {
	mu sync.Mutex
	b  strings.Builder
}

func (l *lockedLog) Write(p []byte) (int, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.b.Write(p)
}

func (l *lockedLog) String() string {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.b.String()
}
