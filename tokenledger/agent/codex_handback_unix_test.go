//go:build unix

package agent

import (
	"os"
	"path/filepath"
	"sort"
	"testing"

	"golang.org/x/sys/unix"
)

// The agent's own leftovers in a login's Codex home (the test's files stand in
// for root's: the tenant is another uid) are handed to the login once —
// directly in the home and one level into a directory of the agent's — by
// descriptor; a link, a file with a second link, and anything deeper are not.
func TestHandBackCodexHome(t *testing.T) {
	home := t.TempDir()
	codexHome := filepath.Join(home, ".codex")
	elsewhere := t.TempDir()
	must := func(err error) {
		t.Helper()
		if err != nil {
			t.Fatal(err)
		}
	}
	must(os.MkdirAll(filepath.Join(codexHome, "log", "deep"), 0o700))
	for _, f := range []string{".ccquota-auth.lock", ".ccquota-auth-state.json", ".ccquota-upstream.json", "auth.json", "log/codex.log", "log/deep/x.log"} {
		must(os.WriteFile(filepath.Join(codexHome, f), []byte("x"), 0o600))
	}
	must(os.WriteFile(filepath.Join(elsewhere, "target"), []byte("x"), 0o600))
	must(os.Symlink(filepath.Join(elsewhere, "target"), filepath.Join(codexHome, ".ccquota-link.json")))
	must(os.Link(filepath.Join(elsewhere, "target"), filepath.Join(codexHome, ".ccquota-hard.json")))

	var got []string
	old := fchownAt
	fchownAt = func(fd, uid, gid int) error {
		var st unix.Stat_t
		if err := unix.Fstat(fd, &st); err != nil {
			return err
		}
		if uid != os.Getuid()+1 || gid != 4243 {
			t.Errorf("chown to %d:%d", uid, gid)
		}
		got = append(got, statKey(t, codexHome, st))
		return nil
	}
	t.Cleanup(func() { fchownAt = old })
	ra := &RunAs{Login: "grace", UID: uint32(os.Getuid()) + 1, GID: 4243, Home: home}
	n, err := handBackCodexHome(ra, codexHome)
	if err != nil {
		t.Fatal(err)
	}
	sort.Strings(got)
	want := []string{".ccquota-auth-state.json", ".ccquota-auth.lock", ".ccquota-upstream.json", "auth.json", "log", "log/codex.log", "log/deep"}
	if n != len(want) || len(got) != len(want) {
		t.Fatalf("handed back %d %q; want %q", n, got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("handed back %q; want %q", got, want)
		}
	}
	// a Codex home that is itself a link is not entered
	must(os.Symlink(codexHome, filepath.Join(home, ".codex-link")))
	got = nil
	if _, err := handBackCodexHome(ra, filepath.Join(home, ".codex-link")); err == nil || len(got) != 0 {
		t.Fatalf("linked home: %v, %q", err, got)
	}
}

// statKey names the file st is, relative to root, by inode.
func statKey(t *testing.T, root string, st unix.Stat_t) string {
	t.Helper()
	var key string
	_ = filepath.WalkDir(root, func(p string, d os.DirEntry, err error) error {
		var s unix.Stat_t
		if err == nil && unix.Lstat(p, &s) == nil && s.Ino == st.Ino && s.Dev == st.Dev {
			key, _ = filepath.Rel(root, p)
		}
		return nil
	})
	return key
}

// openLoginDir never resolves against the working directory.
func TestOpenLoginDirNeedsAnAbsoluteHome(t *testing.T) {
	for _, ra := range []*RunAs{{Login: "x"}, {Login: "x", Home: "rel"}, nil} {
		if d, err := openLoginDir(ra, "."); err == nil {
			d.Close()
			t.Fatalf("%+v: opened", ra)
		}
	}
}
