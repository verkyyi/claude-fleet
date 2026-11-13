package api

import (
	"net/http"
	"net/netip"
	"sync"
	"time"
)

// clientBudget is a per-source token bucket in front of a hub-wide limit on a
// road anyone may call: one source spends its own budget, not everyone's, and
// the hub-wide limit stays behind it as the ceiling. The source is the
// request's client address as the hub reads it everywhere (chatClientIP, after
// forwardedTrust); an IPv6 address counts by its /64. The table is bounded:
// when full, buckets back at full are dropped, and a source that still finds
// no room goes untracked — the hub-wide limit still holds it. In memory, so
// with several replicas each keeps its own.
type clientBudget struct {
	burst  float64 // what a new source may spend at once
	perSec float64 // what it earns back each second
	max    int     // sources tracked at once

	mu sync.Mutex
	m  map[netip.Addr]*clientBucket
}

type clientBucket struct {
	tokens float64
	last   time.Time
}

// clientSource is the key r's budget is kept under.
func clientSource(r *http.Request) netip.Addr {
	a := chatClientIP(r)
	if a.Is6() {
		if p, err := a.Prefix(64); err == nil {
			return p.Addr()
		}
	}
	return a
}

// allow spends one from r's source; false when its budget is spent.
func (b *clientBudget) allow(r *http.Request, now time.Time) bool {
	return b.allowFrom(clientSource(r), now)
}

func (b *clientBudget) allowFrom(src netip.Addr, now time.Time) bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.m == nil {
		b.m = map[netip.Addr]*clientBucket{}
	}
	k := b.m[src]
	if k == nil {
		if len(b.m) >= b.max {
			b.sweep(now)
		}
		if len(b.m) >= b.max {
			return true
		}
		k = &clientBucket{tokens: b.burst, last: now}
		b.m[src] = k
	}
	if now.After(k.last) {
		k.tokens += now.Sub(k.last).Seconds() * b.perSec
		if k.tokens > b.burst {
			k.tokens = b.burst
		}
		k.last = now
	}
	if k.tokens < 1 {
		return false
	}
	k.tokens--
	return true
}

// sweep drops the buckets that have earned back to full: forgetting them
// changes nothing.
func (b *clientBudget) sweep(now time.Time) {
	for src, k := range b.m {
		if k.tokens+now.Sub(k.last).Seconds()*b.perSec >= b.burst {
			delete(b.m, src)
		}
	}
}

// serverBudgets holds the per-server budgets whose limit is not a field of
// Server (one per Server, so test servers do not share a budget).
var serverBudgets sync.Map // budgetKey → *clientBudget

type budgetKey struct {
	s    *Server
	road string
}

func (s *Server) budget(road string, mk func() *clientBudget) *clientBudget {
	if b, ok := serverBudgets.Load(budgetKey{s, road}); ok {
		return b.(*clientBudget)
	}
	b, _ := serverBudgets.LoadOrStore(budgetKey{s, road}, mk())
	return b.(*clientBudget)
}
