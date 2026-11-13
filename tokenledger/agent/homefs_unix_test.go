//go:build unix

package agent

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"golang.org/x/sys/unix"
)

const storeLine = "cli_auth_credentials_store = \"file\"\n"

// tenantHome registers a tenant (this test's own uid unless uid says) whose
// home is a fresh directory, and an "outside" directory that is no one's home.
func tenantHome(t *testing.T, uid *uint32) (home, outside string) {
	t.Helper()
	home, outside = t.TempDir(), t.TempDir()
	ra := selfRunAs(t, "gamma", home)
	if uid != nil {
		ra.UID = *uid
	}
	registerTenant(ra)
	t.Cleanup(func() { unregisterTenant(ra) })
	return home, outside
}

// untouched records a file and fails the test if it changed.
func untouched(t *testing.T, path string) func() {
	t.Helper()
	b0, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	fi0, _ := os.Stat(path)
	return func() {
		t.Helper()
		b, err := os.ReadFile(path)
		fi, _ := os.Stat(path)
		if err != nil || !bytes.Equal(b, b0) || fi.Mode() != fi0.Mode() || !fi.ModTime().Equal(fi0.ModTime()) {
			t.Fatalf("%s changed: %q %v", path, b, err)
		}
	}
}

// noneHolds fails if any file under dir contains secret.
func noneHolds(t *testing.T, dir, secret string) {
	t.Helper()
	_ = filepath.Walk(dir, func(p string, fi os.FileInfo, err error) error {
		if err == nil && fi.Mode().IsRegular() {
			if b, _ := os.ReadFile(p); bytes.Contains(b, []byte(secret)) {
				t.Fatalf("%s holds the outside file's content", p)
			}
		}
		return nil
	})
}

func mustWrite(t *testing.T, path, s string, mode os.FileMode) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(s), mode); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(path, mode); err != nil {
		t.Fatal(err)
	}
}

// The normal case: the line is prepended, the rest and the mode kept, no
// temporary file left; a second run changes nothing.
func TestCodexFileStoreUnderHomeKeepsContentAndMode(t *testing.T) {
	home, _ := tenantHome(t, nil)
	cfg := filepath.Join(home, ".codex", "config.toml")
	orig := "model = \"o3\"\n[profiles.x]\nmodel = \"y\"\n"
	mustWrite(t, cfg, orig, 0o640)
	if err := ensureCodexFileStore(cfg); err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(cfg)
	if string(b) != storeLine+orig {
		t.Fatalf("config.toml = %q", b)
	}
	if fi, _ := os.Stat(cfg); fi.Mode().Perm() != 0o640 {
		t.Fatalf("mode %o, want 640", fi.Mode().Perm())
	}
	ents, _ := os.ReadDir(filepath.Dir(cfg))
	if len(ents) != 1 {
		t.Fatalf("left behind: %v", ents)
	}
	done := untouched(t, cfg)
	if err := ensureCodexFileStore(cfg); err != nil {
		t.Fatal(err)
	}
	done()
	// a missing one is made 0600, its directory too
	fresh := filepath.Join(home, ".codex-accounts", "work", "config.toml")
	if err := ensureCodexFileStore(fresh); err != nil {
		t.Fatal(err)
	}
	if b, _ := os.ReadFile(fresh); string(b) != storeLine {
		t.Fatalf("new config.toml = %q", b)
	}
	if fi, _ := os.Stat(fresh); fi.Mode().Perm() != 0o600 {
		t.Fatalf("new mode %o", fi.Mode().Perm())
	}
}

