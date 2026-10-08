//go:build !unix

package agent

import "os/exec"

func setCredential(cmd *exec.Cmd, ra *RunAs) {}
