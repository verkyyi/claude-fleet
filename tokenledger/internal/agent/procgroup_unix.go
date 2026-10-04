//go:build unix

package agent

import (
	"os/exec"
	"syscall"
)

// setProcessGroup puts the command in its own process group, so a deadline
// can end everything it started — not just the shell.
func setProcessGroup(c *exec.Cmd) {
	c.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
}

// killProcessGroup ends the whole group.
func killProcessGroup(c *exec.Cmd) error {
	if c.Process == nil {
		return nil
	}
	return syscall.Kill(-c.Process.Pid, syscall.SIGKILL)
}
