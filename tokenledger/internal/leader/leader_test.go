package leader

import (
	"context"
	"database/sql"
	"fmt"
	"os"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	_ "github.com/jackc/pgx/v5/stdlib"
)

// The Postgres half needs CCQUOTA_DB_URL (the tokenledger-pg CI job sets it);
// without it only the single-hub half runs.
func pgURL(t *testing.T) string {
	t.Helper()
	u := os.Getenv("CCQUOTA_DB_URL")
	if u == "" {
		t.Skip("CCQUOTA_DB_URL unset: the two-replica tests need Postgres")
	}
	return u
}

func elector(t *testing.T, url, name string) *Elector {
	t.Helper()
	e, err := New(url, name)
	if err != nil {
		t.Fatal(err)
	}
	e.logf = t.Logf
	t.Cleanup(func() { e.Close() })
	return e
}

// A single hub (SQLite) leads everything and its Lock never waits: the
// degenerate case is exactly the hub before #2123.
func TestSingleHubAlwaysLeads(t *testing.T) {
	for _, e := range []*Elector{nil, elector(t, "", "solo")} {
		for _, job := range []string{"alerts", "prune", "spot"} {
			if !e.Leader(context.Background(), job) {
				t.Fatalf("single hub: Leader(%q) = false", job)
			}
		}
		unlock, err := e.Lock(context.Background(), "cred:x")
		if err != nil {
			t.Fatal(err)
		}
		unlock()
		if e.Elected() {
			t.Fatal("single hub reports Elected")
		}
	}
}

func TestReplicaName(t *testing.T) {
	t.Setenv("CCQUOTA_REPLICA", "")
	t.Setenv("HOSTNAME", "ccquota-7d9f-abc")
	if got := Replica(); got != "ccquota-7d9f-abc" {
		t.Fatalf("Replica() = %q, want the pod name", got)
	}
	t.Setenv("CCQUOTA_REPLICA", "hub-a")
	if got := Replica(); got != "hub-a" {
		t.Fatalf("Replica() = %q, want CCQUOTA_REPLICA", got)
	}
}

// terminate ends every database session e holds, the way a killed process or a
// cut network does: nothing on e's side runs to release anything.
func terminate(t *testing.T, url string, e *Elector) {
	t.Helper()
	admin, err := sql.Open("pgx", url)
	if err != nil {
		t.Fatal(err)
	}
	defer admin.Close()
	e.mu.Lock()
	var pids []int
	for _, c := range e.jobs {
		if c == nil {
			continue
		}
		var pid int
		if err := c.QueryRowContext(context.Background(), `SELECT pg_backend_pid()`).Scan(&pid); err == nil {
			pids = append(pids, pid)
		}
	}
	e.mu.Unlock()
	for _, pid := range pids {
		if _, err := admin.Exec(`SELECT pg_terminate_backend($1)`, pid); err != nil {
			t.Fatal(err)
		}
	}
}

var jobs = []string{"prune", "alerts", "spot"}

// Two replicas on one Postgres for an hour of 15 s ticks (accelerated clock):
// every job runs on exactly one replica at every tick; halfway the leader dies
// without a word and the other one takes every job within 15 s of real time.
func TestTwoReplicasOneRunner(t *testing.T) {
	url := pgURL(t)
	a, b := elector(t, url, "hub-a"), elector(t, url, "hub-b")
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go b.Run(ctx)

	const tick = 15 * time.Second
	const ticks = int(time.Hour / tick)
	clock := time.Date(2026, 10, 7, 0, 0, 0, 0, time.UTC)
	runs := map[string]map[string]int{} // job → replica → ticks run
	var log []string
	dead := false
	var killedAt, tookAt time.Time
	for i := 0; i < ticks; i++ {
		now := clock.Add(time.Duration(i) * tick)
		if i == ticks/2 {
			terminate(t, url, a)
			dead, killedAt = true, time.Now()
			// b's own Run takes over: no tick drives it.
			deadline := time.Now().Add(15 * time.Second)
			for {
				b.mu.Lock()
				all := true
				for _, j := range jobs {
					all = all && b.jobs[j] != nil
				}
				b.mu.Unlock()
				if all {
					tookAt = time.Now()
					break
				}
				if time.Now().After(deadline) {
					t.Fatalf("hub-b did not take every job within 15 s of hub-a dying")
				}
				time.Sleep(50 * time.Millisecond)
			}
		}
		for _, j := range jobs {
			var who []string
			if !dead && a.Leader(ctx, j) {
				who = append(who, a.Name())
			}
			if b.Leader(ctx, j) {
				who = append(who, b.Name())
			}
			if len(who) != 1 {
				t.Fatalf("%s tick %d %s: run by %v, want exactly one replica", now.Format(time.TimeOnly), i, j, who)
			}
			if runs[j] == nil {
				runs[j] = map[string]int{}
			}
			runs[j][who[0]]++
			if i == 0 || i == ticks/2 || i == ticks-1 {
				log = append(log, fmt.Sprintf("%s %-6s replica=%s", now.Format(time.TimeOnly), j, who[0]))
			}
		}
	}
	for _, l := range log {
		t.Logf("run: %s", l)
	}
	for _, j := range jobs {
		var parts []string
		for r, n := range runs[j] {
			parts = append(parts, fmt.Sprintf("%s=%d", r, n))
		}
		sort.Strings(parts)
		t.Logf("job %-6s ticks by replica: %s (of %d)", j, strings.Join(parts, " "), ticks)
		if runs[j]["hub-a"]+runs[j]["hub-b"] != ticks {
			t.Fatalf("job %s ran %v times, want %d", j, runs[j], ticks)
		}
	}
	h := tookAt.Sub(killedAt)
	t.Logf("handover: hub-a killed %s, hub-b took every job %s (%s)",
		killedAt.UTC().Format(time.RFC3339Nano), tookAt.UTC().Format(time.RFC3339Nano), h.Round(time.Millisecond))
	if h > 15*time.Second {
		t.Fatalf("handover took %s, want ≤ 15 s", h)
	}
}

// A clean stop hands over at once: the next Leader on the other replica wins.
func TestCloseHandsOver(t *testing.T) {
	url := pgURL(t)
	a, b := elector(t, url, "hub-a"), elector(t, url, "hub-b")
	ctx := context.Background()
	if !a.Leader(ctx, "alerts") || b.Leader(ctx, "alerts") {
		t.Fatal("want hub-a leading alerts, hub-b not")
	}
	a.Close()
	if !b.Leader(ctx, "alerts") {
		t.Fatal("hub-b did not take alerts after hub-a closed")
	}
}

// Lock serialises a critical section across replicas: two replicas × 8
// goroutines never overlap.
func TestLockAcrossReplicas(t *testing.T) {
	url := pgURL(t)
	es := []*Elector{elector(t, url, "hub-a"), elector(t, url, "hub-b")}
	var inside, overlaps atomic.Int32
	var wg sync.WaitGroup
	for i := 0; i < 16; i++ {
		wg.Add(1)
		go func(e *Elector) {
			defer wg.Done()
			unlock, err := e.Lock(context.Background(), "cred:p1/claude/main")
			if err != nil {
				t.Error(err)
				return
			}
			if inside.Add(1) > 1 {
				overlaps.Add(1)
			}
			time.Sleep(5 * time.Millisecond)
			inside.Add(-1)
			unlock()
		}(es[i%2])
	}
	wg.Wait()
	if overlaps.Load() != 0 {
		t.Fatalf("%d overlapping holders of one lock", overlaps.Load())
	}
}
