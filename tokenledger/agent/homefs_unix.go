//go:build unix

package agent

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"

	"golang.org/x/sys/unix"
)

// homeDir is one directory opened for the agent's file work (homefs.go). ra
// nil: under no tenant's home, plain path rules.
type homeDir struct {
	fd   int
	path string
	ra   *RunAs
}

const dirFlags = unix.O_RDONLY | unix.O_DIRECTORY | unix.O_CLOEXEC

// openHomeDir opens dir. Under a tenant's home every component below the home
// is opened without following a link — one that is a link (or no directory)
// is refused; create makes the missing ones with mode, handed to the login.
// Under no home, dir is opened by its path (create: os.MkdirAll).
func openHomeDir(dir string, create bool, mode os.FileMode) (*homeDir, error) {
	dir = filepath.Clean(dir)
	ra, home, rel := loginRootOf(dir)
	if ra == nil {
		if create {
			if err := os.MkdirAll(dir, mode); err != nil {
				return nil, err
			}
		}
		fd, err := unix.Open(dir, dirFlags, 0)
		if err != nil {
			return nil, &os.PathError{Op: "open", Path: dir, Err: err}
		}
		return &homeDir{fd: fd, path: dir}, nil
	}
	fd, err := unix.Open(home, dirFlags, 0)
	if err != nil {
		return nil, &os.PathError{Op: "open", Path: home, Err: err}
	}
	at := home
	for _, c := range rel {
		at = filepath.Join(at, c)
		next, err := unix.Openat(fd, c, dirFlags|unix.O_NOFOLLOW, 0)
		if err == unix.ENOENT && create {
			if merr := unix.Mkdirat(fd, c, uint32(mode.Perm())); merr != nil && merr != unix.EEXIST {
				unix.Close(fd)
				return nil, &os.PathError{Op: "mkdir", Path: at, Err: merr}
			}
			next, err = unix.Openat(fd, c, dirFlags|unix.O_NOFOLLOW, 0)
			if err == nil {
				_ = unix.Fchown(next, int(ra.UID), int(ra.GID))
			}
		}
		unix.Close(fd)
		if err == unix.ELOOP || err == unix.ENOTDIR {
			return nil, &os.PathError{Op: "open", Path: at, Err: errHomeLink}
		}
		if err != nil {
			return nil, &os.PathError{Op: "open", Path: at, Err: err}
		}
		fd = next
	}
	return &homeDir{fd: fd, path: dir, ra: ra}, nil
}

func (d *homeDir) Close() error { return unix.Close(d.fd) }

func (d *homeDir) err(op, name string, err error) error {
	return &os.PathError{Op: op, Path: filepath.Join(d.path, name), Err: err}
}

// open opens name in d for reading: a regular file only; under a home, never
// through a link, and — own — only one the login owns (a hard link to a file
// that is not the login's is not its to have read back).
func (d *homeDir) open(name string, own bool) (*os.File, *unix.Stat_t, error) {
	flags := unix.O_RDONLY | unix.O_CLOEXEC | unix.O_NONBLOCK
	if d.ra != nil {
		flags |= unix.O_NOFOLLOW
	}
	fd, err := unix.Openat(d.fd, name, flags, 0)
	if err == unix.ELOOP {
		err = errHomeNotRegular
	}
	if err != nil {
		return nil, nil, d.err("open", name, err)
	}
	var st unix.Stat_t
	if err := unix.Fstat(fd, &st); err != nil {
		unix.Close(fd)
		return nil, nil, d.err("stat", name, err)
	}
	if st.Mode&unix.S_IFMT != unix.S_IFREG {
		unix.Close(fd)
		return nil, nil, d.err("open", name, errHomeNotRegular)
	}
	if own && d.ra != nil && st.Uid != d.ra.UID {
		unix.Close(fd)
		return nil, nil, d.err("open", name, fmt.Errorf("owned by uid %d, not %s", st.Uid, d.ra.Login))
	}
	return os.NewFile(uintptr(fd), filepath.Join(d.path, name)), &st, nil
}

// readFile reads name (see open), at most homeFileMax bytes: a larger file is
// an error, and nothing of it is returned.
func (d *homeDir) readFile(name string, own bool) ([]byte, error) {
	b, _, err := d.readFileMode(name, own)
	return b, err
}

// readFileMode is readFile plus the file's permission bits.
func (d *homeDir) readFileMode(name string, own bool) ([]byte, os.FileMode, error) {
	f, st, err := d.open(name, own)
	if err != nil {
		return nil, 0, err
	}
	defer f.Close()
	if st.Size > homeFileMax {
		return nil, 0, d.err("read", name, errHomeTooLarge)
	}
	b, err := io.ReadAll(io.LimitReader(f, homeFileMax+1))
	if err != nil {
		return nil, 0, d.err("read", name, err)
	}
	if len(b) > homeFileMax {
		return nil, 0, d.err("read", name, errHomeTooLarge)
	}
	return b, os.FileMode(st.Mode & 0o777), nil
}

