package agent

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os/exec"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/schedule"
)

// The hub cannot choose a Unix account or an executable. Only this control
// lane's login is passed to the supervisor, with a bounded JSON body on stdin.
func (a *Agent) scheduleWrite(ctx context.Context, conn nodeLink, m control.Message) bool {
	var req control.Request
	if json.Unmarshal(m.Payload, &req) != nil || req.Method != "submit" {
		return false
	}
	var env struct {
		OperationID string `json:"operation_id"`
		FleetID     string `json:"fleet_id"`
		Action      string `json:"action"`
		Params      struct {
			Login    string        `json:"login"`
			Action   string        `json:"action"`
			Schedule schedule.Spec `json:"schedule"`
			RunID    string        `json:"run_id,omitempty"`
		} `json:"params"`
	}
	if json.Unmarshal(req.Params, &env) != nil || env.Action != "schedule_control" {
		return false
	}
	status := "failed"
	result := map[string]any{}
	fail := func(e error) { result["error"] = map[string]string{"code": "REFUSED", "message": e.Error()} }
	switch {
	case a.cfg.RunAs == nil || a.cfg.ServiceCtl == "":
		fail(fmt.Errorf("schedule control requires a managed runtime"))
	case env.Params.Login != a.cfg.RunAs.Login:
		fail(fmt.Errorf("wrong login"))
	case env.Params.Action != "apply" && env.Params.Action != "run-now":
		fail(fmt.Errorf("unknown schedule action"))
	default:
		if _, err := schedule.Validate(env.Params.Schedule); err != nil {
			fail(err)
		} else {
			body, _ := json.Marshal(map[string]any{"action": env.Params.Action, "schedule": env.Params.Schedule, "run_id": env.Params.RunID})
			cctx, cancel := context.WithTimeout(a.bgCtx(), 30*time.Second)
			cmd := exec.CommandContext(cctx, serviceCtlPython, "-I", a.cfg.ServiceCtl, "schedule", "--login", a.cfg.RunAs.Login)
			cmd.Dir = "/"
			cmd.Stdin = bytes.NewReader(body)
			var stdout, stderr bytes.Buffer
			cmd.Stdout = &stdout
			cmd.Stderr = &stderr
			err := cmd.Run()
			cancel()
			if err != nil {
				fail(fmt.Errorf("%s", tail(stderr.String(), 1000)))
			} else if json.Unmarshal(stdout.Bytes(), &result) != nil {
				fail(fmt.Errorf("invalid supervisor response"))
			} else {
				status = "succeeded"
			}
		}
	}
	body, _ := json.Marshal(map[string]any{"operation_id": env.OperationID, "fleet_id": env.FleetID, "action": env.Action, "status": status, "result": result})
	out, _ := control.New(control.TypeResult, control.Result{Result: body})
	out.OpID = m.OpID
	cctx, cancel := context.WithTimeout(ctx, nodeWriteTimeout)
	defer cancel()
	_ = conn.write(cctx, out)
	return true
}
