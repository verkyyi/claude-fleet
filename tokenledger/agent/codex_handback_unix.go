//go:build unix

package agent

import (
	"errors"
	"io"
	"os"
	"path/filepath"

	"golang.org/x/sys/unix"
)

// fchownAt is unix.Fchown (a seam for the tests, which cannot chown).
var fchownAt = unix.Fchown

func hbEntryOf(st *unix.Stat_t) hbEntry {
	e := hbEntry{uid: st.Uid, nlink: uint64(st.Nlink)}
	switch st.Mode & unix.S_IFMT {
	case unix.S_IFREG:
		e.kind = hbRegular
	case unix.S_IFDIR:
		e.kind = hbDir
	}
	return e
}

// handBackCodexHome repairs ra's Codex home (codex_handback.go); bound is the
// account the profile was last seen signed in to.
func handBackCodexHome(ra *RunAs, home, bound string) (handBackResult, error) {
	var res handBackResult
	self := uint32(os.Geteuid())
	known := codexHomeKnown(ra, home)
	if known && filepath.Base(filepath.Dir(home)) == ".codex-accounts" {
		// ~/.codex-accounts, the agent's from making a labelled home
		if p, err := openLoginDir(ra, filepath.Dir(home)); err == nil {
			if handDir(p.fd, self, ra) {
				res.dirs++
			}
			p.Close()
		}
	}
	d, err := openLoginDir(ra, home)
	if err != nil {
		return res, err
	}
	defer d.Close()
	if known && handDir(d.fd, self, ra) {
		res.dirs++
	}
	names, err := d.listN(handBackMax)
	if err != nil {
		return res, err
	}
	for _, name := range names {
		var st unix.Stat_t
		if unix.Fstatat(d.fd, name, &st, unix.AT_SYMLINK_NOFOLLOW) != nil {
			continue
		}
		act := handBackAction(name, hbEntryOf(&st), self)
		if act == hbSkip {
			continue
		}
		// decided again on the entry's own descriptor (no link followed, no
		// FIFO waited on): the name may have changed since
		fd, err := unix.Openat(d.fd, name, unix.O_RDONLY|unix.O_CLOEXEC|unix.O_NONBLOCK|unix.O_NOFOLLOW, 0)
		if err != nil {
			continue
		}
		if unix.Fstat(fd, &st) != nil || handBackAction(name, hbEntryOf(&st), self) != act {
			unix.Close(fd)
			continue
		}
		switch act {
		case hbRemove:
			if d.removeSame(name, &st) == nil {
				res.removed++
			}
		case hbChownDir:
			if fchownAt(fd, int(ra.UID), int(ra.GID)) == nil {
				res.dirs++
			}
		case hbAuth:
			why := d.handBackAuthFile(fd, name, &st, bound)
			if why == nil {
				res.auth = true
			} else {
				res.degraded = authLeftReason(home, why)
			}
		}
		unix.Close(fd)
	}
	return res, nil
}

// handDir hands the directory open on fd to ra when it is the agent's own.
func handDir(fd int, self uint32, ra *RunAs) bool {
	var st unix.Stat_t
	if unix.Fstat(fd, &st) != nil || st.Mode&unix.S_IFMT != unix.S_IFDIR || st.Uid != self {
		return false
	}
	return fchownAt(fd, int(ra.UID), int(ra.GID)) == nil
}

// removeSame unlinks name from d when it still names the file st describes
// (same device and inode, not followed).
func (d *homeDir) removeSame(name string, st *unix.Stat_t) error {
	var now unix.Stat_t
	if err := unix.Fstatat(d.fd, name, &now, unix.AT_SYMLINK_NOFOLLOW); err != nil {
		return err
	}
	if now.Dev != st.Dev || now.Ino != st.Ino || now.Mode&unix.S_IFMT != unix.S_IFREG {
		return errors.New("changed")
	}
	return d.remove(name)
}

// handBackAuthFile reads the agent's auth.json open on fd (st its stat), at
// most smallFileMax bytes, and — when handBackAuth accepts it — writes it
// again as a new file of the login's in its place; nil when it did.
func (d *homeDir) handBackAuthFile(fd int, name string, st *unix.Stat_t, bound string) error {
	if st.Size > smallFileMax {
		return errHomeTooLarge
	}
	dup, err := unix.Dup(fd)
	if err != nil {
		return err
	}
	f := os.NewFile(uintptr(dup), filepath.Join(d.path, name))
	b, err := io.ReadAll(io.LimitReader(f, smallFileMax+1))
	f.Close()
	if err != nil {
		return err
	}
	if int64(len(b)) > smallFileMax {
		return errHomeTooLarge
	}
	if err := handBackAuth(b, bound); err != nil {
		return err
	}
	return d.writeAtomic(name, b, 0o600)
}
