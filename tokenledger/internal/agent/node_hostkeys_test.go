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
	t.Setenv("FLEET_NODE_STATE", filepath.Join(dir, "no-entry"))
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

// The entry port's own host key rides along (claude-fleet#3075): `fleet
// connect`'s entry route lands on that sshd. No entry ⇒ nothing added.
func TestNodeHostKeysEntry(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("FLEET_NODE_STATE", dir)
	key := func() string {
		pub, _, _ := ed25519.GenerateKey(rand.Reader)
		sp, _ := ssh.NewPublicKey(pub)
		return strings.TrimSpace(string(ssh.MarshalAuthorizedKey(sp)))
	}
	sys, entry := key(), key()
	f := filepath.Join(dir, "sshd.pub")
	if err := os.WriteFile(f, []byte(sys+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	old := hostKeyFiles
	t.Cleanup(func() { hostKeyFiles = old })
	hostKeyFiles = []string{f}
	if got := nodeHostKeys(); len(got) != 1 || got[0] != sys {
		t.Fatalf("no entry: %q", got)
	}
	if err := os.MkdirAll(filepath.Join(dir, "entry"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "entry", "ssh_host_ed25519_key.pub"), []byte(entry+" fleet-entry\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := nodeHostKeys(); len(got) != 2 || got[0] != sys || got[1] != entry {
		t.Fatalf("with the entry: %q, want [%s %s]", got, sys, entry)
	}
}

// A container machine's sshd key, kept on its own disk (claude-fleet#4127),
// rides along before the entry's: the image itself carries no host key.
func TestNodeHostKeysContainer(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("FLEET_NODE_STATE", dir)
	pub, _, _ := ed25519.GenerateKey(rand.Reader)
	sp, _ := ssh.NewPublicKey(pub)
	want := strings.TrimSpace(string(ssh.MarshalAuthorizedKey(sp)))
	old := hostKeyFiles
	t.Cleanup(func() { hostKeyFiles = old })
	hostKeyFiles = []string{filepath.Join(dir, "missing.pub")}
	if err := os.MkdirAll(filepath.Join(dir, "ssh"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "ssh", "ssh_host_ed25519_key.pub"), []byte(want+" root@u-x\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := nodeHostKeys(); len(got) != 1 || got[0] != want {
		t.Fatalf("container key: %q, want [%s]", got, want)
	}
}

// A person's pod (claude-fleet#4149): its relay reaches the pod's own sshd —
// 127.0.0.1:2222, never :22 — and that sshd's key (the sshd container's
// host.pub) travels in the heartbeat. Anywhere else: :22 and no such key.
func TestPodRelayTargetAndKey(t *testing.T) {
	dir := t.TempDir()
	pub, _, _ := ed25519.GenerateKey(rand.Reader)
	sp, _ := ssh.NewPublicKey(pub)
	want := strings.TrimSpace(string(ssh.MarshalAuthorizedKey(sp)))
	if err := os.WriteFile(filepath.Join(dir, "host.pub"), []byte(want+" root@u-a\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Setenv("FLEET_NODE_STATE", filepath.Join(dir, "none"))
	oldF, oldK := hostKeyFiles, podHostKeyFile
	t.Cleanup(func() { hostKeyFiles, podHostKeyFile = oldF, oldK })
	hostKeyFiles, podHostKeyFile = nil, filepath.Join(dir, "host.pub")

	t.Setenv("FLEET_USER_POD", "")
	if got := defaultSSHRelayTarget(); got != "127.0.0.1:22" || podRelay() {
		t.Fatalf("not a pod: %s", got)
	}
	if got := nodeHostKeys(); got != nil {
		t.Fatalf("not a pod: keys %q", got)
	}
	t.Setenv("FLEET_USER_POD", "1")
	if got := defaultSSHRelayTarget(); got != "127.0.0.1:2222" {
		t.Fatalf("a pod's relay target %s, want 127.0.0.1:2222", got)
	}
	if got := nodeHostKeys(); len(got) != 1 || got[0] != want {
		t.Fatalf("a pod's keys %q, want its sshd's", got)
	}
}
