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

// Usage-silent alerts (claude-fleet#3204). Login verky ran Claude on two
// machines for three days and the hub took none of it: its ~/.claude.json had
// no /login, so the agent skipped every Claude scan and said nothing. To the
// hub that looked exactly like a login nobody used. The fleet inventory says
// otherwise — it names every session and whether it is working — so a
// (machine, login) with a session working for longer than the threshold and
// no turn of that agent in that time is raised as usage_silent, and cleared
// the moment a turn lands or nothing is working any more. The hub only
// records, like every fleet alert.

// defaultUsageSilentAfter is FLEET_USAGE_SILENT_ALERT_SECS's default: a
// working session writes a turn every few minutes, and the agent pushes once
// a minute, so half an hour of silence is not a slow scan.
const defaultUsageSilentAfter = 30 * time.Minute

// usageSilentEvery paces the sweep inside the alerts tick: the judgement is
// in minutes, so reading every fleet row every 15 s buys nothing.
const usageSilentEvery = time.Minute

// usageSilentFresh is how old a fleet row may be and still say what is
// working now: an inventory a node stopped sending is node_lost's to report.
const usageSilentFresh = 5 * time.Minute

// UsageSilentAfterFromEnv reads FLEET_USAGE_SILENT_ALERT_SECS: unset, empty or
// not a positive integer → the default; "0" turns the alert off.
func UsageSilentAfterFromEnv() time.Duration {
	v := strings.TrimSpace(os.Getenv("FLEET_USAGE_SILENT_ALERT_SECS"))
	if v == "0" {
		return -1
	}
	if n, err := strconv.Atoi(v); err == nil && n > 0 {
		return time.Duration(n) * time.Second
	}
	return defaultUsageSilentAfter
}

// usageSilentWatch is the sweep's memory: since when each (endpoint, login,
// source) has had a session working without a break. Kept in the process —
// a replica that takes over the sweep starts counting afresh, which only
// delays an alert, never invents one.
type usageSilentWatch struct {
	mu        sync.Mutex
	last      time.Time
	busySince map[string]time.Time
}

// usageKey is one (endpoint, login, source) the sweep judges.
type usageKey struct {
	endpoint, hostname, osUser, source string
}

func (k usageKey) subject() string { return k.endpoint + "/" + k.source }

func (s *Server) usageSilentAfter() time.Duration {
	if s.UsageSilentAfter != 0 {
		return s.UsageSilentAfter
	}
	return defaultUsageSilentAfter
}

// workingAgents counts, per agent, the sessions of one fleet row that are
// working now. A window that names no agent runs the fleet's.
func workingAgents(row store.FleetRow) map[string]int {
	var ws []struct {
		Agent string `json:"agent"`
		State string `json:"state"`
	}
	if json.Unmarshal([]byte(row.WorkersJSON), &ws) != nil {
		return nil
	}
	out := map[string]int{}
	for _, w := range ws {
		// "working" only: a looping session may sleep an hour between turns,
		// and one waiting on a person spends nothing.
		if w.State != "working" {
			continue
		}
		agent := w.Agent
		if agent == "" {
			agent = row.Agent
		}
		if agent == "claude" || agent == "codex" {
			out[agent]++
		}
	}
	return out
}

// UsageSilentTick is one usage_silent sweep at now (called off the alerts
// tick, paced to usageSilentEvery; force skips the pacing for tests).
func (s *Server) UsageSilentTick(now time.Time, force bool) {
	after := s.usageSilentAfter()
	if after < 0 {
		return
	}
	w := &s.usageSilent
	w.mu.Lock()
	defer w.mu.Unlock()
	if !force && now.Sub(w.last) < usageSilentEvery {
		return
	}
	w.last = now
	if w.busySince == nil {
		w.busySince = map[string]time.Time{}
	}

	fleets, err := s.Store.Fleets()
	if err != nil {
		log.Printf("usage alerts: read fleets: %v", err)
		return
	}
	busy := map[usageKey]int{}
	for _, f := range fleets {
		if !f.Present || f.EndpointID == "" || f.OSUser == "" || now.Sub(f.ObservedAt) > usageSilentFresh {
			continue
		}
		for agent, n := range workingAgents(f) {
			busy[usageKey{f.EndpointID, f.Hostname, f.OSUser, agent}] += n
		}
	}

	silent := map[string]bool{}
	seen := map[string]bool{}
	for k, n := range busy {
		// An endpoint is one login's (each login enrolls its own), so the
		// subject names the login too.
		sub := k.subject()
		seen[sub] = true
		since, ok := w.busySince[sub]
		if !ok {
			w.busySince[sub] = now
			continue
		}
		if now.Sub(since) < after {
			continue
		}
		last, err := s.Store.LastUsageAt(k.endpoint, k.osUser, k.source, now.Add(-after))
		if err != nil {
			log.Printf("usage alerts: read usage of %s: %v", sub, err)
			silent[sub] = true // unknown: neither raise nor clear
			continue
		}
		if !last.IsZero() && now.Sub(last) <= after {
			continue
		}
		silent[k.subject()] = true
		detail := map[string]any{
			"endpoint_id": k.endpoint, "hostname": k.hostname, "os_user": k.osUser,
			"source": k.source, "working": n, "working_since": since.UTC(),
			"after_secs": int(after / time.Second),
		}
		if !last.IsZero() {
			detail["last_usage_at"] = last
		}
		b, _ := json.Marshal(detail)
		if raised, err := s.Store.RaiseFleetAlert(store.AlertUsageSilent, k.subject(), string(b), now); err != nil {
			log.Printf("usage alerts: raise %s: %v", k.subject(), err)
		} else if raised {
			log.Printf("fleet alert: usage_silent %s@%s %s — %d session(s) working since %s, no usage taken in %s",
				k.osUser, nodeLabel(k.hostname), k.source, n, since.UTC().Format(time.RFC3339), after)
		}
	}
	for sub := range w.busySince {
		if !seen[sub] {
			delete(w.busySince, sub)
		}
	}

	open, err := s.Store.OpenFleetAlertSubjects(store.AlertUsageSilent, "")
	if err != nil {
		log.Printf("usage alerts: read open: %v", err)
		return
	}
	for _, sub := range open {
		if silent[sub] {
			continue
		}
		if cleared, err := s.Store.ClearFleetAlert(store.AlertUsageSilent, sub, now); err != nil {
			log.Printf("usage alerts: clear %s: %v", sub, err)
		} else if cleared {
			log.Printf("fleet alert cleared: usage_silent %s", sub)
		}
	}
}
