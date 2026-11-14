package agent

import (
	"errors"
	"io"
	"log"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/shared/identity"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/sessions"
)

// A machine tenant's reads of its login's own files (claude-fleet#2333): the
// identity, the credential file, the transcripts, the Codex registry and
// records, node.env, the probe and account files. The agent runs as root and
// the login arranges its home, so each is read inside that home only, through
// homeDir (homefs.go) — no link followed, a regular file only, its size capped,
// the login's own where the login writes it. A plain agent reads as before.

// Caps on what the agent reads back of a login's file.
const (
	claudeConfigMax = 64 << 20 // ~/.claude.json carries every project's history
	smallFileMax    = 1 << 20
	envFileMax      = 64 << 10
)

// loginReader is how this agent reads its login's files: nil (each reader's
// plain path) for a plain agent; for a machine tenant, inside the login's home
// only, files the login owns, at most max bytes.
func (a *Agent) loginReader(max int64) func(string) ([]byte, error) {
	ra := a.cfg.RunAs
	if ra == nil {
		return nil
	}
	return func(path string) ([]byte, error) { return readAsLogin(ra, path, true, max) }
}

// readAsLogin reads path, which must be inside ra's home (see openLoginDir);
// own: only a file ra owns.
func readAsLogin(ra *RunAs, path string, own bool, max int64) ([]byte, error) {
	d, err := openLoginDir(ra, filepath.Dir(path))
	if err != nil {
		return nil, err
	}
	defer d.Close()
	b, _, err := d.readFileMax(filepath.Base(path), own, max)
	return b, err
}

// openAsLogin opens path, inside ra's home, for reading: a regular file ra
// owns, reached through no link.
func openAsLogin(ra *RunAs, path string) (*os.File, error) {
	d, err := openLoginDir(ra, filepath.Dir(path))
	if err != nil {
		return nil, err
	}
	defer d.Close()
	return d.openOwned(filepath.Base(path))
}

// loginOpener is the transcript scanner's opener for this agent (nil: os.Open).
func (a *Agent) loginOpener() func(string) (*os.File, error) {
	ra := a.cfg.RunAs
	if ra == nil {
		return nil
	}
	return func(path string) (*os.File, error) { return openAsLogin(ra, path) }
}

// readFileFor reads path for this agent: a plain agent as before; a machine
// tenant inside its login's home through homeDir, anywhere else (a place root
// configured) by its path — either way at most max bytes, a regular file.
func (a *Agent) readFileFor(path string, own bool, max int64) ([]byte, error) {
	ra := a.cfg.RunAs
	if ra == nil {
		return os.ReadFile(path)
	}
	if underLogin(ra, path) {
		return readAsLogin(ra, path, own, max)
	}
	return readCapped(path, max)
}

// readCapped reads a regular file at path, at most max bytes.
func readCapped(path string, max int64) ([]byte, error) {
	f, err := os.OpenFile(path, os.O_RDONLY|nonBlock, 0)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	fi, err := f.Stat()
	if err != nil {
		return nil, err
	}
	if !fi.Mode().IsRegular() {
		return nil, &os.PathError{Op: "open", Path: path, Err: errHomeNotRegular}
	}
	b, err := io.ReadAll(io.LimitReader(f, max+1))
	if err != nil {
		return nil, err
	}
	if int64(len(b)) > max {
		return nil, &os.PathError{Op: "read", Path: path, Err: errHomeTooLarge}
	}
	return b, nil
}

// credStoreBase is where credential separation keeps every login's store
// (bin/fleet-credsep-launch.py: <base>/<login>/, the role account's, 0700).
func credStoreBase() string {
	if b := os.Getenv("FLEET_CREDSEP_ROOT_BASE"); b != "" {
		return b
	}
	return "/var/db/fleet-cred"
}

var errNotStoreLink = errors.New("a link to somewhere other than this login's credential store")

// readLoginEnvFile reads a login's node.env (or node.pub.env) for a machine
// tenant: a regular file in the login's home, or — a credential-separated
// login's node.env (claude-fleet#1971) — a link to exactly its own store's
// node.env, read there only when that store is not the login's to change. Any
// other link is refused.
func readLoginEnvFile(ra *RunAs, path string) ([]byte, error) {
	d, err := openLoginDir(ra, filepath.Dir(path))
	if err != nil {
		return nil, err
	}
	defer d.Close()
	name := filepath.Base(path)
	if target, ok := d.readlink(name); ok {
		want := filepath.Join(credStoreBase(), ra.Login, "node.env")
		if !filepath.IsAbs(target) || filepath.Clean(target) != want {
			return nil, &os.PathError{Op: "open", Path: path, Err: errNotStoreLink}
		}
		return readStoreFile(want, ra.UID, envFileMax)
	}
	b, _, err := d.readFileMax(name, false, envFileMax)
	return b, err
}

// loadClaudeCredentials is identity.LoadCredentials for this agent: a machine
// tenant reads its login's credential file confined, and never root's keychain
// (it is none of the login's).
func (a *Agent) loadClaudeCredentials() (*identity.Credentials, error) {
	if a.cfg.RunAs == nil {
		return identity.LoadCredentials(a.cfg.Home)
	}
	return identity.LoadCredentialsWith(a.cfg.Home, a.loginReader(smallFileMax), false)
}

// Session stamps (the statusLine hook's) a machine tenant reads in its login's
// home: each at most stampFileMax, the login's own, no link followed, and at
// most stampEntriesMax entries a pass.
const (
	stampFileMax    = 64 << 10
	stampEntriesMax = 4096
)

func (a *Agent) loadStamps(maxAge time.Duration) (*sessions.Index, error) {
	if a.cfg.RunAs == nil {
		return sessions.Load(a.cfg.SessionsDir, maxAge)
	}
	return sessions.LoadWith(a.cfg.SessionsDir, maxAge, func(p string) ([]byte, error) {
		return a.readFileFor(p, true, stampFileMax)
	}, stampEntriesMax)
}

// linkedHomePath is "skipped: linked home path (…)" naming every one of paths
// (in a machine tenant's home) that the agent does not follow because a
// component of it is a link; "" when none is, or for a plain agent. Each one
// is logged once.
func (a *Agent) linkedHomePath(paths ...string) string {
	ra := a.cfg.RunAs
	if ra == nil {
		return ""
	}
	var linked []string
	for _, p := range paths {
		if !underLogin(ra, p) || !homePathLinked(ra, p) {
			continue
		}
		rel, _ := filepath.Rel(ra.Home, p)
		rel = "~/" + rel
		linked = append(linked, rel)
		if a.linkSaid == nil {
			a.linkSaid = map[string]bool{}
		}
		if !a.linkSaid[p] {
			a.linkSaid[p] = true
			log.Printf("machine agent: %s: %s is a link (or under one); not followed — nothing there is collected until it is a plain path", ra.Login, rel)
		}
	}
	if len(linked) == 0 {
		return ""
	}
	return "skipped: linked home path (" + strings.Join(linked, ", ") + ")"
}

// homePathLinked says p, or a directory on the way to it below ra's home, is
// a link. A missing path is not.
func homePathLinked(ra *RunAs, p string) bool {
	d, err := openLoginDir(ra, filepath.Dir(p))
	if err != nil {
		return linkedPath(err)
	}
	defer d.Close()
	_, isLink := d.readlink(filepath.Base(p))
	return isLink
}
