package agent

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
)

// The compute switch and the probe, read live (claude-fleet#1720).
//
// `fleet node compute on|off` rewrites node.env's CCQUOTA_FLEET_COMPUTE (and
// CCQUOTA_FLEET_COMPUTE_FORCE) and bin/fleet-node-probe.sh rewrites
// node-probe.json; the agent re-reads both on every hello and beat, so neither
// needs the agent restarted. A node.env the agent cannot read keeps the
// start-time reading (Config.FleetComputeOff) — exactly #1719's behaviour.

// defaultConfPath is name under the default claude-fleet conf dir.
func defaultConfPath(home, name string) string {
	return filepath.Join(home, ".config", "claude-fleet", name)
}

// nodeEnv reads node.env's KEY=value lines; ok false when it is unreadable.
func (a *Agent) nodeEnv() (map[string]string, bool) {
	if a.cfg.FleetNodeEnvPath == "" {
		return nil, false
	}
	f, err := os.Open(a.cfg.FleetNodeEnvPath)
	if err != nil {
		return nil, false
	}
	defer f.Close()
	env := map[string]string{}
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		if k, v, ok := strings.Cut(strings.TrimSpace(sc.Text()), "="); ok && !strings.HasPrefix(k, "#") {
			env[strings.TrimPrefix(k, "export ")] = strings.Trim(v, `"'`)
		}
	}
	return env, true
}

// computeOffNow is this login's own word on compute: node.env's line when the
// file is readable (no line = on, a node from before #1719), else the
// start-time setting.
func (a *Agent) computeOffNow() bool {
	if env, ok := a.nodeEnv(); ok {
		return env["CCQUOTA_FLEET_COMPUTE"] == "0"
	}
	return a.cfg.FleetComputeOff
}

// computeClaim is the hello's and heartbeat's Compute (claude-fleet#1719):
// an explicit false when this login only coordinates, else nil — exactly what
// an agent older than #1719 sends.
func (a *Agent) computeClaim() *bool {
	if !a.computeOffNow() {
		return nil
	}
	off := false
	return &off
}

// computeForce is `fleet node compute on --force` (claude-fleet#1720).
func (a *Agent) computeForce() bool {
	env, ok := a.nodeEnv()
	return ok && env["CCQUOTA_FLEET_COMPUTE_FORCE"] == "1" && env["CCQUOTA_FLEET_COMPUTE"] != "0"
}

// nodeProbe is node-probe.json, nil when the probe never ran here (or wrote
// something unreadable): the hub then judges the login as before #1720.
func (a *Agent) nodeProbe() *control.NodeProbe {
	if a.cfg.FleetProbePath == "" {
		return nil
	}
	b, err := os.ReadFile(a.cfg.FleetProbePath)
	if err != nil {
		return nil
	}
	var p control.NodeProbe
	if json.Unmarshal(b, &p) != nil || p.Verdict == "" {
		return nil
	}
	return &p
}

// The daily probe (claude-fleet#1720): the agent runs on every node however it
// was installed, so it is what re-probes — once node-probe.json is a day old
// (or missing), it runs bin/fleet-node-probe.sh from the full install or the
// client install, and the next beat carries the new verdict. A machine that
// moved to an unsupported region is closed by the hub within a day of the move.
const (
	probeEvery   = 24 * time.Hour
	probeCheck   = time.Hour
	probeTimeout = 2 * time.Minute
)

// probeScripts are where bin/fleet-node-probe.sh lives: the node install
// (~/.claude/fleet) first, then the client install (~/.local/share/claude-fleet).
var probeScripts = []string{
	filepath.Join(".claude", "fleet", "bin", "fleet-node-probe.sh"),
	filepath.Join(".local", "share", "claude-fleet", "bin", "fleet-node-probe.sh"),
}

func (a *Agent) probeScript() string {
	for _, rel := range probeScripts {
		p := filepath.Join(a.cfg.Home, rel)
		if st, err := os.Stat(p); err == nil && !st.IsDir() {
			return p
		}
	}
	return ""
}

// probeDue: no probe file yet, or one older than probeEvery.
func (a *Agent) probeDue(now time.Time) bool {
	if a.cfg.FleetProbePath == "" {
		return false
	}
	st, err := os.Stat(a.cfg.FleetProbePath)
	return err != nil || now.Sub(st.ModTime()) >= probeEvery
}

func (a *Agent) runProbe(ctx context.Context) {
	t := time.NewTicker(probeCheck)
	defer t.Stop()
	for {
		a.probeOnce(ctx, time.Now())
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
	}
}

// probeOnce runs the probe when it is due; false when it did not run. Exit 1
// is the script's "does not suit" — a verdict, not a failure.
func (a *Agent) probeOnce(ctx context.Context, now time.Time) bool {
	if !a.probeDue(now) {
		return false
	}
	script := a.probeScript()
	if script == "" {
		return false
	}
	pctx, cancel := context.WithTimeout(ctx, probeTimeout)
	defer cancel()
	cmd := exec.CommandContext(pctx, script, "--quiet")
	cmd.Env = append(os.Environ(), "FLEET_CONF_DIR="+filepath.Dir(a.cfg.FleetProbePath))
	out, err := cmd.CombinedOutput()
	var ee *exec.ExitError
	if err != nil && !(errors.As(err, &ee) && ee.ExitCode() == 1) && ctx.Err() == nil {
		log.Printf("probe: %s: %v %s", script, err, strings.TrimSpace(string(out)))
	}
	return true
}
