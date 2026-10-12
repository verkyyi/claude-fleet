//go:build unix

package agent

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"syscall"
	"testing"
)

var testRA = &RunAs{Login: "alice", UID: 501, GID: 20, Home: "/Users/alice"}

// No core (a root agent, a plain one): prepCmd is what it was — the command
// keeps its own program and argv, and gets the login's credential
// (claude-fleet#3669 共同约定 11).
func TestPrepCmdNoCoreUnchanged(t *testing.T) {
	setCoreSock("")
	cmd := exec.Command("/bin/bash", "/rt/bin/fleet-x.sh", "a")
	if err := prepCmd(withRunAs(context.Background(), testRA), cmd); err != nil {
		t.Fatal(err)
	}
	if cmd.Path != "/bin/bash" || !reflect.DeepEqual(cmd.Args, []string{"/bin/bash", "/rt/bin/fleet-x.sh", "a"}) {
		t.Fatalf("argv changed with no core: %s %v", cmd.Path, cmd.Args)
	}
	if cmd.SysProcAttr == nil || cmd.SysProcAttr.Credential == nil || cmd.SysProcAttr.Credential.Uid != 501 {
		t.Fatalf("no login credential: %+v", cmd.SysProcAttr)
	}
	if cmd.Dir != "/Users/alice" {
		t.Fatalf("dir %q", cmd.Dir)
	}
}

// On the seat a login's command becomes `ccquota core-exec … -- <script> args`:
// no credential of its own (the seat cannot setuid), the interpreter left to
// the core, the caller's environment not carried.
func TestPrepCmdCoreRewrites(t *testing.T) {
	setCoreSock("/run/core.sock")
	defer setCoreSock("")
	self, _ := os.Executable()
	for _, c := range []struct {
		argv []string
		want []string
	}{
		{[]string{"/bin/bash", "/rt/bin/fleet-x.sh", "a"}, []string{"/rt/bin/fleet-x.sh", "a"}},
		{[]string{"/usr/bin/python3", "-I", "/rt/bin/fleet-control.py", "rpc"}, []string{"/rt/bin/fleet-control.py", "rpc"}},
		{[]string{"/rt/bin/fleet-hub-node", "paths"}, []string{"/rt/bin/fleet-hub-node", "paths"}},
		// not a script: asked as it is, and the core refuses what is not under bin/
		{[]string{"/bin/sh", "-c", "id"}, []string{"/bin/sh", "-c", "id"}},
	} {
		cmd := exec.Command(c.argv[0], c.argv[1:]...)
		cmd.Env = []string{"SECRET=1"}
		if err := prepCmd(withRunAs(context.Background(), testRA), cmd); err != nil {
			t.Fatal(err)
		}
		want := append([]string{self, CoreExecCmd, "--sock", "/run/core.sock", "--login", "alice", "--"}, c.want...)
		if cmd.Path != self || !reflect.DeepEqual(cmd.Args, want) {
			t.Fatalf("%v → %s %v, want %v", c.argv, cmd.Path, cmd.Args, want)
		}
		if cmd.SysProcAttr != nil && cmd.SysProcAttr.Credential != nil {
			t.Fatalf("%v: a credential on the seat", c.argv)
		}
		if cmd.Dir != "/" || strings.Contains(strings.Join(cmd.Env, " "), "SECRET") {
			t.Fatalf("%v: dir %q env %v", c.argv, cmd.Dir, cmd.Env)
		}
	}
	// the machine's own work (no login) runs as the seat, untouched
	cmd := exec.Command("/usr/bin/true")
	if err := prepCmd(seatSelf(withRunAs(context.Background(), testRA)), cmd); err != nil {
		t.Fatal(err)
	}
	if cmd.Path != "/usr/bin/true" || cmd.SysProcAttr != nil {
		t.Fatalf("seatSelf: %s %+v", cmd.Path, cmd.SysProcAttr)
	}
}

