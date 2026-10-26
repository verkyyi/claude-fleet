package api

import (
	"context"
	"math/rand"
	"net/http"
	"sync"
	"time"

	"github.com/coder/websocket"
)

// A rolling replica first stops admission, then hands off randomized slots over
// one minute. Keep its listener and peer route alive until the last slot: peers
// still need the nodes that have not moved yet. Browser cursors belong to the
// client (chat's session + byte offset, terminal's generation), not this hub.
const linkDrainSpreadDefault = 60 * time.Second

// linkSet counts the node websockets and the sessions riding them.
type linkSet struct {
	mu      sync.Mutex
	conns   map[*websocket.Conn]struct{}
	live    int // physical links + serveNode sessions
	closing bool
}

// hold registers a physical link; the func releases it.
func (l *linkSet) hold(c *websocket.Conn) func() {
	l.mu.Lock()
	if l.closing {
		l.mu.Unlock()
		go c.Close(websocket.StatusServiceRestart, `{"resume":"hello"}`)
		return func() {}
	}
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
	// Freeze admission under the same lock as hold: an upgrade that raced the
	// draining check must not escape the snapshot.
	s.links.mu.Lock()
	s.links.closing = true
	s.links.mu.Unlock()
	conns, _ := s.links.snapshot()
	rand.Shuffle(len(conns), func(i, j int) { conns[i], conns[j] = conns[j], conns[i] })
	defer s.finishDrain()
	step := time.Duration(0)
	if len(conns) > 1 {
		step = spread / time.Duration(len(conns)-1)
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
			_ = c.Close(websocket.StatusServiceRestart, `{"resume":"hello"}`)
		}(c, time.Duration(i)*step)
	}
	beat := time.NewTicker(replicaBeatEvery)
	defer beat.Stop()
	tick := time.NewTicker(20 * time.Millisecond)
	defer tick.Stop()
	for {
		if _, live := s.links.snapshot(); live <= 0 {
			return len(conns)
		}
		select {
		case <-ctx.Done():
			return len(conns)
		case <-beat.C:
			if s.Replica != nil {
				_ = s.beatReplica(time.Now())
			}
		case <-tick.C:
		}
	}
}
