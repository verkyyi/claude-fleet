// Package fx converts a money figure from the currency it was billed in to the
// one a viewer reads, at a rate fetched from a feed rather than pinned.
//
// This is a PRESENTATION concern and nothing else. Nothing here touches a
// stored figure: cost_usd stays in USD, a plan priced in CNY stays in CNY, and
// api.RealSpendOver still refuses to add two currencies together rather than
// converting one into the other. The ledger records what was charged; this
// package only decides what a reader sees on top of it.
//
// That separation is the whole design, because pricing.GatewayCNYPerUSD's own
// comment names the danger of the alternative: "a live FX feed would silently
// restate every historical figure each morning". It is right — so a converted
// figure here is never silent. Every one carries the rate, where it came from,
// and when it was read, and the API marks it so a surface cannot present a
// converted number as though it were the invoice.
package fx

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"sync"
	"time"
)

// DefaultURL is a keyless daily-updated feed. A deployment that cannot reach it
// (or wants its own treasury's rate) points --fx-url somewhere else; the shape
// below is the common "base + rates map" one that most feeds emit.
const DefaultURL = "https://open.er-api.com/v6/latest/USD"

// DefaultRefresh is how often the feed is re-read. Daily feeds do not move
// faster than this, and a dashboard that re-reads an FX endpoint every minute
// is rude to a free service for no gain.
const DefaultRefresh = time.Hour

// Rate is one conversion, with everything needed to disclose it.
//
// AsOf is the FEED's own timestamp, not when this process fetched it: a feed
// that has stopped updating must look stale even though the last HTTP call
// succeeded a second ago.
type Rate struct {
	Base   string    `json:"base"`
	Target string    `json:"target"`
	Rate   float64   `json:"rate"`
	AsOf   time.Time `json:"as_of"`
	Source string    `json:"source"`

	// Fallback says this is not a live reading: the feed has never answered, or
	// is not configured, and the figure rests on a rate pinned in the binary.
	// A surface must say so — a converted figure whose provenance is unstated is
	// exactly the "silently restated" number this package exists to avoid.
	Fallback bool `json:"fallback"`
}

// Stale reports whether the feed's own timestamp is older than `max`.
func (r Rate) Stale(now time.Time, max time.Duration) bool {
	return r.AsOf.IsZero() || now.Sub(r.AsOf) > max
}

// Feed reads and caches rates for one base currency.
type Feed struct {
	URL      string
	Refresh  time.Duration
	Client   *http.Client
	Pinned   map[string]float64 // target -> rate, used when the feed cannot answer
	PinnedAs string             // what the pinned rates are labelled as

	mu      sync.RWMutex
	base    string
	rates   map[string]float64
	asOf    time.Time
	fetched time.Time
	lastErr error
}

// New builds a feed. A zero URL disables fetching entirely: the pinned rates
// are all that is offered, and every Rate comes back marked Fallback.
func New(url string, refresh time.Duration, pinned map[string]float64, pinnedAs string) *Feed {
	if refresh <= 0 {
		refresh = DefaultRefresh
	}
	return &Feed{
		URL: url, Refresh: refresh, Pinned: pinned, PinnedAs: pinnedAs,
		// A short timeout on purpose: this is decoration on a dashboard, and a
		// slow feed must never hold up a page that has real figures to show.
		Client: &http.Client{Timeout: 10 * time.Second},
	}
}

type feedResponse struct {
	Result   string             `json:"result"`
	BaseCode string             `json:"base_code"`
	Base     string             `json:"base"`
	Rates    map[string]float64 `json:"rates"`
	Updated  int64              `json:"time_last_update_unix"`
}

// Refreshing runs until ctx is cancelled, re-reading the feed on the interval.
// The first read happens immediately so a page loaded seconds after start has a
// live rate rather than the pinned one.
func (f *Feed) Refreshing(ctx context.Context) {
	if f == nil || f.URL == "" {
		return
	}
	_ = f.fetch(ctx)
	t := time.NewTicker(f.Refresh)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			_ = f.fetch(ctx)
		}
	}
}

