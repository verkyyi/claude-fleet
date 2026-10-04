package fx

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

const body = `{"result":"success","base_code":"USD","time_last_update_unix":1789344000,
	"rates":{"USD":1,"CNY":7.0912,"EUR":0.92}}`

func feedServer(t *testing.T, payload string, status int) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(status)
		_, _ = w.Write([]byte(payload))
	}))
}

func TestGet_LiveRateAndItsInverse(t *testing.T) {
	srv := feedServer(t, body, 200)
	defer srv.Close()
	f := New(srv.URL, time.Hour, nil, "")
	if err := f.fetch(context.Background()); err != nil {
		t.Fatalf("fetch: %v", err)
	}

	r, ok := f.Get("USD", "CNY")
	if !ok || r.Rate != 7.0912 {
		t.Fatalf("USD->CNY = %+v, ok=%v", r, ok)
	}
	if r.Fallback {
		t.Error("a live reading was reported as a fallback")
	}
	if r.AsOf.IsZero() {
		t.Error("no as_of: a rate with no date cannot be disclosed honestly")
	}

	// One rate answers both directions. A second fetch for the mirror could
	// disagree with this one, and then one page would show two rates.
	inv, ok := f.Get("CNY", "USD")
	if !ok {
		t.Fatal("CNY->USD not answered")
	}
	if got := inv.Rate * 7.0912; got < 0.999 || got > 1.001 {
		t.Errorf("inverse does not round-trip: %v", got)
	}

	// Crossing two non-base currencies works off the same table.
	if cross, ok := f.Get("CNY", "EUR"); !ok || cross.Rate <= 0 {
		t.Errorf("CNY->EUR = %+v, ok=%v", cross, ok)
	}
}

func TestGet_SameCurrencyIsNotAConversion(t *testing.T) {
	f := New("", time.Hour, nil, "")
	r, ok := f.Get("USD", "USD")
	if !ok || r.Rate != 1 {
		t.Fatalf("identity = %+v, ok=%v", r, ok)
	}
	if r.Fallback {
		t.Error("the identity was marked as a fallback; nothing was converted")
	}
}

// The failure that matters. A feed that cannot be reached must never produce a
// figure that looks live: it either falls back to a rate that SAYS it is pinned,
// or it declines and the page shows the billed currency.
func TestGet_UnreachableFeedFallsBackAndSaysSo(t *testing.T) {
	srv := feedServer(t, "nope", 500)
	srv.Close() // refuse connections outright
	f := New(srv.URL, time.Hour, map[string]float64{"CNY": 7.09}, "pinned in this build")
	_ = f.fetch(context.Background())

	r, ok := f.Get("USD", "CNY")
	if !ok {
		t.Fatal("no rate at all; the pinned fallback did not apply")
	}
	if !r.Fallback {
		t.Error("a pinned rate was presented as a live reading")
	}
	if r.Source != "pinned in this build" {
		t.Errorf("source = %q; a fallback must name itself", r.Source)
	}
	if !r.AsOf.IsZero() {
		t.Error("a pinned fallback claimed a feed timestamp")
	}
	if f.Err() == nil {
		t.Error("the fetch error was not retained for an operator to see")
	}
}

func TestGet_UnknownPairIsDeclined(t *testing.T) {
	srv := feedServer(t, body, 200)
	defer srv.Close()
	f := New(srv.URL, time.Hour, nil, "")
	_ = f.fetch(context.Background())
	// Better to show the billed currency than to invent a rate for a currency
	// the feed does not carry.
	if r, ok := f.Get("USD", "XYZ"); ok {
		t.Errorf("invented a rate for an unknown currency: %+v", r)
	}
}

func TestFetch_RejectsAnUnusableResponse(t *testing.T) {
	for name, payload := range map[string]string{
		"no rates": `{"result":"success","base_code":"USD","rates":{}}`,
		"no base":  `{"result":"success","rates":{"CNY":7.09}}`,
		"garbage":  `not json`,
	} {
		srv := feedServer(t, payload, 200)
		f := New(srv.URL, time.Hour, nil, "")
		if err := f.fetch(context.Background()); err == nil {
			t.Errorf("%s: accepted an unusable response", name)
		}
		srv.Close()
	}
}

func TestStale_UsesTheFeedsOwnTimestamp(t *testing.T) {
	now := time.Now().UTC()
	// A feed that has stopped moving is stale even though the last HTTP call
	// succeeded a moment ago -- which is why AsOf is the feed's date, not ours.
	old := Rate{AsOf: now.Add(-72 * time.Hour)}
	if !old.Stale(now, 48*time.Hour) {
		t.Error("a three-day-old rate did not read as stale")
	}
	if (Rate{AsOf: now.Add(-time.Hour)}).Stale(now, 48*time.Hour) {
		t.Error("an hour-old rate read as stale")
	}
	if !(Rate{}).Stale(now, 48*time.Hour) {
		t.Error("a rate with no date must count as stale")
	}
}

// A nil feed is a hub configured without one. Every call must still answer
// safely rather than panic a request handler.
func TestNilFeedIsSafe(t *testing.T) {
	var f *Feed
	if _, ok := f.Get("USD", "CNY"); ok {
		t.Error("a nil feed produced a rate")
	}
	if r, ok := f.Get("USD", "USD"); !ok || r.Rate != 1 {
		t.Error("a nil feed could not answer the identity")
	}
	if f.Err() != nil {
		t.Error("a nil feed reported an error")
	}
	f.Refreshing(context.Background()) // must return immediately
}
