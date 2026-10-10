package agent

import (
	"crypto/ed25519"
	"crypto/rand"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"golang.org/x/crypto/ssh"
)

// The heartbeat reports the machine's sshd host keys (claude-fleet#2983):
// every readable, well-formed .pub, comment dropped; a missing or broken one
// is skipped.
func TestNodeHostKeys(t *testing.T) {
	dir := t.TempDir()
	pub, _, _ := ed25519.GenerateKey(rand.Reader)
	sp, _ := ssh.NewPublicKey(pub)
	want := strings.TrimSpace(string(ssh.MarshalAuthorizedKey(sp)))
	good := filepath.Join(dir, "ssh_host_ed25519_key.pub")
	bad := filepath.Join(dir, "ssh_host_rsa_key.pub")
	if err := os.WriteFile(good, []byte(want+" root@mini\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(bad, []byte("not a key\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	old := hostKeyFiles
	t.Cleanup(func() { hostKeyFiles = old })
	hostKeyFiles = []string{good, filepath.Join(dir, "missing.pub"), bad}
	if got := nodeHostKeys(); len(got) != 1 || got[0] != want {
		t.Fatalf("nodeHostKeys = %q", got)
	}
	hostKeyFiles = []string{filepath.Join(dir, "missing.pub")}
	if got := nodeHostKeys(); got != nil {
		t.Fatalf("no keys: %q", got)
	}
}
