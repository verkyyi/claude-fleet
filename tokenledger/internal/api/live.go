package api

import (
	"encoding/json"
	"fmt"
	"net/http"
	"sort"
	"sync"
	"time"

	"github.com/verkyyi/ccquota/internal/model"
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
	Source         string    `json:"source"`
	ProfileID      string    `json:"profile_id,omitempty"`
	ObservedAt     time.Time `json:"observed_at"`
	State          string    `json:"state"`
	ContextUnknown bool      `json:"context_unknown,omitempty"`
	CostUnknown    bool      `json:"cost_unknown,omitempty"`
	LinesUnknown   bool      `json:"lines_unknown,omitempty"`
	SessionID      string    `json:"session_id"`
	EndpointID     string    `json:"endpoint_id"`
	Endpoint       string    `json:"endpoint"`
	Account        string    `json:"account,omitempty"`
	SeenAt         time.Time `json:"seen_at"`

	// OSUser is filled in by the hub's enrich hook from the endpoint's own
	// record, not reported by the agent on every heartbeat: Live has no store
	// access of its own, and the login rarely changes mid-session.
	OSUser string `json:"os_user,omitempty"`

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

	// enrich attaches data Live cannot reach on its own — the durable token
	// total behind the hero counter, which lives in the store. Snapshots go out
	// from three places, including a broadcast inside this type, so the hook
	// belongs here rather than at each call site: one of the three would
	// otherwise quietly ship a snapshot with no counter and the number would
	// freeze for exactly the viewers watching it live.
	enrich func(*Snapshot)
}

// Enrich registers a hook run on every snapshot before it is sent.
func (l *Live) Enrich(fn func(*Snapshot)) {
	l.mu.Lock()
	l.enrich = fn
	l.mu.Unlock()
}

// NewLive returns an empty live store.
func NewLive() *Live {
	return &Live{sessions: map[string]*LiveSession{}, subs: map[chan []byte]struct{}{}}
}

// Report merges an endpoint's snapshot of its running sessions.
func (l *Live) Report(endpointID, endpointLabel string, in []LiveSession) {
	l.report(endpointID, endpointLabel, in, false)
}

func liveKey(s LiveSession) string {
	return s.EndpointID + "\x00" + s.Source + "\x00" + s.ProfileID + "\x00" + s.SessionID
}

func (l *Live) report(endpointID, endpointLabel string, in []LiveSession, complete bool) {
	now := time.Now().UTC()

	l.mu.Lock()
	present := map[string]bool{}
	for i := range in {
		s := in[i]
		s.Source = model.UsageSource(s.Source)
		s.EndpointID = endpointID
		s.Endpoint = endpointLabel
		s.SeenAt = now
		if s.ObservedAt.IsZero() && s.Source == model.SourceClaude {
			s.ObservedAt = now
		}
		key := liveKey(s)
		if s.SessionID == "" || s.ObservedAt.IsZero() || s.ObservedAt.After(now.Add(time.Minute)) || now.Sub(s.ObservedAt) > activeWindow || s.State == "completed" || s.State == "interrupted" {
			delete(l.sessions, key)
			continue
		}
		present[key] = true

		// Rates come from the change between two reports of the same session.
		// A single report carries running totals and cannot express a rate.
		if prev, ok := l.sessions[key]; ok {
			if s.ObservedAt.Before(prev.ObservedAt) {
				continue
			}
			if dt := s.ObservedAt.Sub(prev.ObservedAt).Minutes(); dt > 0.01 {
				dTok := float64((s.InputTokens + s.OutputTokens) - (prev.InputTokens + prev.OutputTokens))
				if dTok >= 0 {
					s.TokensPerMin = dTok / dt
				}
				dUSD := s.CostUSD - prev.CostUSD
				if dUSD >= 0 && !s.CostUnknown && !prev.CostUnknown {
					s.USDPerHour = dUSD / (dt / 60)
				}
			}
		}
		l.sessions[key] = &s
	}
	if complete {
		for key, s := range l.sessions {
			if s.EndpointID == endpointID && !present[key] {
				delete(l.sessions, key)
			}
		}
	}
	l.pruneLocked(now)
	l.mu.Unlock()

	l.broadcast()
}

