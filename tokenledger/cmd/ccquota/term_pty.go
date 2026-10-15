package main

import (
	"fmt"
	"os"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/agent"
)

// runTermPty is `ccquota term-pty` (claude-fleet#3838): a terminal relay's last
// hop, started as the login by its agent.
func runTermPty(args []string) int {
	code, err := agent.RunTermPty(args, os.Stdin, os.Stdout)
	if err != nil {
		fmt.Fprintln(os.Stderr, "ccquota term-pty:", err)
		if code == 0 {
			code = 1
		}
	}
	return code
}
