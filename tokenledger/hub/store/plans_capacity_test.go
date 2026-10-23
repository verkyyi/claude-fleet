package store

import (
	"errors"
	"math"
	"sync"
	"testing"
	"time"
)

func testCapacityCatalog() PlanCapacityCatalog {
	return PlanCapacityCatalog{Mode: "shadow", Profiles: []PlanCapacityProfile{{Plan: "pro", Tier: "verified-tier", Pool: "codex", Unit: "reference-work", Basis: "matched workload v1", Source: "https://example.com/verified-capacity", Version: "2026-10", Confidence: "verified", EffectiveFrom: day(2026, 1, 1), Windows: []PlanCapacityWindow{{Minutes: 10080, Units: 10}}}}}
}

func TestPlanCapacityValidation(t *testing.T) {
	for _, tc := range []struct {
		name string
		edit func(*PlanCapacityCatalog)
	}{
		{"negative", func(c *PlanCapacityCatalog) { c.Profiles[0].Windows[0].Units = -1 }},
		{"zero", func(c *PlanCapacityCatalog) { c.Profiles[0].Windows[0].Units = 0 }},
		{"nan", func(c *PlanCapacityCatalog) { c.Profiles[0].Windows[0].Units = math.NaN() }},
		{"infinite", func(c *PlanCapacityCatalog) { c.Profiles[0].Windows[0].Units = math.Inf(1) }},
		{"large", func(c *PlanCapacityCatalog) { c.Profiles[0].Windows[0].Units = 1e10 }},
		{"unknown pool", func(c *PlanCapacityCatalog) { c.Profiles[0].Pool = "model-pool" }},
		{"missing source", func(c *PlanCapacityCatalog) { c.Profiles[0].Source = "" }},
		{"missing version", func(c *PlanCapacityCatalog) { c.Profiles[0].Version = "" }},
		{"missing basis", func(c *PlanCapacityCatalog) { c.Profiles[0].Basis = "" }},
		{"missing time", func(c *PlanCapacityCatalog) { c.Profiles[0].EffectiveFrom = time.Time{} }},
		{"bad confidence", func(c *PlanCapacityCatalog) { c.Profiles[0].Confidence = "automatic" }},
		{"duplicate plan", func(c *PlanCapacityCatalog) { c.Profiles = append(c.Profiles, c.Profiles[0]) }},
		{"duplicate window", func(c *PlanCapacityCatalog) {
			c.Profiles[0].Windows = append(c.Profiles[0].Windows, c.Profiles[0].Windows[0])
		}},
		{"no windows", func(c *PlanCapacityCatalog) { c.Profiles[0].Windows = nil }},
		{"bad duration", func(c *PlanCapacityCatalog) { c.Profiles[0].Windows[0].Minutes = 60 }},
		{"bad mode", func(c *PlanCapacityCatalog) { c.Mode = "priority" }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			c := testCapacityCatalog()
			tc.edit(&c)
			if err := c.Validate(); err == nil {
				t.Fatal("invalid profile accepted")
			}
		})
	}
	for _, units := range []float64{0.000001, 1, 10, 1e9} {
		c := testCapacityCatalog()
		c.Profiles[0].Windows[0].Units = units
		if err := c.Validate(); err != nil {
			t.Fatal(err)
		}
	}
}

func TestPlanCapacityCASHistoryRollback(t *testing.T) {
	s := newStore(t)
	empty, err := s.PlanCapacities()
	if err != nil || empty.Revision != 0 || empty.Catalog.Mode != "off" {
		t.Fatal(empty, err)
	}
	first, err := s.SetPlanCapacities(testCapacityCatalog(), 0, "admin-a", time.Now())
	if err != nil {
		t.Fatal(err)
	}
	var wg sync.WaitGroup
	results := make(chan error, 12)
	for i := 0; i < 12; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_, err := s.SetPlanCapacities(PlanCapacityCatalog{Mode: "off"}, first.Revision, "admin-b", time.Now())
			results <- err
		}()
	}
	wg.Wait()
	close(results)
	successes := 0
	for err := range results {
		if err == nil {
			successes++
		} else if !errors.Is(err, ErrCapacityConflict) {
			t.Fatal(err)
		}
	}
	if successes != 1 {
		t.Fatalf("CAS winners=%d", successes)
	}
	current, err := s.PlanCapacities()
	if err != nil || current.Revision != 2 || current.Catalog.Mode != "off" {
		t.Fatal(current, err)
	}
	restored, err := s.SetPlanCapacities(first.Catalog, current.Revision, "admin-restore", time.Now())
	if err != nil {
		t.Fatal(err)
	}
	history, err := s.PlanCapacityHistory()
	if err != nil || len(history) != 3 || history[0].Actor != "admin-restore" || restored.Catalog.Profiles[0].Source != first.Catalog.Profiles[0].Source {
		t.Fatal(history, err)
	}
}

func TestCodexLiveBindLoads(t *testing.T) {
	s := newStore(t)
	if err := s.EnsureNodes(); err != nil {
		t.Fatal(err)
	}
	now := time.Now()
	for _, worker := range []string{"live", "expired", "revoked", "self", "claude-only"} {
		if _, err := s.SetSessionBind(SessionBind{WorkerID: worker, Provider: "codex", Owner: "pool", Account: "example", SetBy: "auto"}, now); err != nil {
			t.Fatal(err)
		}
		for _, id := range []string{worker + "-1", worker + "-2"} {
			exp := now.Add(time.Hour)
			providers := []string{"codex"}
			if worker == "expired" {
				exp = now.Add(-time.Second)
			}
			if worker == "claude-only" {
				providers = []string{"claude"}
			}
			if err := s.AddSessionCred(SessionCred{ID: id, WorkerID: worker, PrincipalID: "person", Providers: providers, IssuedAt: now.Add(-time.Hour), ExpiresAt: exp}); err != nil {
				t.Fatal(err)
			}
			if worker == "revoked" {
				if _, err := s.RevokeSessionCred(id, "operator", "fixture", now); err != nil {
					t.Fatal(err)
				}
			}
		}
	}
	loads, err := s.CodexLiveBindLoads("self", now)
	if err != nil || loads["pool\x00example"] != 1 {
		t.Fatal(loads, err)
	}
}

func TestPlanCapacitySharedReplica(t *testing.T) {
	a := newStore(t)
	b, err := openStore(a.d, a.src, "capacity-replica")
	if err != nil {
		t.Fatal(err)
	}
	defer b.Close()
	if _, err := a.SetPlanCapacities(testCapacityCatalog(), 0, "admin-a", time.Now()); err != nil {
		t.Fatal(err)
	}
	read, err := b.PlanCapacities()
	if err != nil || read.Revision != 1 || read.Catalog.Profiles[0].Windows[0].Units != 10 {
		t.Fatal(read, err)
	}
	if _, err := b.SetPlanCapacities(PlanCapacityCatalog{Mode: "off"}, 0, "stale-b", time.Now()); !errors.Is(err, ErrCapacityConflict) {
		t.Fatal("stale replica overwrite", err)
	}
}
