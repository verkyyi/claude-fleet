//go:build unix

package agent

import (
	"bytes"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"

	"github.com/verkyyi/claude-fleet/tokenledger/shared/codex"
	"golang.org/x/sys/unix"
)

// The decision alone, on stat results the test makes up (uid 0 the agent's): a
// regular file is never handed over; only the agent's three records are
// removed; only a single-link auth.json is read; only the Codex CLI's own
// directories are handed over; nothing of anyone else's is touched.
func TestHandBackAction(t *testing.T) {
	const root = 0
	reg := func(uid uint32, nlink uint64) hbEntry { return hbEntry{kind: hbRegular, uid: uid, nlink: nlink} }
	dir := hbEntry{kind: hbDir, uid: root, nlink: 3}
	for _, tc := range []struct {
		name string
		e    hbEntry
		want hbAction
	}{
		{".ccquota-auth.lock", reg(root, 1), hbRemove},
		{".ccquota-auth-state.json", reg(root, 1), hbRemove},
		{".ccquota-upstream.json", reg(root, 2), hbRemove}, // removing a second name changes nothing else
		{".ccquota-auth.lock", reg(501, 1), hbSkip},
		{"auth.json", reg(root, 1), hbAuth},
		{"auth.json", reg(root, 2), hbSkip}, // a second name of a file elsewhere
		{"auth.json", reg(501, 1), hbSkip},
		{"config.toml", reg(root, 1), hbSkip},
		{".ccquota-login-observation.json", reg(root, 1), hbSkip},
		{"secret", reg(root, 1), hbSkip},
		{"log", dir, hbChownDir},
		{"sessions", dir, hbChownDir},
		{"archived_sessions", dir, hbChownDir},
		{"tmp", dir, hbChownDir},
		{"elsewhere", dir, hbSkip},
		{"log", hbEntry{kind: hbDir, uid: 501}, hbSkip},
		{"log", reg(root, 1), hbSkip},      // a file where a CLI directory belongs
		{"sessions", reg(root, 1), hbSkip}, // never chowned
		{"auth.json", hbEntry{kind: hbOther, uid: root, nlink: 1}, hbSkip},
		{".ccquota-auth.lock", hbEntry{kind: hbOther, uid: root, nlink: 1}, hbSkip},
	} {
		if got := handBackAction(tc.name, tc.e, root); got != tc.want {
			t.Errorf("%s %+v: %v; want %v", tc.name, tc.e, got, tc.want)
		}
		if tc.e.kind == hbRegular && handBackAction(tc.name, tc.e, root) == hbChownDir {
			t.Errorf("%s: a regular file handed over", tc.name)
		}
	}
	if err := handBackAuth([]byte(`{"secret":"x"}`), "acct"); err == nil {
		t.Fatal("a file that is not a Codex login accepted")
	}
}

