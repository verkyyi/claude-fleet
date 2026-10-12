package agent

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"syscall"
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
//   - only three ops (create · remove · reset, claude-fleet#3504), each one fixed argv — the hub picks the login and the
//     display name, and both must pass control.ValidCreateLogin / ValidFullName
//     (a create the hub marks existing may reuse a digit-leading login the
//     person already holds elsewhere — macOS only, claude-fleet#2105);
//   - never this agent's own login;
//   - one op at a time, each op_id at most once.
//
// The result is kept until the hub acks it and re-sent on every new
// connection, so a link that drops while sysadminctl runs loses nothing: the
// hub marked the op unknown, and this answer settles it. The book — every
// op_id seen, the op running, the results not acked — is also on disk
// (<StateDir>/account-ops.json, claude-fleet#2918), so a RESTART loses nothing
// either: the results go out again, and an op the restart cut off is answered
// with what the machine shows now. The node supervisor reads the same file and
// holds a tenant reload while an op is running.

// accountOpTimeout bounds one onboarding/offboarding script run. Opening a
// login clones claude-fleet and installs its daemons; ten minutes is generous.
const accountOpTimeout = 15 * time.Minute

// accountDetailMax is how much of the script's output travels back.
const accountDetailMax = 2000

// The scripts, relative to the admin login's claude-fleet install.
var (
	loginNewScript    = filepath.Join(".claude", "fleet", "bin", "fleet-login-new.sh")
	loginRemoveScript = filepath.Join(".claude", "fleet", "bin", "fleet-login-remove.sh")
	tccDisclaimScript = filepath.Join(".claude", "fleet", "bin", "fleet-tcc-disclaim.py")
)

// tccDisclaimPython runs fleet-tcc-disclaim.py; a test seam.
var tccDisclaimPython = "/usr/bin/python3"

// tccProbePath is the system TCC database: readable (it is 0644) only by a
// process whose responsible chain holds Full Disk Access — the one question
// tccGranted asks. A test seam, like tccProbeTimeout.
var (
	tccProbePath    = "/Library/Application Support/com.apple.TCC/TCC.db"
	tccProbeTimeout = 5 * time.Second
	tccProbing      sync.Mutex
)

// tccGranted reports whether THIS process — the responsible process of a script
// it runs undisclaimed — holds Full Disk Access: it can open and read the
// system TCC database. tccd not answering (claude-fleet#3086: the open() never
// returns) is «no» after tccProbeTimeout, and while that open is still stuck
// the next op does not start a second one. FLEET_ACCOUNT_DISCLAIM=1 always
// disclaims.
func tccGranted() bool {
	if os.Getenv("FLEET_ACCOUNT_DISCLAIM") == "1" {
		return false
	}
	if !tccProbing.TryLock() {
		return false
	}
	done := make(chan bool, 1)
	go func() {
		defer tccProbing.Unlock()
		f, err := os.Open(tccProbePath)
		if err != nil {
			done <- false
			return
		}
		defer f.Close()
		b := make([]byte, 16)
		n, err := f.Read(b)
		done <- err == nil && bytes.HasPrefix(b[:n], []byte("SQLite format 3"))
	}()
	select {
	case ok := <-done:
		return ok
	case <-time.After(tccProbeTimeout):
		return false
	}
}

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

// recycleScriptMark is what a remove script with the --recycle mode carries
// (claude-fleet#3504): the hello's CapRecycle. Without it the hub sends only
// removes here.
const recycleScriptMark = "--recycle"

// recycleCapable reports whether this login's fleet-login-remove.sh can wash
// a login for the next person (its --recycle mode).
func recycleCapable(home string) bool {
	b, err := os.ReadFile(filepath.Join(home, loginRemoveScript))
	return err == nil && bytes.Contains(b, []byte(recycleScriptMark))
}

