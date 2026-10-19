package agent

import (
	"encoding/binary"
	"errors"
	"fmt"
	"path/filepath"
	"regexp"
	"strconv"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

// `ccquota term-pty` (claude-fleet#3838): a terminal relay's last hop, started
// AS the login by its agent (prepCmd). It opens the pseudo-terminal itself — so
// the terminal is the login's, never root's — runs the ONE attach command on it,
// and speaks a small framed protocol with the agent on stdio:
//
//	agent → helper (stdin):  'd' <u32 len> <bytes>   keystrokes for the terminal
//	                         'r' <u32 4>  <cols u16> <rows u16>   a resize
//	helper → agent (stdout): termPtyReady once the command runs, then the
//	                         terminal's output, raw
//
// stdin's end hangs the terminal up (SIGHUP to its process group, SIGKILL
// after termPtyHangup); the command's end ends stdout. What runs is fixed here:
// ~/.claude/fleet/bin/fleet-term-attach.sh --view <id> --target <target>, the
// two words checked against their alphabets — nothing a browser sends names a
// program, a path or a socket.

// TermPtyCmd is the subcommand name (cmd/ccquota).
const TermPtyCmd = "term-pty"

const (
	termPtyReady = 0x01
	// termPtyHangup bounds how long a hung-up terminal's command may take to go.
	termPtyHangup = 3 * time.Second

	termFrameData   = 'd'
	termFrameResize = 'r'
)

var termViewRE = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9-]{0,47}$`)

// termAttachScript is the one command, under the login's home.
var termAttachScript = filepath.Join(".claude", "fleet", "bin", "fleet-term-attach.sh")

// termAttachArgv is what term-pty runs on the terminal. A variable only so the
// tests can run a throwaway command instead of tmux.
var termAttachArgv = func(home, view, target string) []string {
	return []string{"/bin/bash", filepath.Join(home, termAttachScript), "--view", view, "--target", target}
}

func termPtyArgs(args []string) (view, target string, cols, rows int, err error) {
	for i := 0; i < len(args); i++ {
		if i+1 >= len(args) {
			return "", "", 0, 0, fmt.Errorf("%s needs a value", args[i])
		}
		v := args[i+1]
		switch args[i] {
		case "--view":
			view = v
		case "--target":
			target = v
		case "--cols":
			cols, _ = strconv.Atoi(v)
		case "--resume":
			if len(v) > 128 || !regexp.MustCompile(`^[A-Za-z0-9:-]*$`).MatchString(v) {
				return "", "", 0, 0, errors.New("bad resume identity")
			}
		case "--take", "--renew":
			if v != "1" {
				return "", "", 0, 0, errors.New("bad takeover")
			}
		case "--rows":
			rows, _ = strconv.Atoi(v)
		default:
			return "", "", 0, 0, fmt.Errorf("unknown argument %q", args[i])
		}
		i++
	}
	switch {
	case !termViewRE.MatchString(view):
		return "", "", 0, 0, errors.New("--view is not a view id")
	case !control.ValidTermTarget(target):
		return "", "", 0, 0, errors.New("--target is not a terminal target")
	case cols < 0 || cols > control.TermColsMax || rows < 0 || rows > control.TermRowsMax:
		return "", "", 0, 0, errors.New("size out of range")
	}
	return view, target, cols, rows, nil
}

// termFrame encodes one agent → helper frame.
func termFrame(kind byte, p []byte) []byte {
	b := make([]byte, 5+len(p))
	b[0] = kind
	binary.BigEndian.PutUint32(b[1:], uint32(len(p)))
	copy(b[5:], p)
	return b
}

func termResizeFrame(cols, rows int) []byte {
	var p [4]byte
	binary.BigEndian.PutUint16(p[0:], uint16(cols))
	binary.BigEndian.PutUint16(p[2:], uint16(rows))
	return termFrame(termFrameResize, p[:])
}
