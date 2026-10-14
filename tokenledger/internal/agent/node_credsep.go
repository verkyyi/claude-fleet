package agent

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
)

// The heartbeat's credsep (claude-fleet#2295, EPIC #2293 共同约定 1): is this
// login's subscription out of its own reach? The ONE judgement is the
// claude-fleet script's — `fleet-credsep.sh status` says separated (exit 0)
// AND `fleet-credsep.sh check` passes (exit 0) — never a second copy here.
// The hub leases a role=user person's login real tokens only on "separated".

var credsepScript = filepath.Join(".claude", "fleet", "bin", "fleet-credsep.sh")

const (
	// credsepInterval: the scripts read files and run `sudo -n true`, so the
	// verdict is re-asked at most this often; the beats between carry it.
	credsepInterval = 5 * time.Minute
	credsepTimeout  = 20 * time.Second
)

// credsepCommand is the seam the tests replace.
var credsepCommand = exec.CommandContext

type credsepProbe struct {
	at     time.Time
	word   string
	served *bool
}

// reading is the login's credsep word: separated | not | unknown.
func (p *credsepProbe) reading(ctx context.Context, home string, now time.Time) string {
	if !p.at.IsZero() && now.Sub(p.at) < credsepInterval {
		return p.word
	}
	p.at, p.word, p.served = now, credsepJudge(ctx, home), credsepServed(ctx, home)
	return p.word
}

// credsepServed is `fleet-credsep.sh served` (claude-fleet#4247): does the
// proxy hand this login a credential now? Exit 0 yes, 3 no; nil for anything
// else — cannot tell (2), a script older than the verb (its «unknown command»
// is 2 too), or one that never ran.
func credsepServed(ctx context.Context, home string) *bool {
	script := filepath.Join(home, credsepScript)
	if _, err := os.Stat(script); err != nil {
		return nil
	}
	var v bool
	switch credsepRun(ctx, home, script, "served") {
	case 0:
		v = true
	case 3:
		v = false
	default:
		return nil
	}
	return &v
}

func credsepJudge(ctx context.Context, home string) string {
	script := filepath.Join(home, credsepScript)
	if _, err := os.Stat(script); err != nil {
		return control.CredsepUnknown
	}
	switch credsepRun(ctx, home, script, "status") {
	case 0:
	case 3:
		return control.CredsepNot
	default:
		return control.CredsepUnknown
	}
	switch credsepRun(ctx, home, script, "check") {
	case 0:
		return control.CredsepSeparated
	case 1:
		return control.CredsepNot // separated, but the doctor's row warns
	}
	return control.CredsepUnknown
}

// credsepRun is one verb's exit status; -1 when it never ran or was killed.
func credsepRun(ctx context.Context, home, script, verb string) int {
	ctx, cancel := context.WithTimeout(ctx, credsepTimeout)
	defer cancel()
	cmd := credsepCommand(ctx, "/bin/bash", script, verb)
	cmd.Env = append(os.Environ(), "HOME="+home)
	err := prepCmd(ctx, cmd)
	if err == nil {
		err = cmd.Run()
	}
	var ee *exec.ExitError
	switch {
	case err == nil:
		return 0
	case errors.As(err, &ee) && ctx.Err() == nil:
		return ee.ExitCode()
	}
	return -1
}
