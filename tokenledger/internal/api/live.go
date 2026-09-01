package api

import (
	"encoding/json"
	"fmt"
	"net/http"
	"sort"
	"sync"
	"time"
)

// LiveSession is one running Claude Code session as its own statusLine
// reported it, seconds ago.
//
// This is deliberately NOT the same quantity as the stored usage events. It is
// Claude Code's own per-session accounting, arriving on a seconds-scale
// heartbeat, whereas the transcript scan is a minute behind by design and is
// the durable record. The dashboard shows this as a live indicator and never
// adds it to the totals — two different measurements of overlapping things,
// summed, would be wrong in a way nobody could see.
type LiveSession struct {
	SessionID  string    `json:"session_id"`
	EndpointID string    `json:"endpoint_id"`
	Endpoint   string    `json:"endpoint"`
	Account    string    `json:"account,omitempty"`
	SeenAt     time.Time `json:"seen_at"`

	CostUSD      float64 `json:"cost_usd"`
	InputTokens  int64   `json:"input_tokens"`
	OutputTokens int64   `json:"output_tokens"`
	LinesAdded   int64   `json:"lines_added"`
	LinesRemoved int64   `json:"lines_removed"`

	ContextUsedPct float64 `json:"context_used_pct"`
	CacheHitRatio  float64 `json:"cache_hit_ratio"`
	Model          string  `json:"model,omitempty"`
	Effort         string  `json:"effort,omitempty"`
	Worktree       string  `json:"worktree,omitempty"`
	CWD            string  `json:"cwd,omitempty"`

	// Billing separates plan-consuming sessions from API-key ones. Only the
	// former draw down a subscription's quota; adding API spend to a plan's
	// utilization would misattribute it entirely.
	Billing string `json:"billing,omitempty"`

	// TokensPerMin and USDPerHour are derived from consecutive reports of the
	// same session. They are the only genuinely "live" rates in the system.
	TokensPerMin float64 `json:"tokens_per_min"`
	USDPerHour   float64 `json:"usd_per_hour"`
}

// activeWindow is how long a session counts as running after its last report.
//
// Claude Code redraws the statusLine every turn, so a session that is actually
// working reports far more often than this. A longer window would leave
// finished sessions on screen pretending to be alive.
const activeWindow = 3 * time.Minute

// Live holds the current state of every reporting session, in memory only.
//
// Nothing here is persisted: it describes what is happening this minute, and a
// hub restart legitimately knows nothing until the agents report again.
// Writing it to SQLite would add write amplification on a seconds-scale
// heartbeat for data whose value expires in minutes.
type Live struct {
	mu       sync.RWMutex
	sessions map[string]*LiveSession
	subs     map[chan []byte]struct{}
}

// NewLive returns an empty live store.
func NewLive() *Live {
	return &Live{sessions: map[string]*LiveSession{}, subs: map[chan []byte]struct{}{}}
}

// Report merges an endpoint's snapshot of its running sessions.
func (l *Live) Report(endpointID, endpointLabel string, in []LiveSession) {
	now := time.Now().UTC()

	l.mu.Lock()
	for i := range in {
		s := in[i]
		s.EndpointID = endpointID
		s.Endpoint = endpointLabel
		s.SeenAt = now

		// Rates come from the change between two reports of the same session.
		// A single report carries running totals and cannot express a rate.
		if prev, ok := l.sessions[s.SessionID]; ok {
			if dt := now.Sub(prev.SeenAt).Minutes(); dt > 0.01 {
				dTok := float64((s.InputTokens + s.OutputTokens) - (prev.InputTokens + prev.OutputTokens))
				if dTok >= 0 {
					s.TokensPerMin = dTok / dt
				}
				dUSD := s.CostUSD - prev.CostUSD
				if dUSD >= 0 {
					s.USDPerHour = dUSD / (dt / 60)
				}
			}
		}
		l.sessions[s.SessionID] = &s
	}
	l.pruneLocked(now)
	l.mu.Unlock()

	l.broadcast()
}

func (l *Live) pruneLocked(now time.Time) {
	for id, s := range l.sessions {
		if now.Sub(s.SeenAt) > activeWindow {
			delete(l.sessions, id)
		}
	}
}

// Snapshot is the whole live picture.
type Snapshot struct {
	At       time.Time     `json:"at"`
	Sessions []LiveSession `json:"sessions"`

	ActiveSessions int     `json:"active_sessions"`
	APISessions    int     `json:"api_sessions"`
	Endpoints      int     `json:"endpoints"`
	TokensPerMin   float64 `json:"tokens_per_min"`
	USDPerHour     float64 `json:"usd_per_hour"`
	LinesAdded     int64   `json:"lines_added"`
	LinesRemoved   int64   `json:"lines_removed"`

	Note string `json:"note"`
}

const liveNote = "Live figures come from each session's own statusLine, seconds old. " +
	"They are Claude Code's per-session accounting and are shown alongside the " +
	"stored totals, never added to them."

