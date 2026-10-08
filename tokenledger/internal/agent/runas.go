package agent

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
)

// One node program per machine (claude-fleet#2333): `ccquota agent --machine`
// runs as root and serves every login of the machine in one process. Each
// login's work — fleet-control.py, the account script, the relay helper, git —
// must still run AS that login, exactly as when the login ran its own agent.
// The login rides the context: a tenant's Run wraps its ctx with withRunAs,
// and every command the package starts goes through prepCmd, which drops the
// child to that uid/gid with that home. A command started in machine mode
// with no login on its context is refused, never run as root.

// RunAs is the login a tenant's work runs as.
type RunAs struct {
	Login  string
	UID    uint32
	GID    uint32
	Groups []uint32
	Home   string
}

type runAsKey struct{}

// withRunAs puts the login on ctx; nil leaves ctx as it is (a plain agent).
func withRunAs(ctx context.Context, ra *RunAs) context.Context {
	if ra == nil {
		return ctx
	}
	return context.WithValue(ctx, runAsKey{}, ra)
}

func runAsOf(ctx context.Context) *RunAs {
	ra, _ := ctx.Value(runAsKey{}).(*RunAs)
	return ra
}

// machineStrict counts running machine agents (RunMachine): while one runs as
// root, a command with no login on its context is refused.
var machineStrict atomic.Int32

// errNoLogin is a command a machine-mode agent was asked to start with no
// login to start it as.
var errNoLogin = errors.New("machine agent: no login to run this command as (refused rather than run as root)")

// prepCmd makes cmd run as ctx's login: credentials, HOME/USER/LOGNAME and a
// working directory of the login's home unless one is set. A plain agent
// (no login on ctx, not in machine mode) is untouched, byte for byte.
func prepCmd(ctx context.Context, cmd *exec.Cmd) error {
	ra := runAsOf(ctx)
	if ra == nil {
		if machineStrict.Load() > 0 && os.Geteuid() == 0 {
			return errNoLogin
		}
		return nil
	}
	setCredential(cmd, ra)
	env := cmd.Env
	if env == nil {
		env = os.Environ()
	}
	out := make([]string, 0, len(env)+3)
	for _, kv := range env {
		k, _, _ := strings.Cut(kv, "=")
		switch k {
		case "HOME", "USER", "LOGNAME", "MAIL", "SUDO_USER", "SUDO_UID", "SUDO_GID", "SUDO_COMMAND":
			continue
		}
		out = append(out, kv)
	}
	out = append(out, "HOME="+ra.Home, "USER="+ra.Login, "LOGNAME="+ra.Login)
	cmd.Env = out
	if cmd.Dir == "" && ra.Home != "" {
		cmd.Dir = ra.Home
	}
	return nil
}

// tenantHomes is every machine tenant's home → its login (claude-fleet#2333),
// set once by RunMachine before any tenant runs. A file the agent writes under
// a login's home belongs to that login — the path says whose it is, so the
// writers need no login of their own.
var (
	tenantMu    sync.RWMutex
	tenantHomes []*RunAs
)

func registerTenant(ra *RunAs) {
	tenantMu.Lock()
	defer tenantMu.Unlock()
	tenantHomes = append(tenantHomes, ra)
}

func unregisterTenant(ra *RunAs) {
	tenantMu.Lock()
	defer tenantMu.Unlock()
	for i, x := range tenantHomes {
		if x == ra {
			tenantHomes = append(tenantHomes[:i], tenantHomes[i+1:]...)
			return
		}
	}
}

// ownPath hands a file or directory the agent just wrote under a login's home
// to that login: root wrote it, and the login's own scripts and CLIs must keep
// reading and replacing it. Outside every tenant's home (or no tenants — a
// plain agent): nothing to do.
func ownPath(path string) {
	tenantMu.RLock()
	defer tenantMu.RUnlock()
	for _, ra := range tenantHomes {
		if ra.Home != "" && (path == ra.Home || strings.HasPrefix(path, ra.Home+string(os.PathSeparator))) {
			_ = os.Lchown(path, int(ra.UID), int(ra.GID))
			return
		}
	}
}

// mkdirOwned is os.MkdirAll that hands every directory it created under a
// login's home to that login.
func mkdirOwned(dir string, mode os.FileMode) error {
	var made []string
	for d := dir; ; d = filepath.Dir(d) {
		if _, err := os.Lstat(d); err == nil || d == filepath.Dir(d) {
			break
		}
		made = append(made, d)
	}
	if err := os.MkdirAll(dir, mode); err != nil {
		return err
	}
	for _, d := range made {
		ownPath(d)
	}
	return nil
}

// osLogin is the login this agent's work is for: the tenant's, else the
// process's own.
func (a *Agent) osLogin() string {
	if a.cfg.RunAs != nil {
		return a.cfg.RunAs.Login
	}
	if u, err := user.Current(); err == nil {
		return u.Username
	}
	return ""
}

// bgCtx is a fresh context that still carries this agent's login, for work
// that deliberately outlives the context it started from.
func (a *Agent) bgCtx() context.Context {
	return withRunAs(context.Background(), a.cfg.RunAs)
}
