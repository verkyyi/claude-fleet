package agent

import (
	"crypto/ed25519"
	"crypto/rand"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

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
	oldF, oldK, oldT := hostKeyFiles, podHostKeyFile, sshRelayTarget
	t.Cleanup(func() { hostKeyFiles, podHostKeyFile, sshRelayTarget = oldF, oldK, oldT; podKeyAt = time.Time{} })
	hostKeyFiles, podHostKeyFile = nil, filepath.Join(dir, "host.pub")
	sshRelayTarget, podKeyAt = closedAddr(t), time.Time{} // no sshd answering: the file alone

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

func closedAddr(t *testing.T) string {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	a := l.Addr().String()
	l.Close()
	return a
}

// A pod rolled onto a new image keeps its old spec (the hub's roll patches the
// image alone — claude-fleet#4149): no /run/sshd-key mount, so the key its sshd
// shows is read off the sshd itself on the relay's address — the key a relayed
// login meets — and asked again only after podKeyEvery.
func TestPodSSHDKeyReadOffTheSSHD(t *testing.T) {
	_, priv, _ := ed25519.GenerateKey(rand.Reader)
	signer, err := ssh.NewSignerFromKey(priv)
	if err != nil {
		t.Fatal(err)
	}
	want := strings.TrimSpace(string(ssh.MarshalAuthorizedKey(signer.PublicKey())))
	cfg := &ssh.ServerConfig{NoClientAuth: true}
	cfg.AddHostKey(signer)
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { l.Close() })
	dials := 0
	go func() {
		for {
			c, err := l.Accept()
			if err != nil {
				return
			}
			dials++
			go func() { _, _, _, _ = ssh.NewServerConn(c, cfg); c.Close() }()
		}
	}()
	t.Setenv("FLEET_USER_POD", "1")
	t.Setenv("FLEET_NODE_STATE", filepath.Join(t.TempDir(), "none"))
	oldF, oldK, oldT := hostKeyFiles, podHostKeyFile, sshRelayTarget
	t.Cleanup(func() { hostKeyFiles, podHostKeyFile, sshRelayTarget = oldF, oldK, oldT; podKeyAt = time.Time{} })
	hostKeyFiles, podHostKeyFile = nil, filepath.Join(t.TempDir(), "absent.pub")
	sshRelayTarget, podKeyAt = l.Addr().String(), time.Time{}
	if got := nodeHostKeys(); len(got) != 1 || got[0] != want {
		t.Fatalf("keys %q, want the sshd's %q", got, want)
	}
	if got := nodeHostKeys(); len(got) != 1 || got[0] != want || dials != 1 {
		t.Fatalf("a second beat: keys %q, dials %d — want the same key, no second dial", got, dials)
	}
	t.Setenv("FLEET_USER_POD", "")
	if got := nodeHostKeys(); got != nil {
		t.Fatalf("not a pod: %q", got)
	}
}

// The door's way home (A5SQ): an entry relay goes to the machine's entry port
// — FLEET_ENTRY_PORT, else 22022 — never the hub's word for an address, and a
// pod offers none.
func TestEntryRelayTarget(t *testing.T) {
	t.Setenv("FLEET_USER_POD", "")
	t.Setenv("FLEET_ENTRY_PORT", "")
	if got := entryRelayTarget(); got != "127.0.0.1:22022" || !entryRelayOK() {
		t.Fatalf("default: %s ok=%v", got, entryRelayOK())
	}
	t.Setenv("FLEET_ENTRY_PORT", "2201")
	if got := entryRelayTarget(); got != "127.0.0.1:2201" {
		t.Fatalf("FLEET_ENTRY_PORT=2201: %s", got)
	}
	for _, bad := range []string{"0", "70000", "x", "1.2.3.4:22"} {
		t.Setenv("FLEET_ENTRY_PORT", bad)
		if got := entryRelayTarget(); got != "127.0.0.1:22022" {
			t.Fatalf("FLEET_ENTRY_PORT=%q: %s, want the default", bad, got)
		}
	}
	t.Setenv("FLEET_USER_POD", "1")
	if entryRelayOK() {
		t.Fatal("a pod offers the entry relay")
	}
}
