package api

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/shared/model"
)

// meterServer is usageServer's hub (one 4242-token turn) with the public
// site on and no built site.
func meterServer(t *testing.T) *Server {
	t.Helper()
	s := usageServer(t)
	s.Site = true // the public site at "/" (claude-fleet#3583)
	return s
}

func meterGet(t *testing.T, s *Server, path string, hdr map[string]string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest("GET", path, nil)
	for k, v := range hdr {
		req.Header.Set(k, v)
	}
	rec := httptest.NewRecorder()
	s.Handler().ServeHTTP(rec, req)
	return rec
}

// With no built site the old landing page is gone (claude-fleet#3939): a
// signed-out "/" is the gate's answer; signed in, /app; the old console's
// files are a 404 for everyone (claude-fleet#1987) — never the app's index.
func TestRoot_NoSiteIsTheGate(t *testing.T) {
	s := meterServer(t)
	if rec := meterGet(t, s, "/", nil); rec.Code != http.StatusUnauthorized {
		t.Fatalf("signed-out / with no site = %d, want the gate's 401", rec.Code)
	}
	rec := meterGet(t, s, "/", map[string]string{"Authorization": "Bearer viewer-secret"})
	if rec.Code != http.StatusFound || rec.Header().Get("Location") != AppPrefix {
		t.Fatalf("signed-in / = %d → %q, want 302 → /app", rec.Code, rec.Header().Get("Location"))
	}
	for _, p := range []string{"/index.html", "/landing.html", "/app.js", "/app.css"} {
		for _, hdr := range []map[string]string{nil, {"Authorization": "Bearer viewer-secret"}} {
			if rec := meterGet(t, s, p, hdr); rec.Code != http.StatusNotFound {
				t.Errorf("%s (signed in %v) = %d, want 404", p, hdr != nil, rec.Code)
			}
		}
	}
	if rec := meterGet(t, s, "/v1/live", nil); rec.Code != http.StatusUnauthorized {
		t.Errorf("signed-out /v1/live = %d, want 401", rec.Code)
	}
}

func decodeMeter(t *testing.T, rec *httptest.ResponseRecorder) map[string]any {
	t.Helper()
	var m map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &m); err != nil {
		t.Fatalf("meter.json is not JSON: %v %q", err, rec.Body.String())
	}
	return m
}

func TestMeter_PublicWithTheLiveJSONFields(t *testing.T) {
	t.Setenv(MeterOriginsEnv, "https://www.example.com, https://example.com/")
	s := meterServer(t)
	rec := meterGet(t, s, "/meter.json", map[string]string{"Origin": "https://www.example.com"})
	if rec.Code != http.StatusOK {
		t.Fatalf("/meter.json = %d %s, want 200 with no credential", rec.Code, rec.Body.String())
	}
	m := decodeMeter(t, rec)
	// The live.json page contract: TokenMeter.vue reads exactly these.
	for _, k := range []string{"total", "ts", "windowTokens", "windowSecs", "ratePerSec"} {
		if _, ok := m[k]; !ok {
			t.Errorf("meter.json lacks %q: %v", k, m)
		}
	}
	if m["total"].(float64) != 4242 {
		t.Errorf("total = %v, want the lifetime total 4242", m["total"])
	}
	if m["windowSecs"].(float64) <= 0 {
		t.Errorf("windowSecs = %v, want > 0", m["windowSecs"])
	}
	if got := rec.Header().Get("Access-Control-Allow-Origin"); got != "https://www.example.com" {
		t.Errorf("ACAO = %q, want the configured origin echoed", got)
	}
	if cc := rec.Header().Get("Cache-Control"); cc != "public, max-age=10" {
		t.Errorf("Cache-Control = %q", cc)
	}
	// Nothing that names a person, a machine or an account.
	for _, forbidden := range []string{"alice", "h1", "a@example.com", "acct-1", "/repo/a"} {
		if strings.Contains(rec.Body.String(), forbidden) {
			t.Errorf("meter.json leaks %q", forbidden)
		}
	}

	for _, o := range []string{"https://evil.example", "http://www.example.com"} {
		rec := meterGet(t, s, "/meter.json", map[string]string{"Origin": o})
		if got := rec.Header().Get("Access-Control-Allow-Origin"); got != "" {
			t.Errorf("Origin %s got ACAO %q, want none", o, got)
		}
	}
	if !meterOrigin("https://example.com") {
		t.Errorf("a configured origin with a trailing / is still that origin")
	}
}

// TestMeter_NoOriginUnconfigured: with CCQUOTA_METER_ORIGINS unset no site's
// script may read the counter (issue #3577) — the numbers are still served.
func TestMeter_NoOriginUnconfigured(t *testing.T) {
	t.Setenv(MeterOriginsEnv, "")
	s := meterServer(t)
	rec := meterGet(t, s, "/meter.json", map[string]string{"Origin": "https://www.example.com"})
	if rec.Code != http.StatusOK {
		t.Fatalf("/meter.json = %d, want 200", rec.Code)
	}
	if got := rec.Header().Get("Access-Control-Allow-Origin"); got != "" {
		t.Errorf("ACAO = %q with no origin configured, want none", got)
	}
}