// fakeCore answers one exec-as the way bin/fleet-node-core.py does: it takes the
// caller's three descriptors with the request, runs «the job» on them (reads
// stdin, writes stdout), then {"ok","pid"} and {"exit": rc}. refuse answers
// {"refused"} instead, the descriptors closed unused.
func fakeCore(t *testing.T, refuse string, rc int) (string, chan map[string]any) {
	t.Helper()
	dir, err := os.MkdirTemp("", "core")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	sock := filepath.Join(dir, "c.sock")
	l, err := net.ListenUnix("unix", &net.UnixAddr{Name: sock, Net: "unix"})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { l.Close() })
	got := make(chan map[string]any, 1)
	go func() {
		c, err := l.AcceptUnix()
		if err != nil {
			return
		}
		defer c.Close()
		buf, oob := make([]byte, 4096), make([]byte, syscall.CmsgSpace(3*4))
		n, oobn, _, _, err := c.ReadMsgUnix(buf, oob)
		if err != nil {
			return
		}
		var fds []int
		if msgs, err := syscall.ParseSocketControlMessage(oob[:oobn]); err == nil {
			for _, m := range msgs {
				if r, err := syscall.ParseUnixRights(&m); err == nil {
					fds = append(fds, r...)
				}
			}
		}
		var req map[string]any
		_ = json.Unmarshal(bytes.TrimSpace(buf[:n]), &req)
		req["fds"] = len(fds)
		got <- req
		if refuse != "" || len(fds) != 3 {
			for _, fd := range fds {
				syscall.Close(fd)
			}
			c.Write([]byte(`{"refused": "exec-as", "why": "` + refuse + `"}` + "\n"))
			return
		}
		in := os.NewFile(uintptr(fds[0]), "in")
		out := os.NewFile(uintptr(fds[1]), "out")
		syscall.Close(fds[2])
		c.Write([]byte(`{"ok": true, "pid": 4242}` + "\n"))
		b, _ := io.ReadAll(in)
		out.Write(append([]byte("got:"), b...))
		in.Close()
		out.Close()
		c.Write([]byte(`{"exit": ` + coreItoa(rc) + `}` + "\n"))
	}()
	return sock, got
}

func coreItoa(n int) string { b, _ := json.Marshal(n); return string(b) }

// The helper itself, run as a subprocess of the test binary.
func TestCoreExecHelperProcess(t *testing.T) {
	if os.Getenv("FLEET_TEST_CORE_EXEC") == "" {
		t.Skip("helper")
	}
	os.Exit(CoreExec(os.Getenv("FLEET_TEST_CORE_EXEC"), "alice", []string{"/rt/bin/fleet-control.py", "rpc"}))
}

func runHelper(t *testing.T, sock, stdin string) (int, string, string) {
	t.Helper()
	cmd := exec.Command(os.Args[0], "-test.run=^TestCoreExecHelperProcess$")
	cmd.Env = append(os.Environ(), "FLEET_TEST_CORE_EXEC="+sock)
	cmd.Stdin = strings.NewReader(stdin)
	var out, errb bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errb
	err := cmd.Run()
	var ee *exec.ExitError
	switch {
	case err == nil:
		return 0, out.String(), errb.String()
	case errors.As(err, &ee):
		return ee.ExitCode(), out.String(), errb.String()
	}
	t.Fatal(err)
	return -1, "", ""
}

// The job runs on the caller's own pipes and its exit code is the helper's: a
// fleet-control.py rpc reads its request on stdin and answers on stdout, as when
// the agent was root.
func TestCoreExecStreams(t *testing.T) {
	sock, got := fakeCore(t, "", 3)
	rc, out, errs := runHelper(t, sock, `{"op":"discover"}`)
	req := <-got
	if req["op"] != "exec-as" || req["fds"] != 3 {
		t.Fatalf("request %v", req)
	}
	args, _ := req["args"].(map[string]any)
	if args["login"] != "alice" || !reflect.DeepEqual(args["argv"], []any{"/rt/bin/fleet-control.py", "rpc"}) || len(args) != 2 {
		t.Fatalf("args %v", args)
	}
	if rc != 3 || out != `got:{"op":"discover"}` {
		t.Fatalf("rc %d out %q stderr %q", rc, out, errs)
	}
}

// A refusal is one stderr line naming why, and exit 126: nothing ran.
func TestCoreExecRefused(t *testing.T) {
	sock, _ := fakeCore(t, "argv[0] /bin/sh is not a file under bin/", 0)
	rc, out, errs := runHelper(t, sock, "")
	if rc != coreRefusedExit || out != "" || !strings.Contains(errs, "not a file under bin/") {
		t.Fatalf("rc %d out %q stderr %q", rc, out, errs)
	}
	// no core at all: the same
	rc, _, errs = runHelper(t, filepath.Join(t.TempDir(), "none.sock"), "")
	if rc != coreRefusedExit || !strings.Contains(errs, "root core") {
		t.Fatalf("no core: rc %d stderr %q", rc, errs)
	}
}
