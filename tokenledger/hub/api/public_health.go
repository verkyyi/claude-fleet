package api

import (
	"bytes"
	"encoding/json"
	"io/fs"
	"net/http"
	"sync"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

const PublicHealthPath = "/v1/status"
const publicHealthTTL = 30 * time.Second

// No identity keys, unbounded maps, or auth lookups on this public road.
// One snapshot per replica per 30 seconds, including failed reads; the mutex
// coalesces cold requests. Query strings and caller cookies cannot vary it.
type publicHealthCache struct {
	mu     sync.Mutex
	until  time.Time
	code   int
	body   [2][]byte // edition only: Chinese, English
	rateMu sync.Mutex
	last   time.Time
	tokens float64
}

func (c *publicHealthCache) allow(now time.Time) bool {
	c.rateMu.Lock()
	defer c.rateMu.Unlock()
	if c.last.IsZero() {
		c.tokens = 120
	} else {
		c.tokens += now.Sub(c.last).Seconds() * 60
		if c.tokens > 120 {
			c.tokens = 120
		}
	}
	c.last = now
	if c.tokens < 1 {
		return false
	}
	c.tokens--
	return true
}

// These exact public routes precede authentication/trial/view-as middleware.
// Even a signed-in admin receives the same public bytes. Private extensions
// remain on HealthPath behind viewerOnly and Cache-Control: no-store.
func (s *Server) publicHealthRoutes(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		p := r.URL.Path
		if p != "/status" && p != "/status/" && p != PublicHealthPath {
			next.ServeHTTP(w, r)
			return
		}
		w.Header().Set("Cache-Control", "no-store")
		if !s.publicHealth.allow(time.Now()) {
			w.Header().Set("Retry-After", "2")
			httpError(w, 429, "Please retry shortly")
			return
		}
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			w.Header().Set("Allow", "GET, HEAD")
			httpError(w, 405, "GET or HEAD only")
			return
		}
		if p == PublicHealthPath {
			s.handlePublicHealth(w, r)
			return
		}
		if p == "/status/" {
			http.Redirect(w, r, "/status", http.StatusMovedPermanently)
			return
		}
		// The app bundle has a standalone status entry, with no shell, user
		// requests or auth wall. CSP does not enumerate private terminal doors.
		if s.ConsoleFS == nil {
			http.NotFound(w, r)
			return
		}
		b, err := fs.ReadFile(s.ConsoleFS, "app/index.html")
		if err != nil {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Cache-Control", "public, max-age=30, s-maxage=30")
		w.Header().Set("Content-Security-Policy", consoleCSP)
		w.Header().Set("X-Frame-Options", "DENY")
		w.Header().Set("Referrer-Policy", "no-referrer")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		http.ServeContent(w, r, "index.html", time.Time{}, bytes.NewReader(b))
	})
}

// Explicit public DTOs: do not marshal private responses and delete fields.
type publicHealthSpread struct {
	MedianSecs *float64 `json:"median_secs"`
	P90Secs    *float64 `json:"p90_secs"`
}
type publicHealthLatency struct {
	MeanMS      *float64 `json:"mean_ms"`
	MaxMS       *int64   `json:"max_ms"`
	FailureRate *float64 `json:"failure_rate"`
	At          int64    `json:"at"`
}
type publicHealthData struct {
	Language   string                       `json:"language"`
	State      string                       `json:"state"`
	At         int64                        `json:"at"`
	Components map[string]store.HealthProbe `json:"components"`
	Events     []store.HealthEvent          `json:"events"`
	Reply24    publicHealthSpread           `json:"reply_24h"`
	Reply7     publicHealthSpread           `json:"reply_7d"`
	Latency    publicHealthLatency          `json:"latency"`
}

func (s *Server) publicHealthSnapshot(now time.Time) (publicHealthData, error) {
	out := publicHealthData{At: now.UnixMilli()}
	ps, err := s.Store.HealthProbes(now.Add(-15 * time.Minute))
	if err != nil {
		return out, err
	}
	out.State, out.Components = healthOverview(ps, now)
	out.Events, err = s.Store.HealthEvents(now.Add(-7 * 24 * time.Hour))
	if err != nil {
		return out, err
	}
	// Reject unknown components and legacy diagnostic notes on the read too.
	events := []store.HealthEvent{}
	for _, e := range out.Events {
		if !healthKnown(e.Component) {
			continue
		}
		if !healthNotePublic(e.NoteZH) {
			e.NoteZH = ""
		}
		if !healthNotePublic(e.NoteEN) {
			e.NoteEN = ""
		}
		events = append(events, e)
	}
	out.Events = events
	ts, err := s.Store.ChatTimings(now.Add(-7 * 24 * time.Hour))
	if err != nil {
		return out, err
	}
	day := []store.ChatTiming{}
	for _, t := range ts {
		if t.At.After(now.Add(-24 * time.Hour)) {
			day = append(day, t)
		}
	}
	spread := func(ts []store.ChatTiming) publicHealthSpread {
		x := chatSpread(ts).Reply
		return publicHealthSpread{x.MedianSecs, x.P90Secs}
	}
	out.Reply24, out.Reply7 = spread(day), spread(ts)
	rtts, err := s.Store.LinkRTTs(now.Add(-24 * time.Hour))
	if err != nil {
		return out, err
	}
	var n, fails, sum, max int64
	for _, x := range rtts {
		n += x.N
		fails += x.Fails
		sum += x.SumMS
		if x.MaxMS > max {
			max = x.MaxMS
		}
		if x.Hour*3600000 > out.Latency.At {
			out.Latency.At = x.Hour * 3600000
		}
	}
	if n > fails {
		mean := float64(sum) / float64(n-fails)
		out.Latency.MeanMS = &mean
		out.Latency.MaxMS = &max
	}
	if n > 0 {
		ratio := float64(fails) / float64(n)
		out.Latency.FailureRate = &ratio
	}
	return out, nil
}

func (s *Server) handlePublicHealth(w http.ResponseWriter, r *http.Request) {
	c := &s.publicHealth
	c.mu.Lock()
	if !time.Now().Before(c.until) {
		out, err := s.publicHealthSnapshot(time.Now())
		c.code = http.StatusOK
		if err != nil {
			c.code = http.StatusServiceUnavailable
			c.body = [2][]byte{[]byte(`{"error":"Health data unavailable"}`), []byte(`{"error":"Health data unavailable"}`)}
		} else {
			out.Language = "zh"
			c.body[0], _ = json.Marshal(out)
			out.Language = "en"
			c.body[1], _ = json.Marshal(out)
		}
		c.until = time.Now().Add(publicHealthTTL)
	}
	i := 0
	if s.siteSandbox(r) {
		i = 1
	}
	b, code := c.body[i], c.code
	c.mu.Unlock()
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	if code == http.StatusOK {
		w.Header().Set("Cache-Control", "public, max-age=30, s-maxage=30")
	} else {
		w.Header().Set("Retry-After", "30")
	}
	w.WriteHeader(code)
	if r.Method != http.MethodHead {
		_, _ = w.Write(b)
	}
}
