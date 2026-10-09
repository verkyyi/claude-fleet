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

// claude-fleet#2433: a login served by `ccquota agent --machine` beats the same
// compute word and probe its own agent did. m4's logins/<login>.env names no
// FLEET_CONF_DIR, so the tenant falls back to the login's own conf dir — the
// files fleet-credsep-launch.py's agent branch read too, node.env a symlink into
// the root-owned credential store (root follows it; the login could not).
func TestMachineTenantBeatsComputeAndProbeLikeItsOwnAgent(t *testing.T) {
	home, store := t.TempDir(), t.TempDir()
	conf := filepath.Join(home, ".config", "claude-fleet")
	if err := os.MkdirAll(conf, 0o700); err != nil {
		t.Fatal(err)
	}
	stored := filepath.Join(store, "node.env")
	os.WriteFile(stored, []byte("CCQUOTA_TOKEN=x\nCCQUOTA_FLEET=1\nCCQUOTA_FLEET_COMPUTE=0\n"), 0o600)
	if err := os.Symlink(stored, filepath.Join(conf, "node.env")); err != nil {
		t.Fatal(err)
	}
	ts := time.Now().UTC().Add(-23 * time.Hour).Truncate(time.Second)
	os.WriteFile(filepath.Join(conf, "node-probe.json"), []byte(`{"loc":"US","anthropic":"reachable","openai":"reachable","ts":"`+
		ts.Format(time.RFC3339)+`","verdict":"ok"}`), 0o600)
	old := fleetControlCommand
	fleetControlCommand = func(context.Context, string, []byte) ([]byte, error) { return []byte(`{"result":{}}`), nil }
	t.Cleanup(func() { fleetControlCommand = old })

	build := func(ra *RunAs) *Agent {
		a, err := New(Config{HubURL: "http://hub.invalid", Token: "x", Home: home, StateDir: t.TempDir(),
			SessionsDir: t.TempDir(), Fleet: true, FleetComputeOff: true, RunAs: ra})
		if err != nil {
			t.Fatal(err)
		}
		return a
	}
	plain := build(nil)
	tenant := build(&RunAs{Login: "verkyyi", UID: 501, GID: 20, Home: home})
	if tenant.cfg.FleetNodeEnvPath != filepath.Join(conf, "node.env") || tenant.cfg.FleetProbePath != filepath.Join(conf, "node-probe.json") ||
		tenant.cfg.FleetNodeEnvPath != plain.cfg.FleetNodeEnvPath || tenant.cfg.FleetProbePath != plain.cfg.FleetProbePath {
		t.Fatalf("tenant reads %q / %q; its own agent %q / %q", tenant.cfg.FleetNodeEnvPath, tenant.cfg.FleetProbePath,
			plain.cfg.FleetNodeEnvPath, plain.cfg.FleetProbePath)
	}
	for name, a := range map[string]*Agent{"own agent": plain, "machine tenant": tenant} {
		hb := a.nodeHeartbeat(context.Background(), &fleetProbe{})
		if hb.Compute == nil || *hb.Compute {
			t.Fatalf("%s: beat compute %v; want an explicit off (node.env says 0)", name, hb.Compute)
		}
		if hb.Probe == nil || hb.Probe.Verdict != "ok" || hb.Probe.Loc != "US" || !hb.Probe.TS.Equal(ts) {
			t.Fatalf("%s: beat probe %+v; want the login's ok probe of %s", name, hb.Probe, ts)
		}
		if c := a.computeClaim(); c == nil || *c {
			t.Fatalf("%s: hello claim %v; want false", name, c)
		}
	}
	// `fleet node compute on` (root writing the store's copy) reaches both live.
	os.WriteFile(stored, []byte("CCQUOTA_TOKEN=x\nCCQUOTA_FLEET=1\nCCQUOTA_FLEET_COMPUTE=1\n"), 0o600)
	if hb := tenant.nodeHeartbeat(context.Background(), &fleetProbe{}); hb.Compute == nil || !*hb.Compute {
		t.Fatalf("tenant after compute on: beat compute %v", hb.Compute)
	}
}

// claude-fleet#2661: a credential-separated node.env is a link the agent may
// not follow. It reads node.pub.env beside it, and with neither readable it
// keeps the last word it read — never the start-time CCQUOTA_FLEET_COMPUTE=0.
func TestComputeUnreadableNodeEnv(t *testing.T) {
	dir := t.TempDir()
	envf, pubf := filepath.Join(dir, "node.env"), filepath.Join(dir, "node.pub.env")
	write := func(p, s string) {
		if err := os.WriteFile(p, []byte(s), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	a := &Agent{cfg: Config{FleetComputeOff: true, FleetNodeEnvPath: envf}}
	write(envf, "CCQUOTA_TOKEN=x\nCCQUOTA_FLEET_COMPUTE=1\n")
	if a.computeOffNow() {
		t.Fatal("node.env says on")
	}
	// The separation: node.env becomes a link into a dir this login cannot
	// enter (a dangling link stands in for it), node.pub.env carries the rest.
	if err := os.Remove(envf); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(dir, "root-only", "node.env"), envf); err != nil {
		t.Fatal(err)
	}
	// A restart's window: neither file — the last word, not the start-time off.
	if a.computeOffNow() {
		t.Fatal("unreadable node.env and no node.pub.env: want the last reading (on), got the start-time off")
	}
	write(pubf, "CCQUOTA_FLEET_COMPUTE=0\n")
	if !a.computeOffNow() {
		t.Fatal("node.pub.env says off")
	}
	write(pubf, "CCQUOTA_FLEET_COMPUTE=1\nCCQUOTA_FLEET_PERSONAL=1\n")
	if a.computeOffNow() || !a.personalNow() {
		t.Fatal("node.pub.env says on + personal")
	}
	// A fresh agent that never read either keeps #1719's start-time reading.
	if err := os.Remove(pubf); err != nil {
		t.Fatal(err)
	}
	if !(&Agent{cfg: Config{FleetComputeOff: true, FleetNodeEnvPath: envf}}).computeOffNow() {
		t.Fatal("never read: want the start-time off")
	}
}
