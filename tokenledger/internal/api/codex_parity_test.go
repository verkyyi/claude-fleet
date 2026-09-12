package api

import (
	"github.com/verkyyi/ccquota/internal/model"
	"testing"
	"time"
)

func TestCodexQuotaHealthAndScope(t *testing.T) {
	h := newHarness(t)
	seedReviewHarness(t, h)
	now := time.Now().UTC()
	reset := now.Add(7 * 24 * time.Hour)
	b := model.Batch{Identity: model.Identity{Source: "codex", AccountUUID: "codex:account:test", Hostname: "mac"}, Collector: &model.CollectorStatus{ProfileID: "profile", ObservedAt: now, State: "ok"}, Quotas: []model.QuotaSnapshot{{ObservedAt: now, ProfileID: "profile", Plan: "prolite", Observation: "app_server", Windows: []model.QuotaWindow{{ID: "codex:primary", LimitID: "codex", Minutes: 10080, UsedPercent: 97, ResetsAt: &reset}}}}}
	r := h.push(t, h.tokens["mac"], b)
	r.Body.Close()
	if r.StatusCode != 200 {
		t.Fatal(r.StatusCode)
	}
	var v LimitsAcross
	h.getJSON(t, "/v1/limits?account=all&source=codex", &v)
	if len(v.PerAccount) != 1 || v.PerAccount[0].Limits.FiveHour != nil || len(v.PerAccount[0].Limits.Windows) != 1 || v.PerAccount[0].Limits.Windows[0].Minutes != 10080 {
		t.Fatalf("window coerced or source mixed: %+v", v)
	}
	var wrong LimitsView
	h.getJSON(t, "/v1/limits?account=acct-a&source=codex", &wrong)
	if wrong.Available {
		t.Fatal("cross-source limits available")
	}
	var collectors []model.CollectorStatus
	h.getJSON(t, "/v1/collectors?account=all&source=codex", &collectors)
	if len(collectors) != 1 || collectors[0].AccountUUID != b.Identity.AccountUUID || collectors[0].EndpointID == "" {
		t.Fatal("collector identity not stamped")
	}
	// Replayed older snapshots cannot overwrite current quota or health.
	b.Quotas[0].ObservedAt = now.Add(-time.Hour)
	b.Quotas[0].Windows[0].UsedPercent = 1
	b.Collector.ObservedAt = now.Add(-time.Hour)
	b.Collector.State = "degraded"
	r = h.push(t, h.tokens["mac"], b)
	r.Body.Close()
	q, err := h.srv.LimitsFor(b.Identity.AccountUUID)
	if err != nil || q.Windows[0].Utilization != 97 {
		t.Fatal("older quota became current")
	}
	collectors, _ = h.srv.Store.Collectors("", "codex")
	if collectors[0].State != "ok" {
		t.Fatal("older collector became current")
	}
}

func TestLiveSourceScopeAndLifecycle(t *testing.T) {
	h := newHarness(t)
	seedReviewHarness(t, h)
	now := time.Now().UTC()
	b := model.Batch{Identity: model.Identity{Source: "codex", AccountUUID: "codex:local"}, Events: []model.UsageEvent{{MessageUUID: "codex:r", SessionID: "codex:s", TS: now, OutputTokens: 123}}}
	r := h.push(t, h.tokens["mac"], b)
	r.Body.Close()
	l := h.srv.LiveStore
	l.Report("mac", "mac", []LiveSession{{SessionID: "same", Source: "claude", Account: "acct-a", InputTokens: 999}, {SessionID: "same", Source: "codex", Account: "codex:local", ObservedAt: now, InputTokens: 100, OutputTokens: 20, CostUnknown: true}})
	var v Snapshot
	h.getJSON(t, "/v1/live?source=codex&account=all", &v)
	if v.ActiveSessions != 1 || v.SessionTokens != 120 || v.Counter == nil || v.Counter.Tokens != 123 {
		t.Fatalf("live scope mixed or ledger duplicated: %+v", v)
	}
	l.report("mac", "mac", nil, true)
	if l.Snapshot().ActiveSessions != 0 {
		t.Fatal("completed endpoint snapshot did not clear sessions")
	}
	l.Report("mac", "mac", []LiveSession{{SessionID: "history", Source: "codex", ObservedAt: now.Add(-24 * time.Hour), InputTokens: 900}})
	if l.Snapshot().ActiveSessions != 0 {
		t.Fatal("historical replay resurrected a session")
	}
}

// Codex usage whose session no logged-in profile can claim arrives under the
// pool key. Once the operator has bound the pool, it must land on the real
// account at ingest — otherwise the pool account is re-created on the next
// scan and the history has to be merged by hand again.
func TestIngest_BoundCodexPoolLandsOnTheRealAccount(t *testing.T) {
	h := newHarness(t)
	seedReviewHarness(t, h)
	now := time.Now().UTC()
	real := "codex:account:real"
	if err := h.srv.Store.UpsertAccount(model.Identity{AccountUUID: real, Source: "codex"}, "", ""); err != nil {
		t.Fatal(err)
	}
	if err := h.srv.Store.BindSourcePool("codex", real); err != nil {
		t.Fatal(err)
	}

	b := model.Batch{
		Identity: model.Identity{Source: "codex", AccountUUID: "codex:local", DisplayName: "Codex (local usage)"},
		Events:   []model.UsageEvent{{MessageUUID: "codex:pooled", SessionID: "codex:s", TS: now, OutputTokens: 77}},
	}
	r := h.push(t, h.tokens["mac"], b)
	r.Body.Close()
	if r.StatusCode != 200 {
		t.Fatalf("ingest returned %d", r.StatusCode)
	}

	var pooled, landed int
	if err := h.srv.Store.DB().QueryRow(
		`SELECT COUNT(*) FROM usage_events WHERE account_uuid='codex:local'`).Scan(&pooled); err != nil {
		t.Fatal(err)
	}
	if err := h.srv.Store.DB().QueryRow(
		`SELECT COUNT(*) FROM usage_events WHERE account_uuid=?`, real).Scan(&landed); err != nil {
		t.Fatal(err)
	}
	if pooled != 0 || landed != 1 {
		t.Fatalf("pooled=%d landed=%d, want the turn under the bound account", pooled, landed)
	}
	accts, err := h.srv.Store.ListAccounts()
	if err != nil {
		t.Fatal(err)
	}
	for _, a := range accts {
		if a.AccountUUID == "codex:local" {
			t.Fatal("the pool account was re-created at ingest")
		}
		if a.AccountUUID == real && a.DisplayName == "Codex (local usage)" {
			t.Fatal("the pool's placeholder name overwrote the real account's")
		}
	}
}
