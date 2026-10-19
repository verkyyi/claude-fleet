package limits

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func hdr(kv map[string]string) http.Header {
	h := http.Header{}
	for k, v := range kv {
		h.Set(k, v)
	}
	return h
}

// The 100x bug, pinned.
//
// The endpoint's `utilization` is 0-100; the header's is 0-1, and nothing in
// either says so. Measured side by side on one account at one moment: the
// endpoint reported 18.0 and 4.0, the headers 0.17 and 0.04. Storing the header
// raw would show 0.17% for a subscription at 17%, and every gauge would read
// "healthy" right up to the moment work started being refused.
func TestSnapshotFromHeaders_ConvertsFractionToPercentage(t *testing.T) {
	snap := SnapshotFromHeaders(hdr(map[string]string{
		"anthropic-ratelimit-unified-5h-utilization": "0.17",
		"anthropic-ratelimit-unified-5h-reset":       "1788325200",
		"anthropic-ratelimit-unified-7d-utilization": "0.04",
		"anthropic-ratelimit-unified-7d-reset":       "1788674400",
	}))
	if snap == nil {
		t.Fatal("no snapshot from complete headers")
	}
	if got := snap.FiveHour.Utilization; got < 16.9 || got > 17.1 {
		t.Errorf("five-hour = %v%%, want ~17 — the header fraction was not scaled", got)
	}
	if got := snap.SevenDay.Utilization; got < 3.9 || got > 4.1 {
		t.Errorf("seven-day = %v%%, want ~4", got)
	}
	if snap.SevenDay.ResetsAt == nil {
		t.Fatal("no seven-day reset; the account cannot be fingerprinted without it")
	}
	if want := time.Unix(1788674400, 0).UTC(); !snap.SevenDay.ResetsAt.Equal(want) {
		t.Errorf("seven-day reset = %v, want %v", snap.SevenDay.ResetsAt, want)
	}
}

// A near-full window must read as near-full. This is the assertion that would
// have caught the unit bug in production rather than in a unit test.
func TestSnapshotFromHeaders_AFullWindowReadsAsFull(t *testing.T) {
	snap := SnapshotFromHeaders(hdr(map[string]string{
		"anthropic-ratelimit-unified-5h-utilization": "0.99",
		"anthropic-ratelimit-unified-7d-utilization": "0.97",
	}))
	if snap == nil {
		t.Fatal("no snapshot")
	}
	if snap.FiveHour.Utilization < 90 {
		t.Errorf("a 99%% window reads as %v%% — a gauge would call this healthy",
			snap.FiveHour.Utilization)
	}
}

// An API-key token has invoices, not windows. Reporting it as a plan at 0%
// would claim quota that does not exist.
func TestSnapshotFromHeaders_NoRateLimitHeadersIsUnknownNotZero(t *testing.T) {
	if snap := SnapshotFromHeaders(hdr(map[string]string{"content-type": "application/json"})); snap != nil {
		t.Errorf("headers with no rate limits produced a snapshot: %+v", snap)
	}
}

// One window present is still worth having; the other must not be invented.
func TestSnapshotFromHeaders_PartialHeaders(t *testing.T) {
	snap := SnapshotFromHeaders(hdr(map[string]string{
		"anthropic-ratelimit-unified-7d-utilization": "0.25",
	}))
	if snap == nil {
		t.Fatal("a seven-day-only reading was discarded")
	}
	if snap.SevenDay.Utilization != 25 {
		t.Errorf("seven-day = %v, want 25", snap.SevenDay.Utilization)
	}
	if snap.FiveHour.ResetsAt != nil {
		t.Error("a five-hour reset was invented from absent headers")
	}
}

// Garbage must not become a confident zero.
func TestSnapshotFromHeaders_UnparseableValueIsNotZero(t *testing.T) {
	snap := SnapshotFromHeaders(hdr(map[string]string{
		"anthropic-ratelimit-unified-5h-utilization": "not-a-number",
	}))
	if snap != nil {
		t.Errorf("an unparseable utilization produced %+v", snap)
	}
}

