package agent

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
)

// The node half of one node program per machine (claude-fleet#2333).

func selfRunAs(t *testing.T, login, home string) *RunAs {
	t.Helper()
	u, err := user.Current()
	if err != nil {
		t.Fatal(err)
	}
	uid, _ := strconv.ParseUint(u.Uid, 10, 32)
	gid, _ := strconv.ParseUint(u.Gid, 10, 32)
	return &RunAs{Login: login, UID: uint32(uid), GID: uint32(gid), Home: home}
}

// A command started for a tenant gets the login's HOME / USER / LOGNAME and
// its home as the working directory; a plain agent's command is untouched.
func TestPrepCmdRunsAsTheLogin(t *testing.T) {
	home := t.TempDir()
	ctx := withRunAs(context.Background(), selfRunAs(t, "beta", home))
	cmd := exec.CommandContext(ctx, "/bin/sh", "-c", `printf '%s|%s|%s|%s' "$HOME" "$USER" "$LOGNAME" "$PWD"`)
	cmd.Env = append(os.Environ(), "HOME=/var/root", "USER=root", "SUDO_USER=x")
	if err := prepCmd(ctx, cmd); err != nil {
		t.Fatal(err)
	}
	out, err := cmd.Output()
	if err != nil {
		t.Fatal(err)
	}
	got := strings.Split(string(out), "|")
	real, _ := filepath.EvalSymlinks(home)
	if got[0] != home || got[1] != "beta" || got[2] != "beta" || (got[3] != home && got[3] != real) {
		t.Fatalf("ran with HOME|USER|LOGNAME|PWD = %q; want %s|beta|beta|%s", out, home, home)
	}
	for _, kv := range cmd.Env {
		if strings.HasPrefix(kv, "SUDO_USER=") {
			t.Fatalf("root's sudo context leaked into the login's env: %s", kv)
		}
	}

	plain := exec.Command("/bin/true")
	if err := prepCmd(context.Background(), plain); err != nil || plain.Env != nil || plain.SysProcAttr != nil {
		t.Fatalf("a plain agent's command was touched: %v %+v", err, plain)
	}
}

// The root agent's own FLEET_CONF_DIR / TMPDIR (the supervisor's root-only
// dirs) never reach the login (claude-fleet#2471): the login's conf dir does —
// its <login>.env's, else ~/.config/claude-fleet — and a value the caller set
// on cmd.Env itself stays.
func TestPrepCmdGivesTheLoginItsConfDir(t *testing.T) {
	home := t.TempDir()
	t.Setenv("FLEET_CONF_DIR", "/var/db/fleet-node/conf")
	t.Setenv("TMPDIR", "/var/db/fleet-node/tmp")
	read := func(ra *RunAs, env []string) map[string][]string {
		t.Helper()
		cmd := exec.Command("/usr/bin/true")
		cmd.Env = env
		if err := prepCmd(withRunAs(context.Background(), ra), cmd); err != nil {
			t.Fatal(err)
		}
		got := map[string][]string{}
		for _, kv := range cmd.Env {
			k, v, _ := strings.Cut(kv, "=")
			got[k] = append(got[k], v)
		}
		return got
	}
	ra := selfRunAs(t, "beta", home)
	got := read(ra, nil)
	if want := filepath.Join(home, ".config", "claude-fleet"); len(got["FLEET_CONF_DIR"]) != 1 || got["FLEET_CONF_DIR"][0] != want {
		t.Fatalf("FLEET_CONF_DIR = %q; want only %s", got["FLEET_CONF_DIR"], want)
	}
	if len(got["TMPDIR"]) != 0 {
		t.Fatalf("root's TMPDIR leaked into the login's env: %q", got["TMPDIR"])
	}
	ra.ConfDir = "/elsewhere/conf"
	if got := read(ra, nil); len(got["FLEET_CONF_DIR"]) != 1 || got["FLEET_CONF_DIR"][0] != ra.ConfDir {
		t.Fatalf("FLEET_CONF_DIR = %q; want the login's own %s", got["FLEET_CONF_DIR"], ra.ConfDir)
	}
	explicit := append(os.Environ(), "FLEET_CONF_DIR=/caller/set")
	if got := read(ra, explicit); len(got["FLEET_CONF_DIR"]) != 1 || got["FLEET_CONF_DIR"][0] != "/caller/set" {
		t.Fatalf("FLEET_CONF_DIR = %q; want the caller's /caller/set", got["FLEET_CONF_DIR"])
	}
}

// Only a root machine agent refuses a command with no login: never run it as
// root. As anyone else, or with no machine running, it is a plain agent.
func TestPrepCmdStrictOnlyForARootMachine(t *testing.T) {
	machineStrict.Add(1)
	defer machineStrict.Add(-1)
	err := prepCmd(context.Background(), exec.Command("/bin/true"))
	if os.Geteuid() == 0 {
		if err != errNoLogin {
			t.Fatalf("root machine agent ran a command with no login: %v", err)
		}
	} else if err != nil {
		t.Fatalf("non-root: %v", err)
	}
}

