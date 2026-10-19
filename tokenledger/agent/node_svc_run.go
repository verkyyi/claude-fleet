package agent

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

// A service run on this login (claude-fleet#4086).
//
// A service login (CCQUOTA_FLEET_SVC=1 in its env file — root's decision, never
// the hub's) lists CapSvcRun, and the hub hands it one attempt at a time:
// TypeSvcRun {run, attempt, deadline, token}. The agent starts the login's own
// bin/fleet-svc-local.sh as the login, in a process group of its own, the key on
// its stdin and nowhere else (not the argv, not the environment), answers
// {ok} at once and lets the run hand its result in itself over the hub's HTTP
// road. It holds each attempt's process: past the deadline (+ a grace for the
// hand-in) or on TypeSvcRunCancel the group is killed and `fleet-svc-local.sh
// clean R<n> <k>` removes what the attempt left. A run outlives the control
// link that started it: a dropped link is not a cancel.

// svcLocalScript is the runner wrapper in a login's install.
var svcLocalScript = filepath.Join(".claude", "fleet", "bin", "fleet-svc-local.sh")

// svcRunGrace is how long past its deadline an attempt may take to hand in.
const svcRunGrace = 2 * time.Minute

var (
	svcRunRE   = regexp.MustCompile(`^R[0-9]{1,12}$`)
	svcTokenRE = regexp.MustCompile(`^fsj_[a-z2-7]{52}$`)
)

// svcRunTable is this login's attempts still running, by "R<n>/<k>".
type svcRunTable struct {
	mu   sync.Mutex
	runs map[string]*svcRunProc
}

type svcRunProc struct {
	cmd  *exec.Cmd
	stop chan struct{} // closed by a cancel
	once sync.Once
}

func (t *svcRunTable) add(key string, p *svcRunProc) bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.runs == nil {
		t.runs = map[string]*svcRunProc{}
	}
	if t.runs[key] != nil {
		return false
	}
	t.runs[key] = p
	return true
}

func (t *svcRunTable) get(key string) *svcRunProc {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.runs[key]
}

func (t *svcRunTable) drop(key string) {
	t.mu.Lock()
	defer t.mu.Unlock()
	delete(t.runs, key)
}

func (t *svcRunTable) count() int {
	t.mu.Lock()
	defer t.mu.Unlock()
	return len(t.runs)
}

// svcScript is the wrapper's path; "" when this login has none.
func (a *Agent) svcScript() string {
	if a.cfg.Home == "" {
		return ""
	}
	p := filepath.Join(a.cfg.Home, svcLocalScript)
	if fi, err := os.Stat(p); err != nil || fi.IsDir() {
		return ""
	}
	return p
}

// svcRunCapable: this login is a service login with the runner installed.
func (a *Agent) svcRunCapable() bool { return a.cfg.FleetSvc && a.svcScript() != "" }

func svcReply(ctx context.Context, conn nodeLink, opID string, ack control.SvcRunAck) {
	msg, err := control.New(control.TypeResult, ack)
	if err != nil {
		return
	}
	msg.OpID = opID
	wctx, cancel := context.WithTimeout(ctx, nodeWriteTimeout)
	defer cancel()
	_ = conn.write(wctx, msg)
}

