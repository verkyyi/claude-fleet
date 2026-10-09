package agent

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"os/exec"
	"regexp"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
)

// service_control (claude-fleet#2527, EPIC #2524 C3): the hub's write that
// stops / starts / restarts an entry of the machine's login-level register,
// runs a task now or gives it a new schedule. The register is root's
// (/var/db/fleet-node/logins/<login>/services/, 0700), so this is the one write
// a tenant does NOT hand to the login's fleet-control.py: the machine agent
// runs the root runtime's fleet-node-supervisor.py itself, as root, with a
// FIXED argv — `service <verb> --login <this tenant's login> --name <name>` —
// the way handleAccountOp runs its scripts. The login is never the hub's to
// name: it is the lane's own, so a write that reached the wrong lane can only
// ever touch that lane's login (and is refused when the hub said another).
// It answers at once, final: succeeded or failed, never accepted.

// serviceCtlTimeout bounds one supervisor call: it rewrites one JSON file.
const serviceCtlTimeout = 30 * time.Second

// serviceCtlPython runs the supervisor (a seam for the tests).
var serviceCtlPython = "/usr/bin/python3"

var (
	svcNameRE  = regexp.MustCompile(`^[a-z0-9][a-z0-9._-]{0,47}$`)
	svcAtRE    = regexp.MustCompile(`^([01]?[0-9]|2[0-3]):[0-5][0-9]$`)
	svcCronRE  = regexp.MustCompile(`^[0-9*,/-]+( [0-9*,/-]+){4}$`)
	svcTZRE    = regexp.MustCompile(`^[A-Za-z][A-Za-z0-9_+/-]{0,63}$`)
	svcVerbOf  = map[string]string{"start": "start", "stop": "stop", "restart": "restart", "run_now": "run", "set_schedule": "schedule"}
	errSvcArgs = errors.New("bad service_control params")
)

// serviceCtlArgv is the supervisor's argv for one service_control on login's
// register, or why not.
func serviceCtlArgv(script, login string, params map[string]any) ([]string, error) {
	str := func(k string) string { s, _ := params[k].(string); return s }
	if l := str("login"); l != "" && l != login {
		return nil, fmt.Errorf("this lane is %s's, not %s's", login, l)
	}
	name, action := str("name"), str("action")
	if !svcNameRE.MatchString(name) {
		return nil, fmt.Errorf("%w: name", errSvcArgs)
	}
	verb, ok := svcVerbOf[action]
	if !ok {
		return nil, fmt.Errorf("%w: action must be start, stop, restart, run_now or set_schedule", errSvcArgs)
	}
	argv := []string{"-I", script, "service", verb, "--login", login, "--name", name}
	if action != "set_schedule" {
		return argv, nil
	}
	at, cron, tz := str("at"), str("cron"), str("tz")
	switch {
	case (at == "") == (cron == ""):
		return nil, fmt.Errorf("%w: set_schedule needs at or cron, not both", errSvcArgs)
	case at != "" && !svcAtRE.MatchString(at):
		return nil, fmt.Errorf("%w: at must be HH:MM", errSvcArgs)
	case cron != "" && !svcCronRE.MatchString(cron):
		return nil, fmt.Errorf("%w: cron must be five fields", errSvcArgs)
	case tz != "" && !svcTZRE.MatchString(tz):
		return nil, fmt.Errorf("%w: tz", errSvcArgs)
	}
	if at != "" {
		argv = append(argv, "--at", at)
	} else {
		argv = append(argv, "--cron", cron)
	}
	if tz != "" {
		argv = append(argv, "--tz", tz)
	}
	return argv, nil
}

// serviceControlWrite answers m when it is a service_control submit and says
// so; anything else is left to the controller (false).
func (a *Agent) serviceControlWrite(ctx context.Context, conn nodeLink, m control.Message) bool {
	var req control.Request
	if json.Unmarshal(m.Payload, &req) != nil || req.Method != "submit" {
		return false
	}
	var env struct {
		OperationID string         `json:"operation_id"`
		FleetID     string         `json:"fleet_id"`
		Action      string         `json:"action"`
		Params      map[string]any `json:"params"`
	}
	if json.Unmarshal(req.Params, &env) != nil || env.Action != "service_control" {
		return false
	}
	reply := func(msg control.Message) {
		msg.OpID = m.OpID
		wctx, cancel := context.WithTimeout(ctx, nodeWriteTimeout)
		defer cancel()
		_ = conn.write(wctx, msg)
	}
	what := fmt.Sprintf("control: write service_control operation %s", env.OperationID)
	fail := func(code, msg string) {
		log.Printf("%s refused %s: %s", what, code, msg)
		reply(control.Message{Type: control.TypeError, Proto: control.Proto,
			Error: &control.Error{Code: code, Message: msg}})
	}
	if a.cfg.RunAs == nil || a.cfg.ServiceCtl == "" {
		fail("UNAVAILABLE", "service control needs the machine's node program (ccquota agent --machine, a managed machine)")
		return true
	}
	argv, err := serviceCtlArgv(a.cfg.ServiceCtl, a.cfg.RunAs.Login, env.Params)
	if err != nil {
		code := control.CodeBadArgs
		if !errors.Is(err, errSvcArgs) {
			code = control.CodeWrongLogin
		}
		fail(code, err.Error())
		return true
	}
	what += fmt.Sprintf(" %s/%s %s", a.cfg.RunAs.Login, env.Params["name"], env.Params["action"])
	status, result := runServiceCtl(a.bgCtx(), argv)
	body, _ := json.Marshal(map[string]any{"operation_id": env.OperationID, "fleet_id": env.FleetID,
		"action": env.Action, "status": status, "result": result})
	out, err := control.New(control.TypeResult, control.Result{Result: body})
	if err != nil {
		fail(control.CodeUnknownOutcome, err.Error())
		return true
	}
	log.Printf("%s: %s", what, status)
	reply(out)
	return true
}

// runServiceCtl runs the supervisor AS ROOT — deliberately not through
// prepCmd, which would drop it to the login the register refuses — and turns
// its exit into the operation's final status and result.
func runServiceCtl(ctx context.Context, argv []string) (string, map[string]any) {
	cctx, cancel := context.WithTimeout(ctx, serviceCtlTimeout)
	defer cancel()
	cmd := exec.CommandContext(cctx, serviceCtlPython, argv...)
	cmd.Dir = "/"
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	err := cmd.Run()
	said := strings.TrimSpace(stdout.String())
	if err == nil {
		return "succeeded", map[string]any{"how": "service " + argv[3], "output": tail(said, 1000),
			"observed_at": time.Now().UTC().Format(time.RFC3339)}
	}
	exit := -1
	var ee *exec.ExitError
	if errors.As(err, &ee) {
		exit = ee.ExitCode()
	}
	// the supervisor's reason is its first line; a usage text may follow
	msg, _, _ := strings.Cut(strings.TrimSpace(stderr.String()), "\n")
	if msg == "" {
		msg = err.Error()
	}
	code := "REFUSED"
	if exit == 1 && strings.Contains(msg, "is not registered") {
		code = "NOT_FOUND"
	}
	return "failed", map[string]any{"error": map[string]any{"code": code, "message": tail(msg, 1000), "exit": exit}}
}