// exists says name is in d (not followed when it is a link).
func (d *homeDir) exists(name string) bool {
	var st unix.Stat_t
	return unix.Fstatat(d.fd, name, &st, unix.AT_SYMLINK_NOFOLLOW) == nil
}

// createTemp makes a new 0600 file in d whose name starts with prefix,
// handed to the login; the caller renames or removes it.
func (d *homeDir) createTemp(prefix string) (*os.File, string, error) {
	for range 16 {
		var r [8]byte
		if _, err := rand.Read(r[:]); err != nil {
			return nil, "", err
		}
		name := prefix + hex.EncodeToString(r[:])
		fd, err := unix.Openat(d.fd, name, unix.O_RDWR|unix.O_CREAT|unix.O_EXCL|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0o600)
		if err == unix.EEXIST {
			continue
		}
		if err != nil {
			return nil, "", d.err("create", name, err)
		}
		f := os.NewFile(uintptr(fd), filepath.Join(d.path, name))
		d.own(f)
		return f, name, nil
	}
	return nil, "", d.err("create", prefix+"*", unix.EEXIST)
}

// own hands f to the login (under no home: nothing to do).
func (d *homeDir) own(f *os.File) {
	if d.ra != nil {
		_ = f.Chown(int(d.ra.UID), int(d.ra.GID))
	}
}

// writeAtomic writes data to name with mode through a new file in d and one
// rename: a link at name is replaced, never followed.
func (d *homeDir) writeAtomic(name string, data []byte, mode os.FileMode) error {
	f, tmp, err := d.createTemp("." + name + ".")
	if err != nil {
		return err
	}
	ok := false
	defer func() {
		if !ok {
			_ = d.remove(tmp)
		}
	}()
	if err := f.Chmod(mode); err != nil {
		f.Close()
		return err
	}
	if _, err := f.Write(data); err != nil {
		f.Close()
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	if err := d.rename(tmp, d, name); err != nil {
		return err
	}
	ok = true
	return nil
}

// rename moves name in d to toName in to.
func (d *homeDir) rename(name string, to *homeDir, toName string) error {
	if err := unix.Renameat(d.fd, name, to.fd, toName); err != nil {
		return &os.LinkError{Op: "rename", Old: filepath.Join(d.path, name), New: filepath.Join(to.path, toName), Err: err}
	}
	return nil
}

// remove unlinks name from d; a missing one is no error.
func (d *homeDir) remove(name string) error {
	if err := unix.Unlinkat(d.fd, name, 0); err != nil && err != unix.ENOENT {
		return d.err("remove", name, err)
	}
	return nil
}

// removeAll removes name from d and, when it is a directory, everything in
// it — no link followed; a missing one is no error.
func (d *homeDir) removeAll(name string) error {
	return removeAllAt(d.fd, name, d.path, 0)
}

func removeAllAt(dirfd int, name, path string, depth int) error {
	full := filepath.Join(path, name)
	var st unix.Stat_t
	if err := unix.Fstatat(dirfd, name, &st, unix.AT_SYMLINK_NOFOLLOW); err != nil {
		if err == unix.ENOENT {
			return nil
		}
		return &os.PathError{Op: "remove", Path: full, Err: err}
	}
	if st.Mode&unix.S_IFMT != unix.S_IFDIR {
		if err := unix.Unlinkat(dirfd, name, 0); err != nil && err != unix.ENOENT {
			return &os.PathError{Op: "remove", Path: full, Err: err}
		}
		return nil
	}
	if depth > 32 {
		return &os.PathError{Op: "remove", Path: full, Err: errors.New("too deep")}
	}
	fd, err := unix.Openat(dirfd, name, dirFlags|unix.O_NOFOLLOW, 0)
	if err != nil {
		return &os.PathError{Op: "remove", Path: full, Err: err}
	}
	f := os.NewFile(uintptr(fd), full)
	names, err := f.Readdirnames(-1)
	if err == nil {
		for _, n := range names {
			if err = removeAllAt(fd, n, full, depth+1); err != nil {
				break
			}
		}
	}
	f.Close()
	if err != nil {
		return err
	}
	if err := unix.Unlinkat(dirfd, name, unix.AT_REMOVEDIR); err != nil && err != unix.ENOENT {
		return &os.PathError{Op: "remove", Path: full, Err: err}
	}
	return nil
}

// list is d's entries' names.
func (d *homeDir) list() ([]string, error) {
	fd, err := unix.Openat(d.fd, ".", dirFlags, 0)
	if err != nil {
		return nil, d.err("open", ".", err)
	}
	f := os.NewFile(uintptr(fd), d.path)
	defer f.Close()
	return f.Readdirnames(-1)
}

// openRead opens name in d for reading (see open; not owner-checked).
func (d *homeDir) openRead(name string) (*os.File, error) {
	f, _, err := d.open(name, false)
	return f, err
}
