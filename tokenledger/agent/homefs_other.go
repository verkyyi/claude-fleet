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
	f, fi, err := d.open(name)
	if err != nil {
		return nil, 0, err
	}
	defer f.Close()
	if fi.Size() > homeFileMax {
		return nil, 0, &os.PathError{Op: "read", Path: d.at(name), Err: errHomeTooLarge}
	}
	b, err := io.ReadAll(io.LimitReader(f, homeFileMax+1))
	if err != nil {
		return nil, 0, err
	}
	if len(b) > homeFileMax {
		return nil, 0, &os.PathError{Op: "read", Path: d.at(name), Err: errHomeTooLarge}
	}
	return b, fi.Mode().Perm(), nil
}

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
