package api

import (
	"bytes"
	"html/template"
	"io/fs"
	"log"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/badge"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/i18n"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// The public counter (claude-fleet#1988).
//
// /meter.json is the figure on claudefleet's front page and on
// 24haowan.com's homepage, which used to reach it through a publisher script
// holding a viewer token (monorepo tools/ccquota-publish.sh → live.json on a
// bucket). Its fields ARE that file's page contract — TokenMeter.vue replays
// each window — so a rename here is a rename there:
//
//	total         the lifetime total, LifetimeTotals: the one number behind the
//	              dashboard, the badges and the MCP. Never goes down.
//	ts            epoch seconds the total was measured at.
//	windowTokens  how much total grew since the previous measurement …
//	windowSecs    … and over how many seconds. A difference of two totals,
//	              never "events in the last N seconds": a late event would be
//	              missed forever and the replay would stop adding up.
//	ratePerSec    the last six hours' average, tokens per second — only for
//	              picking which odometer wheel still reads clearly.
//
// /odometer.svg is the same figure as `ccquota badge` draws it. Both are behind
// the hub.public_meter setting (default on); off, both answer 404.
const (
	// MeterKey switches the public counter: "off" hides it, anything else
	// (or unset) shows it.
	MeterKey = "hub.public_meter"

	// meterMinWindow is the shortest replay window served. The page pulls
	// every 15s; a shorter window would be replayed in a blink and then stand
	// still until the next pull.
	meterMinWindow = 15 * time.Second
	meterRateSpan  = 6 * time.Hour
	meterRateTTL   = time.Minute
	meterMaxAge    = "public, max-age=10"
)

// meterOrigins may read /meter.json from a browser.
var meterOrigins = map[string]bool{
	"https://www.24haowan.com": true,
	"https://24haowan.com":     true,
}

type meterSample struct {
	at     time.Time
	tokens int64
}

// meterState keeps the last two measurements the page replays between, and
// the cached six-hour rate.
type meterState struct {
	mu         sync.Mutex
	prev, cur  meterSample
	rate       float64
	rateAt     time.Time
	rateLoaded bool
}

type meterView struct {
	Total        int64   `json:"total"`
	TS           int64   `json:"ts"`
	WindowTokens int64   `json:"windowTokens"`
	WindowSecs   int64   `json:"windowSecs"`
	RatePerSec   float64 `json:"ratePerSec"`
}

// publicMeter reports whether the public counter is on. An unreadable
// settings table reads as the default: the setting exists to turn it off.
func (s *Server) publicMeter() bool {
	if s.Store == nil {
		return false
	}
	settings, err := s.Store.FleetSettings()
	if err != nil {
		return true
	}
	return !strings.EqualFold(strings.TrimSpace(settings[MeterKey]), "off")
}

// meterRead takes a new measurement when the last one is at least
// meterMinWindow old, and returns the replay view.
func (s *Server) meterRead(now time.Time) (meterView, bool) {
	m := &s.meter
	m.mu.Lock()
	defer m.mu.Unlock()

	if m.cur.at.IsZero() || now.Sub(m.cur.at) >= meterMinWindow {
		_, tokens, at, err := s.counter.Total(s.Store.LifetimeTotals)
		if err == nil && at.After(m.cur.at) {
			if tokens < m.cur.tokens {
				// The store shrank (a rebuild, a dedupe). The page's
				// wheels never roll back; hold the figure until it is
				// passed again.
				tokens = m.cur.tokens
			}
			if !m.cur.at.IsZero() {
				m.prev = m.cur
			}
			m.cur = meterSample{at: at, tokens: tokens}
		}
	}
	if m.cur.at.IsZero() || m.cur.tokens <= 0 {
		// Nothing measured: no figure, never a zero — a zero odometer
		// looks like a fact.
		return meterView{}, false
	}

	if !m.rateLoaded || now.Sub(m.rateAt) >= meterRateTTL {
		sum, err := s.Store.Summary(store.Filter{Account: store.AllAccounts, Start: now.Add(-meterRateSpan), End: now})
		if err == nil {
			m.rate = float64(sum.Tokens) / meterRateSpan.Seconds()
			m.rateAt, m.rateLoaded = now, true
		}
	}

	v := meterView{
		Total:      m.cur.tokens,
		TS:         m.cur.at.Unix(),
		RatePerSec: float64(int64(m.rate*1000+0.5)) / 1000,
	}
	if !m.prev.at.IsZero() {
		v.WindowSecs = int64(m.cur.at.Sub(m.prev.at).Round(time.Second) / time.Second)
		v.WindowTokens = m.cur.tokens - m.prev.tokens
		if v.WindowSecs <= 0 {
			v.WindowSecs = 1
		}
	} else {
		// The first reading after a start: estimate one window from the
		// six-hour rate, as the publisher did — it only shapes the opening
		// roll, and total−windowTokens still sits below the true figure.
		v.WindowSecs = int64(meterMinWindow / time.Second)
		v.WindowTokens = int64(m.rate * float64(v.WindowSecs))
	}
	if v.WindowTokens > v.Total {
		v.WindowTokens = v.Total
	}
	if v.WindowTokens < 0 {
		v.WindowTokens = 0
	}
	return v, true
}

func (s *Server) handleMeter(w http.ResponseWriter, r *http.Request) {
	if !s.publicMeter() {
		http.NotFound(w, r)
		return
	}
	if o := r.Header.Get("Origin"); meterOrigins[o] {
		w.Header().Set("Access-Control-Allow-Origin", o)
	}
	w.Header().Add("Vary", "Origin")
	switch r.Method {
	case http.MethodGet, http.MethodHead:
	case http.MethodOptions:
		w.Header().Set("Access-Control-Allow-Methods", "GET, HEAD")
		w.WriteHeader(http.StatusNoContent)
		return
	default:
		w.Header().Set("Allow", "GET, HEAD")
		httpError(w, http.StatusMethodNotAllowed, "GET")
		return
	}
	v, ok := s.meterRead(time.Now())
	if !ok {
		w.Header().Set("Cache-Control", "no-store")
		httpError(w, http.StatusServiceUnavailable, "the counter has not been measured yet")
		return
	}
	w.Header().Set("Cache-Control", meterMaxAge)
	writeJSON(w, http.StatusOK, v)
}

// handleOdometer draws the same figure as `ccquota badge`: the animated
// odometer, all time. ?theme / ?style / ?size / ?bg … as on /badge/.
func (s *Server) handleOdometer(w http.ResponseWriter, r *http.Request) {
	if !s.publicMeter() {
		http.NotFound(w, r)
		return
	}
	v, ok := s.meterRead(time.Now())
	if !ok {
		w.Header().Set("Cache-Control", "no-store")
		httpError(w, http.StatusServiceUnavailable, "the counter has not been measured yet")
		return
	}
	turns, _, _, _ := s.counter.Total(s.Store.LifetimeTotals)
	d := badgeOptions(r)
	d.Tokens, d.Turns, d.Period = v.Total, turns, "all"
	w.Header().Set("Cache-Control", badgeMaxAge)
	w.Header().Set("Content-Type", "image/svg+xml; charset=utf-8")
	_, _ = w.Write(badge.Render(d))
}

// serveLanding answers a signed-out "/" with the front page
// (claude-fleet#1988). Any other path, or a hub built without it, falls
// through to the gate's sign-in redirect or 401.
//
// The page is an html/template drawn in the language pageLocale picks
// (claude-fleet#2023), so it arrives in 中文 or English with <html lang> set.
func (s *Server) serveLanding(w http.ResponseWriter, r *http.Request) bool {
	if r.URL.Path != "/" || (r.Method != http.MethodGet && r.Method != http.MethodHead) || s.UI == nil {
		return false
	}
	src, err := fs.ReadFile(s.UI, "landing.html")
	if err != nil {
		return false
	}
	loc := s.pageLocale(w, r)
	tmpl, err := template.New("landing").Funcs(pageFuncs(loc)).Parse(string(src))
	if err != nil {
		log.Printf("landing.html: %v", err)
		return false
	}
	var body bytes.Buffer
	if err := tmpl.Execute(&body, landingPage{
		pageView: newPageView(r, loc),
		Hosted:   i18n.Interpolate(pageT(loc, "landing.foot.hosted"), map[string]string{"host": r.Host}),
	}); err != nil {
		log.Printf("landing.html: %v", err)
		return false
	}
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Content-Language", loc)
	w.Header().Add("Vary", "Accept-Language, Cookie")
	// Same-origin only: the page sends no request anywhere else.
	w.Header().Set("Content-Security-Policy", "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'")
	if r.Method == http.MethodHead {
		return true
	}
	_, _ = w.Write(body.Bytes())
	return true
}

// landingPage is what landing.html is drawn from.
type landingPage struct {
	pageView
	Hosted string // "Hosted at <host>", until the script repeats it from location
}
