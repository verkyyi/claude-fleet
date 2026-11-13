package store

import (
	"context"
	"strings"
	"sync"
	"testing"
	"time"
)

// A fresh store is ready; one behind this build's migrations is not; one
// AHEAD of it (an old replica mid-rollout, after the new image migrated) is.
func TestReadyFollowsTheMigrations(t *testing.T) {
	s := newStore(t)
	ctx := context.Background()
	if err := s.Ready(ctx); err != nil {
		t.Fatalf("a fresh store: %v", err)
	}
	if _, err := s.write.Exec(`DELETE FROM hub_migrations`); err != nil {
		t.Fatal(err)
	}
	if err := s.Ready(ctx); err == nil || !strings.Contains(err.Error(), "needs") {
		t.Fatalf("a store behind the build: %v, want not ready", err)
	}
	if _, err := s.write.Exec(`INSERT INTO hub_migrations (id, name, applied_at, detail) VALUES (?, 'from-a-newer-build', ?, '{}')`,
		LatestMigration()+1, fmtTime(time.Now())); err != nil {
		t.Fatal(err)
	}
	if err := s.Ready(ctx); err != nil {
		t.Fatalf("a store ahead of the build: %v, want ready", err)
	}
	s.Close()
	if err := s.Ready(ctx); err == nil {
		t.Fatal("a closed database reads ready")
	}
}

// Probes that ask at once share one check and all read ready (task N9GH:
// kubelet, the deploy probe and the health prober overlapped, and every one
// but the first got a 503 for the others' check).
func TestReadyConcurrentProbesShareOneCheck(t *testing.T) {
	s := newStore(t)
	var wg sync.WaitGroup
	errs := make(chan error, 32)
	for i := 0; i < 32; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
			defer cancel()
			errs <- s.Ready(ctx)
		}()
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		if err != nil {
			t.Fatalf("a concurrent probe on a healthy store: %v", err)
		}
	}
}

// The probe's write is one row, overwritten.
func TestTouchDeployProbeIsOneRow(t *testing.T) {
	s := newStore(t)
	ctx := context.Background()
	t0 := time.Date(2026, 10, 7, 0, 0, 0, 0, time.UTC)
	for i := 0; i < 3; i++ {
		if err := s.TouchDeployProbe(ctx, t0.Add(time.Duration(i)*time.Second), "hub-a"); err != nil {
			t.Fatal(err)
		}
	}
	var n int
	var v string
	if err := s.read.QueryRow(`SELECT COUNT(*), MAX(value) FROM rollup_meta WHERE key = ?`, deployProbeKey).Scan(&n, &v); err != nil {
		t.Fatal(err)
	}
	if n != 1 || v != "2026-10-07T00:00:02Z hub-a" {
		t.Fatalf("deploy_probe rows = %d, value %q", n, v)
	}
}
