package api

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"time"
)

// The app's push channel (claude-fleet#2794, EPIC #2792 C2).
//
// One Server-Sent Events connection per tab carries every topic a page may
// draw from: `nodes` (the body of /v1/nodes), `sessions` (fleet_sessions) and
// `usage` (/v1/live) — each cut by the SAME scope its own route applies
// (FleetScope through fleetScope, UserScope for live), here on the hub, so a
// person's stream never carries another login's machine, session or usage
// (EPIC #2512's rule; the page filters nothing). A topic is sent when the
// connection opens — a reconnect is answered with the whole current picture —
// and afterwards only when its content moved: a validator over the body with
// the clock-derived fields (`at`, `age_sec`) left out. A heartbeat wakes the
// nodes and sessions topics at once, a live report the usage topic; a 5 s
// recheck catches what no local event announces (a machine going lost by its
// silence, a beat that reached another replica). One topic is sent at most
// once a second: a burst of beats is one event.
//
//	GET /v1/fleet/stream?topics=nodes,sessions,usage
//	event: <topic>   data: {"observed_at": …, "sent_at": …, "body": …}
//	event: ping      data: {"sent_at": …}            every 20 s
//
// observed_at is when the source measured what the body shows — the newest
// heartbeat behind it, the newest live report — null when nothing says
// (an older node, a hub just restarted): the page then shows 时间未知, never
// a fresh-looking time. Absent the route, the pages poll as they did.

// FleetStreamPath is the route.
const FleetStreamPath = "/v1/fleet/stream"

// fleetStreamTopics are the topics a stream may carry, in send order.
var fleetStreamTopics = []string{"nodes", "sessions", "usage"}

// fleetStreamRecheck re-reads every topic with no event behind it.
var fleetStreamRecheck = 5 * time.Second

// fleetStreamPing keeps an idle stream talking: intermediaries do not time it
// out, and the page's 30 s watchdog hears it.
var fleetStreamPing = 20 * time.Second

// fleetStreamCoalesce is the least time between two events of a topic.
var fleetStreamCoalesce = time.Second

// streamFrame is one event's data.
type streamFrame struct {
	ObservedAt *time.Time `json:"observed_at"`
	SentAt     time.Time  `json:"sent_at"`
	Body       any        `json:"body"`
}

// streamTopicsArg reads `topics` (comma-separated; empty = all). An unknown
// topic is an error, never silently dropped.
func streamTopicsArg(q string) ([]string, error) {
	if strings.TrimSpace(q) == "" {
		return fleetStreamTopics, nil
	}
	want := map[string]bool{}
	for _, t := range strings.Split(q, ",") {
		t = strings.TrimSpace(t)
		if t == "" {
			continue
		}
		known := false
		for _, k := range fleetStreamTopics {
			known = known || k == t
		}
		if !known {
			return nil, fmt.Errorf("unknown topic %q (known: %s)", t, strings.Join(fleetStreamTopics, ", "))
		}
		want[t] = true
	}
	var out []string
	for _, k := range fleetStreamTopics {
		if want[k] {
			out = append(out, k)
		}
	}
	if len(out) == 0 {
		return fleetStreamTopics, nil
	}
	return out, nil
}

// streamVolatile are the keys a validator leaves out: they move with the
// clock, not with what was measured.
var streamVolatile = map[string]bool{"at": true, "age_sec": true}

// streamValidator is a body's content, clock fields aside.
func streamValidator(body any) string {
	b, err := json.Marshal(body)
	if err != nil {
		return ""
	}
	var v any
	if json.Unmarshal(b, &v) != nil {
		return ""
	}
	b, _ = json.Marshal(stripVolatile(v))
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}

func stripVolatile(v any) any {
	switch x := v.(type) {
	case map[string]any:
		for k, e := range x {
			if streamVolatile[k] {
				delete(x, k)
				continue
			}
			x[k] = stripVolatile(e)
		}
	case []any:
		for i := range x {
			x[i] = stripVolatile(x[i])
		}
	}
	return v
}

// nodesFor is /v1/nodes' body for r.
func (s *Server) nodesFor(r *http.Request, now time.Time) (NodesSnapshot, error) {
	visible, err := s.fleetScope(r)
	if err != nil {
		return NodesSnapshot{}, err
	}
	snap, err := s.nodesWhere(now, visible)
	if err != nil {
		return NodesSnapshot{}, err
	}
	snap.Account = s.accountStateOf(principalOf(r.Context()), now)
	if visible == nil {
		s.stampSpares(&snap)
	}
	return snap, nil
}

// nodesObserved is the newest heartbeat behind a roster.
func nodesObserved(snap NodesSnapshot) time.Time {
	var t time.Time
	for _, n := range snap.Nodes {
		if n.LastHeartbeat != nil && n.LastHeartbeat.After(t) {
			t = *n.LastHeartbeat
		}
	}
	return t
}

