package agent

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
)

// Files under a login's home (homeDir, homefs_unix.go). The machine agent runs
// as root, and a login's home is the login's to arrange: any directory or file
// under it may be a link to somewhere else, a FIFO or a device by the time root
// touches it. So everything the agent reads back, writes, renames or removes
// under a tenant's home goes through homeDir: the home itself is opened by its
// path (its parents are root's), every directory below it one component at a
// time without following a link, and the file is opened from that directory —
// no link followed, a regular file only, its size capped, a file whose content
// is written back owned by the login itself. What the agent creates there is
// handed to the login on the open descriptor.
//
// A path under no tenant's home (a plain agent, running as its own login, or a
// place root configured) keeps plain path rules.

// homeFileMax is the most of a file under a login's home the agent reads back.
const homeFileMax = 1 << 20

var (
	errHomeLink       = errors.New("not a plain directory (a link, or not a directory)")
	errHomeNotRegular = errors.New("not a regular file")
	errHomeTooLarge   = errors.New("larger than the agent reads")
)

// loginRootOf is the tenant whose home holds path, that home, and path's
// components below it; nil when path is under no tenant's home.
func loginRootOf(path string) (*RunAs, string, []string) {
	path = filepath.Clean(path)
	tenantMu.RLock()
	defer tenantMu.RUnlock()
	for _, ra := range tenantHomes {
		if ra.Home == "" {
			continue
		}
		home := filepath.Clean(ra.Home)
		if path == home {
			return ra, home, nil
		}
		if rest, ok := strings.CutPrefix(path, home+string(os.PathSeparator)); ok {
			return ra, home, strings.Split(rest, string(os.PathSeparator))
		}
	}
	return nil, "", nil
}

// underLogin says path is inside ra's home (not the home itself).
func underLogin(ra *RunAs, path string) bool {
	if ra == nil || ra.Home == "" || !filepath.IsAbs(path) {
		return false
	}
	return strings.HasPrefix(filepath.Clean(path), filepath.Clean(ra.Home)+string(os.PathSeparator))
}

// writeAtomic writes data to path with mode via a same-directory rename, so a
// CLI reading mid-write sees the old file or the new one, never half of one.
// Missing directories are made 0700; under a login's home all of it is the
// login's.
func writeAtomic(path string, data []byte, mode os.FileMode) error {
	d, err := openHomeDir(filepath.Dir(path), true, 0o700)
	if err != nil {
		return err
	}
	defer d.Close()
	return d.writeAtomic(filepath.Base(path), data, mode)
}

// mkdirOwned is os.MkdirAll that hands every directory it created under a
// login's home to that login, and goes through no link below that home.
func mkdirOwned(dir string, mode os.FileMode) error {
	d, err := openHomeDir(dir, true, mode)
	if err != nil {
		return err
	}
	return d.Close()
}

// readHomeFile reads path through homeDir (see homeDir.readFile).
func readHomeFile(path string, own bool) ([]byte, error) {
	d, err := openHomeDir(filepath.Dir(path), false, 0)
	if err != nil {
		return nil, err
	}
	defer d.Close()
	return d.readFile(filepath.Base(path), own)
}

// removeHomeFile removes path's last component from its directory, opened
// through homeDir; a missing one is no error.
func removeHomeFile(path string) error {
	d, err := openHomeDir(filepath.Dir(path), false, 0)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	defer d.Close()
	return d.remove(filepath.Base(path))
}
