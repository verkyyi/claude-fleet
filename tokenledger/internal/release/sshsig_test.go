package release

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// sshVerify runs the system's ssh-keygen -Y verify, the client's whole check
// (claude-fleet#3162). Skipped where there is no ssh-keygen.
func sshVerify(t *testing.T, pub ed25519.PublicKey, ns string, msg []byte, armored string) error {
	t.Helper()
	kg, err := exec.LookPath("ssh-keygen")
	if err != nil {
		t.Skip("no ssh-keygen")
	}
	d := t.TempDir()
	signers := filepath.Join(d, "allowed_signers")
	sig := filepath.Join(d, "sig")
	line := `fleet-release namespaces="` + ns + `" ` + SSHPublicKey(pub) + "\n"
	if err := os.WriteFile(signers, []byte(line), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(sig, []byte(armored), 0o644); err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command(kg, "-Y", "verify", "-f", signers, "-I", "fleet-release", "-n", ns, "-s", sig)
	cmd.Stdin = bytes.NewReader(msg)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return &verifyErr{string(out)}
	}
	return nil
}

type verifyErr struct{ s string }

func (e *verifyErr) Error() string { return e.s }

func TestSSHSigVerifiesWithSSHKeygen(t *testing.T) {
	pub, key, _ := ed25519.GenerateKey(rand.Reader)
	msg := []byte(`{"schema":1,"sha":"x"}`)
	armored := SSHSigArmor(SSHSign(key, SSHSigNS, msg))
	if err := sshVerify(t, pub, SSHSigNS, msg, armored); err != nil {
		t.Fatalf("ssh-keygen refused a good signature: %v", err)
	}
	if err := sshVerify(t, pub, SSHSigNS, append(msg, ' '), armored); err == nil {
		t.Fatal("ssh-keygen took a signature over other bytes")
	}
	if err := sshVerify(t, pub, SSHSigKeyNS, msg, armored); err == nil {
		t.Fatal("ssh-keygen took a manifest signature in the key namespace")
	}
	other, _, _ := ed25519.GenerateKey(rand.Reader)
	if err := sshVerify(t, other, SSHSigNS, msg, armored); err == nil {
		t.Fatal("ssh-keygen took a signature by another key")
	}
}

func TestEndorseVerifiesUnderTheOldKey(t *testing.T) {
	oldPub, oldKey, _ := ed25519.GenerateKey(rand.Reader)
	newPub, _, _ := ed25519.GenerateKey(rand.Reader)
	e := Endorse(oldKey, newPub)
	line, armored, ok := strings.Cut(e, "\n")
	if !ok || line != FormatPublicKey(newPub) {
		t.Fatalf("endorsement's first line: %q", line)
	}
	if err := sshVerify(t, oldPub, SSHSigKeyNS, []byte(line+"\n"), armored); err != nil {
		t.Fatalf("the old key's endorsement does not verify: %v", err)
	}
	if err := sshVerify(t, newPub, SSHSigKeyNS, []byte(line+"\n"), armored); err == nil {
		t.Fatal("a key vouched for itself")
	}
}
