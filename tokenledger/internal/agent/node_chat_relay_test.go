package agent

import (
	"bytes"
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
