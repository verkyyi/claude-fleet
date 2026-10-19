package agent

import (
	"bytes"
	"context"
	"errors"
	"io"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// `ccquota chat-pipe` (claude-fleet#3644): no argument may name a target, and it
// reaches the login's own $FLEET_CONF_DIR/webchat/chat.sock, saying ready first.
func TestChatPipe(t *testing.T) {
	if err := RunChatPipe([]string{"/tmp/other.sock"}, nil, io.Discard); err == nil {
		t.Fatal("chat-pipe took an argument")
	}
	conf, err := os.MkdirTemp("/tmp", "cp")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(conf)
	t.Setenv("FLEET_CONF_DIR", conf)
	if err := RunChatPipe(nil, bytes.NewReader(nil), io.Discard); err == nil {
		t.Fatal("chat-pipe succeeded with no socket listening")
	}
	os.MkdirAll(filepath.Join(conf, "webchat"), 0o700)
	ln, err := net.Listen("unix", chatSockPath(conf))
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	got := make(chan string, 1)
	go func() {
		c, err := ln.Accept()
		if err != nil {
			return
		}
		b, _ := io.ReadAll(c)
		c.Write([]byte("answer"))
		c.Close()
		got <- string(b)
	}()
	inR, inW := io.Pipe()
	var out bytes.Buffer
	done := make(chan error, 1)
	go func() { done <- RunChatPipe(nil, inR, &out) }()
	inW.Write([]byte("hello"))
	inW.Close()
	select {
	case s := <-got:
		if s != "hello" {
			t.Fatalf("the socket got %q", s)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("the socket got nothing")
	}
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	if o := out.String(); len(o) == 0 || o[0] != chatPipeReady {
		t.Fatalf("stdout %q does not start with the ready byte", o)
	}
}

// claude-fleet#3648: the first /chat found no socket and nothing started the
// service (#3647's ensure had no caller). A machine tenant now runs the fixed
// `service ensure --login <its login> --name webchat --wait 3` and dials again;
// a plain agent (no register to write) dials once and says why.
func TestChatSockEnsuresOnDemand(t *testing.T) {
	if _, err := os.Stat("/usr/bin/python3"); err != nil {
		t.Skip("no /usr/bin/python3")
	}
	dir := t.TempDir()
	argvFile := filepath.Join(dir, "argv")
	sup := filepath.Join(dir, "fleet-node-supervisor.py")
	os.WriteFile(sup, []byte(`import sys
open("`+argvFile+`", "a").write(" ".join(sys.argv[1:]) + "\n")
print("alice/webchat registered · ready")
`), 0o644)
	up := false
	dials := 0
	dial := func(context.Context) (io.ReadWriteCloser, error) {
		dials++
		if !up {
			return nil, errors.New("connect: no such file or directory")
		}
		c1, c2 := net.Pipe()
		c2.Close()
		return c1, nil
	}

	plain := &Agent{}
	if _, err := plain.chatSockOrEnsure(context.Background(), context.Background(), "alice", "r1", dial); err == nil || dials != 1 {
		t.Fatalf("plain agent: err=%v dials=%d", err, dials)
	}
	if _, err := os.Stat(argvFile); err == nil {
		t.Fatal("a plain agent ran the supervisor")
	}

	a := &Agent{cfg: Config{RunAs: &RunAs{Login: "alice"}, ServiceCtl: sup}}
	dials = 0
	orig := dial
	dial = func(ctx context.Context) (io.ReadWriteCloser, error) {
		c, err := orig(ctx)
		if dials == 1 {
			up = true // the ensure (next) starts it
		}
		return c, err
	}
	c, err := a.chatSockOrEnsure(context.Background(), context.Background(), "alice", "r2", dial)
	if err != nil || dials != 2 {
		t.Fatalf("tenant: err=%v dials=%d", err, dials)
	}
	c.Close()
	got, _ := os.ReadFile(argvFile)
	if want := "service ensure --login alice --name webchat --wait 3\n"; string(got) != want {
		t.Fatalf("supervisor argv = %q, want %q", got, want)
	}

	// running already: no ensure
	os.Remove(argvFile)
	dials = 0
	if c, err = a.chatSockOrEnsure(context.Background(), context.Background(), "alice", "r3", orig); err != nil || dials != 1 {
		t.Fatalf("running: err=%v dials=%d", err, dials)
	}
	c.Close()
	if _, err := os.Stat(argvFile); err == nil {
		t.Fatal("ensured a service that answered")
	}
}
