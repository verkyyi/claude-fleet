package agent

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"sync"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
)

// The admin agent's half of account provisioning (claude-fleet#1411).
//
// The hub asks a machine to open or close one person's login; the agent of
// the operator's own login there — the one with password-less sudo — runs
// claude-fleet's onboarding script for it. That makes this agent a high-value
// target, so what it will do is fixed HERE, not by the hub:
//
//   - only when started with CCQUOTA_FLEET_ADMIN=1 (Config.FleetAdmin); any
//     other agent refuses every account op with NOT_ADMIN;
//   - only two ops, each one fixed argv — the hub picks the login and the
//     display name, and both must pass control.ValidCreateLogin / ValidFullName
//     (a create the hub marks existing may reuse a digit-leading login the
//     person already holds elsewhere — macOS only, claude-fleet#2105);
//   - never this agent's own login;
//   - one op at a time, each op_id at most once.
//
// The result is kept until the hub acks it and re-sent on every new
// connection, so a link that drops while sysadminctl runs loses nothing: the
// hub marked the op unknown, and this answer settles it.

// accountOpTimeout bounds one onboarding/offboarding script run. Opening a
// login clones claude-fleet and installs its daemons; ten minutes is generous.
const accountOpTimeout = 15 * time.Minute

// accountDetailMax is how much of the script's output travels back.
const accountDetailMax = 2000

// The scripts, relative to the admin login's claude-fleet install.
var (
	loginNewScript    = filepath.Join(".claude", "fleet", "bin", "fleet-login-new.sh")
	loginRemoveScript = filepath.Join(".claude", "fleet", "bin", "fleet-login-remove.sh")
)

// credsepMark is the line fleet-login-new.sh ends a create with when it opened
// the login credential-separated (claude-fleet#2294, its step 7b), and
// credsepScriptMark what a version of the script that separates carries.
const (
	credsepMark       = "credsep: separated"
	credsepScriptMark = "--no-credsep"
)

// credsepCapable reports whether this login's fleet-login-new.sh opens every
// login separated — the hello's CapCredsep. A script from before #2294 (or none)
// does not: the hub then opens no spare login here (claude-fleet#2263).
func credsepCapable(home string) bool {
	b, err := os.ReadFile(filepath.Join(home, loginNewScript))
	return err == nil && bytes.Contains(b, []byte(credsepScriptMark)) && bytes.Contains(b, []byte(credsepMark))
}

// credsepResult is AccountResult.Credsep for a create's output: "separated"
// only when its LAST non-empty line says so (a pending / off / failed open says
// something else, and is never handed out as a spare).
func credsepResult(out string) string {
	lines := strings.Split(strings.TrimRight(out, " \t\r\n"), "\n")
	if strings.TrimSpace(lines[len(lines)-1]) == credsepMark {
		return control.CredsepSeparated
	}
	return ""
}

// accountGOOS is the platform the digit-leading rule is judged on; a test seam.
var accountGOOS = runtime.GOOS

// accountCommand is the injection point for tests.
var accountCommand = exec.CommandContext

// accountArgv is the ONE place the argv of an account op is decided.
func accountArgv(home string, op control.AccountOp) (string, []string) {
	if op.Op == control.AccountRemove {
		keep := "--keep-home"
		if op.DropHome {
			keep = "--delete-home"
		}
		return filepath.Join(home, loginRemoveScript), []string{op.Login, keep, "--apply"}
	}
	return filepath.Join(home, loginNewScript), []string{op.Login, "--full-name", op.FullName, "--share-pool", "--apply"}
}

// accountEnv is the create's join code and this hub's address, handed to
// fleet-login-new.sh in its environment, never its argv (claude-fleet#2652):
// a script that predates them ignores both. nil = the agent's own environment.
func accountEnv(hub string, op control.AccountOp) []string {
	if op.Op != control.AccountCreate || op.JoinCode == "" || hub == "" {
		return nil
	}
	return append(os.Environ(), "FLEET_LOGIN_JOIN_CODE="+op.JoinCode, "FLEET_LOGIN_HUB="+hub)
}

// accountOps is the admin agent's state across connections.
type accountOps struct {
	mu sync.Mutex
	// seen is every op_id ever accepted, so a duplicate send never runs the
	// script twice (bounded: oldest forgotten past seenMax).
	seen  map[string]bool
	order []string
	// outbox holds results the hub has not acked yet, by op_id.
	outbox map[string]control.Message
	// send writes on the current connection; nil between connections.
	send func(control.Message) error

	// run serialises the scripts: two sysadminctl runs racing for the next
	// free uid is not a case worth finding out about.
	run sync.Mutex
}

const seenMax = 512

func (o *accountOps) attach(send func(control.Message) error) {
	o.mu.Lock()
	o.send = send
	pending := make([]control.Message, 0, len(o.outbox))
	for _, m := range o.outbox {
		pending = append(pending, m)
	}
	o.mu.Unlock()
	for _, m := range pending {
		if err := send(m); err != nil {
			return // the session is ending; the next one tries again
		}
	}
}

func (o *accountOps) detach() {
	o.mu.Lock()
	o.send = nil
	o.mu.Unlock()
}

func (o *accountOps) acked(opID string) {
	o.mu.Lock()
	delete(o.outbox, opID)
	o.mu.Unlock()
}

