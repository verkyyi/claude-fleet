package api

import (
	"fmt"
	"log"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

// A browser terminal that comes back by itself (task RMVE).
//
// Two halves live here. Drain: when this hub replica is told to stop (a
// rolling release sends SIGTERM), every open terminal attachment is told
// `hub_restart` — the page reconnects at once, to the replica still up —
// and this replica's fleet_replicas row goes, so the other one stops handing
// it the in-memory state's requests. Health: GET TermHealthPath reads
// fleet_term_sessions back as the numbers the task is judged by — how often a
// page that was opened got a terminal, how often a drop came back by itself
// and how fast, how often a person had to press a button.

// TermHealthPath is the operator's read of the terminal numbers.
const TermHealthPath = "/v1/fleet/term/health"

// drainState is closed once, when the hub starts going away.
type drainState struct {
	once sync.Once
	ch   chan struct{}
	mu   sync.Mutex
}

func (s *Server) drainCh() <-chan struct{} { return s.drainChan() }

func (s *Server) drainChan() chan struct{} {
	s.drain.mu.Lock()
	defer s.drain.mu.Unlock()
	if s.drain.ch == nil {
		s.drain.ch = make(chan struct{})
	}
	return s.drain.ch
}

// Draining reports whether Drain was called.
func (s *Server) Draining() bool {
	select {
	case <-s.drainCh():
		return true
	default:
		return false
	}
}

// Drain tells every open terminal to come back elsewhere and drops this
// replica's row. Called once, before the listeners shut down.
func (s *Server) Drain() {
	ch := s.drainChan()
	s.drain.once.Do(func() {
		close(ch)
		if s.Replica != nil && s.Store != nil {
			if err := s.Store.ForgetReplica(s.Replica.Name); err != nil {
				log.Printf("fleet: replica %s: forget on drain: %v", s.Replica.Name, err)
			}
		}
	})
}

// termCause is the browser's word for why it connects; anything else is "".
func termCause(c string) string {
	switch c {
	case "first", "auto", "manual", "take", "renew":
		return c
	}
	return ""
}

// termReason is a node's error word as recorded; an unknown one is node_error.
func termReason(e string) string {
	switch e {
	case "ended", "open_elsewhere", "interrupted", "invalid_renew", "door_unavailable", "unsupported", "not_yours":
		return e
	}
	return "node_error"
}

// termEndReason is what follows the path in a closed row's outcome.
func termEndReason(outcome string) string {
	if i := strings.LastIndex(outcome, "; "); i >= 0 {
		return outcome[i+2:]
	}
	return ""
}

// TermHealth is GET TermHealthPath's answer.
type TermHealth struct {
	Since    time.Time `json:"since"`
	Sessions int       `json:"sessions"`
	// opens: a page opened (or a button pressed) — got a path within 10 s
	Opens   int `json:"opens"`
	OpensOK int `json:"opens_ok"`
	// drops: a terminal that had a path ended by anything but its page going
	Drops       int            `json:"drops"`
	Recovered   int            `json:"recovered"`
	RecoverP50  float64        `json:"recover_p50_secs"`
	RecoverP95  float64        `json:"recover_p95_secs"`
	DropReasons map[string]int `json:"drop_reasons"`
	// manual: connections a button made (sign-in excluded: that is a page load)
	Manual int `json:"manual"`
	// unrecorded: a path, no close — the replica went before writing it
	Unrecorded int `json:"unrecorded"`
}

// termHealth computes the numbers over rows (oldest first).
func termHealth(rows []store.FleetTermSession, since, now time.Time) TermHealth {
	h := TermHealth{Since: since, Sessions: len(rows), DropReasons: map[string]int{}}
	next := map[string][]store.FleetTermSession{}
	for _, r := range rows {
		if r.Previous != "" {
			next[r.Previous] = append(next[r.Previous], r)
		}
	}
	// the first of r's successors (following previous links) that got a path
	var back func(id string, depth int) time.Time
	back = func(id string, depth int) time.Time {
		var best time.Time
		if depth > 50 {
			return best
		}
		for _, c := range next[id] {
			t := c.SelectedAt
			if t.IsZero() {
				t = back(c.ID, depth+1)
			}
			if !t.IsZero() && (best.IsZero() || t.Before(best)) {
				best = t
			}
		}
		return best
	}
	var secs []float64
	for _, r := range rows {
		switch r.Cause {
		case "first", "manual":
			h.Opens++
			if !r.SelectedAt.IsZero() && r.SelectedAt.Sub(r.OpenedAt) <= 10*time.Second {
				h.OpensOK++
			}
		}
		if r.Cause == "manual" {
			h.Manual++
		}
		if r.SelectedAt.IsZero() {
			continue
		}
		if r.ClosedAt.IsZero() {
			if now.Sub(r.OpenedAt) > 24*time.Hour {
				h.Unrecorded++
			}
			continue
		}
		why := termEndReason(r.Outcome)
		if why == "browser_closed" || why == "" {
			continue
		}
		h.Drops++
		h.DropReasons[why]++
		if t := back(r.ID, 0); !t.IsZero() && t.Sub(r.ClosedAt) <= time.Minute {
			h.Recovered++
			secs = append(secs, t.Sub(r.ClosedAt).Seconds())
		}
	}
	if len(secs) > 0 {
		sort.Float64s(secs)
		at := func(q float64) float64 { return secs[min(len(secs)-1, int(q*float64(len(secs))))] }
		h.RecoverP50, h.RecoverP95 = at(0.5), at(0.95)
	}
	return h
}

func (s *Server) handleTermHealth(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Allow", "GET, HEAD")
		httpError(w, http.StatusMethodNotAllowed, "GET only")
		return
	}
	hours := 24
	if v := r.URL.Query().Get("hours"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n < 1 || n > 24*30 {
			httpError(w, http.StatusBadRequest, fmt.Sprintf("hours: want 1..720, got %q", firstLine(v)))
			return
		}
		hours = n
	}
	if s.Store == nil {
		http.NotFound(w, r)
		return
	}
	now := time.Now().UTC()
	since := now.Add(-time.Duration(hours) * time.Hour)
	rows, err := s.Store.FleetTermSessionsSince(since)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, termHealth(rows, since, now))
}
