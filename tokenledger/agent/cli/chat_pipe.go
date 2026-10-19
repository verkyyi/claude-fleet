package cli

import (
	"fmt"
	"os"

	"github.com/verkyyi/claude-fleet/tokenledger/agent"
)

// runChatPipe is `ccquota chat-pipe` (claude-fleet#3644): a chat relay's last
// hop, started as the login by its agent — the login's own conversation socket
// on stdio, nothing else.
func runChatPipe(args []string) int {
	if err := agent.RunChatPipe(args, os.Stdin, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "ccquota chat-pipe:", err)
		return 1
	}
	return 0
}
