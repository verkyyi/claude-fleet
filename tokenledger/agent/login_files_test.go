//go:build unix

package agent

import (
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"

	"github.com/verkyyi/claude-fleet/tokenledger/shared/codex"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/identity"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/scan"
)

// A machine tenant reads its login's files inside the login's home only: a
// link out of it (another login's identity, credentials, transcripts, Codex
// login) is not followed, and nothing unbounded is read. A plain agent follows
// its own links as before.
func TestMachineTenantReadsNoLinkOutOfTheHome(t *testing.T) {
	home, other := t.TempDir(), t.TempDir()
	ra := &RunAs{Login: "grace", UID: uint32(os.Getuid()), GID: uint32(os.Getgid()), Home: home}
	tenant := &Agent{cfg: Config{Home: home, RunAs: ra}}
	plain := &Agent{cfg: Config{Home: home}}
	link := func(target, at string) {
		t.Helper()
		os.MkdirAll(filepath.Dir(at), 0o700)
		if err := os.Symlink(target, at); err != nil {
			t.Fatal(err)
		}
	}

	// ~/.claude.json → another login's
	os.WriteFile(filepath.Join(other, ".claude.json"), []byte(`{"oauthAccount":{"accountUuid":"someone-else"}}`), 0o600)
	link(filepath.Join(other, ".claude.json"), filepath.Join(home, ".claude.json"))
	if id, err := identity.DetectWith(home, tenant.loginReader(claudeConfigMax)); err == nil {
		t.Fatalf("tenant identified through a link as %s", id.AccountUUID)
	}
	if id, err := identity.DetectWith(home, plain.loginReader(claudeConfigMax)); err != nil || id.AccountUUID != "someone-else" {
		t.Fatalf("plain agent no longer reads its own link: %v %v", id, err)
	}

	// ~/.claude/.credentials.json → another login's
	os.MkdirAll(filepath.Join(other, ".claude"), 0o700)
	os.WriteFile(filepath.Join(other, ".claude", ".credentials.json"), []byte(`{"claudeAiOauth":{"accessToken":"other"}}`), 0o600)
	link(filepath.Join(other, ".claude", ".credentials.json"), filepath.Join(home, ".claude", ".credentials.json"))
	t.Setenv("CCQUOTA_OAUTH_TOKEN", "")
	t.Setenv("CLAUDE_SECURESTORAGE_CONFIG_DIR", "")
	if c, err := tenant.loadClaudeCredentials(); err == nil {
		t.Fatalf("tenant read a credential through a link: %q", c.AccessToken)
	}

	// a transcript that is a link to another login's
	proj := filepath.Join(home, ".claude", "projects", "p")
	os.MkdirAll(proj, 0o700)
	line := `{"type":"assistant","uuid":"u1","timestamp":"2026-11-01T00:00:00Z","requestId":"r1","message":{"id":"m1","model":"claude-opus-4","usage":{"input_tokens":1,"output_tokens":1}}}` + "\n"
	os.WriteFile(filepath.Join(other, "t.jsonl"), []byte(line), 0o600)
	link(filepath.Join(other, "t.jsonl"), filepath.Join(proj, "t.jsonl"))
	sc := scan.NewScanner(identity.ProjectsDir(home), filepath.Join(t.TempDir(), "cursor.json"))
	sc.Open = tenant.loginOpener()
	if evs, err := sc.Scan(); err != nil || len(evs) != 0 {
		t.Fatalf("tenant scanned a linked transcript: %d events, %v", len(evs), err)
	}
	sc = scan.NewScanner(identity.ProjectsDir(home), filepath.Join(t.TempDir(), "cursor.json"))
	if evs, err := sc.Scan(); err != nil || len(evs) != 1 {
		t.Fatalf("plain scanner: %d events, %v; want the linked one", len(evs), err)
	}
	// ~/.claude itself a link: nothing below it is opened
	home2 := t.TempDir()
	link(filepath.Join(home, ".claude"), filepath.Join(home2, ".claude"))
	ra2 := &RunAs{Login: "ada", UID: uint32(os.Getuid()), Home: home2}
	if _, err := openAsLogin(ra2, filepath.Join(home2, ".claude", "projects", "p", "x.jsonl")); err == nil {
		t.Fatal("opened a file through a linked directory")
	}

	// ~/.codex/auth.json → another login's
	writeCodexLogin(t, filepath.Join(other, ".codex"))
	link(filepath.Join(other, ".codex", "auth.json"), filepath.Join(home, ".codex", "auth.json"))
	if a, err := codex.ReadAuthWith(filepath.Join(home, ".codex"), tenant.loginReader(smallFileMax)); err == nil {
		t.Fatalf("tenant read a Codex login through a link: %s", a.Identity.AccountUUID)
	}
	// the registry a link: refused, so the login's Codex collection is off
	link(filepath.Join(other, "reg.json"), filepath.Join(home, ".ccquota", "codex-profiles.json"))
	os.WriteFile(filepath.Join(other, "reg.json"), []byte(`{"profiles":[]}`), 0o600)
	if _, err := codex.ProfilesWith(home, "", "", tenant.loginReader(smallFileMax)); err == nil {
		t.Fatal("tenant read a linked Codex registry")
	}

	// unbounded / blocking sources
	if err := syscall.Mkfifo(filepath.Join(home, "fifo.json"), 0o600); err != nil {
		t.Fatal(err)
	}
	link("/dev/zero", filepath.Join(home, "zero.json"))
	os.WriteFile(filepath.Join(home, "big.json"), make([]byte, smallFileMax+1), 0o600)
	for _, n := range []string{"fifo.json", "zero.json", "big.json"} {
		if _, err := tenant.readFileFor(filepath.Join(home, n), false, smallFileMax); err == nil {
			t.Fatalf("%s read", n)
		}
	}
	// outside the home, a place root configured: by its path, still bounded
	if _, err := tenant.readFileFor("/dev/zero", false, smallFileMax); err == nil {
		t.Fatal("/dev/zero read")
	}
}