// The Fable cap, as probed 2026-09-23: an extra "7d_oi" window that only a
// request for the capped model carries. It is keyed by the model asked for,
// scaled like every other window, and the account-wide 5h/7d are NOT repeated
// as per-model claims.
func TestModelClaimsFromHeaders_RecordsEveryNonAccountClaim(t *testing.T) {
	at := time.Unix(1790000000, 0).UTC()
	claims := ModelClaimsFromHeaders(hdr(map[string]string{
		"anthropic-ratelimit-unified-5h-utilization":             "0.10",
		"anthropic-ratelimit-unified-7d-utilization":             "0.80",
		"anthropic-ratelimit-unified-7d_oi-utilization":          "1.0",
		"anthropic-ratelimit-unified-7d_oi-reset":                "1790618400",
		"anthropic-ratelimit-unified-7d_oi-status":               "rejected",
		"anthropic-ratelimit-unified-7d_oi-surpassed-threshold":  "1.0",
		"anthropic-ratelimit-unified-representative-claim":       "seven_day_overage_included",
		"anthropic-ratelimit-unified-some_new_claim-utilization": "0.5",
	}), "claude-fable-5-1", at)

	if len(claims) != 2 {
		t.Fatalf("got %d claims, want 2 (7d_oi and the unknown one): %+v", len(claims), claims)
	}
	oi := claims[0]
	if oi.Claim != "7d_oi" || oi.Model != "claude-fable-5-1" {
		t.Fatalf("first claim = %s/%s, want claude-fable-5-1/7d_oi", oi.Model, oi.Claim)
	}
	if oi.Utilization != 100 || oi.Status != "rejected" || !oi.ObservedAt.Equal(at) {
		t.Errorf("7d_oi = %+v, want 100%% rejected", oi)
	}
	if oi.ResetsAt == nil || !oi.ResetsAt.Equal(time.Unix(1790618400, 0).UTC()) {
		t.Errorf("7d_oi reset = %v", oi.ResetsAt)
	}
	if oi.SurpassedThreshold == nil || *oi.SurpassedThreshold != 1 {
		t.Errorf("surpassed threshold = %v, want 1", oi.SurpassedThreshold)
	}
	// A claim nobody has seen before still comes through — the header is
	// undocumented, and a rename must not make the cap invisible.
	if claims[1].Claim != "some_new_claim" || claims[1].Utilization != 50 {
		t.Errorf("unknown claim = %+v", claims[1])
	}
}

// The same request on a non-capped model carries only the account windows.
func TestModelClaimsFromHeaders_NoneOnAnUncappedModel(t *testing.T) {
	claims := ModelClaimsFromHeaders(hdr(map[string]string{
		"anthropic-ratelimit-unified-5h-utilization": "0.10",
		"anthropic-ratelimit-unified-7d-utilization": "0.80",
	}), "claude-opus-5-5", time.Now())
	if len(claims) != 0 {
		t.Errorf("an uncapped model produced claims: %+v", claims)
	}
}

// A capped account answers the probe with a 429. That is the reading, not a
// failure: it carries every header, and nothing was generated.
func TestFetchForModel_A429WithHeadersIsAReading(t *testing.T) {
	var gotModel string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req struct{ Model string }
		_ = json.NewDecoder(r.Body).Decode(&req)
		gotModel = req.Model
		w.Header().Set("anthropic-ratelimit-unified-5h-utilization", "0.2")
		w.Header().Set("anthropic-ratelimit-unified-7d-utilization", "0.8")
		w.Header().Set("anthropic-ratelimit-unified-7d-reset", "1790000000")
		w.Header().Set("anthropic-ratelimit-unified-7d_oi-utilization", "1.0")
		w.Header().Set("anthropic-ratelimit-unified-7d_oi-status", "rejected")
		w.WriteHeader(http.StatusTooManyRequests)
	}))
	defer srv.Close()
	SetMessagesEndpointForTest(srv.URL)
	defer SetMessagesEndpointForTest("")

	snap, err := New().FetchForModel(context.Background(), "tok", "claude-fable-5-1")
	if err != nil {
		t.Fatalf("a 429 with headers failed: %v", err)
	}
	if gotModel != "claude-fable-5-1" {
		t.Errorf("probed %q, want the configured model", gotModel)
	}
	if snap.SevenDay.Utilization != 80 {
		t.Errorf("seven-day = %v, want 80", snap.SevenDay.Utilization)
	}
	if len(snap.ModelClaims) != 1 || snap.ModelClaims[0].Status != "rejected" {
		t.Errorf("model claims = %+v", snap.ModelClaims)
	}
}

// A 429 WITHOUT the unified headers is an ordinary rate limit, and says nothing
// about the account — it must stay unknown.
func TestFetchForModel_A429WithoutHeadersIsUnavailable(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusTooManyRequests)
	}))
	defer srv.Close()
	SetMessagesEndpointForTest(srv.URL)
	defer SetMessagesEndpointForTest("")

	if _, err := New().FetchForModel(context.Background(), "tok", "claude-fable-5-1"); !errors.Is(err, ErrUnavailable) {
		t.Errorf("err = %v, want ErrUnavailable", err)
	}
}