// answerSvcRun serves one TypeSvcRun.
func (a *Agent) answerSvcRun(ctx context.Context, conn nodeLink, m control.Message) {
	no := func(why string) {
		log.Printf("svc run: refused: %s", why)
		svcReply(ctx, conn, m.OpID, control.SvcRunAck{Line: why})
	}
	if !a.svcRunCapable() {
		no("this login is no service login")
		return
	}
	var req control.SvcRunStart
	if err := json.Unmarshal(m.Payload, &req); err != nil || m.OpID == "" || !svcRunRE.MatchString(req.Run) ||
		req.Attempt < 1 || req.Attempt > 9 || req.Deadline < 60 || req.Deadline > 3600 || !svcTokenRE.MatchString(req.Token) {
		no("malformed svc_run")
		return
	}
	key := req.Run + "/" + strconv.Itoa(req.Attempt)
	// bound to the agent, not this link: a dropped link is not a cancel
	rctx := context.WithoutCancel(ctx)
	cmd := exec.Command(a.svcScript(), "run")
	cmd.Env = append(os.Environ(), "FLEET_SVC_RUN="+req.Run, "FLEET_SVC_ATTEMPT="+strconv.Itoa(req.Attempt),
		"FLEET_SVC_DEADLINE="+strconv.Itoa(req.Deadline), "FLEET_SVC_HUB="+a.cfg.hub(), "FLEET_SVC_CENTRAL="+a.cfg.hub())
	cmd.Stdin = strings.NewReader(req.Token + "\n")
	if err := prepCmd(rctx, cmd); err != nil {
		no("cannot run as this login: " + err.Error())
		return
	}
	setOwnGroup(cmd)
	p := &svcRunProc{cmd: cmd, stop: make(chan struct{})}
	if !a.svcRuns.add(key, p) {
		no(key + " is running here already")
		return
	}
	if err := cmd.Start(); err != nil {
		a.svcRuns.drop(key)
		no("start: " + startWhy(rctx, cmd, err).Error())
		return
	}
	log.Printf("svc run %s: started (deadline %ds)", key, req.Deadline)
	svcReply(ctx, conn, m.OpID, control.SvcRunAck{OK: true})
	go a.svcWatch(rctx, key, req, p, time.Duration(req.Deadline)*time.Second+svcRunGrace)
}

// svcWatch waits the attempt out: its end, its deadline or a cancel. A kill is
// followed by the wrapper's clean, as the login.
func (a *Agent) svcWatch(ctx context.Context, key string, req control.SvcRunStart, p *svcRunProc, limit time.Duration) {
	defer a.svcRuns.drop(key)
	done := make(chan error, 1)
	go func() { done <- p.cmd.Wait() }()
	t := time.NewTimer(limit)
	defer t.Stop()
	why := ""
	select {
	case err := <-done:
		log.Printf("svc run %s: ended (%v)", key, exitWord(err))
		return
	case <-t.C:
		why = "past its deadline"
	case <-p.stop:
		why = "cancelled"
	}
	killGroup(p.cmd)
	<-done
	cctx, cancel := context.WithTimeout(ctx, time.Minute)
	defer cancel()
	clean := exec.CommandContext(cctx, a.svcScript(), "clean", req.Run, strconv.Itoa(req.Attempt))
	err := prepCmd(cctx, clean)
	if err == nil {
		err = clean.Run()
	}
	log.Printf("svc run %s: %s — killed, clean: %v", key, why, exitWord(err))
}

// answerSvcRunCancel serves one TypeSvcRunCancel: an attempt not running here
// is already stopped.
func (a *Agent) answerSvcRunCancel(ctx context.Context, conn nodeLink, m control.Message) {
	var req control.SvcRunCancel
	if err := json.Unmarshal(m.Payload, &req); err != nil || !svcRunRE.MatchString(req.Run) || req.Attempt < 1 || req.Attempt > 9 {
		svcReply(ctx, conn, m.OpID, control.SvcRunAck{Line: "malformed svc_run_cancel"})
		return
	}
	if p := a.svcRuns.get(req.Run + "/" + strconv.Itoa(req.Attempt)); p != nil {
		p.once.Do(func() { close(p.stop) })
	}
	svcReply(ctx, conn, m.OpID, control.SvcRunAck{OK: true})
}

func exitWord(err error) string {
	if err == nil {
		return "exit 0"
	}
	if ee, ok := err.(*exec.ExitError); ok {
		return fmt.Sprintf("exit %d", ee.ExitCode())
	}
	return err.Error()
}
