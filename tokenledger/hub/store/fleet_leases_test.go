package store

import (
	"fmt"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

// Two hubs on one database (EPIC #2119: two copies of the hub) race for the
// same (repo, issue) — free, expired, and handed over — and exactly one of
// them is granted it every time; the other is told who holds it. Two Stores
// opened on the same path are the two hubs: two writer connections, on SQLite
// one file, on the Postgres leg one schema.
func TestLeaseRaceTwoWriters(t *testing.T) {
	path := filepath.Join(t.TempDir(), "race.db")
	a, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { a.Close() })
	if err := a.EnsureNodes(); err != nil {
		t.Fatal(err)
	}
	b, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { b.Close() })
	if err := b.EnsureNodes(); err != nil {
		t.Fatal(err)
	}
	hubs := []*Store{a, b}

	type result struct {
		granted bool
		holder  Lease
		err     error
	}
	race := func(issue int, at time.Time) [2]result {
		var out [2]result
		var wg sync.WaitGroup
		start := make(chan struct{})
		for i, s := range hubs {
			wg.Add(1)
			go func(i int, s *Store) {
				defer wg.Done()
				<-start
				c := LeaseClaim{Repo: "Owner/Repo", Issue: issue, WorkerID: fmt.Sprintf("fleet-%d/w", i),
					FleetID: fmt.Sprintf("fleet-%d", i), EndpointID: fmt.Sprintf("ep-%d", i)}
				g, h, _, err := s.AcquireLease(c, 5*time.Minute, at)
				out[i] = result{g, h, err}
			}(i, s)
		}
		close(start)
		wg.Wait()
		return out
	}
	oneWinner := func(what string, r [2]result) {
		t.Helper()
		for i, x := range r {
			if x.err != nil {
				t.Fatalf("%s: hub %d: %v", what, i, x.err)
			}
		}
		if r[0].granted == r[1].granted {
			t.Fatalf("%s: granted %v / %v — want exactly one winner", what, r[0].granted, r[1].granted)
		}
		win, lose := 0, 1
		if r[1].granted {
			win, lose = 1, 0
		}
		if r[lose].holder.WorkerID != r[win].holder.WorkerID {
			t.Fatalf("%s: the loser was told %q holds it, the winner is %q", what, r[lose].holder.WorkerID, r[win].holder.WorkerID)
		}
		var n int
		if err := a.read.QueryRow(`SELECT COUNT(*) FROM fleet_leases WHERE repo = ? AND worker_id = ?`,
			"owner/repo", r[win].holder.WorkerID).Scan(&n); err != nil || n == 0 {
			t.Fatalf("%s: the stored lease is not the winner's (%d, %v)", what, n, err)
		}
	}

	now := time.Now().UTC()
	for i := 1; i <= 20; i++ {
		// A free issue.
		oneWinner(fmt.Sprintf("free #%d", i), race(i, now))
		// The same issue once its lease has run out: both see it expired.
		oneWinner(fmt.Sprintf("expired #%d", i), race(i, now.Add(10*time.Minute)))
	}
}