func TestMeter_TotalNeverGoesDown(t *testing.T) {
	s := meterServer(t)
	now := time.Now()
	v1, ok := s.meterRead(now)
	if !ok || v1.Total != 4242 {
		t.Fatalf("first read = %+v %v", v1, ok)
	}
	// Pretend the last figure served was higher than the store now holds (a
	// rebuild shrank it): the next window must hold, not roll back.
	s.meter.mu.Lock()
	s.meter.cur.tokens = 9000
	s.meter.cur.at = s.meter.cur.at.Add(-20 * time.Second)
	s.meter.mu.Unlock()
	s.counter.Invalidate()
	v2, ok := s.meterRead(now.Add(meterMinWindow + time.Second))
	if !ok || v2.Total != 9000 || v2.WindowTokens != 0 {
		t.Fatalf("after a shrink = %+v, want total held at 9000 and an empty window", v2)
	}
	if v2.WindowSecs <= 0 {
		t.Errorf("windowSecs = %d, want > 0", v2.WindowSecs)
	}
}

func TestMeter_WindowIsTheDifferenceOfTwoTotals(t *testing.T) {
	s := meterServer(t)
	now := time.Now()
	if _, ok := s.meterRead(now); !ok {
		t.Fatal("no first read")
	}
	s.meter.mu.Lock()
	s.meter.cur.tokens = 4000
	s.meter.cur.at = s.meter.cur.at.Add(-20 * time.Second)
	s.meter.mu.Unlock()
	s.counter.Invalidate()
	v, ok := s.meterRead(now.Add(meterMinWindow + time.Second))
	if !ok {
		t.Fatal("no second read")
	}
	if v.Total != 4242 || v.WindowTokens != 242 {
		t.Fatalf("window = %+v, want total 4242 and windowTokens 4242-4000", v)
	}
	if v.WindowSecs < 19 || v.WindowSecs > 25 {
		t.Errorf("windowSecs = %d, want the ~20s between the two measurements", v.WindowSecs)
	}
}

func TestMeter_SettingOffIs404(t *testing.T) {
	s := meterServer(t)
	// The settings table rides the fleet module's schema.
	if err := s.Store.EnsureNodes(); err != nil {
		t.Fatal(err)
	}
	if err := s.Store.SetFleetSetting(MeterKey, "off", time.Now()); err != nil {
		t.Fatal(err)
	}
	for _, p := range []string{"/meter.json"} {
		if rec := meterGet(t, s, p, nil); rec.Code != http.StatusNotFound {
			t.Errorf("%s with %s=off = %d, want 404", p, MeterKey, rec.Code)
		}
	}
	// Back on ("" = the default).
	if err := s.Store.SetFleetSetting(MeterKey, "", time.Now()); err != nil {
		t.Fatal(err)
	}
	if rec := meterGet(t, s, "/meter.json", nil); rec.Code != http.StatusOK {
		t.Errorf("/meter.json with the default = %d, want 200", rec.Code)
	}
}

func TestMeter_EmptyHubServesNoZero(t *testing.T) {
	s := meterServer(t)
	st := openTestStore(t)
	s.Store = st
	if rec := meterGet(t, s, "/meter.json", nil); rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("/meter.json on an empty hub = %d %s, want 503, never a zero", rec.Code, rec.Body.String())
	}
}

// TestUnconfiguredNotes: an unset deployment key is said once, by name.
func TestUnconfiguredNotes(t *testing.T) {
	got := UnconfiguredNotes(func(string) string { return "" })
	if len(got) != 1 || !strings.HasPrefix(got[0], "未配置 "+MeterOriginsEnv) {
		t.Errorf("unset: %q", got)
	}
	set := UnconfiguredNotes(func(k string) string {
		if k == MeterOriginsEnv {
			return "https://www.example.com"
		}
		return ""
	})
	if len(set) != 0 {
		t.Errorf("set: %q", set)
	}
}

// usageServer is a hub with one 4242-token turn on record.
func usageServer(t *testing.T) *Server {
	t.Helper()
	st := openTestStore(t)

	id := model.Identity{AccountUUID: "acct-1", Email: "a@example.com", Hostname: "h1"}
	if err := st.UpsertAccount(id, "max", "tier"); err != nil {
		t.Fatal(err)
	}
	if err := st.Enroll("ep-1", "ep-1", "h1"); err != nil {
		t.Fatal(err)
	}
	if _, _, err := st.TouchEndpoint("ep-1", id, "test", true, nil); err != nil {
		t.Fatal(err)
	}
	if err := st.SetEndpointTeam("ep-1", "platform"); err != nil {
		t.Fatal(err)
	}
	c := 1.0
	if _, _, err := st.InsertEvents([]model.UsageEvent{{
		AccountUUID: "acct-1", EndpointID: "ep-1", MessageUUID: "m1",
		TS: time.Now().UTC().Add(-time.Hour), Model: "claude-opus-5",
		OutputTokens: 4242, CostUSD: &c, CWD: "/repo/a", OSUser: "alice",
	}}); err != nil {
		t.Fatal(err)
	}
	return &Server{Store: st, ViewerToken: "viewer-secret"}
}
