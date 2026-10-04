package store

import (
	"path/filepath"
	"testing"
	"time"

	"github.com/verkyyi/ccquota/internal/model"
)

func TestQuotaPoolUpdatesPreserveOtherPoolsAndTheirObservationTime(t *testing.T) {
	s, err := Open(filepath.Join(t.TempDir(), "hub.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	now := time.Now().UTC()
	fullAt := now.Add(-time.Minute)
	full := model.QuotaSnapshot{Source: "codex", AccountUUID: "acct", ObservedAt: fullAt, Observation: "app_server", Plan: "pro", Blocked: true, Reason: "model cap",
		Pools:   []model.QuotaPool{{LimitID: "general"}, {LimitID: "model", Blocked: true, Reason: "model cap"}},
		Windows: []model.QuotaWindow{{ID: "general:primary", LimitID: "general", UsedPercent: 20}, {ID: "model:primary", LimitID: "model", UsedPercent: 100}}}
	if err := s.InsertQuota(full); err != nil {
		t.Fatal(err)
	}
	partial := model.QuotaSnapshot{Source: "codex", AccountUUID: "acct", ObservedAt: now, Observation: "transcript", Pools: []model.QuotaPool{{LimitID: "general"}}, Windows: []model.QuotaWindow{{ID: "general:primary", LimitID: "general", UsedPercent: 30}}}
	if err := s.InsertQuota(partial); err != nil {
		t.Fatal(err)
	}
	q, err := s.LatestQuota("acct")
	if err != nil || len(q.Windows) != 2 || !q.Blocked || q.Plan != "pro" {
		t.Fatalf("other pool lost: %+v %v", q, err)
	}
	for _, w := range q.Windows {
		wantAt, wantPct := now, float64(30)
		if w.LimitID == "model" {
			wantAt, wantPct = fullAt, 100
		}
		if w.ObservedAt == nil || !w.ObservedAt.Equal(wantAt) || w.UsedPercent != wantPct {
			t.Fatalf("pool was restamped or overwritten: %+v", w)
		}
	}
	// A new complete read removes the model pool. An ensuing one-pool log
	// update must not resurrect the model's older block or percentage.
	full.ObservedAt = now.Add(time.Second)
	full.Pools, full.Windows = full.Pools[:1], full.Windows[:1]
	full.Blocked, full.Reason = false, ""
	if err := s.InsertQuota(full); err != nil {
		t.Fatal(err)
	}
	partial.ObservedAt = now.Add(2 * time.Second)
	if err := s.InsertQuota(partial); err != nil {
		t.Fatal(err)
	}
	q, err = s.LatestQuota("acct")
	if err != nil || len(q.Windows) != 1 || q.Blocked {
		t.Fatalf("removed pool resurrected: %+v %v", q, err)
	}
	// Stale pools cannot be refreshed by activity in another pool.
	full.AccountUUID, full.ObservedAt = "stale", now.Add(-11*time.Minute)
	full.Windows[0].LimitID, full.Pools[0].LimitID = "expired", "expired"
	s.InsertQuota(full)
	partial.AccountUUID, partial.ObservedAt = "stale", now
	s.InsertQuota(partial)
	q, err = s.LatestQuota("stale")
	if err != nil || len(q.Windows) != 1 || q.Windows[0].LimitID != "general" {
		t.Fatalf("stale pool became fresh: %+v %v", q, err)
	}
}