// config.toml as a link: refused; the link's target neither read back nor
// changed, the link left as it is.
func TestCodexFileStoreRefusesLinkedFile(t *testing.T) {
	home, outside := tenantHome(t, nil)
	secret := filepath.Join(outside, "token")
	mustWrite(t, secret, "OUTSIDE-CONTENT-7f3a\n", 0o600)
	done := untouched(t, secret)
	cfg := filepath.Join(home, ".codex", "config.toml")
	if err := os.MkdirAll(filepath.Dir(cfg), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(secret, cfg); err != nil {
		t.Fatal(err)
	}
	if err := ensureCodexFileStore(cfg); err == nil {
		t.Fatal("a linked config.toml was accepted")
	}
	done()
	if fi, err := os.Lstat(cfg); err != nil || fi.Mode()&os.ModeSymlink == 0 {
		t.Fatalf("config.toml no longer the link: %v", err)
	}
	noneHolds(t, home, "OUTSIDE-CONTENT-7f3a")
}

// A FIFO or a device is refused — at once, never a read that blocks or never
// ends.
func TestCodexFileStoreRefusesFIFOAndDevice(t *testing.T) {
	home, _ := tenantHome(t, nil)
	fifo := filepath.Join(home, ".codex", "config.toml")
	if err := os.MkdirAll(filepath.Dir(fifo), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := unix.Mkfifo(fifo, 0o600); err != nil {
		t.Fatal(err)
	}
	dev := filepath.Join(home, ".codex-accounts", "z", "config.toml")
	if err := os.MkdirAll(filepath.Dir(dev), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("/dev/zero", dev); err != nil {
		t.Fatal(err)
	}
	for _, p := range []string{fifo, dev} {
		errc := make(chan error, 1)
		go func() { errc <- ensureCodexFileStore(p) }()
		select {
		case err := <-errc:
			if err == nil {
				t.Fatalf("%s accepted", p)
			}
		case <-time.After(5 * time.Second):
			t.Fatalf("%s: still reading", p)
		}
	}
	// a FIFO opened directly through homeDir, not via a link, is refused too
	d, err := openHomeDir(filepath.Dir(fifo), false, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer d.Close()
	if _, err := d.readFile("config.toml", false); !errors.Is(err, errHomeNotRegular) {
		t.Fatalf("FIFO: %v", err)
	}
}

// Over homeFileMax: an error, the file left as it is.
func TestCodexFileStoreRefusesOversize(t *testing.T) {
	home, _ := tenantHome(t, nil)
	cfg := filepath.Join(home, ".codex", "config.toml")
	mustWrite(t, cfg, strings.Repeat("#", homeFileMax+1), 0o600)
	done := untouched(t, cfg)
	if err := ensureCodexFileStore(cfg); !errors.Is(err, errHomeTooLarge) {
		t.Fatalf("oversize: %v", err)
	}
	done()
}

// A directory on the way that is a link: refused, nothing read, written or
// made where it points.
func TestHomeFilesRefuseLinkedParent(t *testing.T) {
	home, outside := tenantHome(t, nil)
	target := filepath.Join(outside, "config.toml")
	mustWrite(t, target, "OUTSIDE-CONTENT-91c2\n", 0o600)
	done := untouched(t, target)
	if err := os.Symlink(outside, filepath.Join(home, ".codex")); err != nil {
		t.Fatal(err)
	}
	if err := ensureCodexFileStore(filepath.Join(home, ".codex", "config.toml")); !errors.Is(err, errHomeLink) {
		t.Fatalf("linked parent: %v", err)
	}
	if err := writeAtomic(filepath.Join(home, ".codex", "auth.json"), []byte("x"), 0o600); !errors.Is(err, errHomeLink) {
		t.Fatalf("writeAtomic through a linked parent: %v", err)
	}
	if err := mkdirOwned(filepath.Join(home, ".codex", "a", "b"), 0o700); !errors.Is(err, errHomeLink) {
		t.Fatalf("mkdirOwned through a linked parent: %v", err)
	}
	done()
	if ents, _ := os.ReadDir(outside); len(ents) != 1 {
		t.Fatalf("made where the link points: %v", ents)
	}
	noneHolds(t, home, "OUTSIDE-CONTENT-91c2")
	// a deeper link, under a real directory, is refused the same way
	if err := os.MkdirAll(filepath.Join(home, ".config", "claude-fleet"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(home, ".config", "claude-fleet", "cluster")); err != nil {
		t.Fatal(err)
	}
	if err := writeFileAtomic(filepath.Join(home, ".config", "claude-fleet", "cluster", "machine.json"), []byte("{}")); !errors.Is(err, errHomeLink) {
		t.Fatalf("writeFileAtomic through a linked parent: %v", err)
	}
	if ents, _ := os.ReadDir(outside); len(ents) != 1 {
		t.Fatalf("made where the link points: %v", ents)
	}
}

// A file the login does not own (a hard link to someone else's, say) is
// never read back into a file of the login's.
func TestCodexFileStoreRefusesFileNotTheLogins(t *testing.T) {
	other := uint32(os.Getuid() + 1)
	home, _ := tenantHome(t, &other)
	cfg := filepath.Join(home, ".codex", "config.toml")
	mustWrite(t, cfg, "model = \"o3\"\n", 0o600)
	done := untouched(t, cfg)
	err := ensureCodexFileStore(cfg)
	if err == nil || !strings.Contains(err.Error(), "owned by uid") {
		t.Fatalf("a file not the login's: %v", err)
	}
	done()
}

// writeAtomic replaces a link at the name with a plain file; the link's
// target is not written.
func TestWriteAtomicReplacesLinkNeverFollows(t *testing.T) {
	home, outside := tenantHome(t, nil)
	target := filepath.Join(outside, "hosts.yml")
	mustWrite(t, target, "keep\n", 0o600)
	done := untouched(t, target)
	p := filepath.Join(home, ".config", "gh", "hosts.yml")
	if err := os.MkdirAll(filepath.Dir(p), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(target, p); err != nil {
		t.Fatal(err)
	}
	if err := writeGHHosts(filepath.Dir(p), "u", "tok"); err != nil {
		t.Fatal(err)
	}
	done()
	if fi, err := os.Lstat(p); err != nil || !fi.Mode().IsRegular() || fi.Mode().Perm() != 0o600 {
		t.Fatalf("hosts.yml: %v %v", fi, err)
	}
}

// Removing the hub's marker and lease never follows a link the login put in
// the way.
func TestRemoveClaudeCredFollowsNoLink(t *testing.T) {
	home, outside := tenantHome(t, nil)
	keep := filepath.Join(outside, "keep")
	mustWrite(t, keep, "keep\n", 0o600)
	done := untouched(t, keep)
	dir := filepath.Join(home, ".config", "claude-fleet", "accounts")
	if err := os.MkdirAll(filepath.Join(dir, "a.hub"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(dir, "a.hub", "sub")); err != nil {
		t.Fatal(err)
	}
	mustWrite(t, filepath.Join(dir, "a"), HubMarkerPrefix+"a\n", 0o600)
	if err := removeClaudeCred(dir, "a", nil); err != nil {
		t.Fatal(err)
	}
	done()
	if ents, _ := os.ReadDir(dir); len(ents) != 0 {
		t.Fatalf("left: %v", ents)
	}
	// the accounts directory itself a link: refused, nothing removed there
	mustWrite(t, filepath.Join(outside, "b"), HubMarkerPrefix+"b\n", 0o600)
	acc2 := filepath.Join(home, "acc2")
	if err := os.Symlink(outside, acc2); err != nil {
		t.Fatal(err)
	}
	if err := removeClaudeCred(acc2, "b", nil); !errors.Is(err, errHomeLink) {
		t.Fatalf("linked accounts dir: %v", err)
	}
	if _, err := os.Stat(filepath.Join(outside, "b")); err != nil {
		t.Fatal("removed through a link")
	}
}

// A refused relay's reason is never written through a link already there.
func TestRelayQuarantineFollowsNoLink(t *testing.T) {
	home, outside := tenantHome(t, nil)
	keep := filepath.Join(outside, "keep")
	mustWrite(t, keep, "keep\n", 0o600)
	done := untouched(t, keep)
	out := filepath.Join(home, ".config", "claude-fleet", "control", "outbox")
	mustWrite(t, filepath.Join(out, "1.json"), "{", 0o600)
	if err := os.MkdirAll(filepath.Join(out, "refused"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(keep, filepath.Join(out, "refused", "1.json.why")); err != nil {
		t.Fatal(err)
	}
	relayQuarantine(relayPaths{outbox: out}, filepath.Join(out, "1.json"), "bad")
	done()
	if b, _ := os.ReadFile(filepath.Join(out, "refused", "1.json.why")); string(b) != "bad\n" {
		t.Fatalf(".why = %q", b)
	}
	if _, err := os.Stat(filepath.Join(out, "refused", "1.json")); err != nil {
		t.Fatal(err)
	}
}

// A login's relay paths stay inside its home; a plain agent's are as given.
func TestConfineRelayPaths(t *testing.T) {
	home := t.TempDir()
	ra := selfRunAs(t, "gamma", home)
	in := func(s string) string { return filepath.Join(home, ".config", "claude-fleet", s) }
	p := relayPaths{outbox: in("outbox"), workers: in("w.tsv"), movein: in("movein"), attach: in("attach")}
	if got, ok := confineRelayPaths(p, ra); !ok || got != p {
		t.Fatalf("inside: %+v %v", got, ok)
	}
	for _, bad := range []relayPaths{
		{outbox: "/etc", workers: in("w.tsv")},
		{outbox: in("outbox"), workers: "/etc/w.tsv"},
		{outbox: home, workers: in("w.tsv")},
	} {
		if _, ok := confineRelayPaths(bad, ra); ok {
			t.Fatalf("outside accepted: %+v", bad)
		}
	}
	got, ok := confineRelayPaths(relayPaths{outbox: in("o"), workers: in("w"), movein: "/tmp/m", attach: home + "/../x"}, ra)
	if !ok || got.movein != "" || got.attach != "" {
		t.Fatalf("optional outside kept: %+v", got)
	}
	plain := relayPaths{outbox: "/x/o", workers: "/x/w"}
	if got, ok := confineRelayPaths(plain, nil); !ok || got != plain {
		t.Fatal("a plain agent's paths changed")
	}
}

// Under no tenant's home (a plain agent, running as itself) the codex config
// is still made right.
func TestCodexFileStorePlainAgent(t *testing.T) {
	cfg := filepath.Join(t.TempDir(), ".codex", "config.toml")
	mustWrite(t, cfg, "[t]\n", 0o600)
	if err := ensureCodexFileStore(cfg); err != nil {
		t.Fatal(err)
	}
	if b, _ := os.ReadFile(cfg); string(b) != storeLine+"[t]\n" {
		t.Fatalf("config.toml = %q", b)
	}
}
