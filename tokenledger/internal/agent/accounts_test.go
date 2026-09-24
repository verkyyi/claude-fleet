package agent

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"sync/atomic"
	"testing"
	"time"

	"github.com/verkyyi/ccquota/internal/limits"
	"github.com/verkyyi/ccquota/internal/sessions"
)

// probeServer stands in for the messages endpoint, counting calls and returning
// the unified rate-limit headers a real response carries.
func probeServer(t *testing.T, calls *atomic.Int64, fiveFrac, sevenFrac string, sevenReset time.Time) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		w.Header().Set("anthropic-ratelimit-unified-5h-utilization", fiveFrac)
		w.Header().Set("anthropic-ratelimit-unified-7d-utilization", sevenFrac)
		w.Header().Set("anthropic-ratelimit-unified-7d-reset", itoa(sevenReset.Unix()))
		w.Header().Set("content-type", "application/json")
		_, _ = w.Write([]byte(`{"id":"msg_x"}`))
	}))
	t.Cleanup(srv.Close)
	return srv
}

func itoa(v int64) string { return strconv.FormatInt(v, 10) }

func agentWithAccounts(t *testing.T, dir string, srvURL string) *Agent {
	t.Helper()
	c := limits.New()
	c.HTTP = &http.Client{Timeout: 5 * time.Second}
	a := &Agent{cfg: Config{AccountsDir: dir}, limits: c}
	limits.SetMessagesEndpointForTest(srvURL)
	t.Cleanup(func() { limits.SetMessagesEndpointForTest("") })
	return a
}

func writeToken(t *testing.T, dir, label string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(dir, label), []byte("sk-ant-oat-dummy-token\n"), 0o600); err != nil {
		t.Fatal(err)
	}
}

// The gap this closes: a subscription nothing else can see.
func TestProbeAccounts_ReadsAnUnobservedSubscription(t *testing.T) {
	dir := t.TempDir()
	writeToken(t, dir, "idle@example.com")
	var calls atomic.Int64
	seven := time.Now().UTC().Add(72 * time.Hour).Truncate(time.Minute)
	srv := probeServer(t, &calls, "0.41", "0.09", seven)

	a := agentWithAccounts(t, dir, srv.URL)
	got := a.probeAccounts(context.Background(), map[string]bool{})
	if len(got) != 1 {
		t.Fatalf("got %d readings, want 1", len(got))
	}
	if got[0].FiveHour.Utilization < 40 || got[0].FiveHour.Utilization > 42 {
		t.Errorf("five-hour = %v%%, want ~41 — the header fraction was not scaled",
			got[0].FiveHour.Utilization)
	}
	if got[0].AccountUUID != sessions.FingerprintFor(&seven) {
		t.Errorf("account key = %q; it must be the seven-day fingerprint so the hub "+
			"can fold it onto a real uuid", got[0].AccountUUID)
	}
}

// The property that keeps monitoring from consuming what it measures: a probe
// is an inference call, so a subscription already covered for free this cycle
// must not be probed at all.
func TestProbeAccounts_SkipsSubscriptionsAlreadyObserved(t *testing.T) {
	dir := t.TempDir()
	writeToken(t, dir, "busy@example.com")
	var calls atomic.Int64
	seven := time.Now().UTC().Add(72 * time.Hour).Truncate(time.Minute)
	srv := probeServer(t, &calls, "0.41", "0.09", seven)

	a := agentWithAccounts(t, dir, srv.URL)
	key := sessions.FingerprintFor(&seven)
	got := a.probeAccounts(context.Background(), map[string]bool{key: true})

	if len(got) != 0 {
		t.Errorf("returned %d readings for an already-observed subscription", len(got))
	}
	// It still costs one call to learn WHICH subscription the token is for —
	// the token itself says nothing — but the reading is then discarded rather
	// than double-reported.
	if calls.Load() > 1 {
		t.Errorf("made %d calls; one is enough to identify the account", calls.Load())
	}
}

// Probing on every scan would turn a 15-second cadence into 5,760 inference
// calls a day per subscription.
func TestProbeAccounts_ThrottlesRepeatProbes(t *testing.T) {
	dir := t.TempDir()
	writeToken(t, dir, "a@example.com")
	var calls atomic.Int64
	seven := time.Now().UTC().Add(72 * time.Hour).Truncate(time.Minute)
	srv := probeServer(t, &calls, "0.10", "0.02", seven)

	a := agentWithAccounts(t, dir, srv.URL)
	for i := 0; i < 5; i++ {
		a.probeAccounts(context.Background(), map[string]bool{})
	}
	if calls.Load() != 1 {
		t.Errorf("made %d calls across 5 cycles, want 1", calls.Load())
	}
}

// Off unless configured. A monitor must not start spending an operator's quota
// because it was upgraded.
func TestProbeAccounts_DoesNothingWithoutADirectory(t *testing.T) {
	a := &Agent{cfg: Config{}, limits: limits.New()}
	if got := a.probeAccounts(context.Background(), map[string]bool{}); got != nil {
		t.Errorf("probed %d accounts with no directory configured", len(got))
	}
}

