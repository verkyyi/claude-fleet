//go:build unix

package agent

import (
	"bufio"
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"golang.org/x/sys/unix"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

// RunTermPty is `ccquota term-pty --view <id> --target <target> [--cols N --rows N]`.
func RunTermPty(args []string, stdin io.Reader, stdout io.Writer) (int, error) {
	// The root core stops a login's job with TERM when its caller disconnects.
	// Convert that signal into the same cancellation used by a plain agent.
	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGHUP, os.Interrupt)
	defer cancel()
	defer watchTermCancel(cancel)()
	return runTermPty(ctx, args, stdin, stdout)
}

// Cancellation is independent of framed stdin. In core mode fd 3 stays with
// core-exec, which closes its existing core connection; it is never forwarded
// into a login or added to the core's three-descriptor protocol.
func watchTermCancel(cancel func()) func() {
	if os.Getenv("FLEET_TERM_CANCEL_FD") != "3" {
		return func() {}
	}
	stop := os.NewFile(3, "term-cancel")
	go func() { var b [1]byte; stop.Read(b[:]); cancel() }()
	return func() { stop.Close() }
}

func runTermPty(ctx context.Context, args []string, stdin io.Reader, stdout io.Writer) (int, error) {
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
	// Register the nonblocking master with Go's poller for output; input uses
	// bounded raw writes under the controller lock.
	fd, err := unix.Dup(int(master.Fd()))
	if err != nil {
		master.Close()
		slave.Close()
		return 1, err
	}
	syscall.CloseOnExec(fd)
	if err = syscall.SetNonblock(fd, true); err != nil {
		unix.Close(fd)
		master.Close()
		slave.Close()
		return 1, err
	}
	master.Close()
	master = os.NewFile(uintptr(fd), "term-pty")
	defer master.Close()
	if cols > 0 && rows > 0 {
		_ = termPTYSize(master, cols, rows)
	}
	argv := termAttachArgv(home, view, target)
	admissionR, admissionW, err := os.Pipe()
	if err != nil {
		slave.Close()
		return 1, err
	}
	defer admissionR.Close()
	defer admissionW.Close()
	cmd := exec.Command(argv[0], argv[1:]...)
	cmd.ExtraFiles = []*os.File{admissionW}
	env = append(env, "FLEET_TERM_ADMISSION_FD=3")
	for i := 0; i+1 < len(args); i += 2 {
		if args[i] == "--resume" {
			env = append(env, "FLEET_TERM_RESUME="+args[i+1])
		}
		if args[i] == "--renew" {
			env = append(env, "FLEET_TERM_RENEW=1")
		}
		if args[i] == "--take" {
			env = append(env, "FLEET_TERM_TAKE=1")
		}
		if args[i] == "--previous" {
			env = append(env, "FLEET_TERM_PREVIOUS="+args[i+1])
		}
	}
	cmd.Dir = home
	cmd.Env = env
	cmd.Stdin, cmd.Stdout, cmd.Stderr = slave, slave, slave
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true, Setctty: true, Ctty: 0}
	if err := cmd.Start(); err != nil {
		slave.Close()
		return 1, err
	}
	slave.Close()
	admissionW.Close()
	// Bound a missing/old helper handshake without ever enabling input.
	type admitted struct {
		c   termController
		err error
	}
	result := make(chan admitted, 1)
	go func() { c, e := readTermAdmission(admissionR); result <- admitted{c, e} }()
	var controller termController
	select {
	case got := <-result:
		controller, err = got.c, got.err
	case <-time.After(18 * time.Second):
		err = errors.New("admission_timeout")
	case <-ctx.Done():
		err = ctx.Err()
	}
	if err != nil {
		termHangup(cmd)
		master.Close()
		cmd.Wait()
		if controller.State != "" {
			// Admission metadata only; terminal output can never forge this frame.
			stdout.Write([]byte{termPtyReady})
			json.NewEncoder(stdout).Encode(control.TermControl{T: "error", Err: controller.State, Term: controller.Term, Gen: controller.Gen})
		}
		return 1, err
	}
	controller.ctx = ctx
	if _, err := stdout.Write([]byte{termPtyReady}); err != nil {
		termHangup(cmd)
		master.Close()
		cmd.Wait()
		return 1, err
	}

	if err := json.NewEncoder(stdout).Encode(controller.ready()); err != nil {
		termHangup(cmd)
		master.Close()
		cmd.Wait()
		return 1, err
	}
	exited := make(chan struct{})
	var once sync.Once
	hangup := func() { once.Do(func() { go func() { termHangupWait(cmd, exited) }() }) }
	go func() {
		select {
		case <-ctx.Done():
			hangup()
		case <-exited:
		}
	}()
	go func() {
		termReadFramesControlled(stdin, master, controller)
		hangup()
	}()
	// The terminal's output, until the command (and everything holding the
	// terminal) is gone: EIO on Linux, EOF elsewhere.
	_, _ = io.Copy(stdout, master)
	// Darwin can keep an exiting session leader waiting for its PTY to close.
	// Release the master before waiting for the child, including admission errors.
	master.Close()
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
		case "TMUX", "TMUX_PANE", "TERM", "FLEET_TERM_CANCEL_FD", "FLEET_TERM_RENEW", "FLEET_TERM_RESUME", "FLEET_TERM_TAKE", "FLEET_TERM_PREVIOUS", "FLEET_TERM_ADMISSION_FD":
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
	termReadFramesControlled(r, master, termController{})
}

func termReadFramesControlled(r io.Reader, master *os.File, controller termController) {
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
			if err := termControllerWrite(master, controller, buf[:n]); err != nil {
				return
			}
		case termFrameResize:
			if n != 4 {
				return
			}
			c, rw := int(binary.BigEndian.Uint16(buf[0:])), int(binary.BigEndian.Uint16(buf[2:]))
			if c >= 1 && c <= control.TermColsMax && rw >= 1 && rw <= control.TermRowsMax {
				if err := controller.apply(func() error { return termPTYSize(master, c, rw) }); err != nil {
					return
				}
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

func termControllerWrite(master *os.File, controller termController, data []byte) error {
	until := time.Now().Add(2 * time.Second)
	for len(data) > 0 {
		n := 0
		err := controller.apply(func() error {
			var e error
			raw, re := master.SyscallConn()
			if re != nil {
				return re
			}
			re = raw.Control(func(fd uintptr) { n, e = unix.Write(int(fd), data) })
			if re != nil {
				return re
			}
			return e
		})
		if n > 0 {
			data = data[n:]
		}
		if err != nil && err != unix.EAGAIN && err != unix.EINTR {
			return err
		}
		if time.Now().After(until) {
			return errors.New("terminal backpressure")
		}
		if err == unix.EAGAIN {
			time.Sleep(time.Millisecond)
		}
	}
	return nil
}

func termPTYSize(master *os.File, cols, rows int) error {
	raw, err := master.SyscallConn()
	if err != nil {
		return err
	}
	var resized error
	err = raw.Control(func(fd uintptr) {
		resized = unix.IoctlSetWinsize(int(fd), unix.TIOCSWINSZ, &unix.Winsize{Col: uint16(cols), Row: uint16(rows)})
	})
	if err != nil {
		return err
	}
	return resized
}
