package agent

import (
	"context"
	"log"
	"sync"
	"time"
)

// One bounded HTTP snapshot import, including the helper's local fence writes.
const executionSyncTimeout = 20 * time.Second

// executionStopSync belongs to one nodeSession, never to the shared machine
// transport or a task. Its flags only deduplicate proactive imports; Python's
// controlled admission checks remain authoritative, including when this fails.
type executionStopSync struct {
	mu        sync.Mutex
	running   bool
	succeeded bool
}

func (s *executionStopSync) kick(ctx context.Context, paths relayPaths) {
	if !paths.executionSync || paths.script == "" || ctx.Err() != nil {
		return
	}
	s.mu.Lock()
	if s.running || s.succeeded {
		s.mu.Unlock()
		return
	}
	s.running = true
	s.mu.Unlock()
	go func() {
		// Keep this connection's cancellation and RunAs identity: a reconnect
		// creates its own follow-up, and each machine tenant uses its own HOME.
		// CommandContext cancels the direct helper, not an entire process tree.
		// Its HTTP subprocesses finish under their own transport timeouts; this
		// read/monotonic stop import never grants execution permission.
		rctx, cancel := context.WithTimeout(ctx, executionSyncTimeout)
		defer cancel()
		cmd := relayCommand(rctx, paths.script, "execution-sync")
		cmd.WaitDelay = time.Second
		err := prepCmd(rctx, cmd)
		if err == nil {
			err = cmd.Run()
		}
		s.mu.Lock()
		s.running = false
		s.succeeded = err == nil
		s.mu.Unlock()
		if err != nil && ctx.Err() == nil {
			// Do not log the authenticated helper's output.
			log.Printf("task stop synchronization failed (retried next heartbeat): %v", err)
		}
	}()
}