// fableServer answers like the real endpoint did on 2026-09-23: a request for
// the capped model carries a 7d_oi window (and is a 429 once it is spent); a
// request for anything else carries only the account windows; an unknown model
// is a 400 with no headers at all.
func fableServer(t *testing.T, seen *[]string, sevenReset time.Time, oiFrac string, rejected bool) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req struct{ Model string }
		_ = json.NewDecoder(r.Body).Decode(&req)
		*seen = append(*seen, req.Model)
		if req.Model == "no-such-model" {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		w.Header().Set("anthropic-ratelimit-unified-5h-utilization", "0.10")
		w.Header().Set("anthropic-ratelimit-unified-7d-utilization", "0.80")
		w.Header().Set("anthropic-ratelimit-unified-7d-reset", itoa(sevenReset.Unix()))
		if req.Model == "claude-fable-5-1" {
			w.Header().Set("anthropic-ratelimit-unified-7d_oi-utilization", oiFrac)
			w.Header().Set("anthropic-ratelimit-unified-7d_oi-reset", itoa(sevenReset.Add(-40*time.Hour).Unix()))
			if rejected {
				w.Header().Set("anthropic-ratelimit-unified-7d_oi-status", "rejected")
				w.WriteHeader(http.StatusTooManyRequests)
				return
			}
			w.Header().Set("anthropic-ratelimit-unified-7d_oi-status", "allowed")
		}
		_, _ = w.Write([]byte(`{"id":"msg_x"}`))
	}))
	t.Cleanup(srv.Close)
	return srv
}

// With a probe model configured, the probe asks for THAT model, the capped
// account's 429 is a reading, and the cap is keyed by the model asked for.
func TestProbeAccounts_ProbeModelRecordsItsCap(t *testing.T) {
	dir := t.TempDir()
	writeToken(t, dir, "capped@example.com")
	seven := time.Now().UTC().Add(72 * time.Hour).Truncate(time.Minute)
	var seen []string
	srv := fableServer(t, &seen, seven, "1.0", true)
	a := agentWithAccounts(t, dir, srv.URL)
	a.cfg.ProbeModels = []string{"claude-fable-5-1", "claude-opus-5-5"}

	got := a.probeAccounts(context.Background(), map[string]bool{})
	if len(got) != 1 {
		t.Fatalf("got %d readings, want 1", len(got))
	}
	if len(seen) != 2 || seen[0] != "claude-fable-5-1" || seen[1] != "claude-opus-5-5" {
		t.Errorf("probed %v, want one request per probe model and no default probe", seen)
	}
	snap := got[0]
	if snap.SevenDay.Utilization != 80 {
		t.Errorf("seven-day = %v, want 80 from the model probe", snap.SevenDay.Utilization)
	}
	if len(snap.ModelClaims) != 1 {
		t.Fatalf("model claims = %+v, want only fable's 7d_oi (opus carries none)", snap.ModelClaims)
	}
	if c := snap.ModelClaims[0]; c.Model != "claude-fable-5-1" || c.Claim != "7d_oi" || c.Utilization != 100 || c.Status != "rejected" {
		t.Errorf("claim = %+v", c)
	}
}

// A free source covering the account this cycle normally makes the probe's
// reading redundant — but not when it carries a cap no free source can see.
func TestProbeAccounts_ACapSurvivesAnObservedAccount(t *testing.T) {
	dir := t.TempDir()
	writeToken(t, dir, "busy@example.com")
	seven := time.Now().UTC().Add(72 * time.Hour).Truncate(time.Minute)
	var seen []string
	srv := fableServer(t, &seen, seven, "0.09", false)
	a := agentWithAccounts(t, dir, srv.URL)
	a.cfg.ProbeModels = []string{"claude-fable-5-1"}

	observed := map[string]bool{sessions.FingerprintFor(&seven): true}
	got := a.probeAccounts(context.Background(), observed)
	if len(got) != 1 || len(got[0].ModelClaims) != 1 || got[0].ModelClaims[0].Utilization != 9 {
		t.Fatalf("readings = %+v, want the fable cap at 9%% kept", got)
	}
}

// A mistyped probe model costs the per-model cap, never the account reading.
func TestProbeAccounts_BadProbeModelFallsBackToTheDefaultProbe(t *testing.T) {
	dir := t.TempDir()
	writeToken(t, dir, "acct@example.com")
	seven := time.Now().UTC().Add(72 * time.Hour).Truncate(time.Minute)
	var seen []string
	srv := fableServer(t, &seen, seven, "0.09", false)
	a := agentWithAccounts(t, dir, srv.URL)
	a.cfg.ProbeModels = []string{"no-such-model"}

	got := a.probeAccounts(context.Background(), map[string]bool{})
	if len(got) != 1 || got[0].SevenDay.Utilization != 80 {
		t.Fatalf("readings = %+v, want the default probe's account reading", got)
	}
	if len(seen) != 2 || seen[1] == "no-such-model" {
		t.Errorf("probed %v, want the bad model then the default", seen)
	}
}
