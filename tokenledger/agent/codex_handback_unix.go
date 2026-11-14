//go:build unix

package agent

import (
	"os"
	"path/filepath"

	"golang.org/x/sys/unix"
)

// Before a machine tenant's Codex work ran as the login, the root program
// renewed in the login's Codex home itself: the lock, the renewal and upstream
// records and whatever the Codex CLI wrote there (a rewritten auth.json, its
// log/ and tmp/ files, caches) can be the agent's own files. The login's
// machine-op cannot open those. handBackCodexHome gives them back once per home
// before the first machine-op: every entry directly in the home, and one level
// inside a directory the agent owns there, that is the agent's own, opened by
// descriptor without following a link — a directory, or a regular file with a
// single link — is handed to the login. Nothing else is touched.

// fchownAt is unix.Fchown (a seam for the tests, which cannot chown).
var fchownAt = unix.Fchown

// handBackMax bounds how many entries one home's hand-back looks at.
const handBackMax = 4096

func handBackCodexHome(ra *RunAs, home string) (int, error) {
	d, err := openLoginDir(ra, home)
	if err != nil {
		return 0, err
	}
	defer d.Close()
	self := uint32(os.Geteuid())
	n, seen := 0, 0
	var walk func(dirfd int, path string, depth int) error
	walk = func(dirfd int, path string, depth int) error {
		lf, err := unix.Openat(dirfd, ".", dirFlags, 0)
		if err != nil {
			return &os.PathError{Op: "open", Path: path, Err: err}
		}
		f := os.NewFile(uintptr(lf), path)
		names, err := f.Readdirnames(handBackMax)
		f.Close()
		if err != nil && len(names) == 0 {
			return nil
		}
		for _, name := range names {
			if seen++; seen > handBackMax {
				return nil
			}
			fd, err := unix.Openat(dirfd, name, unix.O_RDONLY|unix.O_CLOEXEC|unix.O_NONBLOCK|unix.O_NOFOLLOW, 0)
			if err != nil {
				continue // a link (ELOOP), a socket, or gone
			}
			var st unix.Stat_t
			if unix.Fstat(fd, &st) != nil || st.Uid != self {
				unix.Close(fd)
				continue
			}
			switch st.Mode & unix.S_IFMT {
			case unix.S_IFREG:
				if st.Nlink == 1 && fchownAt(fd, int(ra.UID), int(ra.GID)) == nil {
					n++
				}
			case unix.S_IFDIR:
				if fchownAt(fd, int(ra.UID), int(ra.GID)) == nil {
					n++
				}
				if depth == 0 {
					_ = walk(fd, filepath.Join(path, name), depth+1)
				}
			}
			unix.Close(fd)
		}
		return nil
	}
	return n, walk(d.fd, home, 0)
}
