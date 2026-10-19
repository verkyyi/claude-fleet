package api

import (
	"math"
	"sync"
	"time"
)

// Placement counts the starts it just sent (claude-fleet#2077, EPIC #2074 C6).
// A new session takes 10–30 s to show in a node's heartbeat — its load, its
// memory, its session count — and in that window every pick of a burst chose
// the same machine: one was pressed full while the other sat idle. recentTable
// is the hub's own memory of what it sent where: one row per start, kept
// recentWindow or until the node's session count has grown past it. judge
// folds the count in (Candidate.Recent) as if those sessions were already
// there — one core of load and recentSessionMem of memory each. The table is
// memory only: a hub restart forgets it, and the worst case is the old pick.
const (
	recentWindow = 90 * time.Second
	// recentSessionMem is what one session in flight is taken to cost in
	// memory: the node's own admission gate reckons an agent's RSS ×3 growth
	// (≈1.2 GB, fleet_machine_headroom), plus its tooling.
	recentSessionMem float64 = 1.5 * (1 << 30)
	// recentDefaultShare is one session's share of a machine whose load or
	// memory the beat did not give (0.5 "middling" in loadScore): the old
	// default cap of 8 sessions a login.
	recentDefaultShare = 0.125
)

type recentStart struct {
	id   uint64
	at   time.Time
	seen int // the heartbeat's session count when sent; -1 unknown
}

// recentTable is endpoint ID → the starts sent there that its heartbeat may
// not show yet. The zero value is ready.
type recentTable struct {
	mu   sync.Mutex
	next uint64
	sent map[string][]recentStart
}

// note records one start sent to endpoint, against the session count its
// heartbeat showed then (nil: unknown), and returns the handle forget takes.
func (t *recentTable) note(endpoint string, seen *int, now time.Time) uint64 {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.sent == nil {
		t.sent = map[string][]recentStart{}
	}
	t.next++
	s := recentStart{id: t.next, at: now, seen: -1}
	if seen != nil {
		s.seen = *seen
	}
	t.sent[endpoint] = append(t.sent[endpoint], s)
	return t.next
}

// forget drops one noted start: the node refused it before anything opened.
func (t *recentTable) forget(endpoint string, id uint64) {
	t.mu.Lock()
	defer t.mu.Unlock()
	rows := t.sent[endpoint]
	for i, r := range rows {
		if r.id == id {
			t.sent[endpoint] = append(rows[:i:i], rows[i+1:]...)
			return
		}
	}
}

// count is how many starts sent to endpoint its heartbeat may not show yet,
// given the session count it shows now (nil: unknown). A start older than
// recentWindow is gone. When the count has grown since the oldest start was
// sent, that many are taken as shown — oldest first — and the rest are
// measured against the new count, so one beat is never credited twice; a
// count that fell (a session ended) credits nothing, and those rows age out.
func (t *recentTable) count(endpoint string, sessions *int, now time.Time) int {
	t.mu.Lock()
	defer t.mu.Unlock()
	rows := t.sent[endpoint]
	if len(rows) == 0 {
		return 0
	}
	keep := rows[:0]
	for _, r := range rows {
		if now.Sub(r.at) < recentWindow {
			keep = append(keep, r)
		}
	}
	if sessions != nil {
		base := -1
		for _, r := range keep {
			if r.seen >= 0 && (base < 0 || r.seen < base) {
				base = r.seen
			}
		}
		if base >= 0 && *sessions > base {
			grown := *sessions - base
			if grown >= len(keep) {
				keep = keep[:0]
			} else {
				keep = keep[grown:]
			}
			for i := range keep {
				if keep[i].seen >= 0 && keep[i].seen < *sessions {
					keep[i].seen = *sessions
				}
			}
		}
	}
	if len(keep) == 0 {
		delete(t.sent, endpoint)
	} else {
		t.sent[endpoint] = keep
	}
	return len(keep)
}

// recentScore is loadScore with recent starts in flight folded in: each adds
// one core of load (1/ncpu per core) and recentSessionMem of memory to the
// beat's readings before the tighter of the two is taken; a reading the beat
// did not give loses recentDefaultShare of its middling 0.5 per start. With
// nothing in flight it is loadScore, byte for byte.
func recentScore(loadPerCore *float64, ncpu int, memFree, memTotal uint64, recent int) float64 {
	if recent <= 0 {
		return loadScore(loadPerCore, memFree, memTotal)
	}
	n := float64(recent)
	cpu := 0.5 * math.Max(0, 1-recentDefaultShare*n)
	mem := cpu
	if loadPerCore != nil && ncpu > 0 {
		cpu = clamp01(1 - (*loadPerCore+n/float64(ncpu))/maxLoadPerCore)
	}
	if memTotal > 0 {
		free := math.Max(0, float64(memFree)-n*recentSessionMem)
		mem = clamp01(free / float64(memTotal))
	}
	return math.Min(cpu, mem)
}
