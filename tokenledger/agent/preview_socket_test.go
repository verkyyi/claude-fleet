//go:build darwin || linux

package agent

import (
	"bufio"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

// Child roles run in fresh processes: changing cwd or uid never affects the
// test runner. The production helper has no test environment switch.
func TestPreviewPeerProcess(t *testing.T) {
	role := os.Getenv("FLEET_PREVIEW_TEST_ROLE")
	if role == "" {
		return
	}
	home := os.Getenv("FLEET_PREVIEW_TEST_HOME")
	if role == "server" {
		path := filepath.Join(home, ".fleet-preview", "app.sock")
		l, e := net.Listen("unix", path)
		if e != nil {
			t.Fatal(e)
		}
		defer l.Close()
		os.Chmod(path, 0600)
		fmt.Println("READY")
		for {
			c, e := l.Accept()
			if e != nil {
				return
			}
			go func() {
				defer c.Close()
				b := make([]byte, 1024)
				for {
					n, e := c.Read(b)
					if n > 0 {
						fmt.Printf("BYTES:%d\n", n)
						c.Write(b[:n])
					}
					if e != nil {
						return
					}
				}
			}()
		}
	}
	dial := net.DialTimeout
	if mode := os.Getenv("FLEET_PREVIEW_TEST_RACE"); mode != "" {
		dial = func(network, addr string, timeout time.Duration) (net.Conn, error) {
			// Deterministic ABA after production's initial lstat, restored
			// before its final lstat. The connected peer retains its real UID.
			if e := os.Rename("app.sock", "original.sock"); e != nil {
				return nil, e
			}
			var e error
			if mode == "symlink" {
				e = os.Symlink("peer.sock", "app.sock")
			} else {
				e = os.Rename("peer.sock", "app.sock")
			}
			if e != nil {
				return nil, e
			}
			c, e := net.DialTimeout(network, addr, timeout)
			if mode == "symlink" {
				os.Remove("app.sock")
			} else {
				os.Rename("app.sock", "peer.sock")
			}
			if restore := os.Rename("original.sock", "app.sock"); restore != nil {
				if c != nil {
					c.Close()
				}
				return nil, restore
			}
			return c, e
		}
	}
	c, e := previewSocketDial(home, "app.sock", os.Geteuid(), dial)
	if e != nil {
		fmt.Fprintln(os.Stderr, e)
		os.Exit(3)
	}
	defer c.Close()
	c.Write([]byte("verified"))
	b := make([]byte, 8)
	if _, e = io.ReadFull(c, b); e != nil {
		t.Fatal(e)
	}
	fmt.Println(string(b))
	os.Exit(0)
}
func previewTestChild(t *testing.T, role, home string, uid int) *exec.Cmd {
	t.Helper()
	cmd := exec.Command(os.Args[0], "-test.run=^TestPreviewPeerProcess$")
	cmd.Env = append(os.Environ(), "FLEET_PREVIEW_TEST_ROLE="+role, "FLEET_PREVIEW_TEST_HOME="+home)
	if os.Geteuid() == 0 {
		cmd.SysProcAttr = &syscall.SysProcAttr{Credential: &syscall.Credential{Uid: uint32(uid), Gid: uint32(uid), Groups: []uint32{}}}
	}
	return cmd
}
func TestPreviewSocketPaths(t *testing.T) {
	if os.Geteuid() < 500 {
		t.Skip("unprivileged same-UID leg")
	}
	u, e := user.Current()
	if e != nil {
		t.Fatal(e)
	}
	home, e := os.MkdirTemp(u.HomeDir, ".preview-test-")
	if e != nil {
		t.Fatal(e)
	}
	defer os.RemoveAll(home)
	dir := filepath.Join(home, ".fleet-preview")
	os.Mkdir(dir, 0700)
	cmd := previewTestChild(t, "server", home, os.Geteuid())
	out, e := cmd.StdoutPipe()
	if e != nil {
		t.Fatal(e)
	}
	cmd.Stderr = os.Stderr
	if e = cmd.Start(); e != nil {
		t.Fatal(e)
	}
	defer func() { cmd.Process.Kill(); cmd.Wait() }()
	if line, _ := bufio.NewReader(out).ReadString('\n'); line != "READY\n" {
		t.Fatal(line)
	}
	if b, e := previewTestChild(t, "client", home, os.Geteuid()).CombinedOutput(); e != nil || !strings.Contains(string(b), "verified") {
		t.Fatal(string(b), e)
	}
	path := filepath.Join(dir, "app.sock")
	saved := filepath.Join(dir, "saved.sock")
	if e = os.Rename(path, saved); e != nil {
		t.Fatal(e)
	}
	os.Symlink("saved.sock", path)
	if b, e := previewTestChild(t, "client", home, os.Geteuid()).CombinedOutput(); e == nil {
		t.Fatal("symlink accepted", string(b))
	}
	os.Remove(path)
	os.Rename(saved, path)
	os.Chmod(path, 0666)
	if b, e := previewTestChild(t, "client", home, os.Geteuid()).CombinedOutput(); e == nil {
		t.Fatal("public socket accepted", string(b))
	}
	os.Chmod(path, 0600)
	os.Chmod(dir, 0755)
	if b, e := previewTestChild(t, "client", home, os.Geteuid()).CombinedOutput(); e == nil {
		t.Fatal("public directory accepted", string(b))
	}
}

// Opt-in privileged drill: FLEET_PREVIEW_TEST_UIDS=503,502 go test -run
// TestPreviewTwoUIDs. Creates only a temporary directory directly below /,
// never accounts, permissions on existing homes, PF, SSH, or services.
func TestPreviewTwoUIDs(t *testing.T) {
	if os.Geteuid() != 0 {
		t.Skip("root required for actual two-UID processes")
	}
	parts := strings.Split(os.Getenv("FLEET_PREVIEW_TEST_UIDS"), ",")
	if len(parts) != 2 {
		t.Skip("set FLEET_PREVIEW_TEST_UIDS to two ordinary numeric UIDs")
	}
	client, _ := strconv.Atoi(parts[0])
	other, _ := strconv.Atoi(parts[1])
	if client < 500 || other < 500 || client == other {
		t.Fatal("two distinct ordinary UIDs required")
	}
	parent := "/"
	if runtime.GOOS == "darwin" {
		parent = "/Users"
	}
	root, e := os.MkdirTemp(parent, "fleet-preview-test-")
	if e != nil {
		t.Fatal(e)
	}
	defer os.RemoveAll(root)
	os.Chmod(root, 0755)
	for _, server := range []int{client, other, 0} {
		t.Run(fmt.Sprint(server), func(t *testing.T) {
			home := filepath.Join(root, fmt.Sprint(server))
			os.Mkdir(home, 0755)
			dir := filepath.Join(home, ".fleet-preview")
			os.Mkdir(dir, 0700)
			os.Chown(dir, server, server)
			cmd := previewTestChild(t, "server", home, server)
			out, e := cmd.StdoutPipe()
			if e != nil {
				t.Fatal(e)
			}
			cmd.Stderr = os.Stderr
			if e = cmd.Start(); e != nil {
				t.Fatal(e)
			}
			defer func() { cmd.Process.Kill(); cmd.Wait() }()
			reader := bufio.NewReader(out)
			if line, _ := reader.ReadString('\n'); line != "READY\n" {
				t.Fatal(line)
			}
			bytesSeen := make(chan string, 16)
			go func() {
				for {
					line, e := reader.ReadString('\n')
					if e != nil {
						return
					}
					bytesSeen <- line
				}
			}()
			// Make the foreign/root peer's inode LOOK owned by the client. Path stat
			// alone would accept it; kernel peer credentials must still refuse it.
			os.Chown(dir, client, client)
			os.Chown(filepath.Join(dir, "app.sock"), client, client)
			b, e := previewTestChild(t, "client", home, client).CombinedOutput()
			if server == client && (e != nil || !strings.Contains(string(b), "verified")) {
				t.Fatal(string(b), e)
			}
			if server != client && (e == nil || !strings.Contains(string(b), "server UID differs")) {
				t.Fatal("foreign peer was not refused by UID", string(b), e)
			}
			if server != client {
				// A real foreign listener with a client-owned inode, reachable
				// via either a socket replacement or symlink ABA.
				path := filepath.Join(dir, "app.sock")
				if e := os.Rename(path, filepath.Join(dir, "peer.sock")); e != nil {
					t.Fatal(e)
				}
				original, e := net.Listen("unix", path)
				if e != nil {
					t.Fatal(e)
				}
				defer original.Close()
				os.Chmod(path, 0600)
				os.Chown(path, client, client)
				for _, mode := range []string{"replace", "symlink"} {
					run := previewTestChild(t, "client", home, client)
					run.Env = append(run.Env, "FLEET_PREVIEW_TEST_RACE="+mode)
					b, e := run.CombinedOutput()
					if e == nil || !strings.Contains(string(b), "server UID differs") {
						t.Fatalf("%s ABA accepted foreign peer: %s %v", mode, b, e)
					}
				}
				select {
				case line := <-bytesSeen:
					t.Fatalf("application bytes reached UID %d: %s", server, line)
				case <-time.After(100 * time.Millisecond):
				}
				t.Log("foreign/root direct, replacement ABA and symlink ABA refused before application bytes")
			}
		})
	}
}
