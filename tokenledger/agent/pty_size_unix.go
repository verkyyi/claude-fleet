//go:build darwin || linux

package agent

import (
	"os"

	"golang.org/x/sys/unix"
)

// setPTYSize sets the terminal's window size; the kernel sends the session's
// foreground group SIGWINCH.
func setPTYSize(f *os.File, cols, rows int) error {
	return unix.IoctlSetWinsize(int(f.Fd()), unix.TIOCSWINSZ, &unix.Winsize{Col: uint16(cols), Row: uint16(rows)})
}
