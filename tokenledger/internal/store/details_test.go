package store

import (
	"github.com/verkyyi/ccquota/internal/model"
	"path/filepath"
	"testing"
	"time"
)

func TestCodexEnrichmentPreservesOriginalAttributionAndRollup(t *testing.T) {
	s, err := Open(filepath.Join(t.TempDir(), "hub.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	at := time.Date(2026, 9, 1, 12, 0, 0, 0, time.UTC)
	e := model.UsageEvent{Source: "codex", AccountUUID: "codex:local", EndpointID: "original", MessageUUID: "codex:request", SessionID: "codex:s", Model: "gpt-6-astra", TS: at, InputTokens: 100, CacheRead: 50, OutputTokens: 20}
	if _, _, err := s.InsertEvents([]model.UsageEvent{e}); err != nil {
		t.Fatal(err)
	}
	// Surviving rollup data with no raw counterpart must not be rebuilt.
	if _, err := s.DB().Exec(`INSERT INTO usage_hourly(hour,account_uuid,endpoint_id,source,events,output_tokens,cost_usd,min_ts,max_ts) VALUES('2020-01-01T00:00:00Z','claude-a','old','claude',7,700,8,'2020-01-01T00:00:00Z','2020-01-01T00:00:00Z')`); err != nil {
		t.Fatal(err)
	}
	write := int64(40)
	cost := .005
	e.AccountUUID = "codex:account:new"
	e.EndpointID = "copy"
	e.Details = &model.UsageDetails{Provider: "openai", CacheWrite: &write, AccountBasis: "observed_profile_login"}
	e.CostUSD = &cost
	for i := 0; i < 2; i++ {
		n, d, err := s.InsertEvents([]model.UsageEvent{e})
		if err != nil || n != 0 || d != 1 {
			t.Fatalf("enrichment created request: %d %d %v", n, d, err)
		}
	}
	f := Filter{Account: AllAccounts, Source: "codex", Start: at.Add(-time.Hour), End: at.Add(time.Hour)}
	sum, err := s.Summary(f)
	if err != nil || sum.Events != 1 || sum.Tokens != 170 || sum.Unpriced != 0 || sum.CostUSD != cost || sum.CacheWriteTokens != 40 || sum.CacheWriteKnownEvents != 1 {
		t.Fatalf("bad enriched rollup: %+v %v", sum, err)
	}
	var acct, ep string
	if err := s.DB().QueryRow(`SELECT account_uuid,endpoint_id FROM usage_events`).Scan(&acct, &ep); err != nil || acct != "codex:local" || ep != "original" {
		t.Fatal("historical attribution changed")
	}
	turns, tokens, err := s.LifetimeTotals()
	if err != nil || turns != 8 || tokens != 870 {
		t.Fatalf("pruned history lost: %d %d %v", turns, tokens, err)
	}
	if _, err := s.PruneEvents(at.Add(time.Hour)); err != nil {
		t.Fatal(err)
	}
	if n, d, err := s.InsertEvents([]model.UsageEvent{e}); err != nil || n != 0 || d != 1 {
		t.Fatalf("pruned request resurrected: %d %d %v", n, d, err)
	}
	e.MessageUUID = "codex:pruned-before-upgrade"
	e.EnrichOnly = true
	if n, _, err := s.InsertEvents([]model.UsageEvent{e}); err != nil || n != 0 {
		t.Fatal("old committed prefix was reinserted")
	}
	_, tokens, _ = s.LifetimeTotals()
	if tokens != 870 {
		t.Fatal("replay changed durable tokens")
	}
}
