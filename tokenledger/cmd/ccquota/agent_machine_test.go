package main

import (
	"os"
	"os/user"
	"path/filepath"
	"strings"
	"testing"
)

// `ccquota agent --machine` reads one <login>.env per login (claude-fleet#2333).
func TestMachineTenantsFromLoginsDir(t *testing.T) {
	me, err := user.Current()
	if err != nil || me.Uid == "0" {
		t.Skip("needs a non-root login to serve")
	}
	dir, state := t.TempDir(), t.TempDir()
	env := "# the login's agent settings\nexport CCQUOTA_TOKEN='tok-1'\nCCQUOTA_FLEET=1\nCCQUOTA_FLEET_ADMIN=1\n" +
		"FLEET_CONF_DIR=\"/x/conf\"\nCCQUOTA_FLEET_CREDS=1\nCCQUOTA_FLEET_CRED_STORE=/var/run/fleet-cred/.shared/ctl.sock\n"
	if err := os.WriteFile(filepath.Join(dir, me.Username+".env"), []byte(env), 0o600); err != nil {
		t.Fatal(err)
	}
	ts, err := machineTenants(dir, state, false)
	if err != nil {
		t.Fatal(err)
	}
	if len(ts) != 1 {
		t.Fatalf("tenants = %d", len(ts))
	}
	c := ts[0]
	if c.Token != "tok-1" || !c.Fleet || !c.FleetAdmin || !c.FleetCreds || c.FleetCredStore == "" ||
		c.RunAs == nil || c.RunAs.Login != me.Username || c.Home != me.HomeDir ||
		c.StateDir != filepath.Join(state, me.Username) || c.FleetNodeEnvPath != "/x/conf/node.env" ||
		c.FleetNudgePath != "/x/conf/global/hub-nudge" {
		t.Fatalf("tenant = %+v", c)
	}

	// Strict (root): a token file anyone else can read is refused.
	if err := os.Chmod(filepath.Join(dir, me.Username+".env"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := machineTenants(dir, state, true); err == nil || !strings.Contains(err.Error(), "only root may read it") {
		t.Fatalf("a world-readable token file: %v", err)
	}

	// No token, no login: refused, never served half-configured.
	os.WriteFile(filepath.Join(dir, me.Username+".env"), []byte("CCQUOTA_FLEET=1\n"), 0o600)
	if _, err := machineTenants(dir, state, false); err == nil || !strings.Contains(err.Error(), "CCQUOTA_TOKEN") {
		t.Fatalf("no token: %v", err)
	}
	if _, err := machineTenants(t.TempDir(), state, false); err == nil {
		t.Fatal("an empty logins directory was accepted")
	}
	// The machine's own token comes from its root-only file the same way.
	me2 := filepath.Join(t.TempDir(), "machine.env")
	os.WriteFile(me2, []byte("CCQUOTA_TOKEN=mach-tok\nCCQUOTA_HUB_URL=https://hub.example\n"), 0o600)
	if env, err := readLoginEnv(me2, false); err != nil || env["CCQUOTA_TOKEN"] != "mach-tok" || env["CCQUOTA_HUB_URL"] != "https://hub.example" {
		t.Fatalf("machine.env = %v %v", env, err)
	}
	if !machineFlag([]string{"--hub", "x", "--machine"}) || machineFlag([]string{"--hub", "x"}) {
		t.Fatal("machineFlag")
	}
}
