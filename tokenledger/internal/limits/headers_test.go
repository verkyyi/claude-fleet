package limits

import (
	"net/http"
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
