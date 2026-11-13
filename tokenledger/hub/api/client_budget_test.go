package api

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"strings"
	"testing"
	"time"
)

func fromAddr(r *http.Request, ip string) *http.Request {
	r.Header.Set("X-Forwarded-For", ip)
	return r
}

// One source spends its own budget: another is untouched; the budget earns
// back; an IPv6 /64 is one source; a full table lets a new source through
// untracked rather than refuse it.
func TestClientBudgetIsolatesSources(t *testing.T) {
	b := &clientBudget{burst: 3, perSec: 1, max: 8}
	now := time.Now()
	a := func(ip string) *http.Request { return fromAddr(httptest.NewRequest("GET", "/", nil), ip) }
	for i := 0; i < 3; i++ {
		if !b.allow(a("198.51.100.1"), now) {
			t.Fatalf("burst %d refused", i)
		}
	}
	if b.allow(a("198.51.100.1"), now) {
		t.Fatal("the spent source was let through")
	}
	if !b.allow(a("198.51.100.2"), now) {
		t.Fatal("another source was refused")
	}
	if !b.allow(a("198.51.100.1"), now.Add(time.Second)) || b.allow(a("198.51.100.1"), now.Add(time.Second)) {
		t.Fatal("refill: one a second")
	}
	for i := 0; i < 3; i++ {
		b.allow(a("2001:db8:1:2::1"), now)
	}
	if b.allow(a("2001:db8:1:2:ffff::9"), now) {
		t.Fatal("the same /64 is a fresh source")
	}
	if !b.allow(a("2001:db8:1:3::1"), now) {
		t.Fatal("another /64 was refused")
	}

	full := &clientBudget{burst: 1, perSec: 0.001, max: 2}
	full.allowFrom(netip.MustParseAddr("192.0.2.1"), now)
	full.allowFrom(netip.MustParseAddr("192.0.2.2"), now)
	if !full.allowFrom(netip.MustParseAddr("192.0.2.3"), now) || len(full.m) != 2 {
		t.Fatalf("a full table: new source refused or tracked (%d)", len(full.m))
	}
	// buckets back at full are dropped to make room
	later := now.Add(time.Hour)
	if !full.allowFrom(netip.MustParseAddr("192.0.2.4"), later) || full.m[netip.MustParseAddr("192.0.2.4")] == nil {
		t.Fatal("a recovered bucket was not swept for a new source")
	}
}

// The status page: one source spending its budget is refused while another
// is still answered.
func TestPublicHealthBudgetPerSource(t *testing.T) {
	h := newFleetHarness(t)
	hd := h.srv.Handler()
	get := func(ip string) int {
		w := httptest.NewRecorder()
		hd.ServeHTTP(w, fromAddr(httptest.NewRequest("GET", PublicHealthPath, nil), ip))
		return w.Code
	}
	refused := false
	for i := 0; i < 100 && !refused; i++ {
		refused = get("198.51.100.7") == 429
	}
	if !refused {
		t.Fatal("one source was never refused")
	}
	if code := get("198.51.100.8"); code != 200 {
		t.Fatalf("another source: %d", code)
	}
}

// `fleet login` start: one source fills its share of the pending table, not
// the table; another source still starts.
func TestDeviceStartPerSource(t *testing.T) {
	h, _ := certHarness(t)
	start := func(ip string) int {
		b, _ := json.Marshal(map[string]string{"public_key": newUserKey(t)})
		req, _ := http.NewRequest(http.MethodPost, h.http.URL+"/v1/fleet/login/start", strings.NewReader(string(b)))
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("X-Forwarded-For", ip)
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		return resp.StatusCode
	}
	for i := 0; i < deviceMaxPerSource; i++ {
		if code := start("198.51.100.20"); code != 200 {
			t.Fatalf("start %d: %d", i, code)
		}
	}
	if code := start("198.51.100.20"); code != http.StatusServiceUnavailable {
		t.Fatalf("past the source's share: %d; want 503", code)
	}
	if code := start("198.51.100.21"); code != 200 {
		t.Fatalf("another source: %d", code)
	}
}

// Sign-in codes: one source drawing past its budget is refused; another
// source still draws.
func TestWxSceneBudgetPerSource(t *testing.T) {
	h := newWxHarness(t)
	draw := func(ip string) int {
		b := newBrowser(t, "")
		req, _ := http.NewRequest(http.MethodPost, h.http.URL+wxQRPath, strings.NewReader("purpose=login"))
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		req.Header.Set("X-Forwarded-For", ip)
		r, err := b.c.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		r.Body.Close()
		return r.StatusCode
	}
	for i := 0; i < wxScenesPerSource; i++ {
		if code := draw("198.51.100.30"); code != 200 {
			t.Fatalf("draw %d: %d", i, code)
		}
	}
	drawn := len(h.wb.drawn)
	if code := draw("198.51.100.30"); code != http.StatusServiceUnavailable || len(h.wb.drawn) != drawn {
		t.Fatalf("past the source's budget: %d, drawn %d→%d; want 503 and none", code, drawn, len(h.wb.drawn))
	}
	if code := draw("198.51.100.31"); code != 200 || len(h.wb.drawn) != drawn+1 {
		t.Fatalf("another source: %d, drawn %d→%d", code, drawn, len(h.wb.drawn))
	}
}