func (l *Live) pruneLocked(now time.Time) {
	for id, s := range l.sessions {
		if now.Sub(s.SeenAt) > activeWindow || (!s.ObservedAt.IsZero() && now.Sub(s.ObservedAt) > activeWindow) {
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

	// USDPerHour is the notional burn rate; USDPerHourBilled is the metered
	// one. See SessionCost below for why they are two fields.
	USDPerHour       float64 `json:"usd_per_hour"`
	USDPerHourBilled float64 `json:"usd_per_hour_billed"`

	LinesAdded   int64 `json:"lines_added"`
	LinesRemoved int64 `json:"lines_removed"`

	// Running totals across the sessions currently alive. A rate answers "how
	// fast", these answer "how much so far" — and unlike a rate they only ever
	// climb while a session lives, which is what makes them worth watching.
	//
	// They fall when a session ends and leaves the window. That is honest:
	// this is "in flight right now", not a cumulative ledger. The durable
	// totals live in the store.
	SessionTokens int64 `json:"session_tokens"`

	// SessionCost and SessionCostBilled are the live picture's two kinds of
	// money, kept apart for the same reason the stored ledger keeps them
	// apart: Claude and Codex heartbeats carry a notional API-equivalent
	// figure, and a pay-per-call source's would be an actual charge. Only
	// notional sources report live today, so the billed field is normally
	// zero — which is precisely why it exists. A single accumulator would
	// have absorbed the first billed heartbeat without a word.
	SessionCost       float64 `json:"session_cost_usd"`
	SessionCostBilled float64 `json:"session_cost_billed_usd"`

	UnpricedSessions int `json:"unpriced_sessions"`

	// Counter is the all-time stored total plus the terms the page needs to
	// project between measurements. Separate from everything above because it
	// is the DURABLE ledger, not the live view — the two are never added.
	Counter *CounterView `json:"counter,omitempty"`

	Note string `json:"note"`
}

const liveNote = "Claude statusLine heartbeats and Codex log observations. Codex is recent activity, not a continuous liveness guarantee. Session totals overlap the durable ledger and are never added to it."

// addCost folds one live session's money into the snapshot, under the kind of
// money it is.
//
// The live view is an overlapping counter that is already never added to the
// stored ledger; this is the same rule one level down. A source with no cost
// kind this build recognises is counted in neither total and left visible on
// its own session row, rather than being guessed into one of them.
func (o *Snapshot) addCost(l LiveSession) {
	switch model.CostKind(l.Source) {
	case model.CostNotional:
		o.SessionCost += l.CostUSD
		o.USDPerHour += l.USDPerHour
	case model.CostBilled:
		o.SessionCostBilled += l.CostUSD
		o.USDPerHourBilled += l.USDPerHour
	}
}

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
		out.LinesAdded += s.LinesAdded
		out.LinesRemoved += s.LinesRemoved
		out.SessionTokens += s.InputTokens + s.OutputTokens
		out.addCost(*s)
		if s.CostUnknown {
			out.UnpricedSessions++
		}
		if s.Billing == "api" {
			out.APISessions++
		}
	}
	l.mu.Unlock()

	out.ActiveSessions = len(out.Sessions)
	out.Endpoints = len(eps)

	l.mu.RLock()
	fn := l.enrich
	l.mu.RUnlock()
	if fn != nil {
		fn(&out)
	}
	sort.Slice(out.Sessions, func(i, j int) bool {
		if out.Sessions[i].TokensPerMin != out.Sessions[j].TokensPerMin {
			return out.Sessions[i].TokensPerMin > out.Sessions[j].TokensPerMin
		}
		return out.Sessions[i].SessionID < out.Sessions[j].SessionID
	})
	return out
}

// osUserCacheTTL bounds how stale the endpoint_id -> os_user map behind the
// live enrich hook may be.
//
// Refreshed at most this often rather than on every snapshot: Snapshot() runs
// on every SSE push, several times a second, and a full ListEndpoints("") is
// more query than that rate deserves for a value that only changes on the
// timescale of an endpoint re-enrolling or switching login.
const osUserCacheTTL = 60 * time.Second

// osUserCache is the endpoint_id -> os_user map behind attachOSUsers.
type osUserCache struct {
	mu sync.Mutex
	m  map[string]string
	at time.Time
}