// A file written under a tenant's home is handed to that login; a file
// anywhere else is left as it is.
func TestOwnPathByHome(t *testing.T) {
	home := t.TempDir()
	ra := selfRunAs(t, "beta", home)
	registerTenant(ra)
	defer unregisterTenant(ra)
	dir := filepath.Join(home, "a", "b")
	if err := mkdirOwned(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	fi, err := os.Stat(filepath.Join(home, "a"))
	if err != nil || !fi.IsDir() {
		t.Fatalf("mkdirOwned: %v", err)
	}
	ownPath(filepath.Join(home, "a", "b")) // no error path to observe as non-root; must not panic
	ownPath("/nonexistent/elsewhere")
}

// The node's twin of the hub's WRONG_LOGIN: a message for a login this
// program does not serve is refused on the link and reaches no tenant; a
// login's message reaches only its own lane, and LINK_CLOSED ends the lane.
func TestMachineLinkDemuxByLogin(t *testing.T) {
	got := make(chan control.Message, 8)
	var hubConn *websocket.Conn
	ready := make(chan struct{})
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		c, err := websocket.Accept(w, r, nil)
		if err != nil {
			return
		}
		var hello control.Message
		if wsjson.Read(r.Context(), c, &hello) != nil {
			return
		}
		welcome, _ := control.New(control.TypeWelcome, control.Welcome{Accepted: true})
		_ = wsjson.Write(r.Context(), c, welcome)
		hubConn = c
		close(ready)
		for {
			var m control.Message
			if wsjson.Read(context.Background(), c, &m) != nil {
				return
			}
			if m.Type != control.TypeHeartbeat {
				got <- m
			}
		}
	}))
	defer srv.Close()

	ml := newMachineLink(MachineConfig{HubURL: srv.URL, Token: "machine", LiveInterval: time.Hour})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go ml.run(ctx)
	<-ready
	lctx, lcancel := context.WithTimeout(ctx, 5*time.Second)
	defer lcancel()
	alpha, err := ml.lane(lctx, "alpha")
	if err != nil {
		t.Fatal(err)
	}
	beta, err := ml.lane(lctx, "beta")
	if err != nil {
		t.Fatal(err)
	}

	send := func(m control.Message) {
		if err := wsjson.Write(ctx, hubConn, m); err != nil {
			t.Fatal(err)
		}
	}
	w, _ := control.New(control.TypeWrite, control.Request{Method: "submit"})
	w.Login = "carol"
	send(w)
	select {
	case r := <-got:
		if r.Type != control.TypeError || r.Error.Code != control.CodeWrongLogin || r.OpID != w.OpID || r.Login != "carol" {
			t.Fatalf("a write for an unserved login answered %+v", r)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("a write for an unserved login was not refused")
	}

	w2, _ := control.New(control.TypeWrite, control.Request{Method: "submit"})
	w2.Login = "beta"
	send(w2)
	rctx, rcancel := context.WithTimeout(ctx, 3*time.Second)
	defer rcancel()
	m, err := beta.read(rctx)
	if err != nil || m.OpID != w2.OpID {
		t.Fatalf("beta's write: %v %+v", err, m)
	}
	nctx, ncancel := context.WithTimeout(ctx, 200*time.Millisecond)
	defer ncancel()
	if m, err := alpha.read(nctx); err == nil {
		t.Fatalf("alpha received beta's message %+v", m)
	}

	// A tenant's write goes out stamped with its login.
	out, _ := control.New(control.TypeResult, control.Result{})
	if err := alpha.write(ctx, out); err != nil {
		t.Fatal(err)
	}
	select {
	case r := <-got:
		if r.Login != "alpha" {
			t.Fatalf("alpha's write left as %q", r.Login)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("alpha's write never arrived")
	}

	send(control.Message{Type: control.TypeError, Proto: control.Proto, Login: "beta",
		Error: &control.Error{Code: control.CodeLinkClosed, Message: "revoked"}})
	ectx, ecancel := context.WithTimeout(ctx, 3*time.Second)
	defer ecancel()
	if _, err := beta.read(ectx); err != errLaneClosed {
		t.Fatalf("beta after LINK_CLOSED: %v; want the lane closed", err)
	}
}

// A controller that dies before printing its JSON answer hands back its last
// stderr line with the exit status (claude-fleet#2471), not «exit status 1».
func TestFleetControlCommandCarriesStderr(t *testing.T) {
	script := filepath.Join(t.TempDir(), "fleet-control.py")
	body := "#!/bin/sh\necho 'Traceback (most recent call last):' >&2\necho \"PermissionError: [Errno 13] Permission denied: '/var/db/fleet-node/conf/control'\" >&2\nexit 1\n"
	if err := os.WriteFile(script, []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}
	out, err := fleetControlCommand(context.Background(), script, []byte("{}"))
	if out != nil || err == nil || !strings.Contains(err.Error(), "exit status 1: PermissionError: [Errno 13]") {
		t.Fatalf("got %q, %v; want the stderr's last line on the error", out, err)
	}
}
