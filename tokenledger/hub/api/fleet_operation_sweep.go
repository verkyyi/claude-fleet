package api

import (
	"context"
	"log"
	"sync"
	"time"
)

type operationSweepState struct {
	sync.Mutex
	last time.Time
}

// Reconciliation used to depend on OperationGet: abandoned callers left the
// hub's accepted/running status behind forever even after the node finished.
func (s *Server) operationSweep(ctx context.Context, now time.Time) {
	if !s.operationSweepState.TryLock() {
		return
	}
	defer s.operationSweepState.Unlock()
	if now.Sub(s.operationSweepState.last) < time.Minute {
		return
	}
	s.operationSweepState.last = now
	// Expire first so a large historical backlog cannot starve current work.
	n, err := s.Store.ExpireFleetOperations(now)
	if err != nil {
		log.Printf("operation expiry: %v", err)
		return
	}
	if n > 0 {
		log.Printf("operation expiry: expired=%d age=24h", n)
		s.sessionsChanged.fire()
	}
	ops, err := s.Store.UnfinishedFleetOperations(now, 32)
	if err != nil {
		log.Printf("operation reconcile: %v", err)
		return
	}
	// Bound the entire pass; the next tick resumes from the oldest observation.
	ctx, cancel := context.WithTimeout(ctx, 45*time.Second)
	defer cancel()
	for _, op := range ops {
		if ctx.Err() != nil {
			return
		}
		if err := s.reconcileOperation(ctx, &op); err != nil {
			// An unreachable node is still unknown, never a retry authorization.
			// Refresh the observation timestamp to give the next row a turn.
			_ = s.Store.TouchUnfinishedOperation(op.ID, time.Now())
		}
	}
}
