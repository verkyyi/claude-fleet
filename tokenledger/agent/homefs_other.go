//go:build !unix

package agent

import (
	"io"
	"os"
	"path/filepath"
)

// homeDir off unix: no machine agent runs here, so no tenant's home — plain
// path rules, the same methods as homefs_unix.go.
type homeDir struct {
	path string
	ra   *RunAs
}

func openHomeDir(dir string, create bool, mode os.FileMode) (*homeDir, error) {
	dir = filepath.Clean(dir)
	if create {
		if err := os.MkdirAll(dir, mode); err != nil {
			return nil, err
		}
	} else if fi, err := os.Stat(dir); err != nil {
		return nil, err
	} else if !fi.IsDir() {
		return nil, &os.PathError{Op: "open", Path: dir, Err: errHomeLink}
	}
	return &homeDir{path: dir}, nil
}

func (d *homeDir) Close() error { return nil }

func (d *homeDir) at(name string) string { return filepath.Join(d.path, name) }

func (d *homeDir) open(name string) (*os.File, os.FileInfo, error) {
	f, err := os.Open(d.at(name))
	if err != nil {
		return nil, nil, err
	}
	fi, err := f.Stat()
	if err != nil {
		f.Close()
		return nil, nil, err
	}
	if !fi.Mode().IsRegular() {
		f.Close()
		return nil, nil, &os.PathError{Op: "open", Path: d.at(name), Err: errHomeNotRegular}
	}
	return f, fi, nil
}

func (d *homeDir) readFile(name string, own bool) ([]byte, error) {
	b, _, err := d.readFileMode(name, own)
	return b, err
}

func (d *homeDir) readFileMode(name string, own bool) ([]byte, os.FileMode, error) {
	return d.readFileMax(name, own, homeFileMax)
}

func (d *homeDir) readFileMax(name string, own bool, max int64) ([]byte, os.FileMode, error) {
	f, fi, err := d.open(name)
	if err != nil {
		return nil, 0, err
	}
	defer f.Close()
	if fi.Size() > max {
		return nil, 0, &os.PathError{Op: "read", Path: d.at(name), Err: errHomeTooLarge}
	}
	b, err := io.ReadAll(io.LimitReader(f, max+1))
	if err != nil {
		return nil, 0, err
	}
	if int64(len(b)) > max {
		return nil, 0, &os.PathError{Op: "read", Path: d.at(name), Err: errHomeTooLarge}
	}
	return b, fi.Mode().Perm(), nil
}

// openLoginDir off unix: plain path rules, dir still required inside ra's home.
func openLoginDir(ra *RunAs, dir string) (*homeDir, error) {
	if ra == nil || ra.Home == "" || !filepath.IsAbs(ra.Home) || !filepath.IsAbs(dir) {
		return nil, &os.PathError{Op: "open", Path: dir, Err: errOutsideHome}
	}
	if !underLogin(ra, dir) && filepath.Clean(dir) != filepath.Clean(ra.Home) {
		return nil, &os.PathError{Op: "open", Path: dir, Err: errOutsideHome}
	}
	return openHomeDir(dir, false, 0)
}

func (d *homeDir) readlink(name string) (string, bool) {
	fi, err := os.Lstat(d.at(name))
	if err != nil || fi.Mode()&os.ModeSymlink == 0 {
		return "", false
	}
	t, err := os.Readlink(d.at(name))
	return t, err == nil
}

func (d *homeDir) openOwned(name string) (*os.File, error) { return d.openRead(name) }

func (d *homeDir) exists(name string) bool {
	_, err := os.Lstat(d.at(name))
	return err == nil
}

func (d *homeDir) createTemp(prefix string) (*os.File, string, error) {
	f, err := os.CreateTemp(d.path, prefix+"*")
	if err != nil {
		return nil, "", err
	}
	return f, filepath.Base(f.Name()), nil
}

func (d *homeDir) own(*os.File) {}

func (d *homeDir) writeAtomic(name string, data []byte, mode os.FileMode) error {
	f, tmp, err := d.createTemp("." + name + ".")
	if err != nil {
		return err
	}
	defer os.Remove(d.at(tmp))
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
	return os.Rename(d.at(tmp), d.at(name))
}

func (d *homeDir) rename(name string, to *homeDir, toName string) error {
	return os.Rename(d.at(name), to.at(toName))
}

func (d *homeDir) remove(name string) error {
	if err := os.Remove(d.at(name)); err != nil && !os.IsNotExist(err) {
		return err
	}
	return nil
}

func (d *homeDir) removeAll(name string) error { return os.RemoveAll(d.at(name)) }

func (d *homeDir) list() ([]string, error) {
	f, err := os.Open(d.path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	return f.Readdirnames(-1)
}

func (d *homeDir) openRead(name string) (*os.File, error) {
	f, _, err := d.open(name)
	return f, err
}

const nonBlock = 0

// readStoreFile off unix: no credential store here; a plain capped read.
func readStoreFile(path string, uid uint32, max int64) ([]byte, error) { return readCapped(path, max) }
