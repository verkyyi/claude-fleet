//go:build unix

package agent

import (
	"context"
	"os"
	"strings"
	"testing"
)

// The command a tenant's Codex work runs in is this program — never a file in
// the login's home — with the login's credential and HOME, and a PATH of its
// own rather than the agent's.
func TestCodexOpCmdCarriesTheLoginsCredential(t *testing.T) {
	t.Setenv("PATH", "/root-only/bin:/usr/bin")
	t.Setenv("HOME", "/var/root")
	ra := &RunAs{Login: "grace", UID: 4242, GID: 4243, Home: "/Users/grace"}
	cmd, err := codexOpCmd(context.Background(), ra)
	if err != nil {
		t.Fatal(err)
	}
	self, _ := os.Executable()
	if cmd.Path != self || strings.HasPrefix(cmd.Path, ra.Home) {
		t.Fatalf("program %s; want this program %s", cmd.Path, self)
	}
	if got := strings.Join(cmd.Args[1:], " "); got != "codex "+CodexOpAction {
		t.Fatalf("args %q", got)
	}
	if cmd.SysProcAttr == nil || cmd.SysProcAttr.Credential == nil ||
		cmd.SysProcAttr.Credential.Uid != 4242 || cmd.SysProcAttr.Credential.Gid != 4243 {
		t.Fatalf("credential %+v; want uid 4242 gid 4243", cmd.SysProcAttr)
	}
	env := map[string]string{}
	for _, kv := range cmd.Env {
		k, v, _ := strings.Cut(kv, "=")
		if _, dup := env[k]; dup {
			t.Fatalf("%s twice in %q", k, cmd.Env)
		}
		env[k] = v
	}
	if env["HOME"] != "/Users/grace" || env["USER"] != "grace" {
		t.Fatalf("HOME %q USER %q", env["HOME"], env["USER"])
	}
	if strings.Contains(env["PATH"], "/root-only") || !strings.Contains(env["PATH"], "/usr/bin") {
		t.Fatalf("PATH %q", env["PATH"])
	}
	if cmd.Dir != ra.Home {
		t.Fatalf("dir %q", cmd.Dir)
	}
	if _, err := codexOpCmd(context.Background(), nil); err == nil {
		t.Fatal("a machine-op with no login was built")
	}
}
