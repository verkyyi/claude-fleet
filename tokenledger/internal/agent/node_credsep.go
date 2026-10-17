package agent

import (
	"bytes"
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
)

// The heartbeat's credsep (claude-fleet#2295, EPIC #2293 共同约定 1): is this
// login's subscription out of its own reach? The ONE judgement is the
// claude-fleet script's — `fleet-credsep.sh judge` (claude-fleet#4622): exit 0
// separated, 3 not, one line why — never a second copy here. A script older
// than the verb (exit 2, «unknown command») is asked the old way: status says
// separated (exit 0) AND check passes (exit 0). The old way read any doctor
// WARN as not separated — on a managed machine a tenant whose own fleet.conf named
// FLEET_HUB_URL (the shared proxy ignores it) was refused every lease.
// The hub leases a login real tokens only on "separated".

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
	why    string // judge's line (claude-fleet#4622); "" from an older script
	served *bool
}

// reading is the login's credsep word: separated | not | unknown.
func (p *credsepProbe) reading(ctx context.Context, home string, now time.Time) string {
	if !p.at.IsZero() && now.Sub(p.at) < credsepInterval {
		return p.word
	}
	p.at = now
	p.word, p.why = credsepJudge(ctx, home)
	p.served = credsepServed(ctx, home)
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

// credsepWhyMax bounds judge's line on the beat.
const credsepWhyMax = 200

func credsepJudge(ctx context.Context, home string) (word, why string) {
	script := filepath.Join(home, credsepScript)
	if _, err := os.Stat(script); err != nil {
		return control.CredsepUnknown, ""
	}
	var out bytes.Buffer
	switch credsepRunOut(ctx, home, script, "judge", &out) {
	case 0:
		return control.CredsepSeparated, credsepLine(out.String())
	case 3:
		return control.CredsepNot, credsepLine(out.String())
	case 2:
		// a script older than judge (or one that could not tell): the old way
	default:
		return control.CredsepUnknown, ""
	}
	switch credsepRun(ctx, home, script, "status") {
	case 0:
	case 3:
		return control.CredsepNot, ""
	default:
		return control.CredsepUnknown, ""
	}
	switch credsepRun(ctx, home, script, "check") {
	case 0:
		return control.CredsepSeparated, ""
	case 1:
		return control.CredsepNot, "" // separated, but the doctor's row warns
	}
	return control.CredsepUnknown, ""
}

// credsepLine is judge's first line, bounded.
func credsepLine(s string) string {
	s, _, _ = strings.Cut(strings.TrimSpace(s), "\n")
	if r := []rune(s); len(r) > credsepWhyMax {
		s = string(r[:credsepWhyMax])
	}
	return s
}

// credsepRun is one verb's exit status; -1 when it never ran or was killed.
func credsepRun(ctx context.Context, home, script, verb string) int {
	return credsepRunOut(ctx, home, script, verb, nil)
}

// credsepRunOut is credsepRun with the verb's stdout into out (nil: dropped).
func credsepRunOut(ctx context.Context, home, script, verb string, out *bytes.Buffer) int {
	ctx, cancel := context.WithTimeout(ctx, credsepTimeout)
	defer cancel()
	cmd := credsepCommand(ctx, "/bin/bash", script, verb)
	cmd.Env = append(os.Environ(), "HOME="+home)
	if out != nil {
		cmd.Stdout = out
	}
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
