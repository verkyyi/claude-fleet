//go:build unix

package agent

import (
	"bufio"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

func TestPanelViewAndSock(t *testing.T) {
	cases := map[string]string{
		"fleet@view-Verkys-Mac-93a1de": "Verkys-Mac-93a1de",
		"fleet":                        "",
		"fleet@view-":                  "",
		"fleet@view-a/b":               "",
		"x@view-y@view-z9":             "z9",
	}
	for in, want := range cases {
		if got := PanelView(in); got != want {
			t.Errorf("PanelView(%q) = %q, want %q", in, got, want)
		}
	}
	t.Setenv("FLEET_PANEL_SOCK_DIR", "/d")
	// the same name fleet-panel-server.py sock_name gives (sha1(view)[:16])
	if got := PanelSock("Verkys-Mac-93a1de"); got != "/d/2931611855070aa3.sock" {
		t.Errorf("PanelSock = %q", got)
	}
}

func TestPanelFallbackArgv(t *testing.T) {
	ctx, ok := parsePanelCtx("fleet@view-v|/dev/ttys1|@3||||zh|120")
	if !ok || ctx.Session != "fleet@view-v" || ctx.Client != "/dev/ttys1" {
		t.Fatalf("parse: %+v %v", ctx, ok)
	}
	got := strings.Join(panelFallbackArgv([]string{"python3", "q.py"}, ctx, ok), " ")
	if got != "python3 q.py --view fleet@view-v --client /dev/ttys1" {
		t.Errorf("argv = %q", got)
	}
	if _, ok := parsePanelCtx("short|x"); ok {
		t.Error("a short context parsed")
	}
}

// No server: the fallback is exec'd with the keypress's view and client and
// FLEET_PANEL_T0.
func TestPanelAttachFallsBack(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("FLEET_PANEL_SOCK_DIR", dir)
	t.Setenv("FLEET_PANEL_CTX", "fleet@view-v|/dev/ttys1|@3||||zh|120")
	var argv0 string
	var argv, env []string
	panelExec = func(p string, a, e []string) error { argv0, argv, env = p, a, e; return nil }
	defer func() { panelExec = syscall.Exec }()
	PanelAttach([]string{"sh", "-c", "true"})
	if filepath.Base(argv0) != "sh" || strings.Join(argv[3:], " ") != "--view fleet@view-v --client /dev/ttys1" {
		t.Fatalf("exec %s %q", argv0, argv)
	}
	found := false
	for _, kv := range env {
		found = found || strings.HasPrefix(kv, "FLEET_PANEL_T0=")
	}
	if !found {
		t.Error("no FLEET_PANEL_T0")
	}
}

// A server: the request carries the context, the environment and three
// descriptors; the child's pid then its rc come back and are the exit code.
func TestPanelAttachServed(t *testing.T) {
	dir, err := os.MkdirTemp("/tmp", "pnl")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(dir)
	t.Setenv("FLEET_PANEL_SOCK_DIR", dir)
	t.Setenv("FLEET_PANEL_CTX", "fleet@view-v|/dev/ttys1|@3||||zh|120")
	ln, err := net.ListenUnix("unix", &net.UnixAddr{Name: PanelSock("v"), Net: "unix"})
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	got := make(chan map[string]any, 1)
	go func() {
		c, err := ln.AcceptUnix()
		if err != nil {
			return
		}
		defer c.Close()
		rd := bufio.NewReader(c)
		head, err := rd.ReadBytes('\n')
		if err != nil {
			return
		}
		c.Write([]byte(`{"ready": 1}` + "\n"))
		buf, oob := make([]byte, 16), make([]byte, 256)
		_, oobn, _, _, err := c.ReadMsgUnix(buf, oob)
		if err != nil {
			return
		}
		msgs, _ := syscall.ParseSocketControlMessage(oob[:oobn])
		fds := 0
		for _, m := range msgs {
			if r, err := syscall.ParseUnixRights(&m); err == nil {
				fds += len(r)
				for _, fd := range r {
					syscall.Close(fd)
				}
			}
		}
		var req map[string]any
		_ = json.Unmarshal(head, &req)
		req["fds"] = float64(fds)
		got <- req
		w := bufio.NewWriter(c)
		w.WriteString(`{"pid": 999999}` + "\n")
		w.Flush()
		time.Sleep(20 * time.Millisecond)
		w.WriteString(`{"rc": 7}` + "\n")
		w.Flush()
	}()
	panelExec = func(string, []string, []string) error { t.Error("fell back"); return nil }
	defer func() { panelExec = syscall.Exec }()
	if rc := PanelAttach([]string{"false"}); rc != 7 {
		t.Errorf("rc = %d", rc)
	}
	req := <-got
	if req["v"].(float64) != 1 || req["ctx"] != "fleet@view-v|/dev/ttys1|@3||||zh|120" || req["fds"].(float64) != 3 {
		t.Errorf("request %v", req)
	}
	if env, _ := req["env"].(map[string]any); env["FLEET_PANEL_CTX"] == nil {
		t.Error("no environment")
	}
}

// A server that takes the connection and never answers is never handed the
// terminal: the connector falls back within panelAnswer.
func TestPanelAttachHungServer(t *testing.T) {
	dir, err := os.MkdirTemp("/tmp", "pnl")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(dir)
	t.Setenv("FLEET_PANEL_SOCK_DIR", dir)
	t.Setenv("FLEET_PANEL_CTX", "fleet@view-h|/dev/ttys1|@3||||zh|120")
	ln, err := net.ListenUnix("unix", &net.UnixAddr{Name: PanelSock("h"), Net: "unix"})
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	fell := false
	panelExec = func(string, []string, []string) error { fell = true; return nil }
	defer func() { panelExec = syscall.Exec }()
	t0 := time.Now()
	PanelAttach([]string{"sh"})
	if !fell || time.Since(t0) > 2*time.Second {
		t.Errorf("fell back %v after %v", fell, time.Since(t0))
	}
}
