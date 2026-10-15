//go:build unix

package agent

import (
	"bufio"
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
)

// RunTermPty is `ccquota term-pty --view <id> --target <target> [--cols N --rows N]`.
func RunTermPty(args []string, stdin io.Reader, stdout io.Writer) (int, error) {
	view, target, cols, rows, err := termPtyArgs(args)
	if err != nil {
		return 2, err
	}
	env, err := termPtyEnv(os.Environ())
	if err != nil {
		return 1, err
	}
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		return 1, errors.New("no home to run the terminal in")
	}
	master, slave, err := openPTY()
	if err != nil {
		return 1, fmt.Errorf("open a terminal: %w", err)
	}
	defer master.Close()
	if cols > 0 && rows > 0 {
		_ = setPTYSize(master, cols, rows)
	}
	argv := termAttachArgv(home, view, target)
	cmd := exec.Command(argv[0], argv[1:]...)
	cmd.Dir = home
	cmd.Env = env
	cmd.Stdin, cmd.Stdout, cmd.Stderr = slave, slave, slave
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true, Setctty: true, Ctty: 0}
	if err := cmd.Start(); err != nil {
		slave.Close()
		return 1, err
	}
	slave.Close()
	if _, err := stdout.Write([]byte{termPtyReady}); err != nil {
		termHangup(cmd)
		return 1, err
	}

	exited := make(chan struct{})
	var once sync.Once
	hangup := func() { once.Do(func() { go func() { termHangupWait(cmd, exited) }() }) }
	go func() {
		termReadFrames(stdin, master)
		hangup()
	}()
	// The terminal's output, until the command (and everything holding the
	// terminal) is gone: EIO on Linux, EOF elsewhere.
	_, _ = io.Copy(stdout, master)
	err = cmd.Wait()
	close(exited)
	if ee := (*exec.ExitError)(nil); errors.As(err, &ee) {
		return ee.ExitCode(), nil
	}
	return 0, nil
}

// termPtyEnv is the terminal's environment: a terminal type, a UTF-8 locale
// (CJK input and wide cells need it), and no tmux of the agent's own.
func termPtyEnv(env []string) ([]string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "locale", "-a")
	cmd.Env = []string{"PATH=" + os.Getenv("PATH"), "LC_ALL=C"}
	locales, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("list terminal locales: %w", err)
	}
	return termPtyLocaleEnv(env, strings.Fields(string(locales)))
}

func termPtyLocaleEnv(env, available []string) ([]string, error) {
	out := make([]string, 0, len(env)+4)
	want := make(map[string]string)
	for _, kv := range env {
		k, v, _ := strings.Cut(kv, "=")
		switch k {
		case "TMUX", "TMUX_PANE", "TERM":
			continue
		case "LANG", "LC_ALL", "LC_CTYPE":
			want[k] = v
			continue
		}
		out = append(out, kv)
	}
	normal := func(s string) string { return strings.ToUpper(strings.ReplaceAll(s, "-", "")) }
	// Preserve an installed UTF-8 choice in locale precedence order. Inherited
	// LC_ALL=C must not override a UTF-8 LANG; never assume C.UTF-8 exists on macOS.
	candidates := append([]string{want["LC_ALL"], want["LC_CTYPE"], want["LANG"], "C.UTF-8", "en_US.UTF-8"}, available...)
	for _, candidate := range candidates {
		if !strings.Contains(normal(candidate), "UTF8") {
			continue
		}
		for _, installed := range available {
			if normal(candidate) == normal(installed) {
				return append(out, "TERM=xterm-256color", "LANG="+installed, "LC_CTYPE="+installed, "LC_ALL="+installed), nil
			}
		}
	}
	return nil, errors.New("no installed UTF-8 locale for the terminal")
}

// termReadFrames applies the agent's frames to the terminal until stdin ends
// or a frame is malformed (which ends it too).
func termReadFrames(r io.Reader, master *os.File) {
	br := bufio.NewReaderSize(r, control.TermFrameMax+8)
	hdr := make([]byte, 5)
	buf := make([]byte, control.TermFrameMax)
	for {
		if _, err := io.ReadFull(br, hdr); err != nil {
			return
		}
		n := binary.BigEndian.Uint32(hdr[1:])
		if n > control.TermFrameMax {
			return
		}
		if _, err := io.ReadFull(br, buf[:n]); err != nil {
			return
		}
		switch hdr[0] {
		case termFrameData:
			if _, err := master.Write(buf[:n]); err != nil {
				return
			}
		case termFrameResize:
			if n != 4 {
				return
			}
			c, rw := int(binary.BigEndian.Uint16(buf[0:])), int(binary.BigEndian.Uint16(buf[2:]))
			if c >= 1 && c <= control.TermColsMax && rw >= 1 && rw <= control.TermRowsMax {
				_ = setPTYSize(master, c, rw)
			}
		default:
			return
		}
	}
}

// termHangup hangs up the terminal's process group at once.
func termHangup(cmd *exec.Cmd) {
	if cmd.Process != nil {
		_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGHUP)
		_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
	}
}

// termHangupWait hangs up the terminal, then kills what is left of its group
// once termPtyHangup has passed without it going.
func termHangupWait(cmd *exec.Cmd, exited <-chan struct{}) {
	if cmd.Process == nil {
		return
	}
	pg := -cmd.Process.Pid
	_ = syscall.Kill(pg, syscall.SIGHUP)
	select {
	case <-exited:
	case <-time.After(termPtyHangup):
	}
	_ = syscall.Kill(pg, syscall.SIGKILL)
}
