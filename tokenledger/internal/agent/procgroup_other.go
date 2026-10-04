//go:build !unix

package agent

import "os/exec"

// No process groups here: the deadline ends the shell alone. SPOT nodes are
// Linux containers, so this is only what keeps the Windows build honest.
func setProcessGroup(c *exec.Cmd) {}

func killProcessGroup(c *exec.Cmd) error {
	if c.Process == nil {
		return nil
	}
	return c.Process.Kill()
}
