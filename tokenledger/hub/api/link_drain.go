package api

import (
	"context"
	"net/http"
	"sync"
	"time"

	"github.com/coder/websocket"
)

// A replica that goes away hands its node links over (task PNWW).
//
// A node link is a hijacked websocket: http.Server.Shutdown neither waits for
// it nor closes it, so before this a hub copy replaced in a rolling release
// simply exited under every link it held — the agents read EOF, and nothing of
// the link's own end ran (nodes.drop, the link's claim, the in-flight account
// ops marked unknown, the relays it carried closed, the drop's record).
//
// Now, once the pod is out of the Service (preStop) and SIGTERM has come,
// DrainLinks closes each link with 1012 (service restart), spread over
// LinkDrainSpread so the replica still up is not met by every machine in the
// same instant, and waits — bounded by the shutdown grace — for every session
// that rode them to end. The agent dials again after its quick redial
// (0.5–1 s, agent/node.go nodeQuickRedial) and lands on a replica that is up;
// a connect that still reaches this one while it drains is answered 503 with
// Retry-After, never accepted. A link is still re-dialled once per release —
// a websocket cannot move between processes — but it is ended on purpose, in
// order, with its cleanup run, and booked as hub_shutdown.

// linkDrainSpreadDefault is how long the closes are spread over.
const linkDrainSpreadDefault = 2 * time.Second

// linkSet counts the node websockets and the sessions riding them.
type linkSet struct {
	mu    sync.Mutex
	conns map[*websocket.Conn]struct{}
	live  int // physical links + serveNode sessions
}

// hold registers a physical link; the func releases it.
func (l *linkSet) hold(c *websocket.Conn) func() {
	l.mu.Lock()
	if l.conns == nil {
		l.conns = map[*websocket.Conn]struct{}{}
	}
	l.conns[c] = struct{}{}
	l.live++
	l.mu.Unlock()
	return func() {
		l.mu.Lock()
		delete(l.conns, c)
		l.live--
		l.mu.Unlock()
	}
}

// enter counts one session (a plain link's, or one login's lane); leave ends it.
func (l *linkSet) enter() { l.mu.Lock(); l.live++; l.mu.Unlock() }
func (l *linkSet) leave() { l.mu.Lock(); l.live--; l.mu.Unlock() }

func (l *linkSet) snapshot() ([]*websocket.Conn, int) {
	l.mu.Lock()
	defer l.mu.Unlock()
	out := make([]*websocket.Conn, 0, len(l.conns))
	for c := range l.conns {
		out = append(out, c)
	}
	return out, l.live
}

// refuseWhileDraining answers a node connect that reached a draining replica.
func (s *Server) refuseWhileDraining(w http.ResponseWriter) bool {
	if s.Replica == nil || !s.Draining() {
		return false // a single hub has no other replica to send it to
	}
	w.Header().Set("Retry-After", "1")
	http.Error(w, "hub replica draining; dial again", http.StatusServiceUnavailable)
	return true
}

// DrainLinks closes every node link this replica holds and waits until every
// session on them has ended or ctx is done. It returns how many links it
// closed. Call it after Drain, beside the listeners' Shutdown.
func (s *Server) DrainLinks(ctx context.Context) int {
	spread := s.LinkDrainSpread
	if spread <= 0 {
		spread = linkDrainSpreadDefault
	}
	conns, _ := s.links.snapshot()
	step := time.Duration(0)
	if len(conns) > 1 {
		step = spread / time.Duration(len(conns))
	}
	for i, c := range conns {
		go func(c *websocket.Conn, after time.Duration) {
			if after > 0 {
				t := time.NewTimer(after)
				select {
				case <-t.C:
				case <-ctx.Done():
					t.Stop()
				}
			}
			// Close waits up to 5 s for the agent's close frame; ctx
			// bounds the whole drain, not each close.
			_ = c.Close(websocket.StatusServiceRestart, "hub replica restarting; dial again")
		}(c, time.Duration(i)*step)
	}
	tick := time.NewTicker(20 * time.Millisecond)
	defer tick.Stop()
	for {
		if _, live := s.links.snapshot(); live <= 0 {
			return len(conns)
		}
		select {
		case <-ctx.Done():
			return len(conns)
		case <-tick.C:
		}
	}
}