// resetResult is AccountResult.Reset for a reset's output: the LAST
// `reset: <verdict>` line's verdict ("clean", or "dirty home,…"); "" when the
// script never said one — never read as clean.
func resetResult(out string) string {
	lines := strings.Split(strings.TrimRight(out, " \t\r\n"), "\n")
	for i := len(lines) - 1; i >= 0; i-- {
		l := strings.TrimSpace(lines[i])
		if v, ok := strings.CutPrefix(l, "reset: "); ok {
			return strings.TrimSpace(v)
		}
	}
	return ""
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
	if op.Op == control.AccountRemove || op.Op == control.AccountReset {
		keep := "--keep-home"
		if op.DropHome {
			keep = "--delete-home"
		}
		if op.Op == control.AccountReset {
			return filepath.Join(home, loginRemoveScript), []string{op.Login, "--recycle", keep, "--apply"}
		}
		return filepath.Join(home, loginRemoveScript), []string{op.Login, keep, "--apply"}
	}
	return filepath.Join(home, loginNewScript), []string{op.Login, "--full-name", op.FullName, "--share-pool", "--apply"}
}

// tccDisclaimed wraps a macOS account script so it is its OWN responsible
// process (claude-fleet#3167): run under this agent, every protected access the
// script tree made was charged to ccquota — a new, ungranted identity on every
// release — so tccd put a dialog on the console that nobody answered, and the
// stuck dialog wedged sandboxd until every user delete on the machine failed.
// Disclaimed, the responsible process is /bin/bash, a platform binary tccd
// never prompts for: the access is refused at once instead. A login whose
// install predates the wrapper runs the script as before.
//
// Once a person has granted this agent Full Disk Access (claude-fleet#3433: the
// updater signs every release's ccquota with the machine's ONE fixed identity
// and the admin agent runs it from one path, so the grant survives a version
// switch), the script runs as this agent's own child instead: its accesses are
// charged to the granted identity and succeed — sysadminctl -deleteUser, dscl —
// and Full Disk Access covers the SystemPolicy services sysadminctl asks for, so
// nothing can prompt. tccGranted is asked before every op: a grant taken back
// sends the next one through the wrapper again.
func tccDisclaimed(home, script string, args []string) (string, []string) {
	if accountGOOS != "darwin" {
		return script, args
	}
	if tccGranted() {
		return script, args
	}
	w := filepath.Join(home, tccDisclaimScript)
	if _, err := os.Stat(w); err != nil {
		return script, args
	}
	return tccDisclaimPython, append([]string{"-I", w, "--", script}, args...)
}

// accountEnv is the create's join code and this hub's address, handed to
// fleet-login-new.sh in its environment, never its argv (claude-fleet#2652),
// and its op_id (claude-fleet#2928: the script marks the login it makes as this
// op's): a script that predates them ignores them. nil = the agent's own
// environment.
func accountEnv(hub, opID string, op control.AccountOp) []string {
	if op.Op != control.AccountCreate && op.Op != control.AccountReset {
		return nil // a reset re-joins the washed login with its own code
	}
	var env []string
	if op.JoinCode != "" && hub != "" {
		env = append(env, "FLEET_LOGIN_JOIN_CODE="+op.JoinCode, "FLEET_LOGIN_HUB="+hub)
	}
	if opIDRE.MatchString(opID) {
		env = append(env, "FLEET_LOGIN_OP_ID="+opID)
	}
	if env == nil {
		return nil
	}
	return append(os.Environ(), env...)
}

// opIDRE is an op_id the script takes (control.NewOpID's hex).
var opIDRE = regexp.MustCompile(`^[0-9a-f]{1,64}$`)

// accountOpsFile is the book's name under the agent's StateDir. Its
// "inflight" key is what bin/fleet-node-supervisor.py reads (#2918): keep it.
const accountOpsFile = "account-ops.json"

// accountInflight is one op running now: what it is, never its join code.
type accountInflight struct {
	Op      string `json:"op"`
	Login   string `json:"login"`
	Started string `json:"started"`
	PID     int    `json:"pid"`
}

