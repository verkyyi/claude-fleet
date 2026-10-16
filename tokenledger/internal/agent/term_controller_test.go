//go:build unix

package agent

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"syscall"
	"testing"
	"time"

	"golang.org/x/sys/unix"
)

func TestTermControllerDelayedFrames(t *testing.T) {
	d := t.TempDir()
	c := termController{Conn: "old", Epoch: 1, Lock: filepath.Join(d, ".lock"), Lease: filepath.Join(d, "lease.json")}
	lock, err := os.OpenFile(c.Lock, os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		t.Fatal(err)
	}
	defer lock.Close()
	writeLease := func(conn string, epoch int) {
		b, _ := json.Marshal(map[string]any{"conn": conn, "epoch": epoch, "ts": time.Now().Unix()})
		if err := os.WriteFile(c.Lease, b, 0600); err != nil {
			t.Fatal(err)
		}
	}
	writeLease("old", 1)
	master, slave, err := openPTY()
	if err != nil {
		t.Fatal(err)
	}
	defer master.Close()
	defer slave.Close()
	setPTYSize(master, 80, 24)
	// Both frames arrived before takeover but are waiting to act. Changing the
	// epoch under the same lock must fence data AND resize at the actual PTY.
	syscall.Flock(int(lock.Fd()), syscall.LOCK_EX)
	done := make(chan struct{})
	go func() {
		termReadFramesControlled(bytes.NewReader(termFrame(termFrameData, []byte("must-not-run\n"))), master, c)
		termReadFramesControlled(bytes.NewReader(termResizeFrame(132, 45)), master, c)
		close(done)
	}()
	writeLease("new", 2)
	syscall.Flock(int(lock.Fd()), syscall.LOCK_UN)
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("stale frames did not stop")
	}
	w, err := unix.IoctlGetWinsize(int(master.Fd()), unix.TIOCGWINSZ)
	if err != nil || w.Col != 80 || w.Row != 24 {
		t.Fatalf("old resize acted: %+v %v", w, err)
	}
	slaveFD := int(slave.Fd())
	syscall.SetNonblock(slaveFD, true)
	b := make([]byte, 128)
	if n, _ := syscall.Read(slaveFD, b); n > 0 {
		t.Fatalf("old input acted: %q", b[:n])
	}
	acted := false
	if c.apply(func() error { acted = true; return nil }) == nil || acted {
		t.Fatal("old cleanup passed fencing")
	}
	c.Conn, c.Epoch = "new", 2
	if err := c.apply(func() error { acted = true; return nil }); err != nil || !acted {
		t.Fatal("new epoch was fenced", err)
	}
	// A dropped transport cancels independently of its framed stdin. Bytes
	// already read from that pipe must not drain into the still-owned pane.
	ctx, cancel := context.WithCancel(context.Background())
	c.ctx = ctx
	syscall.Flock(int(lock.Fd()), syscall.LOCK_EX)
	done = make(chan struct{})
	go func() {
		termReadFramesControlled(bytes.NewReader(termFrame(termFrameData, []byte("queued\n"))), master, c)
		termReadFramesControlled(bytes.NewReader(termResizeFrame(90, 30)), master, c)
		close(done)
	}()
	cancel()
	syscall.Flock(int(lock.Fd()), syscall.LOCK_UN)
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("cancelled frames did not stop")
	}
	if n, _ := syscall.Read(slaveFD, b); n > 0 {
		t.Fatalf("queued input acted: %q", b[:n])
	}
	w, err = unix.IoctlGetWinsize(int(master.Fd()), unix.TIOCGWINSZ)
	if err != nil || w.Col != 80 || w.Row != 24 {
		t.Fatalf("queued resize acted: %+v %v", w, err)
	}
}