// claim records opID; false when it was already accepted once.
func (o *accountOps) claim(opID string) bool {
	o.mu.Lock()
	defer o.mu.Unlock()
	if o.seen == nil {
		o.seen, o.outbox = map[string]bool{}, map[string]control.Message{}
	}
	if o.seen[opID] {
		return false
	}
	o.seen[opID] = true
	o.order = append(o.order, opID)
	if len(o.order) > seenMax {
		delete(o.seen, o.order[0])
		o.order = o.order[1:]
	}
	return true
}

func (o *accountOps) deliver(m control.Message) {
	o.mu.Lock()
	o.outbox[m.OpID] = m
	send := o.send
	o.mu.Unlock()
	if send != nil {
		_ = send(m) // on failure it stays in the outbox for the next session
	}
}

// handleAccountOp answers one TypeAccountOp. It returns at once; the script
// runs in the background and its result is delivered when it ends.
func (a *Agent) handleAccountOp(ctx context.Context, conn nodeLink, m control.Message) {
	refuse := func(code, msg string) {
		e := control.Message{Type: control.TypeError, OpID: m.OpID, Proto: control.Proto,
			Error: &control.Error{Code: code, Message: msg}}
		wctx, cancel := context.WithTimeout(ctx, nodeWriteTimeout)
		defer cancel()
		_ = conn.write(wctx, e)
	}
	if !a.cfg.FleetAdmin {
		log.Printf("control channel: refused an account op: this agent is not an admin agent (CCQUOTA_FLEET_ADMIN is not 1)")
		refuse(control.CodeNotAdmin, "this agent was not started as its machine's admin agent")
		return
	}
	var op control.AccountOp
	if err := json.Unmarshal(m.Payload, &op); err != nil || m.OpID == "" {
		refuse(control.CodeBadArgs, "malformed account op")
		return
	}
	if err := validateAccountOp(op, a.osLogin()); err != nil {
		log.Printf("control channel: refused account op %s: %v", m.OpID, err)
		refuse(control.CodeBadArgs, err.Error())
		return
	}
	if !a.acct.claim(m.OpID) {
		return // already running or done; its result is (or will be) in the outbox
	}
	go func() {
		res := a.runAccountOp(op)
		out, err := control.New(control.TypeAccountResult, res)
		if err != nil {
			return
		}
		out.OpID = m.OpID
		log.Printf("control channel: account op %s %s: ok=%v exit=%d", op.Op, op.Login, res.OK, res.Exit)
		a.acct.deliver(out)
	}()
}

var joinCodeRE = regexp.MustCompile(`^fj_[a-z2-7]{26}$`)

func validateAccountOp(op control.AccountOp, self string) error {
	if op.Op != control.AccountCreate && op.Op != control.AccountRemove {
		return errors.New("op must be create or remove")
	}
	existing := op.Op == control.AccountCreate && op.Existing
	if !control.ValidCreateLogin(op.Login, existing) {
		if existing {
			return errors.New("login is not 2-16 lowercase letters and digits with at least one letter")
		}
		return errors.New("login is not 2-16 lowercase letters and digits starting with a letter")
	}
	if existing && !control.ValidLogin(op.Login) && accountGOOS != "darwin" {
		// useradd's default NAME_REGEX (and Debian adduser's) wants a
		// leading letter or _; fleet-login-new.sh is macOS-only anyway.
		return errors.New("a login starting with a digit can only be opened on macOS, not " + accountGOOS)
	}
	if op.JoinCode != "" && (op.Op != control.AccountCreate || !joinCodeRE.MatchString(op.JoinCode)) {
		return errors.New("join_code must be fj_ + 26 base32 characters, on a create")
	}
	if self != "" && self == op.Login {
		return errors.New("refusing to touch this agent's own login")
	}
	if op.Op == control.AccountCreate && !control.ValidFullName(op.FullName) {
		return errors.New("full_name must be 1-64 printable characters")
	}
	return nil
}

// runAccountOp runs the script. Its exit status is the answer; exit 3 from
// fleet-login-new.sh is "already exists", reported as such and never as OK.
func (a *Agent) runAccountOp(op control.AccountOp) control.AccountResult {
	a.acct.run.Lock()
	defer a.acct.run.Unlock()
	res := control.AccountResult{Op: op.Op, Login: op.Login, Exit: -1}
	script, args := accountArgv(a.cfg.Home, op)
	ctx, cancel := context.WithTimeout(a.bgCtx(), accountOpTimeout)
	defer cancel()
	cmd := accountCommand(ctx, script, args...)
	// The scripts cd to / themselves; starting there too means a sudo -u in
	// them never inherits a cwd the new login cannot read.
	cmd.Dir = "/"
	cmd.Env = accountEnv(a.cfg.HubURL, op)
	var out bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &out
	err := prepCmd(ctx, cmd)
	if err == nil {
		err = cmd.Run()
	}
	res.Detail = tail(out.String(), accountDetailMax)
	var ee *exec.ExitError
	switch {
	case err == nil:
		res.OK, res.Exit = true, 0
		if op.Op == control.AccountCreate {
			res.Credsep = credsepResult(out.String())
		}
	case errors.As(err, &ee):
		res.Exit = ee.ExitCode()
		res.Exists = op.Op == control.AccountCreate && res.Exit == 3
	default:
		res.Detail = tail(err.Error()+"\n"+res.Detail, accountDetailMax)
	}
	return res
}

func tail(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[len(s)-n:]
}
