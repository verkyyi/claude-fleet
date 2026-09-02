package api

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/verkyyi/ccquota/internal/model"
)

// The findings envelope must match the rest of the rollup-backed endpoints
// (handleSummary, handleLimitsHistory, MCP usage_history): account_uuid,
// all_accounts, and the ALIGNED window actually queried -- not the raw query
// string, and not a bare array. "now" has no period to align, so since/until
// must be omitted entirely rather than echoing a fake window.
type findingsEnvelope struct {
	AccountUUID string           `json:"account_uuid"`
	AllAccounts bool             `json:"all_accounts"`
	Since       *time.Time       `json:"since"`
	Until       *time.Time       `json:"until"`
	View        string           `json:"view"`
	Findings    []findingSummary `json:"findings"`
}

type findingSummary struct{ Kind, Severity string }

func TestFindingsReviewAndNow(t *testing.T) {
	h := newHarness(t)
	seedReviewHarness(t, h)

	// since/until are deliberately NOT hour-aligned here (12:15, 14:45) to
	// prove the response echoes the ALIGNED window s.scope() actually queried
	// (12:00-15:00), not the raw query string.
	var review findingsEnvelope
	h.getJSON(t, "/v1/findings?account=all&since=2026-08-31T12:15:00Z&until=2026-08-31T14:45:00Z", &review)
	if review.View != "review" {
		t.Errorf("view = %q, want %q", review.View, "review")
	}
	if review.AccountUUID != "*" || !review.AllAccounts {
		t.Errorf("account_uuid=%q all_accounts=%v, want *,true for account=all", review.AccountUUID, review.AllAccounts)
	}
	wantSince := time.Date(2026, 8, 31, 12, 0, 0, 0, time.UTC)
	wantUntil := time.Date(2026, 8, 31, 15, 0, 0, 0, time.UTC)
	if review.Since == nil || !review.Since.Equal(wantSince) {
		t.Errorf("since = %v, want the widened %v (not the raw 12:15 query)", review.Since, wantSince)
	}
	if review.Until == nil || !review.Until.Equal(wantUntil) {
		t.Errorf("until = %v, want the widened %v (not the raw 14:45 query)", review.Until, wantUntil)
	}
	// s-small's one turn is unpriced (cost nil) -> unpriced_model must fire; nothing else has data
	if len(review.Findings) != 1 || review.Findings[0].Kind != "unpriced_model" {
		t.Fatalf("%+v", review.Findings)
	}

	// Now: the endpoint last reported at ingest (seconds ago) -> not stale; no windows, no live -> empty.
	// since/until must be ABSENT from the JSON entirely, not merely null --
	// checked against the raw bytes, since a missing key and an explicit null
	// both unmarshal to a nil *time.Time.
	_, rawNow := h.get(t, "/v1/findings?account=all&view=now")
	var nowRaw map[string]json.RawMessage
	if err := json.Unmarshal(rawNow, &nowRaw); err != nil {
		t.Fatal(err)
	}
	if _, present := nowRaw["since"]; present {
		t.Errorf("view=now must omit \"since\" entirely, got %s", rawNow)
	}
	if _, present := nowRaw["until"]; present {
		t.Errorf("view=now must omit \"until\" entirely, got %s", rawNow)
	}

	var now findingsEnvelope
	h.getJSON(t, "/v1/findings?account=all&view=now", &now)
	if now.View != "now" {
		t.Errorf("view = %q, want %q", now.View, "now")
	}
	if now.AccountUUID != "*" || !now.AllAccounts {
		t.Errorf("account_uuid=%q all_accounts=%v, want *,true for account=all", now.AccountUUID, now.AllAccounts)
	}
	if len(now.Findings) != 0 {
		t.Fatalf("%+v", now.Findings)
	}
	// make the endpoint stale
	old := time.Now().Add(-3 * time.Hour)
	if _, err := h.srv.Store.DB().Exec(`UPDATE endpoints SET last_seen = ?`, old.UTC().Format(time.RFC3339Nano)); err != nil {
		t.Fatal(err)
	}
	h.getJSON(t, "/v1/findings?account=all&view=now", &now)
	if len(now.Findings) != 1 || now.Findings[0].Kind != "stale_agent" {
		t.Fatalf("%+v", now.Findings)
	}
	_ = model.Batch{}
}