// On a real home (the test's files stand in for the agent's: the login is
// another uid): the records are removed and made again by the login's own
// lock, the CLI's directories and the home are handed over by descriptor and
// no regular file ever is, a second name of a file elsewhere is neither handed
// over nor copied — also once its other name is gone and it has one link —
// and an unknown file of the agent's is left alone.
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
	read := func(p string) []byte {
		t.Helper()
		b, err := os.ReadFile(p)
		must(err)
		return b
	}
	ino := func(p string) uint64 {
		t.Helper()
		var st unix.Stat_t
		must(unix.Lstat(p, &st))
		return uint64(st.Ino)
	}
	must(os.MkdirAll(filepath.Join(codexHome, "log", "deep"), 0o700))
	must(os.MkdirAll(filepath.Join(codexHome, "sessions"), 0o700))
	must(os.MkdirAll(filepath.Join(codexHome, "elsewhere"), 0o700))
	for _, f := range []string{".ccquota-auth.lock", ".ccquota-auth-state.json", ".ccquota-upstream.json", "config.toml", ".ccquota-other.json", "log/codex.log"} {
		must(os.WriteFile(filepath.Join(codexHome, f), []byte("x"), 0o600))
	}
	// auth.json: a second name of a file that is not the login's
	secret := filepath.Join(elsewhere, "secret")
	must(os.WriteFile(secret, []byte(`{"not":"a codex login"}`), 0o600))
	must(os.Link(secret, filepath.Join(codexHome, "auth.json")))

	var chowned []string
	old := fchownAt
	fchownAt = func(fd, uid, gid int) error {
		var st unix.Stat_t
		if err := unix.Fstat(fd, &st); err != nil {
			return err
		}
		if st.Mode&unix.S_IFMT != unix.S_IFDIR {
			t.Errorf("a regular file handed over (inode %d)", st.Ino)
		}
		if uid != os.Getuid()+1 || gid != 4243 {
			t.Errorf("chown to %d:%d", uid, gid)
		}
		chowned = append(chowned, statKey(t, home, st))
		return nil
	}
	t.Cleanup(func() { fchownAt = old })
	ra := &RunAs{Login: "grace", UID: uint32(os.Getuid()) + 1, GID: 4243, Home: home}

	authIno := ino(filepath.Join(codexHome, "auth.json"))
	res, err := handBackCodexHome(ra, codexHome, "codex:account:any")
	must(err)
	sort.Strings(chowned)
	if want := []string{".codex", ".codex/log", ".codex/sessions"}; strings.Join(chowned, ",") != strings.Join(want, ",") || res.dirs != 3 {
		t.Fatalf("handed over %q (%d); want %q", chowned, res.dirs, want)
	}
	for _, f := range []string{".ccquota-auth.lock", ".ccquota-auth-state.json", ".ccquota-upstream.json"} {
		if _, err := os.Lstat(filepath.Join(codexHome, f)); !os.IsNotExist(err) {
			t.Fatalf("%s not removed: %v", f, err)
		}
	}
	if res.removed != 3 {
		t.Fatalf("removed %d", res.removed)
	}
	for _, f := range []string{"config.toml", ".ccquota-other.json", "log/codex.log"} {
		if string(read(filepath.Join(codexHome, f))) != "x" {
			t.Fatalf("%s touched", f)
		}
	}
	if res.auth || res.degraded != "" || ino(filepath.Join(codexHome, "auth.json")) != authIno {
		t.Fatalf("a second name was read: %+v", res)
	}
	// the login's machine-op makes its lock again
	unlock, err := codex.AcquireProfile(codexHome)
	must(err)
	unlock()
	if _, err := os.Lstat(filepath.Join(codexHome, ".ccquota-auth.lock")); err != nil {
		t.Fatalf("lock not made again: %v", err)
	}

	// the other name goes (an atomic replace): the file now has one link and
	// still its content — read, not a Codex login, so left as it is
	must(os.WriteFile(secret+".new", []byte("new"), 0o600))
	must(os.Rename(secret+".new", secret))
	chowned = nil
	res, err = handBackCodexHome(ra, codexHome, "codex:account:any")
	must(err)
	if res.auth || res.degraded == "" || ino(filepath.Join(codexHome, "auth.json")) != authIno ||
		!bytes.Equal(read(filepath.Join(codexHome, "auth.json")), []byte(`{"not":"a codex login"}`)) {
		t.Fatalf("a single-link file that is no Codex login: %+v", res)
	}
	if !strings.Contains(res.degraded, "sign in to this profile again") {
		t.Fatalf("reason %q", res.degraded)
	}

	// a Codex login of the account this profile was last seen signed in to
	// is written again as a new file; another account's is left
	must(os.Remove(filepath.Join(codexHome, "auth.json")))
	writeCodexLogin(t, codexHome)
	login := read(filepath.Join(codexHome, "auth.json"))
	a, err := codex.ParseAuthFile(login)
	must(err)
	before := ino(filepath.Join(codexHome, "auth.json"))
	res, err = handBackCodexHome(ra, codexHome, "codex:account:someone-else")
	must(err)
	if res.auth || res.degraded == "" || ino(filepath.Join(codexHome, "auth.json")) != before {
		t.Fatalf("another account's login rewritten: %+v", res)
	}
	res, err = handBackCodexHome(ra, codexHome, "")
	must(err)
	if res.auth || res.degraded == "" {
		t.Fatalf("a login with no account on record rewritten: %+v", res)
	}
	res, err = handBackCodexHome(ra, codexHome, a.Identity.AccountUUID)
	must(err)
	if !res.auth || res.degraded != "" || ino(filepath.Join(codexHome, "auth.json")) == before ||
		!bytes.Equal(read(filepath.Join(codexHome, "auth.json")), login) {
		t.Fatalf("the profile's own login not rewritten: %+v", res)
	}
	// a hard-linked Codex login of the right account is not read either
	must(os.Remove(filepath.Join(codexHome, "auth.json")))
	must(os.WriteFile(filepath.Join(elsewhere, "login"), login, 0o600))
	must(os.Link(filepath.Join(elsewhere, "login"), filepath.Join(codexHome, "auth.json")))
	res, err = handBackCodexHome(ra, codexHome, a.Identity.AccountUUID)
	must(err)
	if res.auth {
		t.Fatal("a second name of a Codex login copied")
	}

	// a Codex home that is itself a link is not entered
	must(os.Symlink(codexHome, filepath.Join(home, ".codex-link")))
	chowned = nil
	if _, err := handBackCodexHome(ra, filepath.Join(home, ".codex-link"), ""); err == nil || len(chowned) != 0 {
		t.Fatalf("linked home: %v, %q", err, chowned)
	}
	// a profile home under another name: its CLI directories, not itself
	other := filepath.Join(home, "work", "codex")
	must(os.MkdirAll(filepath.Join(other, "tmp"), 0o700))
	chowned = nil
	_, err = handBackCodexHome(ra, other, "")
	must(err)
	if strings.Join(chowned, ",") != "work/codex/tmp" {
		t.Fatalf("other home: handed over %q", chowned)
	}
	// ~/.codex-accounts/<label>: the label's home and ~/.codex-accounts
	labelled := filepath.Join(home, ".codex-accounts", "work")
	must(os.MkdirAll(labelled, 0o700))
	chowned = nil
	_, err = handBackCodexHome(ra, labelled, "")
	must(err)
	sort.Strings(chowned)
	if strings.Join(chowned, ",") != ".codex-accounts,.codex-accounts/work" {
		t.Fatalf("labelled home: handed over %q", chowned)
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