// accountBook is the file's shape.
type accountBook struct {
	Seen     []string                   `json:"seen,omitempty"`
	Inflight map[string]accountInflight `json:"inflight,omitempty"`
	Outbox   map[string]control.Message `json:"outbox,omitempty"`
}

// accountLoginExists is how a cut-off op reads the machine; a test seam.
var accountLoginExists = func(login string) bool {
	_, err := user.Lookup(login)
	return err == nil
}

// accountOps is the admin agent's state across connections.
type accountOps struct {
	mu sync.Mutex
	// path is the book on disk; "" keeps it in memory only.
	path string
	// home is the admin login's home, where fleet-login-new.sh leaves
	// ~/<login>-onboard/op (claude-fleet#2928); "" reads no mark.
	home string
	// owns says the login was made by this op's own run (Agent.ownsCreate);
	// nil = a restart's cut-off creates are never resumed.
	owns     func(login, opID string) bool
	inflight map[string]accountInflight
	// seen is every op_id ever accepted, so a duplicate send never runs the
	// script twice (bounded: oldest forgotten past seenMax).
	seen  map[string]bool
	order []string
	// outbox holds results the hub has not acked yet, by op_id.
	outbox map[string]control.Message
	// resume is the creates a restart cut off whose login the op's own run
	// made (claude-fleet#2928): settled from its mark (resumeAccountOps), not
	// answered as cut off.
	resume map[string]accountInflight
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
	if _, ok := o.outbox[opID]; ok {
		delete(o.outbox, opID)
		o.saveLocked()
	}
	o.mu.Unlock()
}

func (o *accountOps) initLocked() {
	if o.seen == nil {
		o.seen, o.outbox = map[string]bool{}, map[string]control.Message{}
	}
	if o.inflight == nil {
		o.inflight = map[string]accountInflight{}
	}
}

// claim records opID as running op; false when it was already accepted once.
func (o *accountOps) claim(opID string, op control.AccountOp) bool {
	o.mu.Lock()
	defer o.mu.Unlock()
	o.initLocked()
	if o.seen[opID] {
		return false
	}
	o.seen[opID] = true
	o.order = append(o.order, opID)
	if len(o.order) > seenMax {
		delete(o.seen, o.order[0])
		o.order = o.order[1:]
	}
	o.inflight[opID] = accountInflight{Op: op.Op, Login: op.Login,
		Started: time.Now().UTC().Format(time.RFC3339), PID: os.Getpid()}
	o.saveLocked()
	return true
}

func (o *accountOps) deliver(m control.Message) {
	o.mu.Lock()
	o.initLocked()
	o.outbox[m.OpID] = m
	delete(o.inflight, m.OpID)
	o.saveLocked()
	send := o.send
	o.mu.Unlock()
	if send != nil {
		_ = send(m) // on failure it stays in the outbox for the next session
	}
}

// saveLocked writes the book whole by one rename (root 0600: it names
// logins). A failed write keeps the memory copy; the next change tries again.
func (o *accountOps) saveLocked() {
	if o.path == "" {
		return
	}
	b := accountBook{Seen: o.order, Inflight: o.inflight, Outbox: o.outbox}
	data, err := json.Marshal(b)
	if err != nil {
		return
	}
	if err := os.MkdirAll(filepath.Dir(o.path), 0o700); err != nil {
		log.Printf("account ops: %v", err)
		return
	}
	tmp := o.path + ".tmp"
	if err := os.WriteFile(tmp, append(data, '\n'), 0o600); err != nil {
		log.Printf("account ops: %v", err)
		return
	}
	if err := os.Rename(tmp, o.path); err != nil {
		log.Printf("account ops: %v", err)
	}
}

