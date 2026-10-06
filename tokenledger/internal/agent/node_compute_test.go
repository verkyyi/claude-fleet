package agent

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// claude-fleet#1719: only CCQUOTA_FLEET_COMPUTE=0 says anything — unset sends
// exactly what an agent older than #1719 sent (nil, compute on).
func TestComputeClaim(t *testing.T) {
	if c := (&Agent{}).computeClaim(); c != nil {
		t.Fatalf("compute on: claim %v, want nil", *c)
	}
	c := (&Agent{cfg: Config{FleetComputeOff: true}}).computeClaim()
	if c == nil || *c {
		t.Fatalf("compute off: claim %v, want false", c)
	}
}

// claude-fleet#1720: node.env and node-probe.json are re-read live — `fleet
// node compute on|off` and the daily probe need no restart; an unreadable
// node.env keeps the start-time reading; no probe file sends no probe.
func TestComputeLive(t *testing.T) {
	dir := t.TempDir()
	envf, probef := filepath.Join(dir, "node.env"), filepath.Join(dir, "node-probe.json")
	a := &Agent{cfg: Config{FleetComputeOff: true, FleetNodeEnvPath: envf, FleetProbePath: probef}}
	if c := a.computeClaim(); c == nil || *c {
		t.Fatalf("no node.env: want the start-time off, got %v", c)
	}
	if a.nodeProbe() != nil {
		t.Fatal("no probe file must send no probe")
	}
	write := func(p, s string) {
		if err := os.WriteFile(p, []byte(s), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	write(envf, "CCQUOTA_TOKEN=x\nCCQUOTA_FLEET_COMPUTE=1\nCCQUOTA_FLEET_COMPUTE_FORCE=1\n")
	if c := a.computeClaim(); c != nil {
		t.Fatalf("compute on in node.env: claim %v, want nil", *c)
	}
	if !a.computeForce() {
		t.Fatal("force line not read")
	}
	write(envf, "CCQUOTA_TOKEN=x\nCCQUOTA_FLEET_COMPUTE=0\nCCQUOTA_FLEET_COMPUTE_FORCE=1\n")
	if c := a.computeClaim(); c == nil || *c {
		t.Fatalf("compute off in node.env: claim %v", c)
	}
	if a.computeForce() {
		t.Fatal("force means nothing while compute is off")
	}
	write(probef, `{"loc":"CN","anthropic":"unsupported_region","openai":"unreachable","laptop":true,"ts":"2026-10-05T12:00:00Z","verdict":"unsupported_region"}`)
	p := a.nodeProbe()
	if p == nil || p.Loc != "CN" || p.Verdict != "unsupported_region" || !p.Laptop || p.TS.IsZero() {
		t.Fatalf("probe: %+v", p)
	}
	write(probef, `not json`)
	if a.nodeProbe() != nil {
		t.Fatal("an unreadable probe must send none")
	}
}

// The daily probe: due with no file and once a day old; it runs the client
// install's script with FLEET_CONF_DIR pointing at the probe file's dir, and a
// fresh file is not re-probed.
func TestProbeOnce(t *testing.T) {
	home := t.TempDir()
	conf := filepath.Join(home, "conf")
	probef := filepath.Join(conf, "node-probe.json")
	a := &Agent{cfg: Config{Home: home, FleetProbePath: probef}}
	if a.probeOnce(context.Background(), time.Now()) {
		t.Fatal("no script installed: nothing to run")
	}
	bin := filepath.Join(home, ".local", "share", "claude-fleet", "bin")
	if err := os.MkdirAll(bin, 0o755); err != nil {
		t.Fatal(err)
	}
	script := "#!/bin/sh\nmkdir -p \"$FLEET_CONF_DIR\"\nprintf '{\"loc\":\"CN\",\"ts\":\"2026-10-05T00:00:00Z\",\"verdict\":\"unsupported_region\"}' > \"$FLEET_CONF_DIR/node-probe.json\"\nexit 1\n"
	if err := os.WriteFile(filepath.Join(bin, "fleet-node-probe.sh"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	if !a.probeOnce(context.Background(), time.Now()) {
		t.Fatal("no probe file: the probe is due")
	}
	if p := a.nodeProbe(); p == nil || p.Loc != "CN" {
		t.Fatalf("probe after a run: %+v", p)
	}
	if a.probeOnce(context.Background(), time.Now()) {
		t.Fatal("a fresh probe file is not re-probed")
	}
	if !a.probeOnce(context.Background(), time.Now().Add(25*time.Hour)) {
		t.Fatal("a day-old probe is due again")
	}
}
