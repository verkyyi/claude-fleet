package agent

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"log"
	"os/exec"
	"os/user"
	"path/filepath"
	"sync"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

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
//     display name, and both must pass control.ValidLogin / ValidFullName;
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

// accountCommand is the injection point for tests.
var accountCommand = exec.CommandContext

// accountArgv is the ONE place the argv of an account op is decided.
func accountArgv(home string, op control.AccountOp) (string, []string) {
	if op.Op == control.AccountRemove {
		return filepath.Join(home, loginRemoveScript), []string{op.Login, "--keep-home", "--apply"}
	}
	return filepath.Join(home, loginNewScript), []string{op.Login, "--full-name", op.FullName, "--share-pool", "--apply"}
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
func (a *Agent) handleAccountOp(ctx context.Context, conn *websocket.Conn, m control.Message) {
	refuse := func(code, msg string) {
		e := control.Message{Type: control.TypeError, OpID: m.OpID, Proto: control.Proto,
			Error: &control.Error{Code: code, Message: msg}}
		wctx, cancel := context.WithTimeout(ctx, nodeWriteTimeout)
		defer cancel()
		_ = wsjson.Write(wctx, conn, e)
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
	if err := validateAccountOp(op); err != nil {
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

func validateAccountOp(op control.AccountOp) error {
	if op.Op != control.AccountCreate && op.Op != control.AccountRemove {
		return errors.New("op must be create or remove")
	}
	if !control.ValidLogin(op.Login) {
		return errors.New("login is not 2-16 lowercase letters and digits starting with a letter")
	}
	if u, err := user.Current(); err == nil && u.Username == op.Login {
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
	ctx, cancel := context.WithTimeout(context.Background(), accountOpTimeout)
	defer cancel()
	cmd := accountCommand(ctx, script, args...)
	// The scripts cd to / themselves; starting there too means a sudo -u in
	// them never inherits a cwd the new login cannot read.
	cmd.Dir = "/"
	var out bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &out
	err := cmd.Run()
	res.Detail = tail(out.String(), accountDetailMax)
	var ee *exec.ExitError
	switch {
	case err == nil:
		res.OK, res.Exit = true, 0
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
