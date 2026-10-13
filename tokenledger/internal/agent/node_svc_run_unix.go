//go:build unix

package agent

import (
	"os/exec"
	"syscall"
)

// setOwnGroup starts cmd as the leader of a process group of its own, so the
// whole attempt can be killed at once (claude-fleet#4086).
func setOwnGroup(cmd *exec.Cmd) {
	if cmd.SysProcAttr == nil {
		cmd.SysProcAttr = &syscall.SysProcAttr{}
	}
	cmd.SysProcAttr.Setpgid = true
}

// killGroup SIGKILLs cmd's process group.
func killGroup(cmd *exec.Cmd) {
	if cmd.Process == nil {
		return
	}
	_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
}
