package store

import (
	"path/filepath"
	"reflect"
	"testing"
	"time"
)

func poolStore(t *testing.T) *Store {
	t.Helper()
	s, err := Open(filepath.Join(t.TempDir(), "pool.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.Close() })
	if err := s.EnsureNodes(); err != nil {
		t.Fatal(err)
	}
	return s
}

// The budget's 5h / week sums read pool_usage now (claude-fleet#3226): on the
// same batch of requests they equal what the ten-minute bucket table summed,
// bucket for bucket — a person's limit neither tightens nor loosens on the
// switch.
func TestPersonUsageSinceMatchesTheOldBuckets(t *testing.T) {
	s := poolStore(t)
	now := time.Date(2026, 10, 11, 12, 0, 0, 0, time.UTC)
	type req struct {
		who, provider   string
		in, cw, cr, out int64
		ago             time.Duration
	}
	batch := []req{
		{"gh:1", "claude", 100, 5, 9000, 50, time.Minute},
		// the next two share the first one's bucket, the second on another provider
		{"gh:1", "claude", 10, 0, 0, 7, 3 * time.Minute},
		{"gh:1", "codex", 20, 0, 80, 30, 4 * time.Minute},
		{"gh:1", "claude", 1, 2, 3, 4, 4*time.Hour + 55*time.Minute},
		{"gh:1", "claude", 500, 0, 0, 500, 6 * time.Hour},
		{"gh:2", "claude", 7000, 0, 0, 1000, 2 * time.Hour},
		{"gh:1", "claude", 99, 0, 0, 1, 6*24*time.Hour + 23*time.Hour},
		// outside the week
		{"gh:1", "claude", 99, 0, 0, 1, 9 * 24 * time.Hour},
	}
	for _, r := range batch {
		at := now.Add(-r.ago)
		// the old road, verbatim: one bucket row per (person, provider, 10 min)
		if _, err := s.write.Exec(`INSERT INTO fleet_person_usage (principal, provider, bucket, tokens, requests)
			VALUES (?, ?, ?, ?, ?) ON CONFLICT (principal, provider, bucket) DO UPDATE SET
			tokens = fleet_person_usage.tokens + excluded.tokens,
			requests = fleet_person_usage.requests + excluded.requests`,
			r.who, r.provider, personBucket(at), r.in+r.cw+r.out, 1); err != nil {
			t.Fatal(err)
		}
		if err := s.AddPoolUsage(PoolUsage{Principal: r.who, Provider: r.provider, In: r.in, CacheWrite: r.cw,
			CacheRead: r.cr, Out: r.out, At: at}); err != nil {
			t.Fatal(err)
		}
	}
	old := func(principal string, since time.Time) []PersonUsageRow {
		q := `SELECT principal, bucket, SUM(tokens), SUM(requests) FROM fleet_person_usage WHERE bucket >= ?`
		args := []any{personBucket(since)}
		if principal != "" {
			q += ` AND principal = ?`
			args = append(args, principal)
		}
		rows, err := s.write.Query(q+` GROUP BY principal, bucket ORDER BY principal, bucket`, args...)
		if err != nil {
			t.Fatal(err)
		}
		defer rows.Close()
		var out []PersonUsageRow
		for rows.Next() {
			var r PersonUsageRow
			if err := rows.Scan(&r.Principal, &r.Bucket, &r.Tokens, &r.Requests); err != nil {
				t.Fatal(err)
			}
			out = append(out, r)
		}
		return out
	}
	for _, who := range []string{"", "gh:1", "gh:2"} {
		for _, win := range []time.Duration{5 * time.Hour, 7 * 24 * time.Hour} {
			want := old(who, now.Add(-win))
			got, err := s.PersonUsageSince(who, now.Add(-win))
			if err != nil {
				t.Fatal(err)
			}
			if !reflect.DeepEqual(got, want) {
				t.Errorf("%q over %v:\n new %+v\n old %+v", who, win, got, want)
			}
		}
	}
}

// PoolUsageFor reads one person's rows in [since, until), oldest first; a
// worker's live lease names its task; an ownerless row is refused.
func TestPoolUsageForAndLease(t *testing.T) {
	s := poolStore(t)
	now := time.Date(2026, 10, 11, 12, 0, 0, 0, time.UTC)
	for i, who := range []string{"gh:1", "gh:2", "gh:1", "gh:1"} {
		if err := s.AddPoolUsage(PoolUsage{Principal: who, WorkerID: "f/w", Provider: "claude", Model: "m",
			In: int64(i + 1), At: now.Add(time.Duration(i) * time.Hour)}); err != nil {
			t.Fatal(err)
		}
	}
	got, err := s.PoolUsageFor("gh:1", now, now.Add(3*time.Hour))
	if err != nil || len(got) != 2 || got[0].In != 1 || got[1].In != 3 || got[0].Requests != 1 || !got[1].At.Equal(now.Add(2*time.Hour)) {
		t.Fatalf("PoolUsageFor = %+v %v", got, err)
	}
	if all, _ := s.PoolUsageFor("", now, time.Time{}); len(all) != 4 {
		t.Fatalf("everyone = %d rows", len(all))
	}
	if err := s.AddPoolUsage(PoolUsage{Provider: "claude", In: 5, At: now}); err != ErrPoolUsageNoPrincipal {
		t.Fatalf("ownerless: %v", err)
	}
	if _, _, ok, err := s.LeaseForWorker("f/w", now); ok || err != nil {
		t.Fatalf("no lease yet: %v %v", ok, err)
	}
	if ok, _, _, err := s.AcquireLease(LeaseClaim{Repo: "Owner/Repo", Issue: 7, WorkerID: "f/w", FleetID: "f", EndpointID: "e"}, time.Hour, now); !ok || err != nil {
		t.Fatalf("acquire: %v %v", ok, err)
	}
	if repo, issue, ok, err := s.LeaseForWorker("f/w", now.Add(time.Minute)); !ok || err != nil || repo != "owner/repo" || issue != 7 {
		t.Fatalf("lease = %q %d %v %v", repo, issue, ok, err)
	}
	if _, _, ok, _ := s.LeaseForWorker("f/w", now.Add(2*time.Hour)); ok {
		t.Fatal("an expired lease still names a task")
	}
}
