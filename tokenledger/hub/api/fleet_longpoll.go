package api

import (
	"context"
	"encoding/json"
	"net/http"
	"strconv"
	"strings"
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
//
// writing counts recordings in flight (claude-fleet#3396): begin() before a
// heartbeat's first write, end() after its last, so a reader can tell that
// what it just read may be half one beat and half the one before.
type changeBroadcast struct {
	mu      sync.Mutex
	ch      chan struct{}
	last    time.Time
	writing int
	// seq counts fires; keys holds, per key fireFor named, the seq it last
	// fired at (one entry per machine login — a few dozen). A plain fire()
	// names no key and is everyone's (anyKey).
	seq  uint64
	keys map[string]uint64
}

// anyKey is the key of a fire() that names nobody: it concerns every waiter.
const anyKey = "\x00any"

// begin marks a recording in flight; every begin is paired with one end.
func (b *changeBroadcast) begin() {
	b.mu.Lock()
	b.writing++
	b.mu.Unlock()
}

// end closes what begin opened. It wakes nobody: fire() does.
func (b *changeBroadcast) end() {
	b.mu.Lock()
	if b.writing > 0 {
		b.writing--
	}
	b.mu.Unlock()
}

// settled says a read that started when wait() handed out ch saw one
// consistent state: nothing fired since and no recording is in flight.
func (b *changeBroadcast) settled(ch <-chan struct{}) bool {
	select {
	case <-ch:
		return false
	default:
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.writing == 0
}

func (b *changeBroadcast) wait() <-chan struct{} {
	ch, _ := b.waitSeq()
	return ch
}

// waitSeq is wait() plus the fire count at that moment: firedSince(seq, …)
// later says what fired after it.
func (b *changeBroadcast) waitSeq() (<-chan struct{}, uint64) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.ch == nil {
		b.ch = make(chan struct{})
	}
	return b.ch, b.seq
}

func (b *changeBroadcast) fire() { b.fireFor(anyKey) }

// fireFor wakes every waiter, remembering that the change was key's.
func (b *changeBroadcast) fireFor(key string) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.last = time.Now()
	b.seq++
	if b.keys == nil {
		b.keys = map[string]uint64{}
	}
	b.keys[key] = b.seq
	if b.ch != nil {
		close(b.ch)
		b.ch = nil
	}
}

// firedSince reports whether a fire after seq was for a key that concerns
// the asker (or for anyKey).
func (b *changeBroadcast) firedSince(seq uint64, concerns func(key string) bool) bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	for k, at := range b.keys {
		if at > seq && (k == anyKey || concerns(k)) {
			return true
		}
	}
	return false
}

// loginKey is a heartbeat's key on sessionsChanged: the (machine, login) its
// rows are recorded under, the pair a principal's scope is asked about.
func loginKey(hostname, osUser string) string { return hostname + "\x00" + osUser }

func splitLoginKey(k string) (hostname, osUser string, ok bool) {
	i := strings.IndexByte(k, 0)
	if i < 0 {
		return "", "", false
	}
	return k[:i], k[i+1:], true
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
	p, err := s.FleetPrincipal(req)
	if err != nil {
		return nil, err
	}
	concerns := func(k string) bool {
		h, u, ok := splitLoginKey(k)
		return !ok || p.sees(h, u)
	}
	deadline := time.NewTimer(wait)
	defer deadline.Stop()
	for {
		// Subscribe before reading, so a beat between the read and the
		// select is not missed.
		changed, seq := s.sessionsChanged.waitSeq()
		out, err := s.FleetSessions(req) // scope resolved again on every read
		if err != nil {
			return out, err
		}
		if tag, _ := out["etag"].(string); tag == "" || !etagMatches(inm, tag) {
			return out, nil
		}
		built := time.Now()
		recheck := time.NewTimer(fleetSessionsRecheck)
		// Wait for a reason to read again: a beat from a login this caller
		// sees (at once), anyone else's beat (at most every
		// fleetSessionsOtherEvery — what the answer holds beyond the rows,
		// its records and tokens, still shows as soon as before), the
		// recheck, the deadline or the asker leaving.
		var other <-chan time.Time
		var otherT *time.Timer
		read := false
		for !read {
			waited := time.Now()
			select {
			case <-changed:
				if s.sessionsChanged.firedSince(seq, concerns) {
					read = true
					break
				}
				changed, _ = s.sessionsChanged.waitSeq()
				if otherT == nil {
					otherT = time.NewTimer(time.Until(built.Add(fleetSessionsOtherEvery)))
					other = otherT.C
				}
			case <-other:
				read = true
			case <-recheck.C:
				read = true
			case <-deadline.C:
				recheck.Stop()
				stopTimer(otherT)
				addHeld(req.Context(), time.Since(waited))
				return out, nil
			case <-req.Context().Done():
				recheck.Stop()
				stopTimer(otherT)
				addHeld(req.Context(), time.Since(waited))
				return out, nil
			}
			addHeld(req.Context(), time.Since(waited))
		}
		recheck.Stop()
		stopTimer(otherT)
	}
}

// fleetSessionsOtherEvery bounds how often a held fleet_sessions request
// re-reads for heartbeats from logins its caller does not see (task PNWW):
// they cannot move its rows, only what rides beside them.
var fleetSessionsOtherEvery = time.Second

func stopTimer(t *time.Timer) {
	if t != nil {
		t.Stop()
	}
}

// heldKey carries how long a long poll waited for a change out to the access
// log, which logs it as held=<d> beside the request's total time.
type heldKey struct{}

func addHeld(ctx context.Context, d time.Duration) {
	if p, ok := ctx.Value(heldKey{}).(*time.Duration); ok && p != nil {
		*p += d
	}
}
