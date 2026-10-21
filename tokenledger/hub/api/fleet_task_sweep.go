package api

import (
	"log"
	"sync/atomic"
	"time"
)

// The hub's own reconcile of task records (claude-fleet A4G2): every
// taskSweepEvery, on the replica that leads "alerts", every unfinished record
// whose session is over — its ID closed with no result, or never taken by a
// machine within a day — ends (store.ReconcileClosedTasks). Before this only a
// person running `fleet-task-record.sh reconcile` did it.
const taskSweepEvery = 5 * time.Minute

var taskSweepLast atomic.Int64

// TaskSweepTick runs the sweep at now when the last one is taskSweepEvery old.
func (s *Server) TaskSweepTick(now time.Time) {
	last := taskSweepLast.Load()
	if last != 0 && now.Sub(time.Unix(0, last)) < taskSweepEvery {
		return
	}
	if !taskSweepLast.CompareAndSwap(last, now.UnixNano()) {
		return
	}
	out, err := s.Store.ReconcileClosedTasks("", true, now)
	if err != nil {
		log.Printf("task sweep: %v", err)
		return
	}
	for _, it := range out.Items {
		log.Printf("task sweep: %s %s %s → %s (%s)", it.Task, it.Short, it.From, it.To, it.Why)
	}
}
