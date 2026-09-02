package api

import (
	"testing"
	"time"

	"github.com/verkyyi/ccquota/internal/model"
)

func TestFindingsReviewAndNow(t *testing.T) {
	h := newHarness(t)
	seedReviewHarness(t, h)
	var review []struct{ Kind, Severity string }
	h.getJSON(t, "/v1/findings?account=all&since=2026-08-31T12:00:00Z&until=2026-08-31T15:00:00Z", &review)
	// s-small's one turn is unpriced (cost nil) -> unpriced_model must fire; nothing else has data
	if len(review) != 1 || review[0].Kind != "unpriced_model" {
		t.Fatalf("%+v", review)
	}
	// Now: the endpoint last reported at ingest (seconds ago) -> not stale; no windows, no live -> empty
	var now []struct{ Kind string }
	h.getJSON(t, "/v1/findings?account=all&view=now", &now)
	if len(now) != 0 {
		t.Fatalf("%+v", now)
	}
	// make the endpoint stale
	old := time.Now().Add(-3 * time.Hour)
	if _, err := h.srv.Store.DB().Exec(`UPDATE endpoints SET last_seen = ?`, old.UTC().Format(time.RFC3339Nano)); err != nil {
		t.Fatal(err)
	}
	h.getJSON(t, "/v1/findings?account=all&view=now", &now)
	if len(now) != 1 || now[0].Kind != "stale_agent" {
		t.Fatalf("%+v", now)
	}
	_ = model.Batch{}
}
