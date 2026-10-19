package agent

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"sync/atomic"
)

// The machine's node program on the seat (claude-fleet#3669, EPIC #3500 C14):
// with `--core <sock>` it runs as `_fleetnode`, which cannot become a login.
// Every command a tenant starts then goes to the root core's exec-as
// (bin/fleet-node-core.py) — the one place that demotes to a login, and only
// for a program under the release's bin/ (prepCmd's old rule, moved there). The
// command is rewritten into `ccquota core-exec`: this same binary, which hands
// the core its own stdin / stdout / stderr with the request (SCM_RIGHTS) and
// exits with the job's code, so a caller's pipes, deadline and exit status
// work as before. No --core = today's road, byte for byte.

// coreSock is the root core's socket while the node program runs as the seat;
// "" (a root or plain agent) = the old road.
var coreSock atomic.Value

func setCoreSock(sock string) { coreSock.Store(sock) }

func coreSockOf() string {
	s, _ := coreSock.Load().(string)
	return s
}

// CoreExecCmd is the subcommand `ccquota core-exec` (cmd/ccquota).
const CoreExecCmd = "core-exec"

// seatSelf is ctx with no login on it: work that is not a login's (reading the
// machine's tailnet name) runs as the seat itself rather than asking the core.
// Off the seat it is ctx as it is.
func seatSelf(ctx context.Context) context.Context {
	if coreSockOf() == "" {
		return ctx
	}
	return context.WithValue(ctx, runAsKey{}, (*RunAs)(nil))
}

// interpreters prepCmd drops in front of a script: the core puts its own back
// by the file's suffix (interp), so the request names the script itself.
var interpreters = map[string]bool{"bash": true, "sh": true, "python3": true}

// coreArgv is the argv the core is asked to run for cmd: the program (its
// resolved path) and its arguments, an interpreter in front of a script
// (`/bin/bash <script>`, `python3 -I <script>`) left out.
func coreArgv(cmd *exec.Cmd) []string {
	argv := append([]string{cmd.Path}, cmd.Args[1:]...)
	if !interpreters[filepath.Base(cmd.Path)] {
		return argv
	}
	rest := argv[1:]
	for len(rest) > 0 && rest[0] == "-I" {
		rest = rest[1:]
	}
	if len(rest) > 0 && filepath.IsAbs(rest[0]) {
		return rest
	}
	return argv
}

// prepCoreCmd turns cmd into `ccquota core-exec --sock S --login L -- argv…`:
// the core runs argv as L on the helper's stdio, in L's home, with the
// environment it builds itself (HOME, USER, PATH, the login's FLEET_CONF_DIR) —
// what the caller put on cmd.Env does not travel (a seat cannot hand a login an
// environment). A program outside the release's bin/ is refused there.
func prepCoreCmd(cmd *exec.Cmd, ra *RunAs, sock string) error {
	self, err := os.Executable()
	if err != nil {
		return err
	}
	argv := coreArgv(cmd)
	cmd.Path = self
	cmd.Args = append([]string{self, CoreExecCmd, "--sock", sock, "--login", ra.Login, "--"}, argv...)
	cmd.Env = []string{"PATH=/usr/bin:/bin", "LANG=" + os.Getenv("LANG")}
	// the helper's own cwd: the seat may not enter the login's home; the job's
	// is the home, the core's chdir
	cmd.Dir = "/"
	return nil
}

// coreRefusedExit is the helper's exit when the core refused or never ran the
// job (126: «found but cannot run», as a shell says it).
const coreRefusedExit = 126
