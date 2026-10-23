package agent

import (
	"context"
	"log"
	"sync"
	"time"
)

// Only per-connection overlap/throttle bookkeeping. The existing Python
// operations journal is the durable source, including after a lost Hub ACK.
type executionExitRetry struct {
	mu      sync.Mutex
	running bool
	next    time.Time
}

func (s *executionExitRetry) kick(ctx context.Context, paths relayPaths) {
	if !paths.executionExitRetry || paths.script == "" || ctx.Err() != nil {
		return
	}
	s.mu.Lock()
	if s.running || time.Now().Before(s.next) {
		s.mu.Unlock()
		return
	}
	s.running = true
	s.next = time.Now().Add(30 * time.Second)
	s.mu.Unlock()
	go func() {
		rctx, cancel := context.WithTimeout(ctx, 20*time.Second)
		defer cancel()
		cmd := relayCommand(rctx, paths.script, "execution-exit-retry")
		cmd.WaitDelay = time.Second
		err := prepCmd(rctx, cmd)
		if err == nil {
			err = cmd.Run()
		}
		s.mu.Lock()
		s.running = false
		s.mu.Unlock()
		if err != nil && ctx.Err() == nil {
			// Never log the helper's authenticated request/response contents.
			log.Printf("native exit journal retry failed (retried on heartbeat): %v", err)
		}
	}()
}