func (f *Feed) fetch(ctx context.Context) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, f.URL, nil)
	if err != nil {
		f.setErr(err)
		return err
	}
	req.Header.Set("Accept", "application/json")
	resp, err := f.Client.Do(req)
	if err != nil {
		f.setErr(err)
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		err := fmt.Errorf("fx feed: HTTP %d", resp.StatusCode)
		f.setErr(err)
		return err
	}
	var body feedResponse
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		f.setErr(err)
		return err
	}
	base := strings.ToUpper(firstNonEmpty(body.BaseCode, body.Base))
	if base == "" || len(body.Rates) == 0 {
		err := fmt.Errorf("fx feed: no base or no rates in response")
		f.setErr(err)
		return err
	}
	asOf := time.Now().UTC()
	if body.Updated > 0 {
		asOf = time.Unix(body.Updated, 0).UTC()
	}
	up := make(map[string]float64, len(body.Rates))
	for k, v := range body.Rates {
		if v > 0 {
			up[strings.ToUpper(k)] = v
		}
	}
	f.mu.Lock()
	f.base, f.rates, f.asOf, f.fetched, f.lastErr = base, up, asOf, time.Now().UTC(), nil
	f.mu.Unlock()
	return nil
}

func (f *Feed) setErr(err error) {
	f.mu.Lock()
	f.lastErr = err
	f.mu.Unlock()
}

// Get converts one currency to another.
//
// Same currency is the identity, reported as live rather than as a conversion:
// nothing was converted, so there is nothing to disclose.
//
// Otherwise the feed's base is the pivot — a feed keyed on USD answers CNY→USD
// by inverting and, in principle, A→B by crossing. Only pairs the feed actually
// carries are answered; an unknown currency returns ok=false, and the caller
// shows the billed figure untouched rather than a converted one it cannot back.
func (f *Feed) Get(base, target string) (Rate, bool) {
	base, target = strings.ToUpper(base), strings.ToUpper(target)
	if base == "" || target == "" {
		return Rate{}, false
	}
	if base == target {
		return Rate{Base: base, Target: target, Rate: 1, AsOf: time.Now().UTC(), Source: "identity"}, true
	}
	if f == nil {
		return Rate{}, false
	}
	f.mu.RLock()
	feedBase, rates, asOf := f.base, f.rates, f.asOf
	f.mu.RUnlock()

	if r, ok := cross(feedBase, rates, base, target); ok {
		return Rate{Base: base, Target: target, Rate: r, AsOf: asOf, Source: f.URL}, true
	}
	// The feed has never answered, or does not carry this pair. Fall back to a
	// rate pinned in the binary, clearly marked — a page that silently showed a
	// year-old rate as though it were today's would be worse than one that
	// showed no conversion at all.
	if r, ok := cross(pinnedBase(f.Pinned), f.Pinned, base, target); ok {
		return Rate{Base: base, Target: target, Rate: r, Source: f.PinnedAs, Fallback: true}, true
	}
	return Rate{}, false
}

// pinnedBase: the pinned table is USD-based by construction (see cmd/ccquota,
// which fills it from pricing.GatewayCNYPerUSD).
func pinnedBase(m map[string]float64) string {
	if len(m) == 0 {
		return ""
	}
	return "USD"
}

// cross converts base→target using a table keyed on feedBase.
func cross(feedBase string, rates map[string]float64, base, target string) (float64, bool) {
	if feedBase == "" || len(rates) == 0 {
		return 0, false
	}
	rate := func(cur string) (float64, bool) {
		if cur == feedBase {
			return 1, true
		}
		v, ok := rates[cur]
		return v, ok && v > 0
	}
	from, okF := rate(base)
	to, okT := rate(target)
	if !okF || !okT || from == 0 {
		return 0, false
	}
	return to / from, true
}

// Err is the last fetch error, for an operator asking why a figure is pinned.
func (f *Feed) Err() error {
	if f == nil {
		return nil
	}
	f.mu.RLock()
	defer f.mu.RUnlock()
	return f.lastErr
}

func firstNonEmpty(a, b string) string {
	if a != "" {
		return a
	}
	return b
}
