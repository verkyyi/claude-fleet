package agent

import (
	"context"
	"log"
	"os/exec"
	"time"
)

// One bounded pass per connection, using the existing login adapter and journal.
// Link loss only cancels this helper; it owns no native task process.
func (a *Agent) replayTaskReceipts(ctx context.Context, script string) {
	ctx, cancel := context.WithTimeout(ctx, 45*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "bash", script, "replay")
	if err := prepCmd(ctx, cmd); err != nil {
		log.Printf("task recovery: login unavailable: %v", err)
		return
	}
	if err := cmd.Run(); err != nil {
		log.Printf("task recovery: receipts remain unresolved: %v", err)
	}
}