// sessionsObserved is the newest heartbeat behind a fleet_sessions answer.
func sessionsObserved(out map[string]any) time.Time {
	var t time.Time
	nodes, _ := out["nodes"].([]FleetNode)
	for _, n := range nodes {
		if n.ObservedAt.After(t) {
			t = n.ObservedAt
		}
	}
	return t
}

// handleFleetStream serves FleetStreamPath.
func (s *Server) handleFleetStream(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		httpError(w, http.StatusMethodNotAllowed, "GET only")
		return
	}
	topics, err := streamTopicsArg(r.URL.Query().Get("topics"))
	if err != nil {
		httpError(w, http.StatusBadRequest, err.Error())
		return
	}
	want := map[string]bool{}
	for _, t := range topics {
		want[t] = true
	}
	// The usage topic is /v1/live's cut: the person's own (machine, login)
	// pairs, no subscription on them.
	var who *UserLogins
	account, source := "", ""
	if want["usage"] {
		var ok bool
		if account, source, ok = liveScope(w, r); !ok {
			return
		}
		if who, ok = s.userScope(w, r); !ok {
			return
		}
	}
	// The scope is asked before the stream opens, so a caller with none is
	// told so with a status, not a stream of errors.
	if _, err := s.fleetScope(r); err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	flusher, ok := w.(http.Flusher)
	if !ok {
		httpError(w, http.StatusInternalServerError, "streaming unsupported")
		return
	}
	read := func(topic string, now time.Time) (any, time.Time, error) {
		switch topic {
		case "nodes":
			snap, err := s.nodesFor(r, now)
			return snap, nodesObserved(snap), err
		case "sessions":
			out, err := s.FleetSessions(r)
			return out, sessionsObserved(out), err
		default:
			l := s.liveStore()
			return s.FilterLiveFor(l.Snapshot(), account, source, who), l.LastHeard(), nil
		}
	}

	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	// Nginx would hold every event until the stream ends (live.go's precedent).
	w.Header().Set("X-Accel-Buffering", "no")
	w.WriteHeader(http.StatusOK)

	write := func(event string, v any) bool {
		b, err := json.Marshal(v)
		if err != nil {
			return true
		}
		if _, err := fmt.Fprintf(w, "event: %s\ndata: %s\n\n", event, b); err != nil {
			return false
		}
		flusher.Flush()
		return true
	}

	// Per topic: the validator last sent, when, and whether it was woken
	// and not read yet.
	last := map[string]string{}
	sentAt := map[string]time.Time{}
	dirty := map[string]bool{}
	for _, t := range topics {
		dirty[t] = true
	}
	var live chan []byte
	if want["usage"] {
		live = s.liveStore().subscribe()
		defer s.liveStore().unsubscribe(live)
	}
	recheck := time.NewTicker(fleetStreamRecheck)
	defer recheck.Stop()
	ping := time.NewTicker(fleetStreamPing)
	defer ping.Stop()
	var flushC <-chan time.Time
	var flushT *time.Timer
	defer func() {
		if flushT != nil {
			flushT.Stop()
		}
	}()

	// pump reads every dirty topic that may be sent now; one sent under a
	// second ago waits for the flush timer.
	pump := func() bool {
		now := time.Now()
		var wait time.Duration
		for _, t := range topics {
			if !dirty[t] {
				continue
			}
			if d := sentAt[t].Add(fleetStreamCoalesce).Sub(now); !sentAt[t].IsZero() && d > 0 {
				if wait == 0 || d < wait {
					wait = d
				}
				continue
			}
			dirty[t] = false
			body, observed, err := read(t, now)
			if err != nil {
				continue // the recheck tries again
			}
			v := streamValidator(body)
			if v != "" && v == last[t] {
				continue
			}
			f := streamFrame{SentAt: now.UTC(), Body: body}
			if !observed.IsZero() {
				o := observed.UTC()
				f.ObservedAt = &o
			}
			if !write(t, f) {
				return false
			}
			last[t], sentAt[t] = v, now
		}
		if wait > 0 && flushC == nil {
			flushT = time.NewTimer(wait)
			flushC = flushT.C
		}
		return true
	}

	if !pump() {
		return
	}
	for {
		nodesC := s.nodesChanged.wait()
		sessC := s.sessionsChanged.wait()
		select {
		case <-r.Context().Done():
			return
		case <-nodesC:
			dirty["nodes"] = true
		case <-sessC:
			dirty["sessions"] = true
		case <-live:
			dirty["usage"] = true
		case <-recheck.C:
			for _, t := range topics {
				dirty[t] = true
			}
		case <-flushC:
			flushC, flushT = nil, nil
		case <-ping.C:
			if !write("ping", map[string]any{"sent_at": time.Now().UTC()}) {
				return
			}
			continue
		}
		if !pump() {
			return
		}
	}
}