// node.env may be a link only to this login's own credential store (and only
// one the login cannot change); every other link is refused.
func TestMachineTenantNodeEnvLink(t *testing.T) {
	home, base, elsewhere := t.TempDir(), t.TempDir(), t.TempDir()
	t.Setenv("FLEET_CREDSEP_ROOT_BASE", base)
	conf := filepath.Join(home, ".config", "claude-fleet")
	os.MkdirAll(conf, 0o700)
	envf := filepath.Join(conf, "node.env")
	body := []byte("CCQUOTA_FLEET_COMPUTE=0\n")
	for _, d := range []string{filepath.Join(base, "grace"), filepath.Join(base, "ada")} {
		os.Mkdir(d, 0o700)
		os.WriteFile(filepath.Join(d, "node.env"), body, 0o600)
	}
	os.WriteFile(filepath.Join(elsewhere, "node.env"), body, 0o600)
	notOwner := &RunAs{Login: "grace", UID: uint32(os.Getuid()) + 1, Home: home}
	owner := &RunAs{Login: "grace", UID: uint32(os.Getuid()), Home: home}
	for _, tc := range []struct {
		target string
		ra     *RunAs
		ok     bool
	}{
		{filepath.Join(base, "grace", "node.env"), notOwner, true},
		{base + "/grace/../grace/node.env", notOwner, true},
		{filepath.Join(base, "grace", "node.env"), owner, false}, // a store the login owns is no store
		{filepath.Join(base, "ada", "node.env"), notOwner, false},
		{filepath.Join(elsewhere, "node.env"), notOwner, false},
		{"/dev/zero", notOwner, false},
		{"../../x/node.env", notOwner, false},
	} {
		os.Remove(envf)
		if err := os.Symlink(tc.target, envf); err != nil {
			t.Fatal(err)
		}
		a := &Agent{cfg: Config{Home: home, RunAs: tc.ra, FleetNodeEnvPath: envf}}
		env, ok := a.readNodeEnv(envf)
		if ok != tc.ok || (ok && env["CCQUOTA_FLEET_COMPUTE"] != "0") {
			t.Fatalf("link to %s (uid %d): read %v %v; want %v", tc.target, tc.ra.UID, ok, env, tc.ok)
		}
	}
	// the store's directory is itself a link: refused
	os.RemoveAll(filepath.Join(base, "grace"))
	if err := os.Symlink(elsewhere, filepath.Join(base, "grace")); err != nil {
		t.Fatal(err)
	}
	os.Remove(envf)
	os.Symlink(filepath.Join(base, "grace", "node.env"), envf)
	a := &Agent{cfg: Config{Home: home, RunAs: notOwner}}
	if _, ok := a.readNodeEnv(envf); ok {
		t.Fatal("read through a linked store directory")
	}
	// a plain file in the home is read
	os.Remove(envf)
	os.WriteFile(envf, body, 0o600)
	if env, ok := a.readNodeEnv(envf); !ok || env["CCQUOTA_FLEET_COMPUTE"] != "0" {
		t.Fatalf("plain node.env: %v %v", env, ok)
	}
	if !strings.HasPrefix(credStoreBase(), base) {
		t.Fatal("FLEET_CREDSEP_ROOT_BASE not honored")
	}
}
