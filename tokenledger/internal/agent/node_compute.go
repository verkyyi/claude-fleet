package agent

import (
	"bufio"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"

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