// load reads the book at path and keeps writing it there. An op still marked
// running was cut off — this process is new, so whatever ran it is gone — and
// is answered now with what the machine shows (claude-fleet#2918): a remove
// whose login is gone is done; anything else failed, saying whether the login
// exists, so the hub never waits on it.
func (o *accountOps) load(path string) {
	o.mu.Lock()
	defer o.mu.Unlock()
	o.initLocked()
	o.path = path
	var b accountBook
	if data, err := os.ReadFile(path); err == nil {
		if err := json.Unmarshal(data, &b); err != nil {
			log.Printf("account ops: %s: %v (starting a new book)", path, err)
			b = accountBook{}
		}
	}
	for _, id := range b.Seen {
		if !o.seen[id] {
			o.seen[id] = true
			o.order = append(o.order, id)
		}
	}
	for id, m := range b.Outbox {
		o.outbox[id] = m
	}
	for id, f := range b.Inflight {
		if _, done := o.outbox[id]; done {
			continue
		}
		exists := accountLoginExists(f.Login)
		if f.Op == control.AccountCreate && exists && o.ownsLocked() != nil {
			if o.ownsLocked()(f.Login, id) {
				// its own run made the login: finished, still running or
				// stopped — the mark says which (claude-fleet#2928)
				if o.resume == nil {
					o.resume = map[string]accountInflight{}
				}
				f.PID = os.Getpid() // this process settles it now: the supervisor holds for it
				o.inflight[id] = f
				o.resume[id] = f
				if !o.seen[id] {
					o.seen[id] = true
					o.order = append(o.order, id)
				}
				log.Printf("account ops: %s %s (op %s) was cut off by a restart; its own run made the login — settling it now",
					f.Op, f.Login, id)
				continue
			}
		}
		res := cutOffResult(f, exists)
		m, err := control.New(control.TypeAccountResult, res)
		if err != nil {
			continue
		}
		m.OpID = id
		if !o.seen[id] {
			o.seen[id] = true
			o.order = append(o.order, id)
		}
		o.outbox[id] = m
		log.Printf("account ops: %s %s (op %s) was cut off by a restart; answering exit=%d", f.Op, f.Login, id, res.Exit)
	}
	o.saveLocked()
}

// ownsLocked is o.owns, else — with a home — fleet-login-new.sh's mark there.
func (o *accountOps) ownsLocked() func(login, opID string) bool {
	if o.owns != nil || o.home == "" {
		return o.owns
	}
	home := o.home
	return func(login, opID string) bool {
		mk, ok := readOpMark(home, login)
		return ok && mk.op == opID
	}
}

// cutOffResult is the answer to an op the agent's restart cut off.
func cutOffResult(f accountInflight, exists bool) control.AccountResult {
	res := control.AccountResult{Op: f.Op, Login: f.Login, Exit: -1}
	why := "the node agent (pid " + strconv.Itoa(f.PID) + ") stopped while this op ran (started " + f.Started + "); "
	switch {
	case (f.Op == control.AccountRemove || f.Op == control.AccountReset) && !exists:
		res.Exit = control.RemoveExitNoLogin
		res.Detail = why + "the login is gone from this machine"
	case exists:
		res.Detail = why + "the login exists on this machine but may be half made — check it, then adopt, retry or remove it"
	default:
		res.Detail = why + "no such login on this machine: nothing was made"
	}
	return res
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
	if err := a.validAccountOp(op); err != nil {
		log.Printf("control channel: refused account op %s: %v", m.OpID, err)
		refuse(control.CodeBadArgs, err.Error())
		return
	}
	if !a.acct.claim(m.OpID, op) {
		return // already running or done; its result is (or will be) in the outbox
	}
	go func() {
		res := a.runAccountOp(m.OpID, op)
		out, err := control.New(control.TypeAccountResult, res)
		if err != nil {
			return
		}
		out.OpID = m.OpID
		if res.OK {
			log.Printf("control channel: account op %s %s: ok=%v exit=%d", op.Op, op.Login, res.OK, res.Exit)
		} else {
			// What the script last said (claude-fleet#2953): 18 failed removes on
			// mini2 left only «exit=1» here, and the why was on the hub alone.
			log.Printf("control channel: account op %s %s: ok=%v exit=%d: %s", op.Op, op.Login, res.OK, res.Exit, accountWhy(res.Detail))
		}
		a.acct.deliver(out)
	}()
}

