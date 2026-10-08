//go:build unix

package agent

import (
	"os"
	"os/exec"
	"syscall"
)

func setCredential(cmd *exec.Cmd, ra *RunAs) {
	if cmd.SysProcAttr == nil {
		cmd.SysProcAttr = &syscall.SysProcAttr{}
	}
	// Only root may set the supplementary groups; anyone else (a test
	// running tenants as itself) keeps its own.
	cmd.SysProcAttr.Credential = &syscall.Credential{Uid: ra.UID, Gid: ra.GID, Groups: ra.Groups,
		NoSetGroups: os.Geteuid() != 0}
}