// Snapshot returns the current picture, newest-busiest first.
func (l *Live) Snapshot() Snapshot {
	now := time.Now().UTC()

	l.mu.Lock()
	l.pruneLocked(now)
	out := Snapshot{At: now, Note: liveNote, Sessions: make([]LiveSession, 0, len(l.sessions))}
	eps := map[string]struct{}{}
	for _, s := range l.sessions {
		out.Sessions = append(out.Sessions, *s)
		eps[s.EndpointID] = struct{}{}
		out.TokensPerMin += s.TokensPerMin
		out.USDPerHour += s.USDPerHour
		out.LinesAdded += s.LinesAdded
		out.LinesRemoved += s.LinesRemoved
		if s.Billing == "api" {
			out.APISessions++
		}
	}
	l.mu.Unlock()

	out.ActiveSessions = len(out.Sessions)
	out.Endpoints = len(eps)
	sort.Slice(out.Sessions, func(i, j int) bool {
		if out.Sessions[i].TokensPerMin != out.Sessions[j].TokensPerMin {
			return out.Sessions[i].TokensPerMin > out.Sessions[j].TokensPerMin
		}
		return out.Sessions[i].SessionID < out.Sessions[j].SessionID
	})
	return out
}

// subscribe registers a listener for pushed snapshots.
func (l *Live) subscribe() chan []byte {
	// Buffered so a slow browser cannot block an agent's report; a listener
	// that falls behind loses frames rather than stalling the fleet.
	ch := make(chan []byte, 4)
	l.mu.Lock()
	l.subs[ch] = struct{}{}
	l.mu.Unlock()
	return ch
}

func (l *Live) unsubscribe(ch chan []byte) {
	l.mu.Lock()
	delete(l.subs, ch)
	l.mu.Unlock()
	close(ch)
}

func (l *Live) broadcast() {
	b, err := json.Marshal(l.Snapshot())
	if err != nil {
		return
	}
	l.mu.RLock()
	defer l.mu.RUnlock()
	for ch := range l.subs {
		select {
		case ch <- b:
		default: // drop rather than block
		}
	}
}

// --- HTTP ----------------------------------------------------------------

// handleLiveReport accepts an endpoint's snapshot of its running sessions.
func (s *Server) handleLiveReport(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		httpError(w, http.StatusMethodNotAllowed, "POST required")
		return
	}
	tok := bearer(r)
	if tok == "" {
		httpError(w, http.StatusUnauthorized, "missing bearer token")
		return
	}
	ep, err := s.Store.EndpointByTokenHash(HashToken(tok))
	if err != nil {
		httpError(w, http.StatusUnauthorized, "unrecognised enrollment token")
		return
	}

	var body struct {
		Sessions []LiveSession `json:"sessions"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<20)).Decode(&body); err != nil {
		httpError(w, http.StatusBadRequest, "malformed live report: "+err.Error())
		return
	}

	label := ep.Label
	if label == "" {
		label = ep.Hostname
	}
	s.LiveStore.Report(ep.ID, label, body.Sessions)
	writeJSON(w, http.StatusOK, map[string]any{"accepted": len(body.Sessions)})
}

// handleLiveSnapshot returns the current picture as plain JSON.
func (s *Server) handleLiveSnapshot(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, s.LiveStore.Snapshot())
}

// handleLiveStream pushes snapshots over Server-Sent Events.
//
// SSE rather than websockets: this is one-way, it is a handful of KB every few
// seconds, and it survives proxies that would need explicit upgrade handling.
func (s *Server) handleLiveStream(w http.ResponseWriter, r *http.Request) {
	flusher, ok := w.(http.Flusher)
	if !ok {
		httpError(w, http.StatusInternalServerError, "streaming unsupported")
		return
	}

	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	// Nginx buffers proxied responses by default, which would hold every event
	// until the stream ends — the whole point being that it never does.
	w.Header().Set("X-Accel-Buffering", "no")
	w.WriteHeader(http.StatusOK)

	// Send the current state immediately: a viewer should not wait for the
	// next agent report to see anything.
	if b, err := json.Marshal(s.LiveStore.Snapshot()); err == nil {
		fmt.Fprintf(w, "data: %s\n\n", b)
		flusher.Flush()
	}

	ch := s.LiveStore.subscribe()
	defer s.LiveStore.unsubscribe(ch)

	// A heartbeat keeps intermediaries from timing out an idle stream, and
	// lets the browser notice a dead connection.
	beat := time.NewTicker(20 * time.Second)
	defer beat.Stop()

	for {
		select {
		case <-r.Context().Done():
			return
		case b := <-ch:
			fmt.Fprintf(w, "data: %s\n\n", b)
			flusher.Flush()
		case <-beat.C:
			fmt.Fprint(w, ": keepalive\n\n")
			flusher.Flush()
		}
	}
}
