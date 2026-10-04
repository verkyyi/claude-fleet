package store

import (
	"testing"
	"time"

	"github.com/verkyyi/ccquota/internal/model"
)

func TestPricingCoverageExplainsPrunedRequestsAndRespectsScope(t *testing.T) {
	s := newStore(t)
	at := time.Date(2026, 9, 1, 12, 0, 0, 0, time.UTC)
	cost := 1.0
	events := []model.UsageEvent{
		{MessageUUID: "priced", Source: "codex", AccountUUID: "a", EndpointID: "ep", SessionID: "s", TS: at, Model: "priced", InputTokens: 1000000, CostUSD: &cost},
		{MessageUUID: "missing-write", Source: "codex", AccountUUID: "a", EndpointID: "ep", SessionID: "s", TS: at, Model: "sol", InputTokens: 1, Details: &model.UsageDetails{PriceBasis: "unpriced: cache-write breakdown unavailable"}},
		{MessageUUID: "pruned", Source: "codex", AccountUUID: "a", EndpointID: "ep", SessionID: "s", TS: at, Model: "spark", InputTokens: 1},
		{MessageUUID: "other-source", Source: "claude", AccountUUID: "b", EndpointID: "ep", SessionID: "s2", TS: at, Model: "other", InputTokens: 100},
	}
	if _, _, err := s.InsertEvents(events); err != nil {
		t.Fatal(err)
	}
	if _, err := s.write.Exec(`DELETE FROM usage_events WHERE message_uuid='pruned'`); err != nil {
		t.Fatal(err)
	}
	f := Filter{Account: "a", Source: "codex", Start: at, End: at.Add(time.Hour)}
	sum, reasons, err := s.SummaryWithPricing(f)
	if err != nil {
		t.Fatal(err)
	}
	if sum.Events != 3 || sum.Unpriced != 2 || sum.Tokens != 1000002 || len(reasons) != 2 {
		t.Fatalf("wrong scoped totals/explanations: %+v %+v", sum, reasons)
	}
	var explained int64
	for _, r := range reasons {
		explained += r.Events
		if r.Source != "codex" {
			t.Fatal("cross-source reason")
		}
		if r.Model == "spark" && r.Reason != "Historical request details no longer retained" {
			t.Fatal("invented pruned reason")
		}
	}
	if explained != sum.Unpriced {
		t.Fatal("explanation does not cover denominator")
	}
	f.Model = "priced"
	sum, reasons, err = s.SummaryWithPricing(f)
	if err != nil || sum.Events != 1 || sum.Unpriced != 0 || len(reasons) != 0 {
		t.Fatal("model scope ignored", err)
	}
}
