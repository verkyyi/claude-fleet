package api

import (
	"encoding/json"
	"net/http"
	"strconv"
	"sync"
	"time"
)

// The long poll of fleet_sessions (claude-fleet#1526).
//
// #1481 made the sidebar's poll cheap — an ETag, a 304 with no body — but a
// poll is still a clock: a change that lands just after a 2 s ask waits for
// the next one, 1 s on average. Now the asker may say how long it is willing
// to wait (`wait`, seconds): when its If-None-Match still names the current
// answer, the hub holds the request and answers the moment a heartbeat moves
// the validator — or 304 at the deadline, exactly what it answers today. No
// `wait`, no If-None-Match, or a validator that is already stale: the answer
// is immediate and byte for byte what it was. An older hub ignores the field,
// answers 304 at once, and the asker falls back to its 2 s cadence.

// fleetSessionsMaxWait caps `wait`: well under an ingress's 60 s idle timeout,
// and the asker's curl gives up at 30 s.
const fleetSessionsMaxWait = 25 * time.Second

// fleetSessionsRecheck re-reads the answer while a request is held even when
// no heartbeat arrives: the validator also counts rows on a lost machine, and
// a machine goes lost by its silence, not by a beat.
var fleetSessionsRecheck = 5 * time.Second

// changeBroadcast wakes every waiter at once: wait() hands out the current
// channel, fire() closes it and starts a new one. The zero value is ready.
// last is when it last fired — what a test measures a wake-up from.
type changeBroadcast struct {
	mu   sync.Mutex
	ch   chan struct{}
	last time.Time
}

func (b *changeBroadcast) wait() <-chan struct{} {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.ch == nil {
		b.ch = make(chan struct{})
	}
	return b.ch
}

func (b *changeBroadcast) fire() {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.last = time.Now()
	if b.ch != nil {
		close(b.ch)
		b.ch = nil
	}
}

func (b *changeBroadcast) lastFired() time.Time {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.last
}

// fleetSessionsWaitArg reads `wait` — a JSON number, or a query string's
// digits — as a duration capped at fleetSessionsMaxWait; anything else is 0.
func fleetSessionsWaitArg(v any) time.Duration {
	var sec float64
	switch x := v.(type) {
	case json.Number:
		sec, _ = x.Float64()
	case float64:
		sec = x
	case int:
		sec = float64(x)
	case string:
		sec, _ = strconv.ParseFloat(x, 64)
	}
	if !(sec > 0) {
		return 0
	}
	d := time.Duration(sec * float64(time.Second))
	if d > fleetSessionsMaxWait || d < 0 {
		d = fleetSessionsMaxWait
	}
	return d
}

// fleetSessionsWait is fleet_sessions with the long poll: while the request's
// If-None-Match matches the current answer, wait for a heartbeat (or the
// recheck) and read again, until the validator moves, the wait is up, or the
// asker hangs up. What it returns goes through writeFleetResult as always — a
// still-matching validator is the 304.
func (s *Server) fleetSessionsWait(req *http.Request, wait time.Duration) (map[string]any, error) {
	inm := req.Header.Get("If-None-Match")
	if wait <= 0 || inm == "" {
		return s.FleetSessions(req)
	}
	deadline := time.NewTimer(wait)
	defer deadline.Stop()
	for {
		// Subscribe before reading, so a beat between the read and the
		// select is not missed.
		changed := s.sessionsChanged.wait()
		out, err := s.FleetSessions(req)
		if err != nil {
			return out, err
		}
		if tag, _ := out["etag"].(string); tag == "" || !etagMatches(inm, tag) {
			return out, nil
		}
		recheck := time.NewTimer(fleetSessionsRecheck)
		select {
		case <-changed:
		case <-recheck.C:
		case <-deadline.C:
			recheck.Stop()
			return out, nil
		case <-req.Context().Done():
			recheck.Stop()
			return out, nil
		}
		recheck.Stop()
	}
}