var joinCodeRE = regexp.MustCompile(`^fj_[a-z2-7]{26}$`)

// validAccountOp is the whitelist this agent holds an op to: an admin
// login's, or — on a Linux managed machine — its root node program's
// (claude-fleet#3210).
func (a *Agent) validAccountOp(op control.AccountOp) error {
	if a.cfg.LinuxOpener != "" {
		return validateLinuxAccountOp(op, a.cfg.ServiceLogin)
	}
	return validateAccountOp(op, a.osLogin())
}

func validateAccountOp(op control.AccountOp, self string) error {
	if op.Op != control.AccountCreate && op.Op != control.AccountRemove && op.Op != control.AccountReset {
		return errors.New("op must be create, remove or reset")
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
	if op.JoinCode != "" && (op.Op == control.AccountRemove || !joinCodeRE.MatchString(op.JoinCode)) {
		return errors.New("join_code must be fj_ + 26 base32 characters, on a create or a reset")
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
// fleet-login-new.sh is "already exists", reported as such and never as OK —
// unless the login is this very op's (claude-fleet#2928): the same op_id
// arriving again (a re-ask, a restart that lost the book) is answered from
// the mark its first run left, never by running the script a second time. A
// create that fails after its run made the login takes the login back
// (rollbackOwnCreate), so a failed op never leaves a live login behind.
func (a *Agent) runAccountOp(opID string, op control.AccountOp) control.AccountResult {
	a.acct.run.Lock()
	defer a.acct.run.Unlock()
	ctx, cancel := context.WithTimeout(a.bgCtx(), accountOpTimeout)
	defer cancel()
	if op.Op == control.AccountCreate {
		if res, ok := a.settleOwnCreate(ctx, opID, op.Login); ok {
			return res
		}
	}
	res := a.runAccountScript(ctx, opID, op)
	if op.Op == control.AccountCreate && !res.OK && !res.Exists && accountLoginExists(op.Login) &&
		a.ownsCreate(op.Login, opID) {
		res = a.rollbackOwnCreate(ctx, op.Login, res)
	}
	return res
}

// ownsCreate says login was made by op opID's own run: the mark
// fleet-login-new.sh leaves (claude-fleet#2928), or on a Linux managed machine
// the op fleet-node-linux.py wrote into the login's declaration
// (claude-fleet#3210).
func (a *Agent) ownsCreate(login, opID string) bool {
	if opID == "" {
		return false
	}
	if a.cfg.LinuxOpener != "" {
		return linuxDeclaredOp(a.cfg.LinuxTenants, login) == opID
	}
	mk, ok := readOpMark(a.cfg.Home, login)
	return ok && mk.op == opID
}

// runAccountScript runs op's script once and reads its exit.
func (a *Agent) runAccountScript(ctx context.Context, opID string, op control.AccountOp) control.AccountResult {
	res := control.AccountResult{Op: op.Op, Login: op.Login, Exit: -1}
	if op.Op == control.AccountRemove || op.Op == control.AccountReset {
		defer holdLogin(op.Login)()
	}
	script, args := accountArgv(a.cfg.Home, op)
	if a.cfg.LinuxOpener != "" {
		script, args = linuxAccountArgv(a.cfg.LinuxOpener, op)
	} else {
		script, args = tccDisclaimed(a.cfg.Home, script, args)
	}
	cmd := accountCommand(ctx, script, args...)
	// The scripts cd to / themselves; starting there too means a sudo -u in
	// them never inherits a cwd the new login cannot read.
	cmd.Dir = "/"
	cmd.Env = accountEnv(a.cfg.HubURL, opID, op)
	var out bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &out
	var err error
	if a.cfg.LinuxOpener == "" {
		err = prepCmd(ctx, cmd)
	}
	// else: the Linux opener runs as root by design — it is the one command
	// that makes and deletes OS users, and its argv is linuxAccountArgv's
	// (claude-fleet#3210); nothing else on the machine half runs as root.
	if err == nil {
		err = cmd.Run()
	}
	res.Detail = tail(out.String(), accountDetailMax)
	var ee *exec.ExitError
	switch {
	case err == nil:
		res.OK, res.Exit = true, 0
		if op.Op == control.AccountCreate || op.Op == control.AccountReset {
			res.Credsep = credsepResult(out.String())
		}
		if op.Op == control.AccountReset {
			res.Reset = resetResult(out.String())
		}
	case errors.As(err, &ee):
		res.Exit = ee.ExitCode()
		res.Exists = op.Op == control.AccountCreate && res.Exit == 3
	default:
		res.Detail = tail(err.Error()+"\n"+res.Detail, accountDetailMax)
	}
	return res
}

// opMark is ~<admin>/<login>-onboard/op, as fleet-login-new.sh writes it
// (claude-fleet#2928): op= pid= started= before step 1, done= and the result's
// line= rows (credsep last) when the run ended well.
type opMark struct {
	op, started, done string
	pid               int
	lines             []string
}

func opMarkPath(home, login string) string {
	return filepath.Join(home, login+"-onboard", "op")
}

// readOpMark reads login's mark; false when there is none.
func readOpMark(home, login string) (opMark, bool) {
	var mk opMark
	data, err := os.ReadFile(opMarkPath(home, login))
	if err != nil {
		return mk, false
	}
	for _, l := range strings.Split(string(data), "\n") {
		k, v, ok := strings.Cut(l, "=")
		if !ok {
			continue
		}
		switch k {
		case "op":
			mk.op = v
		case "pid":
			mk.pid, _ = strconv.Atoi(v)
		case "started":
			mk.started = v
		case "done":
			mk.done = v
		case "line":
			mk.lines = append(mk.lines, v)
		}
	}
	return mk, mk.op != ""
}

// accountPIDAlive says whether the run that wrote a mark still runs; a test seam.
var accountPIDAlive = func(pid int) bool {
	if pid <= 0 {
		return false
	}
	p, err := os.FindProcess(pid)
	if err != nil {
		return false
	}
	err = p.Signal(syscall.Signal(0))
	return err == nil || errors.Is(err, syscall.EPERM)
}

// accountMarkPoll is how often a run still going is looked at again.
var accountMarkPoll = 2 * time.Second

// settleOwnCreate answers a create whose login exists and whose mark names
// opID — this op's own run made it: finished ⇒ its result; still running ⇒
// waited for (up to ctx); stopped half way ⇒ rolled back. false when the login
// is not this op's (none there, no mark, another op's): the script decides.
func (a *Agent) settleOwnCreate(ctx context.Context, opID, login string) (control.AccountResult, bool) {
	if a.cfg.LinuxOpener != "" {
		// fleet-node-linux.py login open is idempotent under its own op:
		// running it again settles it (claude-fleet#3210).
		return control.AccountResult{}, false
	}
	if a.cfg.Home == "" || !accountLoginExists(login) {
		return control.AccountResult{}, false
	}
	mk, ok := readOpMark(a.cfg.Home, login)
	if !ok || mk.op != opID {
		return control.AccountResult{}, false
	}
	res := control.AccountResult{Op: control.AccountCreate, Login: login, Exit: -1}
	for mk.done == "" && accountPIDAlive(mk.pid) {
		select {
		case <-ctx.Done():
			res.Detail = fmt.Sprintf("this op's own run (pid %d, started %s) is still opening %s after %s; ask again later",
				mk.pid, mk.started, login, accountOpTimeout)
			return res, true
		case <-time.After(accountMarkPoll):
		}
		if mk, ok = readOpMark(a.cfg.Home, login); !ok || mk.op != opID {
			return control.AccountResult{}, false
		}
	}
	if mk.done != "" {
		res.OK, res.Exit = true, 0
		res.Detail = tail(fmt.Sprintf("login %s was opened by this op's own run (started %s, finished %s); answering its result\n%s",
			login, mk.started, mk.done, strings.Join(mk.lines, "\n")), accountDetailMax)
		res.Credsep = credsepResult(res.Detail)
		log.Printf("account ops: create %s (op %s) arrived again: answered from its first run, not run twice", login, opID)
		return res, true
	}
	res.Detail = fmt.Sprintf("this op's own run (pid %d, started %s) made login %s and stopped before the end", mk.pid, mk.started, login)
	return a.rollbackOwnCreate(ctx, login, res), true
}

// rollbackOwnCreate takes back a login this op made and failed to finish
// (claude-fleet#2928): a failed create never leaves a live login with running
// services behind. Its home is kept (archived by fleet-login-remove.sh). The
// result stays a failure, saying what was done.
func (a *Agent) rollbackOwnCreate(ctx context.Context, login string, res control.AccountResult) control.AccountResult {
	// On a Linux managed machine the half-made login's home goes with it
	// (claude-fleet#3210): nothing in it was ever the person's.
	rm := a.runAccountScript(ctx, "", control.AccountOp{Op: control.AccountRemove, Login: login,
		DropHome: a.cfg.LinuxOpener != ""})
	verdict := "rolled back: login " + login + " removed (home kept)"
	if !rm.OK && rm.Exit != control.RemoveExitNoLogin {
		verdict = fmt.Sprintf("rollback FAILED (fleet-login-remove exit %d): login %s is still on this machine — remove it: %s",
			rm.Exit, login, lastLine(rm.Detail))
	}
	log.Printf("account ops: create %s failed after making the login: %s", login, verdict)
	res.OK, res.Exists, res.Credsep = false, false, ""
	res.Detail = tail(res.Detail+"\n"+verdict, accountDetailMax)
	return res
}

// resumeAccountOps settles the creates load() kept for it (claude-fleet#2928).
func (a *Agent) resumeAccountOps() {
	a.acct.mu.Lock()
	todo := a.acct.resume
	a.acct.resume = nil
	a.acct.mu.Unlock()
	for id, f := range todo {
		var res control.AccountResult
		if a.cfg.LinuxOpener != "" {
			// The opener is idempotent under its own op: run it again —
			// without the join code, which the book never keeps; a login
			// that enrolled before the cut goes on, one that did not fails
			// and is rolled back (claude-fleet#3210).
			res = a.runAccountOp(id, control.AccountOp{Op: control.AccountCreate, Login: f.Login})
		} else {
			a.acct.run.Lock()
			ctx, cancel := context.WithTimeout(a.bgCtx(), accountOpTimeout)
			var ok bool
			res, ok = a.settleOwnCreate(ctx, id, f.Login)
			cancel()
			a.acct.run.Unlock()
			if !ok {
				res = cutOffResult(f, accountLoginExists(f.Login))
			}
		}
		out, err := control.New(control.TypeAccountResult, res)
		if err != nil {
			continue
		}
		out.OpID = id
		log.Printf("account ops: %s %s (op %s) settled after the restart: ok=%v exit=%d", f.Op, f.Login, id, res.OK, res.Exit)
		a.acct.deliver(out)
	}
}

// accountWhy is a failed op's last words for the node's log: its last three
// non-empty lines, joined, at most 600 bytes.
func accountWhy(detail string) string {
	var keep []string
	lines := strings.Split(detail, "\n")
	for i := len(lines) - 1; i >= 0 && len(keep) < 3; i-- {
		if l := strings.TrimSpace(lines[i]); l != "" {
			keep = append([]string{l}, keep...)
		}
	}
	if len(keep) == 0 {
		return "(no output)"
	}
	return tail(strings.Join(keep, " | "), 600)
}

func tail(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[len(s)-n:]
}
