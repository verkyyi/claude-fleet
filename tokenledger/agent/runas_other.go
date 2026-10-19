//go:build !unix

package agent

import (
	"os"
	"os/exec"
)

func setCredential(cmd *exec.Cmd, ra *RunAs) {}

func credFacts(ra *RunAs) []string         { return nil }
func fileOwner(os.FileInfo) (uint32, bool) { return 0, false }
func errnoName(error) string               { return "" }