// get returns the cached map, reloading it when stale.
func (c *osUserCache) get(load func() (map[string]string, error)) map[string]string {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.m != nil && time.Since(c.at) < osUserCacheTTL {
		return c.m
	}
	m, err := load()
	if err != nil {
		// Serve the previous map rather than blanking every OSUser on a
		// momentarily unreadable database.
		if c.m != nil {
			return c.m
		}
		return nil
	}
	c.m, c.at = m, time.Now()
	return c.m
}

// loadOSUsers reads the current endpoint_id -> os_user map from the store.
func (s *Server) loadOSUsers() (map[string]string, error) {
	eps, err := s.Store.ListEndpoints("")
	if err != nil {
		return nil, err
	}
	m := make(map[string]string, len(eps))
	for _, e := range eps {
		m[e.ID] = e.OSUser
	}
	return m, nil
}

// attachOSUsers fills in each live session's OSUser from the endpoint's own
// record. Live itself has no store access -- an endpoint's live heartbeat
// carries no os_user -- so this is a server-side enrich hook, the same shape
// as attachCounter.
func (s *Server) attachOSUsers(snap *Snapshot) {
	if s.Store == nil {
		return
	}
	m := s.osUsers.get(s.loadOSUsers)
	for i := range snap.Sessions {
		if u, ok := m[snap.Sessions[i].EndpointID]; ok && u != "" {
			snap.Sessions[i].OSUser = u
		}
	}
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
		Complete bool          `json:"complete"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<20)).Decode(&body); err != nil {
		httpError(w, http.StatusBadRequest, "malformed live report: "+err.Error())
		return
	}

	label := ep.Label
	if label == "" {
		label = ep.Hostname
	}
	s.liveStore().report(ep.ID, label, body.Sessions, body.Complete)
	writeJSON(w, http.StatusOK, map[string]any{"accepted": len(body.Sessions)})
}

// liveStore returns the live store, or an empty one.
//
// A hub built without a live store still answers /v1/live — with nothing in it,
// which is the truth. Dereferencing nil here took the whole connection down
// with a panic, and did it in the handler a dashboard polls continuously.
func (s *Server) liveStore() *Live {
	if s.LiveStore == nil {
		return NewLive()
	}
	return s.LiveStore
}

// handleLiveSnapshot returns the current picture as plain JSON.
func (s *Server) handleLiveSnapshot(w http.ResponseWriter, r *http.Request) {
	account, source, ok := liveScope(w, r)
	if !ok {
		return
	}
	snap := s.FilterLive(s.liveStore().Snapshot(), account, source)
	snap.Note = liveNoteText.In(localeOf(r))
	writeJSON(w, http.StatusOK, snap)
}

// handleLiveStream pushes snapshots over Server-Sent Events.
//
// SSE rather than websockets: this is one-way, it is a handful of KB every few
// seconds, and it survives proxies that would need explicit upgrade handling.
func (s *Server) handleLiveStream(w http.ResponseWriter, r *http.Request) {
	account, source, valid := liveScope(w, r)
	if !valid {
		return
	}
	l := s.liveStore()
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
	if b, err := json.Marshal(s.FilterLive(l.Snapshot(), account, source)); err == nil {
		fmt.Fprintf(w, "data: %s\n\n", b)
		flusher.Flush()
	}

	ch := l.subscribe()
	defer l.unsubscribe(ch)

	// A heartbeat keeps intermediaries from timing out an idle stream, and
	// lets the browser notice a dead connection.
	beat := time.NewTicker(20 * time.Second)
	defer beat.Stop()

	for {
		select {
		case <-r.Context().Done():
			return
		case b := <-ch:
			var snap Snapshot
			if json.Unmarshal(b, &snap) != nil {
				continue
			}
			b, err := json.Marshal(s.FilterLive(snap, account, source))
			if err != nil {
				continue
			}
			fmt.Fprintf(w, "data: %s\n\n", b)
			flusher.Flush()
		case <-beat.C:
			if b, err := json.Marshal(s.FilterLive(l.Snapshot(), account, source)); err == nil {
				fmt.Fprintf(w, "data: %s\n\n", b)
			}
			flusher.Flush()
		}
	}
}
