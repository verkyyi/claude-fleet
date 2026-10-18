package api

import (
	"encoding/json"
	"log"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// Pool-usage-silent alerts (claude-fleet#3233, EPIC #3225). A person's usage
// on the subscription pool stopped growing for three days and only a person
// looking noticed: requests kept going out through the cluster credential
// proxy, the usage reports that bill them did not land. The hub sees both
// halves — the proxy asks it to resolve a pass before it forwards (cached
// ≤ 30 s, so a working session asks again and again), and every report is a
// pool_usage row — so a person whose passes kept resolving for longer than the
// threshold with no row under them in that time is raised as
// pool_usage_silent, and cleared the moment a row lands or the proxy stops
// asking. The hub only records, like every fleet alert; the alert is the
// admin's (alertsSeenBy shows a person no row it cannot place).

// defaultPoolUsageSilentAfter is FLEET_POOL_USAGE_SILENT_ALERT_SECS's default:
// the proxy reports each request as it finishes, so half an hour of requests
// with nothing billed is not a slow report.
const defaultPoolUsageSilentAfter = 30 * time.Minute

// poolUsageActiveGap is how long a person's passes may go unresolved and
// still count as one stretch of use: the proxy caches an answer ≤ 30 s, so a
// working session asks at least every few minutes; a longer quiet (no turn
// going) starts the count afresh.
const poolUsageActiveGap = 5 * time.Minute

// poolUsageSilentEvery paces the sweep inside the alerts tick.
const poolUsageSilentEvery = time.Minute

// PoolUsageSilentAfterFromEnv reads FLEET_POOL_USAGE_SILENT_ALERT_SECS: unset,
// empty or not a positive integer → the default; "0" turns the alert off.
func PoolUsageSilentAfterFromEnv() time.Duration {
	v := strings.TrimSpace(os.Getenv("FLEET_POOL_USAGE_SILENT_ALERT_SECS"))
	if v == "0" {
		return -1
	}
	if n, err := strconv.Atoi(v); err == nil && n > 0 {
		return time.Duration(n) * time.Second
	}
	return defaultPoolUsageSilentAfter
}

// poolUsageStretch is one person's current stretch of resolves.
type poolUsageStretch struct{ first, last time.Time }

// poolUsageSilentWatch is the sweep's memory: each person's stretch of
// resolves. Kept in the process — a restarted hub starts counting afresh,
// which only delays an alert, never invents one.
type poolUsageSilentWatch struct {
	mu      sync.Mutex
	last    time.Time
	resolve map[string]poolUsageStretch
}

func (s *Server) poolUsageSilentAfter() time.Duration {
	if s.PoolUsageSilentAfter != 0 {
		return s.PoolUsageSilentAfter
	}
	return defaultPoolUsageSilentAfter
}

// notePoolResolve records that the proxy was handed a credential for
// principal at now — a request about to go out on the pool.
func (s *Server) notePoolResolve(principal string, now time.Time) {
	if principal == "" || s.poolUsageSilentAfter() < 0 {
		return
	}
	w := &s.poolUsageSilent
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.resolve == nil {
		w.resolve = map[string]poolUsageStretch{}
	}
	st, ok := w.resolve[principal]
	if !ok || now.Sub(st.last) > poolUsageActiveGap {
		st.first = now
	}
	if now.After(st.last) {
		st.last = now
	}
	w.resolve[principal] = st
}

// PoolUsageSilentTick is one pool_usage_silent sweep at now (called off the
// alerts tick, paced to poolUsageSilentEvery; force skips the pacing for tests).
func (s *Server) PoolUsageSilentTick(now time.Time, force bool) {
	after := s.poolUsageSilentAfter()
	if after < 0 {
		return
	}
	w := &s.poolUsageSilent
	w.mu.Lock()
	if !force && now.Sub(w.last) < poolUsageSilentEvery {
		w.mu.Unlock()
		return
	}
	w.last = now
	active := map[string]poolUsageStretch{}
	for p, st := range w.resolve {
		if now.Sub(st.last) > poolUsageActiveGap {
			delete(w.resolve, p)
			continue
		}
		active[p] = st
	}
	w.mu.Unlock()

	silent := map[string]bool{}
	for p, st := range active {
		if now.Sub(st.first) < after {
			continue
		}
		last, err := s.Store.PoolUsageLastAt(p, now.Add(-after))
		if err != nil {
			log.Printf("pool usage alerts: read usage of %s: %v", p, err)
			silent[p] = true // unknown: neither raise nor clear
			continue
		}
		if !last.IsZero() {
			continue
		}
		silent[p] = true
		b, _ := json.Marshal(map[string]any{
			"principal": p, "resolving_since": st.first.UTC(), "last_resolve_at": st.last.UTC(),
			"after_secs": int(after / time.Second),
		})
		if raised, err := s.Store.RaiseFleetAlert(store.AlertPoolUsageSilent, p, string(b), now); err != nil {
			log.Printf("pool usage alerts: raise %s: %v", p, err)
		} else if raised {
			log.Printf("fleet alert: pool_usage_silent %s — the proxy has forwarded on their passes since %s, no pool usage taken in %s",
				p, st.first.UTC().Format(time.RFC3339), after)
		}
	}

	open, err := s.Store.OpenFleetAlertSubjects(store.AlertPoolUsageSilent, "")
	if err != nil {
		log.Printf("pool usage alerts: read open: %v", err)
		return
	}
	for _, sub := range open {
		if silent[sub] {
			continue
		}
		if cleared, err := s.Store.ClearFleetAlert(store.AlertPoolUsageSilent, sub, now); err != nil {
			log.Printf("pool usage alerts: clear %s: %v", sub, err)
		} else if cleared {
			log.Printf("fleet alert cleared: pool_usage_silent %s", sub)
		}
	}
}
